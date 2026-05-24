#!/usr/bin/env python3
from __future__ import annotations

import argparse
import asyncio
import json
import os
import signal
import sys
from collections.abc import Mapping
from pathlib import Path
from typing import Any

try:
    from gateway.config import PlatformConfig
    from gateway.platforms.base import MessageEvent
    from logos.adapter import LogosAdapter
    from logos.ws_server import LogosWebSocketServer
    from websockets.exceptions import ConnectionClosed
except ModuleNotFoundError as exc:
    RUNTIME_IMPORT_ERROR: ModuleNotFoundError | None = exc
    PlatformConfig = None  # type: ignore[assignment]
    MessageEvent = Any  # type: ignore[assignment]
    LogosAdapter = object  # type: ignore[assignment]
    LogosWebSocketServer = object  # type: ignore[assignment]
    ConnectionClosed = Exception  # type: ignore[assignment]
else:
    RUNTIME_IMPORT_ERROR = None


TRAFFIC_SECRET_KEY_MARKERS = (
    "secret",
    "token",
    "password",
    "auth_key",
    "api_key",
    "signature",
    "credential",
    "access_key",
    "private_key",
    "refresh_token",
    "jwt",
)
TRAFFIC_SECRET_EXACT_KEYS = {
    "authorization",
    "cookie",
    "set-cookie",
    "session_key",
    "shared_secret_hash",
}
TRAFFIC_TEXT_KEYS = {"text", "content", "command_preview", "summary", "question"}


def _allow_transcript_logging() -> bool:
    value = os.getenv("LOGOS_TRAFFIC_LOG_TRANSCRIPTS", "")
    return value == "1" or value.lower() in {"true", "yes"}


def _is_traffic_secret_key(key: str) -> bool:
    lowered = key.lower()
    return lowered in TRAFFIC_SECRET_EXACT_KEYS or any(marker in lowered for marker in TRAFFIC_SECRET_KEY_MARKERS)


def _summarize_text(value: Any) -> Any:
    if _allow_transcript_logging() or not isinstance(value, str):
        return value
    return f"[TEXT length={len(value)}]"


def _redact_traffic(value: Any) -> Any:
    if isinstance(value, Mapping):
        return {
            str(key): "[REDACTED]" if _is_traffic_secret_key(str(key))
            else _summarize_text(item) if str(key).lower() in TRAFFIC_TEXT_KEYS
            else _redact_traffic(item)
            for key, item in value.items()
        }
    if isinstance(value, list):
        return [_redact_traffic(item) for item in value]
    if isinstance(value, tuple):
        return tuple(_redact_traffic(item) for item in value)
    return value


def _traffic_payload(frame: Any) -> Any:
    if isinstance(frame, Mapping):
        return _redact_traffic(dict(frame))
    if isinstance(frame, (bytes, bytearray)):
        frame = bytes(frame).decode("utf-8", errors="replace")
    if isinstance(frame, str):
        try:
            decoded = json.loads(frame)
        except json.JSONDecodeError:
            return frame
        return _redact_traffic(decoded)
    return _redact_traffic(frame)


