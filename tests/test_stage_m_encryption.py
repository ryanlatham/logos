from __future__ import annotations

import asyncio
import base64
import json
import secrets
import time

import pytest
import websockets

from gateway.config import PlatformConfig
from logos.adapter import LogosAdapter
from logos.crypto import LogosSessionCrypto
from logos.ws_server import sign_hello

DEVICE = "iphone-enc"
SECRET = "dev-secret"  # the shared master; accepted via LOGOS_ALLOW_ALL_USERS in conftest


def _adapter(tmp_path):
    return LogosAdapter(
        PlatformConfig(enabled=True, extra={"host": "127.0.0.1", "port": 0, "store_path": str(tmp_path / "logos.db")})
    )


async def _negotiate(ws, *, request_id="hello-enc"):
    """Send a v2 (encryption-capable) signed hello; return the client-side session crypto."""
    timestamp_ms = int(time.time() * 1000)
    nonce = f"enc-nonce-{secrets.token_hex(8)}"
    client_nonce = secrets.token_bytes(32)
    enc_client_nonce = base64.b64encode(client_nonce).decode("ascii")
    signature = sign_hello(
        SECRET,
        device_id=DEVICE,
        request_id=request_id,
        project_key=None,
        timestamp_ms=timestamp_ms,
        nonce=nonce,
        enc_client_nonce=enc_client_nonce,
    )
    await ws.send(
        json.dumps(
            {
                "type": "hello",
                "request_id": request_id,
                "device_id": DEVICE,
                "payload": {
                    "timestamp_ms": timestamp_ms,
                    "nonce": nonce,
                    "signature": signature,
                    "enc_supported": ["chacha20-poly1305"],
                    "enc_client_nonce": enc_client_nonce,
                },
            }
        )
    )
    hello = json.loads(await asyncio.wait_for(ws.recv(), timeout=2))
    assert hello["type"] == "hello"
    assert hello["payload"]["authenticated"] is True
    enc = hello["payload"]["enc"]
    server_nonce = base64.b64decode(enc["enc_server_nonce"])
    return LogosSessionCrypto.derive_session(
        device_secret=SECRET, client_nonce=client_nonce, server_nonce=server_nonce, role="client", aead=enc["aead"]
    )


@pytest.mark.asyncio
async def test_encryption_negotiated_and_round_trips(tmp_path):
    adapter = _adapter(tmp_path)

    async def fake_gateway(event):
        return f"echo: {event.text}"

    adapter.set_message_handler(fake_gateway)
    assert await adapter.connect() is True
    try:
        async with websockets.connect(adapter.ws_url) as ws:
            crypto = await _negotiate(ws)
            header = {"type": "text_input", "request_id": "t1", "device_id": DEVICE, "project_key": "default"}
            sealed = crypto.seal_payload(header, {"text": "ping", "client_msg_id": "c1", "is_final": True})
            frame = dict(header)
            frame["payload"] = sealed
            await ws.send(json.dumps(frame))

            saw_encrypted = False
            saw_echo = False
            for _ in range(8):
                raw = json.loads(await asyncio.wait_for(ws.recv(), timeout=4))
                payload = raw.get("payload")
                # Every post-hello server frame must be encrypted.
                assert isinstance(payload, dict) and payload.get("enc") == 1, f"unencrypted frame: {raw}"
                saw_encrypted = True
                opened = crypto.open_payload(raw, payload)  # decrypt in counter order
                message = opened.get("message") if isinstance(opened, dict) else None
                if raw["type"] == "state_update" and isinstance(message, dict) and message.get("content") == "echo: ping":
                    saw_echo = True
                    break
            assert saw_encrypted
            assert saw_echo
    finally:
        await adapter.disconnect()


@pytest.mark.asyncio
async def test_v1_client_without_encryption_still_works_cleartext(tmp_path):
    adapter = _adapter(tmp_path)
    adapter.set_message_handler(lambda event: f"echo: {event.text}")
    assert await adapter.connect() is True
    try:
        async with websockets.connect(adapter.ws_url) as ws:
            timestamp_ms = int(time.time() * 1000)
            nonce = "v1-nonce-abcdef123"
            signature = sign_hello(SECRET, device_id=DEVICE, request_id="h1", project_key=None, timestamp_ms=timestamp_ms, nonce=nonce)
            await ws.send(json.dumps({"type": "hello", "request_id": "h1", "device_id": DEVICE, "payload": {"timestamp_ms": timestamp_ms, "nonce": nonce, "signature": signature}}))
            hello = json.loads(await asyncio.wait_for(ws.recv(), timeout=2))
            assert hello["payload"]["authenticated"] is True
            assert "enc" not in hello["payload"]  # no encryption negotiated for a v1 client
            await ws.send(json.dumps({"type": "text_input", "request_id": "t1", "device_id": DEVICE, "project_key": "default", "payload": {"text": "ping", "client_msg_id": "c1", "is_final": True}}))
            frame = json.loads(await asyncio.wait_for(ws.recv(), timeout=4))
            # Cleartext payloads (not sealed) for a non-negotiating client.
            assert frame["payload"].get("enc") != 1
    finally:
        await adapter.disconnect()


@pytest.mark.asyncio
async def test_required_mode_rejects_non_encrypting_client(tmp_path, monkeypatch):
    monkeypatch.setenv("LOGOS_ENC_MODE", "required")
    adapter = _adapter(tmp_path)
    assert await adapter.connect() is True
    try:
        async with websockets.connect(adapter.ws_url) as ws:
            timestamp_ms = int(time.time() * 1000)
            nonce = "req-nonce-abcdef123"
            signature = sign_hello(SECRET, device_id=DEVICE, request_id="h1", project_key=None, timestamp_ms=timestamp_ms, nonce=nonce)
            await ws.send(json.dumps({"type": "hello", "request_id": "h1", "device_id": DEVICE, "payload": {"timestamp_ms": timestamp_ms, "nonce": nonce, "signature": signature}}))
            response = json.loads(await asyncio.wait_for(ws.recv(), timeout=2))
            assert response["type"] == "error"
            assert response["payload"]["code"] == "encryption_required"
    finally:
        await adapter.disconnect()
