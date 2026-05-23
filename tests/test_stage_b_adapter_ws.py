from __future__ import annotations

import asyncio
import json
import time
from dataclasses import dataclass, field
from typing import Any

import pytest
import websockets

from gateway.config import PlatformConfig
from gateway.platforms.base import MessageEvent, MessageType
from gateway.session import SessionSource
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
async def test_gateway_progress_and_final_reuse_inbound_request_id(tmp_path):
    adapter = LogosAdapter(
        PlatformConfig(enabled=True, extra={"device_secret": "dev-secret", "host": "127.0.0.1", "port": 0, "store_path": str(tmp_path / "logos.db")})
    )
    fake_server = FakeServer()
    adapter.ws_server = fake_server  # type: ignore[assignment]
    handled = asyncio.Event()

    async def fake_gateway_handler(event):
        session_id = event.raw_message["session_id"]
        await adapter.send(event.source.chat_id, "🔧 terminal: \"pytest\"", metadata={"session_id": session_id})
        await adapter.send(
            event.source.chat_id,
            "Final answer for correlated request.",
            metadata={"session_id": session_id, "message_id": "logos-final-correlated"},
        )
        handled.set()
        return None

    adapter.set_message_handler(fake_gateway_handler)

    await adapter.handle_ws_envelope(
        Envelope(
            type="text_input",
            request_id="req-root-normal",
            device_id="iphone-17-pro",
            project_key="archwright",
            payload={"text": "run normal gateway work", "is_final": True, "client_msg_id": "client-normal"},
        )
    )
    await asyncio.wait_for(handled.wait(), timeout=2)

    frames = [item["frame"] for item in fake_server.frames]
    progress_frames = [frame for frame in frames if frame["type"] == "tool_progress"]
    final_frames = [
        frame
        for frame in frames
        if frame["type"] == "state_update"
        and frame["payload"].get("op") == "message_appended"
        and frame["payload"]["message"]["message_id"] == "logos-final-correlated"
    ]
    assert progress_frames
    assert progress_frames[-1]["request_id"] == "req-root-normal"
    assert final_frames
    assert final_frames[-1]["request_id"] == "req-root-normal"


@pytest.mark.asyncio
async def test_queued_followup_does_not_relabel_active_run_progress_with_new_request_id(tmp_path):
    adapter = LogosAdapter(
        PlatformConfig(enabled=True, extra={"device_secret": "dev-secret", "host": "127.0.0.1", "port": 0, "store_path": str(tmp_path / "logos.db")})
    )
    fake_server = FakeServer()
    adapter.ws_server = fake_server  # type: ignore[assignment]
    active_run_may_emit = asyncio.Event()
    active_run_emitted = asyncio.Event()

    async def fake_gateway_handler(event):
        session_id = event.raw_message["session_id"]
        if event.text == "first request":
            await active_run_may_emit.wait()
            await adapter.send(event.source.chat_id, "🔧 terminal: \"old-after-new\"", metadata={"session_id": session_id})
            active_run_emitted.set()
            return None
        return None

    adapter.set_message_handler(fake_gateway_handler)

    await adapter.handle_ws_envelope(
        Envelope(
            type="text_input",
            request_id="req-A",
            device_id="iphone-17-pro",
            project_key="archwright",
            payload={"text": "first request", "is_final": True, "client_msg_id": "client-A"},
        )
    )
    await asyncio.sleep(0)
    await adapter.handle_ws_envelope(
        Envelope(
            type="text_input",
            request_id="req-B",
            device_id="iphone-17-pro",
            project_key="archwright",
            payload={"text": "second request", "is_final": True, "client_msg_id": "client-B"},
        )
    )
    active_run_may_emit.set()
    await asyncio.wait_for(active_run_emitted.wait(), timeout=2)

    progress_frames = [
        item["frame"]
        for item in fake_server.frames
        if item["frame"]["type"] == "tool_progress" and item["frame"]["payload"]["text"] == "🔧 terminal: \"old-after-new\""
    ]
    assert progress_frames
    assert progress_frames[-1]["request_id"] == "req-A"
    assert progress_frames[-1]["request_id"] != "req-B"


