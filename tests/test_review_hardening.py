from __future__ import annotations

import asyncio
import hashlib
import json
import socket
import time

import pytest
import websockets

from gateway.config import PlatformConfig
from logos.adapter import LogosAdapter
from logos.pairing import derive_device_secret
from logos.schema import Envelope
from logos.ws_server import sign_hello


@pytest.mark.asyncio
async def test_websocket_rejects_legacy_plaintext_secret_hello(tmp_path):
    adapter = LogosAdapter(
        PlatformConfig(enabled=True, extra={"host": "127.0.0.1", "port": 0, "store_path": str(tmp_path / "logos.db")})
    )
    assert await adapter.connect() is True
    try:
        async with websockets.connect(adapter.ws_url) as ws:
            await ws.send(json.dumps({"type": "hello", "request_id": "legacy", "device_id": "iphone", "payload": {"secret": "dev-secret"}}))
            response = json.loads(await asyncio.wait_for(ws.recv(), timeout=2))
            assert response["type"] == "error"
            assert response["payload"]["code"] == "auth_failed"
            assert response["payload"]["raw"]["payload"]["secret"] == "[REDACTED]"
    finally:
        await adapter.disconnect()


@pytest.mark.asyncio
async def test_websocket_signed_hello_reports_signature_mismatch_reason(tmp_path):
    adapter = LogosAdapter(
        PlatformConfig(enabled=True, extra={"host": "127.0.0.1", "port": 0, "store_path": str(tmp_path / "logos.db")})
    )
    assert await adapter.connect() is True
    timestamp_ms = int(time.time() * 1000)
    nonce = "nonce-invalid-signature-123"
    try:
        async with websockets.connect(adapter.ws_url) as ws:
            await ws.send(
                json.dumps(
                    {
                        "type": "hello",
                        "request_id": "hello-bad-sig",
                        "device_id": "iphone",
                        "project_key": "default",
                        "payload": {
                            "timestamp_ms": timestamp_ms,
                            "nonce": nonce,
                            "signature": sign_hello(
                                "wrong-secret",
                                device_id="iphone",
                                request_id="hello-bad-sig",
                                project_key="default",
                                timestamp_ms=timestamp_ms,
                                nonce=nonce,
                            ),
                        },
                    }
                )
            )
            response = json.loads(await asyncio.wait_for(ws.recv(), timeout=2))
            assert response["type"] == "error"
            assert response["payload"]["code"] == "auth_failed"
            assert response["payload"]["reason"] == "invalid_signature"
            assert "signature mismatch" in response["payload"]["message"]
    finally:
        await adapter.disconnect()


@pytest.mark.asyncio
async def test_websocket_rejects_signed_hello_without_frame_device_id_for_enrolled_device(tmp_path):
    master_secret = "dev-secret"
    device_id = "iphone-paired"
    adapter = LogosAdapter(
        PlatformConfig(
            enabled=True,
            extra={"device_secret": master_secret, "host": "127.0.0.1", "port": 0, "store_path": str(tmp_path / "logos.db")},
        )
    )
    device_secret = derive_device_secret(master_secret, device_id)
    adapter.store.upsert_device(
        device_id=device_id,
        display_name="Paired iPhone",
        shared_secret_hash=hashlib.sha256(device_secret.encode("utf-8")).hexdigest(),
        capabilities=["text", "speech"],
    )
    assert await adapter.connect() is True
    timestamp_ms = int(time.time() * 1000)
    nonce = "nonce-missing-device-123"
    try:
        async with websockets.connect(adapter.ws_url) as ws:
            await ws.send(
                json.dumps(
                    {
                        "type": "hello",
                        "request_id": "hello-missing-device",
                        "project_key": "default",
                        "payload": {
                            "device_id": device_id,
                            "timestamp_ms": timestamp_ms,
                            "nonce": nonce,
                            "signature": sign_hello(
                                master_secret,
                                device_id=None,
                                request_id="hello-missing-device",
                                project_key="default",
                                timestamp_ms=timestamp_ms,
                                nonce=nonce,
                            ),
                        },
                    }
                )
            )
            response = json.loads(await asyncio.wait_for(ws.recv(), timeout=2))
            assert response["type"] == "error"
            assert response["payload"]["code"] == "auth_failed"
            assert response["payload"]["reason"] == "missing_device_id"
    finally:
        await adapter.disconnect()


