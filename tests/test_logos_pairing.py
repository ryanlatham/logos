from __future__ import annotations

import asyncio
import base64
import hashlib
import hmac
import json
import time
from pathlib import Path

import pytest
import websockets

import gateway.pairing as gateway_pairing
from gateway.config import PlatformConfig
from logos.adapter import LogosAdapter
from logos.schema import Envelope
from logos.pairing import (
    build_pairing_deep_link,
    decode_pairing_deep_link,
    derive_device_secret,
    pairing_token_hash,
)
from logos.ws_server import sign_hello


class CapturingLogosAdapter(LogosAdapter):
    def __init__(self, config: PlatformConfig):
        super().__init__(config)
        self.captured_events = []

    async def handle_message(self, event):  # type: ignore[override]
        self.captured_events.append(event)


def test_derive_device_secret_is_stable_per_device_and_not_master_secret():
    expected = hmac.new(
        b"master-secret",
        b"logos-device:v1:iphone-17-pro",
        hashlib.sha256,
    ).hexdigest()

    assert derive_device_secret("master-secret", "iphone-17-pro") == expected
    assert derive_device_secret("master-secret", "iphone-17-pro") != "master-secret"
    assert derive_device_secret("master-secret", "ipad-mini") != expected


def test_pairing_deep_link_is_versioned_url_safe_and_does_not_expose_device_secret():
    url = build_pairing_deep_link(
        adapter_url="wss://studio.tail752253.ts.net/",
        device_id="iphone-17-pro",
        pair_token="pair-token-secret-value",
        expires_at=1_778_760_000.0,
        autoconnect=True,
    )

    assert url.startswith("logos://pair#")
    assert "pair-token-secret-value" not in url
    payload = decode_pairing_deep_link(url)
    assert payload == {
        "v": 1,
        "adapter_url": "wss://studio.tail752253.ts.net/",
        "device_id": "iphone-17-pro",
        "pair_token": "pair-token-secret-value",
        "expires_at": 1_778_760_000.0,
        "autoconnect": True,
    }


@pytest.mark.asyncio
async def test_websocket_pairing_token_exchange_returns_per_device_secret_and_rejects_replay(tmp_path, monkeypatch):
    monkeypatch.delenv("LOGOS_ALLOW_ALL_USERS", raising=False)
    monkeypatch.delenv("LOGOS_DEVICE_SECRET", raising=False)
    master_secret = "master-secret"
    adapter = LogosAdapter(
        PlatformConfig(
            enabled=True,
            extra={
                "device_secret": master_secret,
                "host": "127.0.0.1",
                "port": 0,
                "store_path": str(tmp_path / "logos.db"),
            },
        )
    )
    invite = adapter.create_pairing_invite(
        adapter_url="ws://127.0.0.1:0",
        device_id="iphone-17-pro",
        ttl_seconds=120,
    )
    assert invite.device_secret_hash == hashlib.sha256(
        derive_device_secret(master_secret, "iphone-17-pro").encode("utf-8")
    ).hexdigest()
    assert adapter.store.get_device("iphone-17-pro") is None

    assert await adapter.connect() is True
    adapter_url = adapter.ws_url
    try:
        async with websockets.connect(adapter_url) as ws:
            await ws.send(
                json.dumps(
                    {
                        "type": "pair",
                        "request_id": "pair-1",
                        "device_id": "iphone-17-pro",
                        "payload": {
                            "pair_token": invite.pair_token,
                            "device_id": "iphone-17-pro",
                            "display_name": "Ryan's iPhone",
                        },
                    }
                )
            )
            response = json.loads(await asyncio.wait_for(ws.recv(), timeout=2))

        assert response["type"] == "pairing_complete"
        assert response["device_id"] == "iphone-17-pro"
        payload = response["payload"]
        assert payload["credential_scope"] == "per_device"
        assert payload["device_secret"] == derive_device_secret(master_secret, "iphone-17-pro")
        assert adapter.store.get_device("iphone-17-pro") is not None
        assert gateway_pairing.PairingStore().is_approved("logos", "iphone-17-pro") is True

        async with websockets.connect(adapter_url) as ws:
            await ws.send(
                json.dumps(
                    {
                        "type": "pair",
                        "request_id": "pair-replay",
                        "device_id": "iphone-17-pro",
                        "payload": {"pair_token": invite.pair_token, "device_id": "iphone-17-pro"},
                    }
                )
            )
            replay = json.loads(await asyncio.wait_for(ws.recv(), timeout=2))

        assert replay["type"] == "error"
        assert replay["payload"]["code"] == "pairing_failed"
        assert replay["payload"]["message"] == "Logos pairing failed. Generate a fresh QR code and try again."
        assert "reason" not in replay["payload"]
        assert "raw" not in replay["payload"]
    finally:
        await adapter.disconnect()