@pytest.mark.asyncio
async def test_requestless_queued_followup_does_not_inherit_active_request_context(tmp_path):
    adapter = LogosAdapter(
        PlatformConfig(enabled=True, extra={"device_secret": "dev-secret", "host": "127.0.0.1", "port": 0, "store_path": str(tmp_path / "logos.db")})
    )
    fake_server = FakeServer()
    adapter.ws_server = fake_server  # type: ignore[assignment]
    active_run_may_finish = asyncio.Event()
    requestless_done = asyncio.Event()

    async def fake_gateway_handler(event):
        session_id = event.raw_message["session_id"]
        if event.text == "first request":
            await active_run_may_finish.wait()
            return None
        if event.text == "requestless followup":
            await adapter.send(event.source.chat_id, "🔧 terminal: \"requestless\"", metadata={"session_id": session_id})
            requestless_done.set()
            return None
        return None

    adapter.set_message_handler(fake_gateway_handler)

    await adapter.handle_ws_envelope(
        Envelope(
            type="text_input",
            request_id="req-A",
            device_id="iphone-17-pro",
            project_key="archwright",
            payload={"text": "first request", "is_final": True, "client_msg_id": "client-A"},
        )
    )
    await asyncio.sleep(0)
    await adapter.handle_ws_envelope(
        Envelope(
            type="text_input",
            request_id=None,
            device_id="iphone-17-pro",
            project_key="archwright",
            payload={"text": "requestless followup", "is_final": True, "client_msg_id": "client-requestless"},
        )
    )
    active_run_may_finish.set()
    await asyncio.wait_for(requestless_done.wait(), timeout=2)

    progress_frames = [
        item["frame"]
        for item in fake_server.frames
        if item["frame"]["type"] == "tool_progress" and item["frame"]["payload"]["text"] == "🔧 terminal: \"requestless\""
    ]
    assert progress_frames
    assert progress_frames[-1]["request_id"] != "req-A"


@pytest.mark.asyncio
async def test_context_request_id_is_not_applied_to_different_session_send(tmp_path):
    adapter = LogosAdapter(
        PlatformConfig(enabled=True, extra={"device_secret": "dev-secret", "host": "127.0.0.1", "port": 0, "store_path": str(tmp_path / "logos.db")})
    )
    fake_server = FakeServer()
    adapter.ws_server = fake_server  # type: ignore[assignment]
    handled = asyncio.Event()

    async def fake_gateway_handler(event):
        await adapter.send(event.source.chat_id, "🔧 terminal: \"wrong-session\"")
        handled.set()
        return None

    adapter.set_message_handler(fake_gateway_handler)
    event = MessageEvent(
        text="custom session request",
        message_type=MessageType.TEXT,
        source=SessionSource(
            platform=adapter.platform,
            chat_id="project:archwright",
            chat_name="archwright",
            chat_type="dm",
            user_id="iphone-17-pro",
            user_name="iphone-17-pro",
            message_id="client-custom",
        ),
        raw_message={
            "type": "text_input",
            "request_id": "req-custom-session",
            "project_key": "archwright",
            "session_id": "custom-session",
            "payload": {"text": "custom session request", "is_final": True, "client_msg_id": "client-custom"},
        },
        message_id="client-custom",
    )

    await adapter.handle_message(event)
    await asyncio.wait_for(handled.wait(), timeout=2)

    progress_frames = [
        item["frame"]
        for item in fake_server.frames
        if item["frame"]["type"] == "tool_progress" and item["frame"]["payload"]["text"] == "🔧 terminal: \"wrong-session\""
    ]
    assert progress_frames
    assert progress_frames[-1]["request_id"] != "req-custom-session"


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
async def test_edit_message_updates_existing_logos_message_for_final_content(tmp_path):
    adapter = LogosAdapter(PlatformConfig(enabled=True, extra={"device_secret": "dev-secret", "store_path": str(tmp_path / "logos.db")}))
    fake_server = FakeServer()
    adapter.ws_server = fake_server  # type: ignore[assignment]

    sent = await adapter.send("project:archwright", "Hermes is drafting the response.", metadata={"session_id": "sess-1"})
    original = adapter.store.get_message("sess-1", sent.message_id)
    assert original is not None
    original_summary = adapter.store.get_summary(original.session_id, original.message_id)
    assert original_summary is not None
    edited = await adapter.edit_message("project:archwright", sent.message_id, "Hermes finished the response.", finalize=True)

    assert edited.success is True
    assert edited.message_id == sent.message_id
    stored = adapter.store.get_message("sess-1", sent.message_id)
    assert stored is not None
    assert stored.content == "Hermes finished the response."
    assert stored.server_seq > original.server_seq
    update_frames = [item["frame"] for item in fake_server.frames if item["frame"]["type"] == "state_update" and item["frame"]["payload"].get("op") == "message_updated"]
    assert update_frames
    update = update_frames[-1]
    assert update["request_id"] == sent.message_id
    assert update["server_seq"] == stored.server_seq
    assert update["payload"]["message"]["message_id"] == sent.message_id
    assert update["payload"]["message"]["server_seq"] == stored.server_seq
    replay = adapter._handle_messages_get(
        Envelope(type="messages_get", request_id="get-after-edit", device_id="iphone", project_key="archwright", payload={"after_server_seq": original.server_seq})
    )
    assert [message["content"] for message in replay["payload"]["messages"]] == ["Hermes finished the response."]
    project = adapter.store.get_project("archwright")
    assert project is not None
    assert project.last_seen_server_seq == stored.server_seq
    assert project.last_preview == "Hermes finished the response."
    summary = adapter.store.get_summary(stored.session_id, stored.message_id)
    assert summary is not None
    assert summary.source_hash != original_summary.source_hash


