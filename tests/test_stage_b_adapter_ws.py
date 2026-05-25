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
async def test_logos_timeout_config_defaults_overrides_and_handshake_payloads(tmp_path, monkeypatch):
    monkeypatch.delenv("LOGOS_TIMEOUT_SECONDS", raising=False)
    adapter = LogosAdapter(
        PlatformConfig(enabled=True, extra={"device_secret": "dev-secret", "store_path": str(tmp_path / "default.db")})
    )

    assert adapter.stale_timeout_seconds == 900
    hello = await adapter.handle_ws_envelope(
        Envelope(type="hello", request_id="hello-default", device_id="iphone", project_key="archwright", payload={})
    )
    assert hello["payload"]["client_config"]["stale_timeout_seconds"] == 900
    registered = adapter._handle_register_device(
        Envelope(type="register_device", request_id="reg-default", device_id="iphone", project_key="archwright", payload={})
    )
    assert registered["payload"]["client_config"]["stale_timeout_seconds"] == 900

    configured = LogosAdapter(
        PlatformConfig(enabled=True, extra={"device_secret": "dev-secret", "timeout_seconds": 120, "store_path": str(tmp_path / "configured.db")})
    )
    assert configured.stale_timeout_seconds == 120

    monkeypatch.setenv("LOGOS_TIMEOUT_SECONDS", "45")
    env_override = LogosAdapter(
        PlatformConfig(enabled=True, extra={"device_secret": "dev-secret", "timeout_seconds": 120, "store_path": str(tmp_path / "env.db")})
    )
    assert env_override.stale_timeout_seconds == 45

    monkeypatch.setenv("LOGOS_TIMEOUT_SECONDS", "not-a-number")
    invalid_env_falls_back_to_config = LogosAdapter(
        PlatformConfig(enabled=True, extra={"device_secret": "dev-secret", "timeout_seconds": 75, "store_path": str(tmp_path / "invalid-env.db")})
    )
    assert invalid_env_falls_back_to_config.stale_timeout_seconds == 75

    invalid_config = LogosAdapter(
        PlatformConfig(enabled=True, extra={"device_secret": "dev-secret", "timeout_seconds": -1, "store_path": str(tmp_path / "invalid-config.db")})
    )
    assert invalid_config.stale_timeout_seconds == 900

    monkeypatch.setenv("LOGOS_TIMEOUT_SECONDS", str(999999999))
    clamped = LogosAdapter(
        PlatformConfig(enabled=True, extra={"device_secret": "dev-secret", "store_path": str(tmp_path / "clamped.db")})
    )
    assert clamped.stale_timeout_seconds == 86400


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
async def test_context_request_id_and_session_are_applied_when_metadata_omits_session(tmp_path):
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
    assert progress_frames[-1]["request_id"] == "req-custom-session"
    assert progress_frames[-1]["session_id"] == "custom-session"


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
    assert frame["payload"]["message"]["metadata"]["finalized"] is True
    assert frame["payload"]["message"]["metadata"]["source"] == "hermes"
    assert fake_server.frames[-1]["frame"]["type"] == "run_status"
    assert fake_server.frames[-1]["frame"]["payload"]["status"] == "idle"