def format_traffic_log_line(direction: str, frame: Any) -> str:
    payload = _traffic_payload(frame)
    rendered = json.dumps(payload, default=str, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
    return f"TRAFFIC {direction} {rendered}"


def log_traffic(direction: str, frame: Any) -> None:
    print(format_traffic_log_line(direction, frame), flush=True)


class TrafficLoggingWebSocket:
    def __init__(self, websocket: Any) -> None:
        self._websocket = websocket

    def __getattr__(self, name: str) -> Any:
        return getattr(self._websocket, name)

    def __aiter__(self):
        return self._logged_messages()

    async def _logged_messages(self):
        async for raw in self._websocket:
            log_traffic("<-", raw)
            yield raw

    async def send(self, data: Any) -> None:
        log_traffic("->", data)
        await self._websocket.send(data)

    async def close(self, *args: Any, **kwargs: Any) -> Any:
        return await self._websocket.close(*args, **kwargs)


class TrafficLoggingWebSocketServer(LogosWebSocketServer):
    async def _handle_connection(self, websocket: Any) -> None:
        try:
            await super()._handle_connection(TrafficLoggingWebSocket(websocket))
        except ConnectionClosed:
            return


class StageFMockLogosAdapter(LogosAdapter):
    """Small Hermes-like adapter for iOS Simulator UI validation.

    It uses the real Logos WebSocket/protocol/storage code and replaces only the
    Hermes gateway run with a deterministic echo. This is not product behavior;
    it is a Stage F simulator fixture.
    """

    async def connect(self) -> bool:
        if not self.device_secret:
            self._set_fatal_error(
                "config_missing",
                "LOGOS_DEVICE_SECRET must be set in the runtime environment",
                retryable=False,
            )
            return False
        if not self._is_safe_bind_host(self.host):
            self._set_fatal_error(
                "unsafe_bind_host",
                f"Refusing to bind Logos WebSocket to unsafe host {self.host!r}; use loopback, private/Tailscale IP, or set LOGOS_ALLOW_UNSAFE_BIND=1",
                retryable=False,
            )
            return False
        self.ws_server = TrafficLoggingWebSocketServer(
            self,
            host=self.host,
            port=self.port,
            device_secret=self.device_secret,
        )
        try:
            await self.ws_server.start()
        except Exception as exc:
            self._set_fatal_error("connect_failed", str(exc), retryable=True)
            return False
        self._mark_connected()
        return True

    async def handle_message(self, event: MessageEvent) -> None:  # type: ignore[override]
        content = event.text.strip()
        chat_id = event.source.chat_id if event.source else "project:default"
        if content == "/mock_approval":
            await self.send_exec_approval(
                chat_id=chat_id,
                command="echo stage-f",
                session_key="stage-f-session",
                description="Stage F fixture approval",
                metadata={"approval_id": "stage-f-approval", "risk": "Fixture only; no command is executed."},
            )
            return
        if content == "/mock_clarify":
            await self.send_clarify(
                chat_id=chat_id,
                clarify_id="stage-f-clarify",
                question="Which Stage F path should Logos test?",
                choices=["text", "approval", "clarification"],
                session_key="stage-f-session",
            )
            return
        if content == "/mock_delayed_thread_updates":
            request_id = "stage-f-delayed-thread-updates"
            await asyncio.sleep(0.8)
            await self._broadcast_progress_text(
                chat_id=chat_id,
                content="Delayed progress update: preparing thread auto-follow fixture.",
                metadata={"request_id": request_id, "session_id": "stage-f-delayed-session"},
                request_id=request_id,
                kind="tool_progress",
            )
            await asyncio.sleep(0.4)
            await self.send(
                chat_id=chat_id,
                content="Delayed final update: thread auto-follow fixture complete.",
                metadata={
                    "request_id": request_id,
                    "source": "stage_f_mock",
                    "session_id": "stage-f-delayed-session",
                },
            )
            return
        if content == "/mock_slow_thread_updates":
            asyncio.create_task(self._send_slow_thread_updates(chat_id))
            return
        if content == "/mock_tall_thread_update":
            request_id = "stage-f-tall-thread-update"
            await asyncio.sleep(0.8)
            await self.send(
                chat_id=chat_id,
                content=(
                    "Tall delayed final update: auto-follow should survive a large response.\n\n"
                    "This fixture intentionally spans multiple lines so the incoming assistant bubble "
                    "moves the scroll geometry away from the previous bottom before the scheduled follow runs.\n\n"
                    "Line 1: the user stayed at the bottom.\n"
                    "Line 2: no manual detach happened.\n"
                    "Line 3: the follow task should use its captured eligibility.\n"
                    "Line 4: a transient bottom-distance change should not show New updates.\n"
                    "Line 5: the final line should still be reachable without manual scrolling."
                ),
                metadata={
                    "request_id": request_id,
                    "source": "stage_f_mock",
                    "session_id": "stage-f-tall-thread-session",
                },
            )
            return
        if content == "/mock_run_control_shrink":
            request_id = "stage-f-run-control-shrink"
            await self._broadcast_progress_text(
                chat_id=chat_id,
                content="Run control shrink progress is visible before final response.",
                metadata={"request_id": request_id, "session_id": "stage-f-run-control-shrink-session"},
                request_id=request_id,
                kind="tool_progress",
            )
            await asyncio.sleep(4.0)
            await self.send(
                chat_id=chat_id,
                content="Run control shrink final update complete.",
                metadata={
                    "request_id": request_id,
                    "source": "stage_f_mock",
                    "session_id": "stage-f-run-control-shrink-session",
                },
            )
            return
        await self.send(
            chat_id=chat_id,
            content=f"Mock Hermes received: {content}",
            metadata={"source": "stage_f_mock"},
        )

    async def _send_slow_thread_updates(self, chat_id: str) -> None:
        request_id = "stage-f-slow-thread-updates"
        await asyncio.sleep(14.0)
        await self.send(
            chat_id=chat_id,
            content="Slow delayed final update: detached reading fixture complete.",
            metadata={
                "request_id": request_id,
                "source": "stage_f_mock",
                "session_id": "stage-f-slow-thread-session",
            },
        )


async def amain() -> int:
    parser = argparse.ArgumentParser(description="Run a Stage F Logos mock adapter for iOS Simulator validation")
    parser.add_argument("--host", default=os.getenv("LOGOS_WS_HOST", "127.0.0.1"))
    parser.add_argument("--port", type=int, default=int(os.getenv("LOGOS_WS_PORT", "8765")))
    parser.add_argument("--secret", default=os.getenv("LOGOS_DEVICE_SECRET", "stage-f-secret"))
    parser.add_argument("--store", default=os.getenv("LOGOS_STORE_PATH", "/tmp/logos-stage-f-simulator.db"))
    args = parser.parse_args()

    if RUNTIME_IMPORT_ERROR is not None:
        print(f"ERROR: missing Logos mock adapter dependency: {RUNTIME_IMPORT_ERROR}", file=sys.stderr, flush=True)
        return 1

    store = Path(args.store)
    if store.exists():
        store.unlink()
    os.environ["LOGOS_DEVICE_SECRET"] = args.secret
    os.environ.setdefault("LOGOS_ALLOW_ALL_USERS", "1")
    adapter = StageFMockLogosAdapter(
        PlatformConfig(
            enabled=True,
            extra={
                "host": args.host,
                "port": args.port,
                "store_path": str(store),
            },
        )
    )
    connected = await adapter.connect()
    if not connected:
        return 1
    print(f"READY ws://{args.host}:{adapter.ws_server.actual_port} secret=[REDACTED] store={store}", flush=True)

    stop = asyncio.Event()
    loop = asyncio.get_running_loop()
    for sig in (signal.SIGINT, signal.SIGTERM):
        try:
            loop.add_signal_handler(sig, stop.set)
        except NotImplementedError:
            pass
    await stop.wait()
    await adapter.disconnect()
    return 0


if __name__ == "__main__":
    raise SystemExit(asyncio.run(amain()))