@pytest.mark.asyncio
async def test_tool_progress_send_and_edit_broadcast_transient_progress_frames(tmp_path):
    adapter = LogosAdapter(PlatformConfig(enabled=True, extra={"device_secret": "dev-secret", "store_path": str(tmp_path / "logos.db")}))
    fake_server = FakeServer()
    adapter.ws_server = fake_server  # type: ignore[assignment]

    sent = await adapter.send("project:archwright", "🔧 terminal: \"pytest\"", metadata={"session_id": "sess-progress"})

    assert sent.success is True
    assert str(sent.message_id).startswith("progress-")
    assert adapter.store.messages_after_server_seq("archwright", 0) == []
    first_frame = fake_server.frames[-1]["frame"]
    assert first_frame["type"] == "tool_progress"
    assert first_frame["project_key"] == "archwright"
    assert first_frame["session_id"] == "sess-progress"
    assert first_frame["payload"]["text"] == "🔧 terminal: \"pytest\""
    assert first_frame["payload"]["transient"] is True

    edited = await adapter.edit_message("project:archwright", sent.message_id, "🔧 terminal: \"pytest\"\n🔍 web_search: \"docs\"")

    assert edited.success is True
    assert edited.message_id == sent.message_id
    assert adapter.store.messages_after_server_seq("archwright", 0) == []
    second_frame = fake_server.frames[-1]["frame"]
    assert second_frame["type"] == "tool_progress"
    assert second_frame["request_id"] == sent.message_id
    assert second_frame["payload"]["text"] == "🔧 terminal: \"pytest\"\n🔍 web_search: \"docs\""