@pytest.mark.asyncio
async def test_final_answer_about_context_compression_is_not_classified_as_progress(tmp_path):
    final_answers = [
        "Context compression is useful when a conversation grows long.",
        "Context compression: a practical technique for long conversations.",
        "Preflight compression: a practical technique for long conversations.",
        "Context compression for long conversations reduces token usage.",
        "Compacting context for long tasks can help.",
        "Preflight compression: compacting context can reduce token usage.",
        "Context compression: compressing older turns is useful.",
        "Context compression: complete guide to long conversations.",
        "Preflight compression: context management for long prompts.",
        "Context compression: starting with a short summary can help.",
    ]

    for index, content in enumerate(final_answers):
        adapter = LogosAdapter(PlatformConfig(enabled=True, extra={"device_secret": "dev-secret", "store_path": str(tmp_path / f"logos-{index}.db")}))
        fake_server = FakeServer()
        adapter.ws_server = fake_server  # type: ignore[assignment]

        result = await adapter.send(
            "project:archwright",
            content,
            metadata={"session_id": "sess-context-answer", "request_id": f"req-context-answer-{index}"},
        )

        assert result.success is True
        assert not [item["frame"] for item in fake_server.frames if item["frame"]["type"] == "tool_progress"], content
        state_updates = [item["frame"] for item in fake_server.frames if item["frame"]["type"] == "state_update" and item["frame"]["payload"].get("op") == "message_appended"]
        assert state_updates
        message = state_updates[-1]["payload"]["message"]
        assert message["content"] == content
        assert message["metadata"]["finalized"] is True
        assert message["metadata"]["source"] == "hermes"


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
    assert stored.metadata["finalized"] is True
    assert stored.metadata["source"] == "hermes"
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
async def test_tool_progress_send_and_edit_persist_durable_progress_frames(tmp_path):
    adapter = LogosAdapter(PlatformConfig(enabled=True, extra={"device_secret": "dev-secret", "store_path": str(tmp_path / "logos.db")}))
    fake_server = FakeServer()
    adapter.ws_server = fake_server  # type: ignore[assignment]

    sent = await adapter.send("project:archwright", "🔧 terminal: \"pytest\"", metadata={"session_id": "sess-progress"})

    assert sent.success is True
    assert str(sent.message_id).startswith("progress-")
    stored_messages = adapter.store.messages_after_server_seq("archwright", 0)
    assert [message.content for message in stored_messages] == ["🔧 terminal: \"pytest\""]
    assert stored_messages[0].metadata["source"] == "tool_progress"
    assert stored_messages[0].metadata["progress_kind"] == "tool_progress"
    assert stored_messages[0].metadata["finalized"] is False
    assert stored_messages[0].metadata["transient"] is False
    first_frame = fake_server.frames[-1]["frame"]
    assert first_frame["type"] == "tool_progress"
    assert first_frame["project_key"] == "archwright"
    assert first_frame["session_id"] == "sess-progress"
    assert first_frame["payload"]["text"] == "🔧 terminal: \"pytest\""
    assert first_frame["payload"]["transient"] is False
    assert first_frame["payload"]["message"]["message_id"] == sent.message_id
    assert first_frame["payload"]["message"]["metadata"]["source"] == "tool_progress"

    edited = await adapter.edit_message("project:archwright", sent.message_id, "🔧 terminal: \"pytest\"\n🔍 web_search: \"docs\"")

    assert edited.success is True
    assert edited.message_id == sent.message_id
    stored_messages = adapter.store.messages_after_server_seq("archwright", 0)
    assert len(stored_messages) == 1
    assert stored_messages[0].content == "🔧 terminal: \"pytest\"\n🔍 web_search: \"docs\""
    assert stored_messages[0].metadata["finalized"] is False
    second_frame = fake_server.frames[-1]["frame"]
    assert second_frame["type"] == "tool_progress"
    assert second_frame["request_id"] == sent.message_id
    assert second_frame["payload"]["text"] == "🔧 terminal: \"pytest\"\n🔍 web_search: \"docs\""
    assert second_frame["payload"]["message"]["server_seq"] == stored_messages[0].server_seq


