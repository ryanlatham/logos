#!/usr/bin/env python3
"""Live Logos smoke tests against the real Hermes gateway plugin.

This script intentionally does not use scripts/run_stage_f_mock_adapter.py. It
connects to the configured Logos WebSocket endpoint, authenticates with the same
hello HMAC as the iOS client, and exercises the live Hermes gateway path.

It never prints the device secret. Results are emitted as JSON suitable for
pasting into test reports.
"""
from __future__ import annotations

import argparse
import asyncio
import base64
import hashlib
import hmac
import json
import os
import time
import uuid
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Awaitable, Callable

import websockets
import yaml


@dataclass(frozen=True)
class LiveConfig:
    url: str
    secret: str
    device_id: str
    fast_model_provider: str | None
    fast_model_model: str | None
    tts_provider: str | None


def load_config(path: Path, *, device_id: str | None = None, url: str | None = None) -> LiveConfig:
    config = yaml.safe_load(path.expanduser().read_text()) or {}
    logos = ((config.get("platforms") or {}).get("logos") or {})
    extra = logos.get("extra") or {}
    secret = str(os.getenv("LOGOS_DEVICE_SECRET") or extra.get("device_secret") or "").strip()
    if not secret:
        raise SystemExit("Logos device secret missing from LOGOS_DEVICE_SECRET or config platforms.logos.extra.device_secret; refusing unauthenticated smoke")
    host = str(os.getenv("LOGOS_HOST") or extra.get("host") or "127.0.0.1").strip()
    port = int(os.getenv("LOGOS_PORT") or extra.get("port") or 8765)
    return LiveConfig(
        url=url or f"ws://{host}:{port}",
        secret=secret,
        device_id=device_id or "logos-live-smoke-cli",
        fast_model_provider=os.getenv("LOGOS_FAST_MODEL_PROVIDER") or extra.get("fast_model_provider"),
        fast_model_model=os.getenv("LOGOS_FAST_MODEL_MODEL") or extra.get("fast_model_model"),
        tts_provider=os.getenv("LOGOS_TTS_PROVIDER") or extra.get("tts_provider"),
    )


def hello_signature(config: LiveConfig, *, request_id: str, project_key: str | None) -> dict[str, Any]:
    timestamp_ms = int(time.time() * 1000)
    nonce = str(uuid.uuid4())
    canonical = "\n".join([
        "logos-v1",
        config.device_id,
        request_id,
        project_key or "",
        str(timestamp_ms),
        nonce,
    ])
    signature = hmac.new(config.secret.encode("utf-8"), canonical.encode("utf-8"), hashlib.sha256).hexdigest()
    return {"timestamp_ms": timestamp_ms, "nonce": nonce, "signature": signature}


async def send_json(ws: Any, frame: dict[str, Any]) -> None:
    await ws.send(json.dumps(frame, separators=(",", ":")))


async def recv_json(ws: Any, *, timeout: float) -> dict[str, Any]:
    raw = await asyncio.wait_for(ws.recv(), timeout=timeout)
    if isinstance(raw, bytes):
        raw = raw.decode("utf-8", errors="replace")
    return json.loads(raw)


async def open_authenticated(config: LiveConfig, *, project_key: str, timeout: float):
    ws = await websockets.connect(config.url, max_size=12_000_000)
    request_id = "hello-" + uuid.uuid4().hex
    await send_json(ws, {
        "type": "hello",
        "request_id": request_id,
        "device_id": config.device_id,
        "project_key": project_key,
        "payload": {
            **hello_signature(config, request_id=request_id, project_key=project_key),
            "after_server_seq": 0,
        },
    })
    hello = await recv_json(ws, timeout=timeout)
    if not bool((hello.get("payload") or {}).get("authenticated")):
        await ws.close()
        raise RuntimeError(f"hello was not authenticated: {safe_frame_summary(hello)}")
    client_config = (hello.get("payload") or {}).get("client_config") or {}
    stale_timeout = client_config.get("stale_timeout_seconds")
    if not isinstance(stale_timeout, int) or stale_timeout <= 0:
        await ws.close()
        raise RuntimeError(f"hello missing client_config.stale_timeout_seconds: {safe_frame_summary(hello)}")
    await send_json(ws, {
        "type": "register_device",
        "request_id": "register-" + uuid.uuid4().hex,
        "device_id": config.device_id,
        "project_key": project_key,
        "payload": {
            "display_name": "Logos live smoke CLI",
            "capabilities": ["text", "speech", "projects", "approval", "clarification", "playback_audio"],
        },
    })
    return ws, hello