@pytest.mark.asyncio
async def test_websocket_signed_hello_rejects_replayed_nonce(tmp_path):
    adapter = LogosAdapter(
        PlatformConfig(enabled=True, extra={"host": "127.0.0.1", "port": 0, "store_path": str(tmp_path / "logos.db")})
    )
    assert await adapter.connect() is True
    timestamp_ms = int(time.time() * 1000)
    nonce = "nonce-replay-test-123"
    payload = {
        "timestamp_ms": timestamp_ms,
        "nonce": nonce,
        "signature": sign_hello(
            "dev-secret",
            device_id="iphone",
            request_id="hello-1",
            project_key="default",
            timestamp_ms=timestamp_ms,
            nonce=nonce,
        ),
    }
    try:
        async with websockets.connect(adapter.ws_url) as ws:
            await ws.send(json.dumps({"type": "hello", "request_id": "hello-1", "device_id": "iphone", "project_key": "default", "payload": payload}))
            ok = json.loads(await asyncio.wait_for(ws.recv(), timeout=2))
            assert ok["type"] == "hello"
        async with websockets.connect(adapter.ws_url) as ws:
            await ws.send(json.dumps({"type": "hello", "request_id": "hello-1", "device_id": "iphone", "project_key": "default", "payload": payload}))
            replay = json.loads(await asyncio.wait_for(ws.recv(), timeout=2))
            assert replay["type"] == "error"
            assert replay["payload"]["code"] == "auth_failed"
    finally:
        await adapter.disconnect()


def test_connect_refuses_wildcard_bind_without_explicit_override(tmp_path, monkeypatch):
    monkeypatch.delenv("LOGOS_ALLOW_UNSAFE_BIND", raising=False)
    adapter = LogosAdapter(
        PlatformConfig(enabled=True, extra={"host": "0.0.0.0", "port": 0, "store_path": str(tmp_path / "logos.db")})
    )
    assert LogosAdapter._is_safe_bind_host("0.0.0.0") is False
    assert asyncio.run(adapter.connect()) is False


def test_safe_bind_allows_private_and_tailscale_hostnames(monkeypatch):
    def fake_getaddrinfo(host, port, proto=0):
        assert host == "ryans-mac-studio"
        return [
            (socket.AF_INET, socket.SOCK_STREAM, proto, "", ("100.116.9.88", 0)),
            (socket.AF_INET, socket.SOCK_STREAM, proto, "", ("192.168.1.39", 0)),
        ]

    monkeypatch.setattr("logos.adapter.socket.getaddrinfo", fake_getaddrinfo)
    assert LogosAdapter._is_safe_bind_host("ryans-mac-studio") is True


def test_safe_bind_rejects_public_hostname(monkeypatch):
    def fake_getaddrinfo(host, port, proto=0):
        return [(socket.AF_INET, socket.SOCK_STREAM, proto, "", ("8.8.8.8", 0))]

    monkeypatch.setattr("logos.adapter.socket.getaddrinfo", fake_getaddrinfo)
    assert LogosAdapter._is_safe_bind_host("example.com") is False


@pytest.mark.asyncio
async def test_messages_batch_replays_pending_approval_after_reconnect(tmp_path):
    adapter = LogosAdapter(PlatformConfig(enabled=True, extra={"store_path": str(tmp_path / "logos.db")}))
    await adapter.send_exec_approval(
        chat_id="project:alpha",
        command="python manage.py migrate",
        session_key="agent:main:logos:dm:project:alpha",
        description="May modify DB",
        metadata={"session_id": "project:alpha"},
    )

    response = adapter._handle_messages_get(
        Envelope(type="messages_get", request_id="get", device_id="iphone", project_key="alpha", payload={"after_server_seq": 0})
    )

    pending = response["payload"]["pending_interactions"]
    assert len(pending) == 1
    assert pending[0]["type"] == "approval_request"
    assert pending[0]["request_id"]
    assert pending[0]["payload"]["command_preview"] == "python manage.py migrate"


@pytest.mark.asyncio
async def test_final_user_text_is_mirrored_for_reconnect_delta(tmp_path):
    captured = []

    class Capturing(LogosAdapter):
        async def handle_message(self, event):  # type: ignore[override]
            captured.append(event)

    adapter = Capturing(PlatformConfig(enabled=True, extra={"store_path": str(tmp_path / "logos.db")}))
    await adapter.handle_ws_envelope(
        Envelope(
            type="text_input",
            request_id="r1",
            device_id="iphone",
            project_key="alpha",
            payload={"text": "hello", "client_msg_id": "client-hello", "is_final": True},
        )
    )

    batch = adapter._handle_messages_get(
        Envelope(type="messages_get", request_id="get", device_id="iphone", project_key="alpha", payload={"after_server_seq": 0})
    )
    assert captured[-1].text == "hello"
    assert [message["content"] for message in batch["payload"]["messages"]] == ["hello"]
    assert batch["payload"]["messages"][0]["message_id"] == "client-hello"