@pytest.mark.asyncio
async def test_websocket_accepts_hello_signed_with_per_device_secret_for_enrolled_device(tmp_path, monkeypatch):
    monkeypatch.delenv("LOGOS_ALLOW_ALL_USERS", raising=False)
    monkeypatch.delenv("LOGOS_DEVICE_SECRET", raising=False)
    master_secret = "master-secret"
    device_id = "iphone-17-pro"
    adapter = LogosAdapter(
        PlatformConfig(
            enabled=True,
            extra={
                "device_secret": master_secret,
                "host": "127.0.0.1",
                "port": 0,
                "store_path": str(tmp_path / "logos.db"),
            },
        )
    )
    device_secret = derive_device_secret(master_secret, device_id)
    adapter.store.upsert_device(
        device_id=device_id,
        display_name="Ryan's iPhone",
        shared_secret_hash=hashlib.sha256(device_secret.encode("utf-8")).hexdigest(),
        capabilities=["text", "speech"],
    )
    assert await adapter.connect() is True
    try:
        timestamp_ms = int(time.time() * 1000)
        nonce = "nonce-per-device-123"
        async with websockets.connect(adapter.ws_url) as ws:
            await ws.send(
                json.dumps(
                    {
                        "type": "hello",
                        "request_id": "hello-per-device",
                        "device_id": device_id,
                        "project_key": "default",
                        "payload": {
                            "timestamp_ms": timestamp_ms,
                            "nonce": nonce,
                            "signature": sign_hello(
                                device_secret,
                                device_id=device_id,
                                request_id="hello-per-device",
                                project_key="default",
                                timestamp_ms=timestamp_ms,
                                nonce=nonce,
                            ),
                        },
                    }
                )
            )
            hello = json.loads(await asyncio.wait_for(ws.recv(), timeout=2))

        assert hello["type"] == "hello"
        assert hello["payload"]["authenticated"] is True
        assert hello["payload"]["credential_scope"] == "per_device"
    finally:
        await adapter.disconnect()