async def wait_for(
    ws: Any,
    predicate: Callable[[dict[str, Any]], bool],
    *,
    timeout: float,
    trace: list[dict[str, Any]],
    label: str,
) -> dict[str, Any]:
    deadline = time.time() + timeout
    while time.time() < deadline:
        frame = await recv_json(ws, timeout=min(20.0, max(0.1, deadline - time.time())))
        trace.append(frame)
        if predicate(frame):
            return frame
    raise TimeoutError(f"timed out waiting for {label}; recent={recent_trace(trace)}")


def payload(frame: dict[str, Any]) -> dict[str, Any]:
    item = frame.get("payload")
    return item if isinstance(item, dict) else {}


def message(frame: dict[str, Any]) -> dict[str, Any]:
    msg = payload(frame).get("message")
    return msg if isinstance(msg, dict) else {}


def recent_trace(trace: list[dict[str, Any]], limit: int = 20) -> list[dict[str, Any]]:
    return [safe_frame_summary(frame) for frame in trace[-limit:]]


def safe_frame_summary(frame: dict[str, Any]) -> dict[str, Any]:
    body = payload(frame)
    summary: dict[str, Any] = {
        "type": frame.get("type"),
        "project_key": frame.get("project_key"),
        "request_id": frame.get("request_id"),
        "op": body.get("op"),
        "status": body.get("status"),
    }
    msg = body.get("message") if isinstance(body.get("message"), dict) else None
    if msg:
        summary["message_role"] = msg.get("role")
        summary["message_id"] = msg.get("message_id")
        summary["message_chars"] = len(str(msg.get("content") or ""))
    if frame.get("type") == "audio_end":
        summary["chunk_count"] = body.get("chunk_count")
        summary["source"] = body.get("source")
    if frame.get("type") in {"approval_request", "clarify_request"}:
        summary["interaction_id"] = body.get("approval_id") or body.get("clarify_id") or frame.get("request_id")
    return {k: v for k, v in summary.items() if v is not None}


async def scenario_text(config: LiveConfig, *, project_key: str, timeout: float) -> dict[str, Any]:
    trace: list[dict[str, Any]] = []
    sentinel = "LOGOS_TEXT_OK_" + uuid.uuid4().hex[:8]
    ws, _ = await open_authenticated(config, project_key=project_key, timeout=timeout)
    async with ws:
        request_id = "text-" + uuid.uuid4().hex
        await send_json(ws, {
            "type": "text_input",
            "request_id": request_id,
            "device_id": config.device_id,
            "project_key": project_key,
            "payload": {
                "text": f"Live Logos text smoke. Reply exactly with {sentinel}.",
                "client_msg_id": "client-" + request_id,
                "is_final": True,
            },
        })
        ack = await wait_for(
            ws,
            lambda f: f.get("type") == "state_update" and payload(f).get("op") == "fast_ack",
            timeout=timeout,
            trace=trace,
            label="fast_ack",
        )
        assistant = await wait_for(
            ws,
            lambda f: message(f).get("role") == "assistant" and sentinel in str(message(f).get("content") or ""),
            timeout=timeout,
            trace=trace,
            label="assistant sentinel",
        )
        return {
            "scenario": "text",
            "project_key": project_key,
            "ok": True,
            "sentinel": sentinel,
            "ack_text": payload(ack).get("ack_text"),
            "fast_model_confidence": (payload(ack).get("fast_model") or {}).get("confidence"),
            "assistant_message_id": message(assistant).get("message_id"),
            "frame_types": [frame.get("type") for frame in trace[:12]],
        }