@pytest.mark.asyncio
async def test_progress_message_id_finalize_persists_progress_and_appends_final_content(tmp_path):
    adapter = LogosAdapter(PlatformConfig(enabled=True, extra={"device_secret": "dev-secret", "store_path": str(tmp_path / "logos.db")}))
    fake_server = FakeServer()
    adapter.ws_server = fake_server  # type: ignore[assignment]

    sent = await adapter.send("project:archwright", "🔧 terminal: \"pytest\"", metadata={"session_id": "sess-progress"})
    assert sent.success is True
    assert str(sent.message_id).startswith("progress-")

    edited = await adapter.edit_message("project:archwright", sent.message_id, "Final answer after the tool finished.", finalize=True)

    assert edited.success is True
    assert edited.message_id != sent.message_id
    stored = adapter.store.get_message("sess-progress", str(sent.message_id))
    assert stored is not None
    assert stored.content == "🔧 terminal: \"pytest\""
    assert stored.metadata["source"] == "tool_progress"
    assert stored.metadata["finalized"] is False
    final_stored = adapter.store.get_message("sess-progress", str(edited.message_id))
    assert final_stored is not None
    assert final_stored.content == "Final answer after the tool finished."
    assert final_stored.metadata["finalized"] is True
    assert final_stored.metadata["source"] == "hermes"
    assert final_stored.metadata.get("source") != "tool_progress"
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
    assert [message["content"] for message in replay["payload"]["messages"]] == ["🔧 terminal: \"pytest\"", "Final answer after the tool finished."]


@pytest.mark.asyncio
async def test_send_final_with_progress_message_id_appends_separate_final_instead_of_reusing_progress(tmp_path):
    adapter = LogosAdapter(PlatformConfig(enabled=True, extra={"device_secret": "dev-secret", "store_path": str(tmp_path / "logos.db")}))
    fake_server = FakeServer()
    adapter.ws_server = fake_server  # type: ignore[assignment]

    progress = await adapter.send(
        "project:archwright",
        "🔧 terminal: \"pytest\"",
        metadata={"session_id": "sess-progress", "message_id": "hermes-progress-1", "request_id": "req-progress-1"},
    )
    final = await adapter.send(
        "project:archwright",
        "Final answer after progress id collision.",
        metadata={"session_id": "sess-progress", "message_id": "hermes-progress-1", "request_id": "req-progress-1", "source": "hermes"},
    )

    assert progress.success is True
    assert final.success is True
    assert final.message_id != progress.message_id
    stored_progress = adapter.store.get_message("sess-progress", "hermes-progress-1")
    stored_final = adapter.store.get_message("sess-progress", str(final.message_id))
    assert stored_progress is not None
    assert stored_progress.content == "🔧 terminal: \"pytest\""
    assert stored_progress.metadata["source"] == "tool_progress"
    assert stored_final is not None
    assert stored_final.content == "Final answer after progress id collision."
    assert stored_final.metadata["request_id"] == "req-progress-1"
    assert stored_final.metadata.get("source") == "hermes"
    replay = adapter._handle_messages_get(
        Envelope(type="messages_get", request_id="get-collision", device_id="iphone", project_key="archwright", payload={"after_server_seq": 0})
    )
    assert [message["content"] for message in replay["payload"]["messages"]] == [
        "🔧 terminal: \"pytest\"",
        "Final answer after progress id collision.",
    ]


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
async def test_custom_progress_message_id_finalize_uses_original_session_and_persists_both_messages(tmp_path):
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
    stored_messages = adapter.store.messages_after_server_seq("archwright", 0)
    assert [message.content for message in stored_messages] == ["🔧 terminal: \"pytest\""]
    assert stored_messages[0].metadata["source"] == "tool_progress"

    progressed = await adapter.edit_message("project:archwright", "hermes-msg-42", "🔍 web_search: \"docs\"", finalize=False)
    assert progressed.success is True
    assert progressed.message_id == "hermes-msg-42"
    assert progressed.raw_response["session_id"] == "sess-progress"

    edited = await adapter.edit_message("project:archwright", "hermes-msg-42", "Final answer for the caller-supplied message id.", finalize=True)

    assert edited.success is True
    stored = adapter.store.get_message("sess-progress", "hermes-msg-42")
    assert stored is not None
    assert stored.content == "🔍 web_search: \"docs\""
    assert stored.metadata["source"] == "tool_progress"
    assert stored.metadata["progress_kind"] == "terminal"
    assert stored.metadata["finalized"] is False
    final_stored = adapter.store.get_message("sess-progress", str(edited.message_id))
    assert final_stored is not None
    assert final_stored.message_id != "hermes-msg-42"
    assert final_stored.content == "Final answer for the caller-supplied message id."
    assert final_stored.metadata["finalized"] is True
    assert final_stored.metadata.get("source") != "tool_progress"
    assert "progress_kind" not in final_stored.metadata
    assert "kind" not in final_stored.metadata
    assert adapter.store.get_message("project:archwright", "hermes-msg-42") is None
    frames = [item["frame"] for item in fake_server.frames]
    assert [frame["type"] for frame in frames] == ["tool_progress", "tool_progress", "state_update", "state_update", "run_status"]
    assert frames[2]["request_id"] == "hermes-msg-42"
    assert frames[2]["payload"]["op"] == "message_appended"
    assert frames[2]["payload"]["message"]["message_id"] == final_stored.message_id
    assert frames[2]["payload"]["message"]["metadata"].get("source") != "tool_progress"
    assert "progress_kind" not in frames[2]["payload"]["message"]["metadata"]


