from __future__ import annotations

import asyncio
import json
import time
from dataclasses import dataclass, field
from typing import Any

import pytest
import websockets

from gateway.config import PlatformConfig
from logos.adapter import LogosAdapter
from logos.schema import Envelope
from logos.ws_server import sign_hello


@dataclass
class FakeServer:
    frames: list[dict[str, Any]] = field(default_factory=list)

    async def broadcast(self, frame: dict[str, Any], *, project_key: str | None = None) -> None:
        self.frames.append({"frame": frame, "project_key": project_key})


class CapturingLogosAdapter(LogosAdapter):
    def __init__(self, config: PlatformConfig):
        super().__init__(config)
        self.captured_events = []

    async def handle_message(self, event):  # type: ignore[override]
        self.captured_events.append(event)


@pytest.mark.asyncio
async def test_final_text_input_uses_gateway_handle_message_path_without_rewriting_slashes(tmp_path):
    adapter = CapturingLogosAdapter(
        PlatformConfig(enabled=True, extra={"device_secret": "dev-secret", "host": "127.0.0.1", "port": 0, "store_path": str(tmp_path / "logos.db")})
    )
    frame = Envelope(
        type="text_input",
        request_id="req-text",
        device_id="iphone-17-pro",
        project_key="archwright",
        payload={"text": "/resume archwright", "is_final": True, "client_msg_id": "client-1"},
    )

    await adapter.handle_ws_envelope(frame)

    assert len(adapter.captured_events) == 1
    event = adapter.captured_events[0]
    assert event.text == "/resume archwright"
    assert event.message_id == "client-1"
    assert event.source.platform.value == "logos"
    assert event.source.chat_type == "dm"
    assert event.source.chat_id == "project:archwright"
    assert event.source.chat_name == "archwright"
    assert event.source.user_id == "iphone-17-pro"
    assert event.source.user_name == "iphone-17-pro"
    assert event.raw_message["type"] == "text_input"


@pytest.mark.asyncio
async def test_non_final_speech_does_not_enter_gateway_path(tmp_path):
    adapter = CapturingLogosAdapter(PlatformConfig(enabled=True, extra={"device_secret": "dev-secret", "store_path": str(tmp_path / "logos.db")}))
    frame = Envelope(
        type="speech",
        request_id="req-speech",
        device_id="iphone-17-pro",
        project_key="archwright",
        payload={"text": "partial", "is_final": False, "client_msg_id": "client-2"},
    )

    response = await adapter.handle_ws_envelope(frame)

    assert adapter.captured_events == []
    assert response["type"] == "state_update"
    assert response["payload"]["op"] == "speech_partial_received"


@pytest.mark.asyncio
async def test_send_broadcasts_gateway_response_as_state_update(tmp_path):
    adapter = LogosAdapter(PlatformConfig(enabled=True, extra={"device_secret": "dev-secret", "store_path": str(tmp_path / "logos.db")}))
    fake_server = FakeServer()
    adapter.ws_server = fake_server  # type: ignore[assignment]

    result = await adapter.send("project:archwright", "Hermes response", metadata={"session_id": "sess-1"})

    assert result.success is True
    assert result.message_id is not None
    assert fake_server.frames[0]["project_key"] == "archwright"
    frame = fake_server.frames[0]["frame"]
    assert frame["type"] == "state_update"
    assert frame["project_key"] == "archwright"
    assert frame["session_id"] == "sess-1"
    assert frame["server_seq"] == 1
    assert frame["payload"]["op"] == "message_appended"
    assert frame["payload"]["message"]["role"] == "assistant"
    assert frame["payload"]["message"]["content"] == "Hermes response"


@pytest.mark.asyncio
async def test_websocket_auth_and_text_round_trip_to_fake_gateway_handler(tmp_path):
    adapter = LogosAdapter(
        PlatformConfig(enabled=True, extra={"device_secret": "dev-secret", "host": "127.0.0.1", "port": 0, "store_path": str(tmp_path / "logos.db")})
    )

    async def fake_gateway(event):
        assert event.text == "ping"
        return f"echo: {event.text}"

    adapter.set_message_handler(fake_gateway)
    assert await adapter.connect() is True
    try:
        uri = adapter.ws_url
        assert uri.startswith("ws://127.0.0.1:")
        async with websockets.connect(uri) as ws:
            timestamp_ms = int(time.time() * 1000)
            nonce = "nonce-for-test-123"
            signature = sign_hello(
                "dev-secret",
                device_id="iphone",
                request_id="hello-1",
                project_key=None,
                timestamp_ms=timestamp_ms,
                nonce=nonce,
            )
            await ws.send(json.dumps({"type": "hello", "request_id": "hello-1", "device_id": "iphone", "payload": {"timestamp_ms": timestamp_ms, "nonce": nonce, "signature": signature}}))
            hello = json.loads(await asyncio.wait_for(ws.recv(), timeout=2))
            assert hello["type"] == "hello"
            assert hello["payload"]["authenticated"] is True

            await ws.send(json.dumps({"type": "text_input", "request_id": "text-1", "device_id": "iphone", "project_key": "default", "payload": {"text": "ping", "client_msg_id": "client-3", "is_final": True}}))
            frames = [json.loads(await asyncio.wait_for(ws.recv(), timeout=3)) for _ in range(4)]
            assert any(frame["type"] == "state_update" and frame["payload"].get("op") == "fast_ack" for frame in frames)
            assert any(frame["type"] == "run_status" and frame["payload"]["status"] == "running" for frame in frames)
            message_frames = [frame for frame in frames if frame["type"] == "state_update" and frame["payload"].get("message")]
            assert message_frames
            assert any(frame["project_key"] == "default" and frame["payload"]["message"]["content"] == "ping" for frame in message_frames)
            assert any(frame["project_key"] == "default" and frame["payload"]["message"]["content"] == "echo: ping" for frame in message_frames)
    finally:
        await adapter.disconnect()