async def scenario_tts(config: LiveConfig, *, project_key: str, timeout: float) -> dict[str, Any]:
    trace: list[dict[str, Any]] = []
    audio_id = "audio-" + uuid.uuid4().hex
    ws, _ = await open_authenticated(config, project_key=project_key, timeout=timeout)
    async with ws:
        await send_json(ws, {
            "type": "playback_audio",
            "request_id": "tts-" + uuid.uuid4().hex,
            "device_id": config.device_id,
            "project_key": project_key,
            "payload": {
                "audio_id": audio_id,
                "mode": "direct",
                "text": "Logos live speech smoke. This should be intelligible speech.",
            },
        })
        first_chunk = await wait_for(
            ws,
            lambda f: f.get("type") == "audio_chunk" and payload(f).get("audio_id") == audio_id,
            timeout=timeout,
            trace=trace,
            label="audio_chunk",
        )
        audio_prefix = base64.b64decode(str(payload(first_chunk).get("data") or "")[:128] + "===")[:4]
        end = await wait_for(
            ws,
            lambda f: f.get("type") == "audio_end" and payload(f).get("audio_id") == audio_id,
            timeout=timeout,
            trace=trace,
            label="audio_end",
        )
        return {
            "scenario": "tts",
            "project_key": project_key,
            "ok": True,
            "audio_id": audio_id,
            "riff_prefix": audio_prefix == b"RIFF",
            "source": payload(end).get("source"),
            "chunk_count": payload(end).get("chunk_count"),
            "mime_type": payload(end).get("mime_type"),
        }


async def scenario_clarify(config: LiveConfig, *, project_key: str, timeout: float) -> dict[str, Any]:
    trace: list[dict[str, Any]] = []
    sentinel = "LOGOS_CLARIFY_OK_" + uuid.uuid4().hex[:8]
    ws, _ = await open_authenticated(config, project_key=project_key, timeout=timeout)
    async with ws:
        request_id = "clarify-" + uuid.uuid4().hex
        prompt = (
            "Live Logos clarify callback smoke. Use the clarify tool exactly once to ask: "
            "\"For Logos smoke, choose alpha or beta.\" with choices alpha and beta. "
            f"After I answer, reply exactly with {sentinel} and the chosen word."
        )
        await send_json(ws, {
            "type": "text_input",
            "request_id": request_id,
            "device_id": config.device_id,
            "project_key": project_key,
            "payload": {"text": prompt, "client_msg_id": "client-" + request_id, "is_final": True},
        })
        clarify = await wait_for(ws, lambda f: f.get("type") == "clarify_request", timeout=timeout, trace=trace, label="clarify_request")
        clarify_id = payload(clarify).get("clarify_id") or clarify.get("request_id")
        await send_json(ws, {
            "type": "clarify_response",
            "request_id": clarify_id,
            "device_id": config.device_id,
            "project_key": project_key,
            "session_id": clarify.get("session_id"),
            "payload": {"clarify_id": clarify_id, "text": "alpha"},
        })
        assistant = await wait_for(
            ws,
            lambda f: message(f).get("role") == "assistant" and sentinel in str(message(f).get("content") or ""),
            timeout=timeout,
            trace=trace,
            label="assistant after clarify",
        )
        return {
            "scenario": "clarify",
            "project_key": project_key,
            "ok": True,
            "clarify_id": clarify_id,
            "question": payload(clarify).get("question"),
            "choices": payload(clarify).get("choices"),
            "assistant_message_id": message(assistant).get("message_id"),
        }