@pytest.mark.asyncio
async def test_progress_message_id_finalize_persists_final_content_instead_of_progress(tmp_path):
    adapter = LogosAdapter(PlatformConfig(enabled=True, extra={"device_secret": "dev-secret", "store_path": str(tmp_path / "logos.db")}))
    fake_server = FakeServer()
    adapter.ws_server = fake_server  # type: ignore[assignment]

    sent = await adapter.send("project:archwright", "🔧 terminal: \"pytest\"", metadata={"session_id": "sess-progress"})
    assert sent.success is True
    assert str(sent.message_id).startswith("progress-")

    edited = await adapter.edit_message("project:archwright", sent.message_id, "Final answer after the tool finished.", finalize=True)

    assert edited.success is True
    assert edited.message_id == sent.message_id
    stored = adapter.store.get_message("sess-progress", str(sent.message_id))
    assert stored is not None
    assert stored.content == "Final answer after the tool finished."
    assert stored.metadata["finalized"] is True
    frames = [item["frame"] for item in fake_server.frames]
    assert frames[0]["type"] == "tool_progress"
    assert frames[-1]["type"] == "run_status"
    state_updates = [frame for frame in frames if frame["type"] == "state_update"]
    assert state_updates[-2]["request_id"] == sent.message_id
    assert state_updates[-2]["payload"]["op"] == "message_appended"
    assert state_updates[-2]["payload"]["message"]["content"] == "Final answer after the tool finished."
    assert state_updates[-1]["payload"]["op"] == "summary_ready"
    replay = adapter._handle_messages_get(
        Envelope(type="messages_get", request_id="get-finalized-progress", device_id="iphone", project_key="archwright", payload={"after_server_seq": 0})
    )
    assert [message["content"] for message in replay["payload"]["messages"]] == ["Final answer after the tool finished."]


@pytest.mark.asyncio
async def test_progress_finalize_preserves_root_request_id_when_present(tmp_path):
    adapter = LogosAdapter(PlatformConfig(enabled=True, extra={"device_secret": "dev-secret", "store_path": str(tmp_path / "logos.db")}))
    fake_server = FakeServer()
    adapter.ws_server = fake_server  # type: ignore[assignment]

    sent = await adapter.send(
        "project:archwright",
        "🔧 terminal: \"pytest\"",
        metadata={"session_id": "sess-progress", "message_id": "hermes-msg-root", "request_id": "req-root-progress"},
    )
    edited = await adapter.edit_message("project:archwright", "hermes-msg-root", "Final answer with root request id.", finalize=True)

    assert sent.success is True
    assert edited.success is True
    frames = [item["frame"] for item in fake_server.frames]
    progress_frames = [frame for frame in frames if frame["type"] == "tool_progress"]
    state_updates = [frame for frame in frames if frame["type"] == "state_update" and frame["payload"].get("op") == "message_appended"]
    assert progress_frames[-1]["request_id"] == "req-root-progress"
    assert state_updates[-1]["request_id"] == "req-root-progress"


@pytest.mark.asyncio
async def test_custom_progress_message_id_finalize_uses_original_session_and_persists(tmp_path):
    adapter = LogosAdapter(PlatformConfig(enabled=True, extra={"device_secret": "dev-secret", "store_path": str(tmp_path / "logos.db")}))
    fake_server = FakeServer()
    adapter.ws_server = fake_server  # type: ignore[assignment]

    sent = await adapter.send(
        "project:archwright",
        "🔧 terminal: \"pytest\"",
        metadata={
            "session_id": "sess-progress",
            "message_id": "hermes-msg-42",
            "source": "tool_progress",
            "progress_kind": "terminal",
        },
    )
    assert sent.success is True
    assert sent.message_id == "hermes-msg-42"
    assert adapter.store.messages_after_server_seq("archwright", 0) == []

    progressed = await adapter.edit_message("project:archwright", "hermes-msg-42", "🔍 web_search: \"docs\"", finalize=False)
    assert progressed.success is True
    assert progressed.message_id == "hermes-msg-42"
    assert progressed.raw_response["session_id"] == "sess-progress"

    edited = await adapter.edit_message("project:archwright", "hermes-msg-42", "Final answer for the caller-supplied message id.", finalize=True)

    assert edited.success is True
    stored = adapter.store.get_message("sess-progress", "hermes-msg-42")
    assert stored is not None
    assert stored.content == "Final answer for the caller-supplied message id."
    assert stored.metadata["finalized"] is True
    assert stored.metadata.get("source") != "tool_progress"
    assert "progress_kind" not in stored.metadata
    assert "kind" not in stored.metadata
    assert adapter.store.get_message("project:archwright", "hermes-msg-42") is None
    frames = [item["frame"] for item in fake_server.frames]
    assert [frame["type"] for frame in frames] == ["tool_progress", "tool_progress", "state_update", "state_update", "run_status"]
    assert frames[2]["request_id"] == "hermes-msg-42"
    assert frames[2]["payload"]["op"] == "message_appended"
    assert frames[2]["payload"]["message"]["message_id"] == "hermes-msg-42"
    assert frames[2]["payload"]["message"]["metadata"].get("source") != "tool_progress"
    assert "progress_kind" not in frames[2]["payload"]["message"]["metadata"]


