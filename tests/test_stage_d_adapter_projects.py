from __future__ import annotations

import pytest

from gateway.config import PlatformConfig
from logos.adapter import LogosAdapter
from logos.schema import Envelope


class CapturingLogosAdapter(LogosAdapter):
    def __init__(self, config: PlatformConfig):
        super().__init__(config)
        self.captured_events = []

    async def handle_message(self, event):  # type: ignore[override]
        self.captured_events.append(event)


@pytest.mark.asyncio
async def test_adapter_project_lifecycle_frames_update_store_and_return_picker_data(tmp_path):
    adapter = LogosAdapter(PlatformConfig(enabled=True, extra={"device_secret": "dev-secret", "store_path": str(tmp_path / "logos.db")}))

    created = await adapter.handle_ws_envelope(
        Envelope(type="new_project", request_id="new-1", device_id="iphone", payload={"title": "Archwright Phase 6"})
    )
    listed = await adapter.handle_ws_envelope(
        Envelope(type="list_projects", request_id="list-1", device_id="iphone", payload={})
    )
    switched = await adapter.handle_ws_envelope(
        Envelope(type="switch_project", request_id="switch-1", device_id="iphone", payload={"project_key": "archwright-phase-6"})
    )
    renamed = await adapter.handle_ws_envelope(
        Envelope(type="rename_project", request_id="rename-1", device_id="iphone", project_key="archwright-phase-6", payload={"title": "Archwright"})
    )

    assert created["type"] == "state_update"
    assert created["payload"]["op"] == "project_created"
    assert created["payload"]["project"]["project_key"] == "archwright-phase-6"
    assert listed["type"] == "projects_list"
    assert listed["payload"]["projects"][0]["project_key"] == "archwright-phase-6"
    assert switched["payload"]["op"] == "active_project_changed"
    assert switched["payload"]["project"]["project_key"] == "archwright-phase-6"
    assert renamed["payload"]["op"] == "project_renamed"
    assert renamed["payload"]["project"]["title"] == "Archwright"


@pytest.mark.asyncio
async def test_final_text_without_project_key_uses_device_active_project_and_preserves_resume_slash(tmp_path):
    adapter = CapturingLogosAdapter(
        PlatformConfig(enabled=True, extra={"device_secret": "dev-secret", "store_path": str(tmp_path / "logos.db")})
    )
    await adapter.handle_ws_envelope(
        Envelope(type="new_project", request_id="new-1", device_id="iphone", payload={"title": "Alpha"})
    )
    await adapter.handle_ws_envelope(
        Envelope(type="switch_project", request_id="switch-1", device_id="iphone", payload={"project_key": "alpha"})
    )

    await adapter.handle_ws_envelope(
        Envelope(type="text_input", request_id="text-1", device_id="iphone", payload={"text": "/resume Alpha", "is_final": True})
    )

    assert len(adapter.captured_events) == 1
    event = adapter.captured_events[0]
    assert event.text == "/resume Alpha"
    assert event.source.chat_id == "project:alpha"
    assert event.source.chat_name == "Alpha"


@pytest.mark.asyncio
async def test_send_updates_project_session_pointer_for_picker(tmp_path):
    adapter = LogosAdapter(PlatformConfig(enabled=True, extra={"device_secret": "dev-secret", "store_path": str(tmp_path / "logos.db")}))

    await adapter.send("project:alpha", "hello", metadata={"session_id": "sess-alpha"})
    listed = await adapter.handle_ws_envelope(
        Envelope(type="list_projects", request_id="list-1", device_id="iphone", payload={})
    )

    project = listed["payload"]["projects"][0]
    assert project["project_key"] == "alpha"
    assert project["current_session_id"] == "sess-alpha"
    assert project["last_preview"] == "hello"