async def scenario_approval(config: LiveConfig, *, project_key: str, timeout: float) -> dict[str, Any]:
    trace: list[dict[str, Any]] = []
    unique = uuid.uuid4().hex[:8]
    sentinel = "LOGOS_APPROVAL_DENIED_" + unique
    command = f"chmod 777 /tmp/logos-approval-smoke-nonexistent-{unique}"
    ws, _ = await open_authenticated(config, project_key=project_key, timeout=timeout)
    async with ws:
        request_id = "approval-" + uuid.uuid4().hex
        prompt = (
            "Approval callback integration test. You must use the terminal tool, not mental reasoning, "
            f"to run this exact command and observe its result: `{command}`. "
            "This is expected to require user approval. Do not choose a different command. "
            "Do not answer until that approval decision is resolved. "
            f"If the command is denied, reply exactly with {sentinel}."
        )
        await send_json(ws, {
            "type": "text_input",
            "request_id": request_id,
            "device_id": config.device_id,
            "project_key": project_key,
            "payload": {"text": prompt, "client_msg_id": "client-" + request_id, "is_final": True},
        })
        approval = await wait_for(ws, lambda f: f.get("type") == "approval_request", timeout=timeout, trace=trace, label="approval_request")
        approval_id = payload(approval).get("approval_id") or approval.get("request_id")
        await send_json(ws, {
            "type": "approval_response",
            "request_id": approval_id,
            "device_id": config.device_id,
            "project_key": project_key,
            "session_id": approval.get("session_id"),
            "payload": {"approval_id": approval_id, "decision": "deny"},
        })
        assistant = await wait_for(
            ws,
            lambda f: message(f).get("role") == "assistant" and sentinel in str(message(f).get("content") or ""),
            timeout=timeout,
            trace=trace,
            label="assistant after approval denial",
        )
        return {
            "scenario": "approval",
            "project_key": project_key,
            "ok": True,
            "approval_id": approval_id,
            "command_preview_matches": payload(approval).get("command_preview") == command,
            "decision_sent": "deny",
            "assistant_message_id": message(assistant).get("message_id"),
        }


SCENARIOS: dict[str, Callable[..., Awaitable[dict[str, Any]]]] = {
    "text": scenario_text,
    "tts": scenario_tts,
    "clarify": scenario_clarify,
    "approval": scenario_approval,
}


async def run(args: argparse.Namespace) -> int:
    config = load_config(Path(args.config), device_id=args.device_id, url=args.url)
    names = list(SCENARIOS) if args.scenario == ["all"] else args.scenario
    results: list[dict[str, Any]] = []
    for name in names:
        project_key = f"{args.project_prefix}-{name}-{uuid.uuid4().hex[:6]}"
        result = await SCENARIOS[name](config, project_key=project_key, timeout=args.timeout)
        results.append(result)
    print(json.dumps({
        "url": config.url,
        "device_id": config.device_id,
        "secret": "[REDACTED]",
        "fast_model_provider": config.fast_model_provider,
        "fast_model_model": config.fast_model_model,
        "tts_provider": config.tts_provider,
        "results": results,
    }, indent=2, sort_keys=True))
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description="Run live Logos smoke tests against the Hermes gateway plugin")
    default_config = Path(os.getenv("HERMES_HOME", Path.home() / ".hermes")).expanduser() / "config.yaml"
    parser.add_argument("--config", default=str(default_config))
    parser.add_argument("--device-id", default="logos-live-smoke-cli")
    parser.add_argument("--url", default=None)
    parser.add_argument("--project-prefix", default="live-smoke")
    parser.add_argument("--timeout", type=float, default=300.0)
    parser.add_argument("--scenario", action="append", choices=["all", *SCENARIOS.keys()])
    args = parser.parse_args()
    if not args.scenario:
        args.scenario = ["all"]
    if "all" in args.scenario and len(args.scenario) > 1:
        parser.error("--scenario all cannot be combined with specific scenarios")
    return asyncio.run(run(args))


if __name__ == "__main__":
    raise SystemExit(main())