@pytest.mark.asyncio
async def test_gateway_still_working_send_broadcasts_transient_status_progress_without_idle(tmp_path):
    adapter = LogosAdapter(PlatformConfig(enabled=True, extra={"device_secret": "dev-secret", "store_path": str(tmp_path / "logos.db")}))
    fake_server = FakeServer()
    adapter.ws_server = fake_server  # type: ignore[assignment]
    content = "⏳ Still working... (3 min elapsed — iteration 1/1000, API call #1 completed)"

    sent = await adapter.send("project:archwright", content, metadata={"session_id": "sess-progress"})

    assert sent.success is True
    assert str(sent.message_id).startswith("progress-")
    assert adapter.store.messages_after_server_seq("archwright", 0) == []
    frames = [item["frame"] for item in fake_server.frames]
    assert [frame["type"] for frame in frames] == ["tool_progress"]
    frame = frames[0]
    assert frame["project_key"] == "archwright"
    assert frame["session_id"] == "sess-progress"
    assert frame["payload"]["kind"] == "gateway_status"
    assert frame["payload"]["progress_kind"] == "gateway_status"
    assert frame["payload"]["text"] == content
    assert frame["payload"]["transient"] is True


@pytest.mark.asyncio
async def test_gateway_restart_warning_send_broadcasts_transient_status_progress_without_idle(tmp_path):
    adapter = LogosAdapter(PlatformConfig(enabled=True, extra={"device_secret": "dev-secret", "store_path": str(tmp_path / "logos.db")}))
    fake_server = FakeServer()
    adapter.ws_server = fake_server  # type: ignore[assignment]
    content = "⚠️ Gateway restarting — Your current task will be interrupted. Send any message after restart and I'll try to resume where you left off."

    sent = await adapter.send("project:archwright", content, metadata={"session_id": "sess-progress"})

    assert sent.success is True
    assert str(sent.message_id).startswith("progress-")
    assert adapter.store.messages_after_server_seq("archwright", 0) == []
    frames = [item["frame"] for item in fake_server.frames]
    assert [frame["type"] for frame in frames] == ["tool_progress"]
    frame = frames[0]
    assert frame["payload"]["kind"] == "gateway_status"
    assert frame["payload"]["progress_kind"] == "gateway_status"
    assert frame["payload"]["text"] == content


@pytest.mark.asyncio
async def test_gateway_shutdown_warning_send_broadcasts_transient_status_progress_without_idle(tmp_path):
    adapter = LogosAdapter(PlatformConfig(enabled=True, extra={"device_secret": "dev-secret", "store_path": str(tmp_path / "logos.db")}))
    fake_server = FakeServer()
    adapter.ws_server = fake_server  # type: ignore[assignment]
    content = "⚠️ Gateway shutting down — active work will stop until the gateway is back."

    sent = await adapter.send("project:archwright", content, metadata={"session_id": "sess-progress"})

    assert sent.success is True
    assert str(sent.message_id).startswith("progress-")
    assert adapter.store.messages_after_server_seq("archwright", 0) == []
    frames = [item["frame"] for item in fake_server.frames]
    assert [frame["type"] for frame in frames] == ["tool_progress"]
    frame = frames[0]
    assert frame["payload"]["kind"] == "gateway_status"
    assert frame["payload"]["progress_kind"] == "gateway_status"
    assert frame["payload"]["text"] == content


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
