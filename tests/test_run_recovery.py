"""WS2 phase H: durable run recovery via the on_processing_start / on_processing_complete hooks.

Hermes-dependent (MessageEvent / ProcessingOutcome) — listed in conftest's Tier-1 skip set.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any

import pytest

from gateway.config import PlatformConfig
from gateway.platforms.base import MessageEvent, MessageType, ProcessingOutcome
from gateway.session import SessionSource
from logos.adapter import LogosAdapter


@dataclass
class FakeServer:
    frames: list[dict[str, Any]] = field(default_factory=list)

    async def broadcast(self, frame: dict[str, Any], *, project_key: str | None = None) -> None:
        self.frames.append({"frame": frame, "project_key": project_key})

    def run_status_frames(self) -> list[dict[str, Any]]:
        return [item["frame"] for item in self.frames if item["frame"].get("type") == "run_status"]


def _make_adapter(tmp_path, name: str = "run.db") -> LogosAdapter:
    adapter = LogosAdapter(
        PlatformConfig(enabled=True, extra={"device_secret": "dev-secret", "store_path": str(tmp_path / name)})
    )
    adapter.ws_server = FakeServer()
    return adapter


def _event(adapter: LogosAdapter, *, text: str, request_id: str, project_key: str = "archwright", session_id: str = "s1") -> MessageEvent:
    return MessageEvent(
        text=text,
        message_type=MessageType.TEXT,
        source=SessionSource(
            platform=adapter.platform,
            chat_id=f"project:{project_key}",
            chat_name=project_key,
            chat_type="dm",
            user_id="iphone",
            user_name="iphone",
            message_id="client-1",
        ),
        raw_message={
            "type": "text_input",
            "request_id": request_id,
            "project_key": project_key,
            "session_id": session_id,
            "payload": {"text": text},
        },
        message_id="client-1",
    )


@pytest.mark.asyncio
async def test_on_processing_start_records_run_origin(tmp_path):
    adapter = _make_adapter(tmp_path)
    await adapter.on_processing_start(_event(adapter, text="build the thing", request_id="req-1"))

    state = adapter.store.latest_run_state("archwright")
    assert state is not None
    assert state.status == "running"
    assert state.origin_request_id == "req-1"
    assert state.started_at is not None
    assert state.origin_text == "build the thing"


@pytest.mark.asyncio
async def test_on_processing_complete_failure_reconciles_with_retry_text(tmp_path):
    adapter = _make_adapter(tmp_path)
    event = _event(adapter, text="build the thing", request_id="req-1")
    await adapter.on_processing_start(event)
    adapter.ws_server.frames.clear()

    await adapter.on_processing_complete(event, ProcessingOutcome.FAILURE)

    state = adapter.store.latest_run_state("archwright")
    assert state is not None
    assert state.status == "error"
    assert state.payload.get("interrupted") is True
    assert state.payload.get("final_status") == "failed"
    assert state.payload.get("retry_text") == "build the thing"

    statuses = adapter.ws_server.run_status_frames()
    assert statuses, "expected a run_status broadcast so a connected client clears the spinner"
    assert statuses[-1]["payload"]["status"] == "error"


@pytest.mark.asyncio
async def test_on_processing_complete_cancelled_is_interrupted(tmp_path):
    adapter = _make_adapter(tmp_path)
    event = _event(adapter, text="long task", request_id="req-2")
    await adapter.on_processing_start(event)
    adapter.ws_server.frames.clear()

    await adapter.on_processing_complete(event, ProcessingOutcome.CANCELLED)

    state = adapter.store.latest_run_state("archwright")
    assert state.status == "idle"
    assert state.payload.get("final_status") == "cancelled"
    assert state.payload.get("interrupted") is True


@pytest.mark.asyncio
async def test_on_processing_complete_is_idempotent_after_final_message(tmp_path):
    adapter = _make_adapter(tmp_path)
    event = _event(adapter, text="hi", request_id="req-3")
    await adapter.on_processing_start(event)
    # Simulate Hermes' final response already having flipped the run idle via send().
    adapter.store.upsert_run_state(project_key="archwright", session_id="s1", status="idle", request_id="req-3")
    adapter.ws_server.frames.clear()

    await adapter.on_processing_complete(event, ProcessingOutcome.SUCCESS)

    # Already terminal -> the hook must not re-broadcast or re-reconcile.
    assert adapter.ws_server.run_status_frames() == []


@pytest.mark.asyncio
async def test_on_processing_complete_ignores_mismatched_request(tmp_path):
    adapter = _make_adapter(tmp_path)
    await adapter.on_processing_start(_event(adapter, text="first", request_id="req-A"))
    # A newer run for the same project is now active.
    adapter.store.upsert_run_state(project_key="archwright", session_id="s1", status="running", request_id="req-B")
    adapter.ws_server.frames.clear()

    # The stale completion for req-A must not terminate the active req-B run.
    await adapter.on_processing_complete(_event(adapter, text="first", request_id="req-A"), ProcessingOutcome.FAILURE)

    state = adapter.store.latest_run_state("archwright")
    assert state.status == "running"
    assert state.request_id == "req-B"
    assert adapter.ws_server.run_status_frames() == []


@pytest.mark.asyncio
async def test_on_processing_complete_success_without_final_message_idles(tmp_path):
    adapter = _make_adapter(tmp_path)
    event = _event(adapter, text="hi", request_id="req-4")
    await adapter.on_processing_start(event)
    adapter.ws_server.frames.clear()

    await adapter.on_processing_complete(event, ProcessingOutcome.SUCCESS)

    state = adapter.store.latest_run_state("archwright")
    assert state.status == "idle"
    assert state.payload.get("final_status") == "completed"
    assert state.payload.get("interrupted") is not True
