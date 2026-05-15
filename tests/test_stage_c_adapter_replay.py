from __future__ import annotations

import asyncio
import json
import time

import pytest
import websockets

from gateway.config import PlatformConfig
from logos.adapter import LogosAdapter
from logos.ws_server import sign_hello


@pytest.mark.asyncio
async def test_messages_get_returns_messages_batch_after_server_seq(tmp_path):
    adapter = LogosAdapter(
        PlatformConfig(enabled=True, extra={"device_secret": "dev-secret", "store_path": str(tmp_path / "logos.db")})
    )
    await adapter.send("project:alpha", "first", metadata={"session_id": "sess-1"})
    await adapter.send("project:alpha", "second", metadata={"session_id": "sess-1"})

    response = await adapter.handle_ws_envelope(
        adapter.envelope_from_dict(
            {
                "type": "messages_get",
                "request_id": "get-1",
                "device_id": "iphone",
                "project_key": "alpha",
                "payload": {"after_server_seq": 1, "limit": 20},
            }
        )
    )

    assert response["type"] == "messages_batch"
    assert response["request_id"] == "get-1"
    assert response["project_key"] == "alpha"
    assert response["payload"]["has_more"] is False
    assert [m["content"] for m in response["payload"]["messages"]] == ["second"]
    assert response["payload"]["messages"][0]["server_seq"] == 2


@pytest.mark.asyncio
async def test_messages_get_supports_before_message_id_pagination(tmp_path):
    adapter = LogosAdapter(
        PlatformConfig(enabled=True, extra={"device_secret": "dev-secret", "store_path": str(tmp_path / "logos.db")})
    )
    for text in ("one", "two", "three"):
        await adapter.send("project:alpha", text, metadata={"session_id": "sess-1"})

    response = await adapter.handle_ws_envelope(
        adapter.envelope_from_dict(
            {
                "type": "messages_get",
                "request_id": "get-older",
                "device_id": "iphone",
                "project_key": "alpha",
                "session_id": "sess-1",
                "payload": {"before_message_id": "logos-3", "limit": 2},
            }
        )
    )

    assert response["type"] == "messages_batch"
    assert [m["content"] for m in response["payload"]["messages"]] == ["one", "two"]


@pytest.mark.asyncio
async def test_reconnect_hello_replays_missed_messages_after_last_seen_seq(tmp_path):
    adapter = LogosAdapter(
        PlatformConfig(
            enabled=True,
            extra={"device_secret": "dev-secret", "host": "127.0.0.1", "port": 0, "store_path": str(tmp_path / "logos.db")},
        )
    )
    await adapter.send("project:alpha", "old", metadata={"session_id": "sess-1"})
    await adapter.send("project:alpha", "missed", metadata={"session_id": "sess-1"})

    assert await adapter.connect() is True
    try:
        async with websockets.connect(adapter.ws_url) as ws:
            timestamp_ms = int(time.time() * 1000)
            nonce = "nonce-for-reconnect-123"
            signature = sign_hello(
                "dev-secret",
                device_id="iphone",
                request_id="hello-reconnect",
                project_key="alpha",
                timestamp_ms=timestamp_ms,
                nonce=nonce,
            )
            await ws.send(
                json.dumps(
                    {
                        "type": "hello",
                        "request_id": "hello-reconnect",
                        "device_id": "iphone",
                        "project_key": "alpha",
                        "payload": {"timestamp_ms": timestamp_ms, "nonce": nonce, "signature": signature, "after_server_seq": 1},
                    }
                )
            )
            hello = json.loads(await asyncio.wait_for(ws.recv(), timeout=2))
            batch = json.loads(await asyncio.wait_for(ws.recv(), timeout=2))
    finally:
        await adapter.disconnect()

    assert hello["type"] == "hello"
    assert batch["type"] == "messages_batch"
    assert [m["content"] for m in batch["payload"]["messages"]] == ["missed"]