@pytest.mark.asyncio
async def test_send_typing_emits_throttled_scoped_keepalive_run_status(tmp_path):
    adapter = LogosAdapter(PlatformConfig(enabled=True, extra={"device_secret": "dev-secret", "store_path": str(tmp_path / "logos.db")}))
    fake_server = FakeServer()
    adapter.ws_server = fake_server  # type: ignore[assignment]

    await adapter.send_typing(
        "project:archwright",
        metadata={"session_id": "sess-typing", "request_id": "req-typing", "device_id": "iphone"},
    )
    await adapter.send_typing(
        "project:archwright",
        metadata={"session_id": "sess-typing", "request_id": "req-typing", "device_id": "iphone"},
    )

    frames = [item["frame"] for item in fake_server.frames]
    assert len(frames) == 1
    frame = frames[0]
    assert frame["type"] == "run_status"
    assert frame["request_id"] == "req-typing"
    assert frame["project_key"] == "archwright"
    assert frame["session_id"] == "sess-typing"
    assert frame["device_id"] == "iphone"
    assert frame["payload"]["status"] == "running"
    assert frame["payload"]["keepalive"] is True
    assert frame["payload"]["source"] == "typing"
    assert frame["payload"]["stale_timeout_seconds"] == 900


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
async def test_retry_status_send_broadcasts_transient_status_progress_without_idle(tmp_path):
    adapter = LogosAdapter(PlatformConfig(enabled=True, extra={"device_secret": "dev-secret", "store_path": str(tmp_path / "logos.db")}))
    fake_server = FakeServer()
    adapter.ws_server = fake_server  # type: ignore[assignment]
    content = "⏳ Retrying in 2.6s (attempt 1/3)..."

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
async def test_provider_abort_status_send_broadcasts_transient_status_progress_without_idle(tmp_path):
    adapter = LogosAdapter(PlatformConfig(enabled=True, extra={"device_secret": "dev-secret", "store_path": str(tmp_path / "logos.db")}))
    fake_server = FakeServer()
    adapter.ws_server = fake_server  # type: ignore[assignment]
    content = "⚠️ No response from provider for 300s (non-streaming, model: gpt-5.5). Aborting call."

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
async def test_context_compaction_status_send_broadcasts_transient_status_progress_without_idle(tmp_path):
    adapter = LogosAdapter(PlatformConfig(enabled=True, extra={"device_secret": "dev-secret", "store_path": str(tmp_path / "logos.db")}))
    fake_server = FakeServer()
    adapter.ws_server = fake_server  # type: ignore[assignment]
    content = "Preflight compression: compacting context before continuing."

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
            assert hello["payload"]["client_config"]["stale_timeout_seconds"] == 900

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