@pytest.mark.asyncio
async def test_websocket_rejects_post_auth_frames_for_different_device_id(tmp_path, monkeypatch):
    monkeypatch.delenv("LOGOS_ALLOW_ALL_USERS", raising=False)
    monkeypatch.delenv("LOGOS_DEVICE_SECRET", raising=False)
    master_secret = "master-secret"
    device_id = "iphone-17-pro"
    other_device_id = "ipad-mini"
    adapter = LogosAdapter(
        PlatformConfig(
            enabled=True,
            extra={
                "device_secret": master_secret,
                "host": "127.0.0.1",
                "port": 0,
                "store_path": str(tmp_path / "logos.db"),
            },
        )
    )
    device_secret = derive_device_secret(master_secret, device_id)
    adapter.store.upsert_device(
        device_id=device_id,
        display_name="Ryan's iPhone",
        shared_secret_hash=hashlib.sha256(device_secret.encode("utf-8")).hexdigest(),
        capabilities=["text", "speech"],
    )
    assert await adapter.connect() is True
    try:
        timestamp_ms = int(time.time() * 1000)
        nonce = "nonce-device-binding-123"
        async with websockets.connect(adapter.ws_url) as ws:
            await ws.send(
                json.dumps(
                    {
                        "type": "hello",
                        "request_id": "hello-device-binding",
                        "device_id": device_id,
                        "project_key": "default",
                        "payload": {
                            "timestamp_ms": timestamp_ms,
                            "nonce": nonce,
                            "signature": sign_hello(
                                device_secret,
                                device_id=device_id,
                                request_id="hello-device-binding",
                                project_key="default",
                                timestamp_ms=timestamp_ms,
                                nonce=nonce,
                            ),
                        },
                    }
                )
            )
            hello = json.loads(await asyncio.wait_for(ws.recv(), timeout=2))
            assert hello["type"] == "hello"

            await ws.send(
                json.dumps(
                    {
                        "type": "list_projects",
                        "request_id": "spoofed-device-frame",
                        "device_id": other_device_id,
                        "payload": {},
                    }
                )
            )
            rejected = json.loads(await asyncio.wait_for(ws.recv(), timeout=2))

        assert rejected["type"] == "error"
        assert rejected["payload"]["code"] == "device_mismatch"
        assert rejected["device_id"] == other_device_id
    finally:
        await adapter.disconnect()


def test_qr_pairing_command_registers_and_generates_png_without_printing_token(tmp_path, monkeypatch):
    monkeypatch.setenv("LOGOS_DEVICE_SECRET", "master-secret")
    monkeypatch.setenv("LOGOS_STORE_PATH", str(tmp_path / "logos.db"))
    monkeypatch.setenv("LOGOS_PUBLIC_URL", "wss://studio.tail752253.ts.net/")

    adapter = LogosAdapter(PlatformConfig(enabled=True, extra={"store_path": str(tmp_path / "logos.db")}))
    response = adapter.build_pairing_command_response(
        raw_args="device_id=iphone-17-pro ttl=120",
        image_dir=tmp_path,
        now=1_778_760_000.0,
    )

    assert "MEDIA:" in response
    assert "iphone-17-pro" in response
    assert "pair_token" not in response
    assert "master-secret" not in response
    media_path = Path(response.split("MEDIA:", 1)[1].split()[0])
    assert media_path.exists()
    assert media_path.suffix == ".png"
    assert media_path.read_bytes().startswith(b"\x89PNG")
    assert adapter.store.get_pairing_token(pairing_token_hash(adapter.latest_pairing_invite.pair_token)) is not None


@pytest.mark.asyncio
async def test_qr_paired_device_is_gateway_authorized_before_dispatch(tmp_path, monkeypatch):
    monkeypatch.delenv("LOGOS_ALLOW_ALL_USERS", raising=False)
    monkeypatch.delenv("LOGOS_ALLOWED_USERS", raising=False)
    monkeypatch.setattr(gateway_pairing, "PAIRING_DIR", tmp_path / "gateway-pairing")
    master_secret = "master-secret"
    device_id = "iphone-17-pro"
    device_secret = derive_device_secret(master_secret, device_id)
    adapter = CapturingLogosAdapter(
        PlatformConfig(
            enabled=True,
            extra={
                "device_secret": master_secret,
                "store_path": str(tmp_path / "logos.db"),
            },
        )
    )
    adapter.store.upsert_device(
        device_id=device_id,
        display_name="Ryan's iPhone",
        shared_secret_hash=hashlib.sha256(device_secret.encode("utf-8")).hexdigest(),
        capabilities=["text", "speech"],
    )
    assert gateway_pairing.PairingStore().is_approved("logos", device_id) is False

    await adapter.handle_ws_envelope(
        Envelope(
            type="text_input",
            request_id="text-1",
            device_id=device_id,
            project_key="alpha",
            payload={"text": "hello", "client_msg_id": "client-hello", "is_final": True},
        )
    )

    assert adapter.captured_events[-1].text == "hello"
    assert adapter.captured_events[-1].source.user_id == device_id
    assert gateway_pairing.PairingStore().is_approved("logos", device_id) is True
