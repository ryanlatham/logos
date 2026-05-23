from __future__ import annotations

import pytest

from gateway.config import PlatformConfig
from logos.adapter import LogosAdapter, _validate_config
from logos.schema import Envelope


class FakeServer:
    def __init__(self) -> None:
        self.frames: list[dict] = []

    async def broadcast(self, frame: dict, *, project_key: str | None = None) -> None:
        self.frames.append({"frame": frame, "project_key": project_key})


def test_live_plugin_config_accepts_config_secret_without_env(tmp_path, monkeypatch):
    monkeypatch.delenv("LOGOS_DEVICE_SECRET", raising=False)
    config = PlatformConfig(enabled=True, extra={"device_secret": "configured-secret", "store_path": str(tmp_path / "logos.db")})
    assert _validate_config(config) is True
    adapter = LogosAdapter(config)
    assert adapter.device_secret == "configured-secret"


def test_live_plugin_config_accepts_configured_allowed_devices(tmp_path, monkeypatch):
    monkeypatch.delenv("LOGOS_ALLOW_ALL_USERS", raising=False)
    monkeypatch.delenv("LOGOS_ALLOWED_USERS", raising=False)
    configured = LogosAdapter(
        PlatformConfig(
            enabled=True,
            extra={
                "device_secret": "configured-secret",
                "store_path": str(tmp_path / "configured.db"),
                "allowed_users": ["iphone-live", "logos-live-smoke-cli"],
            },
        )
    )
    assert configured.is_device_allowed("logos-live-smoke-cli") is True
    assert configured.is_device_allowed("unknown-device") is False

    allow_all = LogosAdapter(
        PlatformConfig(
            enabled=True,
            extra={
                "device_secret": "configured-secret",
                "store_path": str(tmp_path / "allow-all.db"),
                "allow_all_users": True,
            },
        )
    )
    assert allow_all.is_device_allowed("first-time-iphone") is True

class CapturingLogosAdapter(LogosAdapter):
    def __init__(self, config: PlatformConfig):
        super().__init__(config)
        self.captured_events = []

    async def handle_message(self, event):  # type: ignore[override]
        self.captured_events.append(event)


@pytest.mark.asyncio
async def test_run_cancel_maps_to_gateway_stop_command(tmp_path):
    adapter = CapturingLogosAdapter(PlatformConfig(enabled=True, extra={"device_secret": "dev-secret", "store_path": str(tmp_path / "logos.db")}))
    await adapter.handle_ws_envelope(Envelope(type="new_project", request_id="new", device_id="iphone", payload={"title": "Alpha"}))

    response = await adapter.handle_ws_envelope(Envelope(type="run_cancel", request_id="cancel", device_id="iphone", project_key="alpha", payload={}))

    assert response["type"] == "run_status"
    assert response["payload"]["status"] == "idle"
    assert response["payload"]["cancelled"] is True
    assert adapter.captured_events[-1].text == "/stop"
    assert adapter.captured_events[-1].source.chat_id == "project:alpha"


@pytest.mark.asyncio
async def test_approval_response_requires_matching_pending_request(tmp_path):
    adapter = CapturingLogosAdapter(PlatformConfig(enabled=True, extra={"store_path": str(tmp_path / "logos.db")}))

    rejected = await adapter.handle_ws_envelope(Envelope(type="approval_response", request_id="missing", device_id="iphone", project_key="alpha", payload={"decision": "approve"}))
    assert rejected["type"] == "error"
    assert rejected["payload"]["code"] == "approval_not_pending"

    adapter.store.upsert_pending_interaction(
        request_id="a1",
        kind="approval",
        project_key="alpha",
        session_id="project:alpha",
        frame_type="approval_request",
        payload={"approval_id": "a1"},
        server_seq=1,
    )
    await adapter.handle_ws_envelope(Envelope(type="approval_response", request_id="a1", device_id="iphone", project_key="alpha", payload={"decision": "approve"}))

    adapter.store.upsert_pending_interaction(
        request_id="a2",
        kind="approval",
        project_key="alpha",
        session_id="project:alpha",
        frame_type="approval_request",
        payload={"approval_id": "a2"},
        server_seq=2,
    )
    await adapter.handle_ws_envelope(Envelope(type="approval_response", request_id="a2", device_id="iphone", project_key="alpha", payload={"decision": "deny"}))

    assert [event.text for event in adapter.captured_events] == ["/approve", "/deny"]


@pytest.mark.asyncio
async def test_approval_response_resolves_gateway_approval_directly(tmp_path, monkeypatch):
    adapter = CapturingLogosAdapter(PlatformConfig(enabled=True, extra={"device_secret": "dev-secret", "store_path": str(tmp_path / "logos.db")}))
    calls: list[tuple[str, str]] = []

    def fake_resolve(session_key: str, choice: str, resolve_all: bool = False) -> int:
        calls.append((session_key, choice))
        return 1

    monkeypatch.setattr("tools.approval.resolve_gateway_approval", fake_resolve)
    adapter.store.upsert_pending_interaction(
        request_id="a-live",
        kind="approval",
        project_key="alpha",
        session_id="project:alpha",
        frame_type="approval_request",
        payload={"approval_id": "a-live", "session_key": "agent:main:logos:dm:project:alpha"},
        server_seq=1,
    )

    response = await adapter.handle_ws_envelope(Envelope(type="approval_response", request_id="a-live", device_id="iphone", project_key="alpha", payload={"decision": "approve"}))

    assert response["type"] == "run_status"
    assert calls == [("agent:main:logos:dm:project:alpha", "once")]
    assert adapter.captured_events == []
    assert adapter.store.get_pending_interaction("a-live") is None


@pytest.mark.asyncio
async def test_clarify_response_routes_answer_text_to_gateway_path(tmp_path):
    adapter = CapturingLogosAdapter(PlatformConfig(enabled=True, extra={"device_secret": "dev-secret", "store_path": str(tmp_path / "logos.db")}))

    response = await adapter.handle_ws_envelope(Envelope(type="clarify_response", request_id="c1", device_id="iphone", project_key="alpha", payload={"text": "Use feature/auth."}))

    assert response["type"] == "run_status"
    assert response["payload"]["status"] == "running"
    assert adapter.captured_events[-1].text == "Use feature/auth."


@pytest.mark.asyncio
async def test_clarify_response_resolves_gateway_clarify_directly(tmp_path, monkeypatch):
    adapter = CapturingLogosAdapter(PlatformConfig(enabled=True, extra={"device_secret": "dev-secret", "store_path": str(tmp_path / "logos.db")}))
    calls: list[tuple[str, str]] = []

    def fake_resolve(clarify_id: str, text: str) -> bool:
        calls.append((clarify_id, text))
        return True

    monkeypatch.setattr("tools.clarify_gateway.resolve_gateway_clarify", fake_resolve)
    adapter.store.upsert_pending_interaction(
        request_id="clar-live",
        kind="clarification",
        project_key="alpha",
        session_id="project:alpha",
        frame_type="clarify_request",
        payload={"clarify_id": "clar-live", "session_key": "agent:main:logos:dm:project:alpha"},
        server_seq=1,
    )

    response = await adapter.handle_ws_envelope(Envelope(type="clarify_response", request_id="clar-live", device_id="iphone", project_key="alpha", payload={"text": "alpha"}))

    assert response["type"] == "run_status"
    assert response["payload"]["clarify_resolved"] is True
    assert calls == [("clar-live", "alpha")]
    assert adapter.captured_events == []
    assert adapter.store.get_pending_interaction("clar-live") is None


@pytest.mark.asyncio
async def test_clarify_response_rejects_wrong_project_without_resolving_gateway(tmp_path, monkeypatch):
    adapter = CapturingLogosAdapter(PlatformConfig(enabled=True, extra={"device_secret": "dev-secret", "store_path": str(tmp_path / "logos.db")}))
    calls: list[tuple[str, str]] = []

    def fake_resolve(clarify_id: str, text: str) -> bool:
        calls.append((clarify_id, text))
        return True

    monkeypatch.setattr("tools.clarify_gateway.resolve_gateway_clarify", fake_resolve)
    adapter.store.upsert_pending_interaction(
        request_id="clar-live",
        kind="clarification",
        project_key="alpha",
        session_id="project:alpha",
        frame_type="clarify_request",
        payload={"clarify_id": "clar-live"},
        server_seq=1,
    )

    response = await adapter.handle_ws_envelope(Envelope(type="clarify_response", request_id="clar-live", device_id="iphone", project_key="beta", payload={"text": "wrong project"}))

    assert response["type"] == "error"
    assert response["payload"]["code"] == "clarify_not_pending"
    assert calls == []
    assert adapter.store.get_pending_interaction("clar-live") is not None


@pytest.mark.asyncio
async def test_send_clarify_and_exec_approval_emit_rich_websocket_cards(tmp_path):
    adapter = LogosAdapter(PlatformConfig(enabled=True, extra={"device_secret": "dev-secret", "store_path": str(tmp_path / "logos.db")}))
    fake_server = FakeServer()
    adapter.ws_server = fake_server  # type: ignore[assignment]

    clarify_result = await adapter.send_clarify(
        chat_id="project:alpha",
        question="Which branch?",
        choices=["main", "feature/auth"],
        clarify_id="clar-1",
        session_key="agent:main:logos:dm:project:alpha",
        metadata={"session_id": "sess-alpha"},
    )
    approval_result = await adapter.send_exec_approval(
        chat_id="project:alpha",
        command="python manage.py migrate",
        session_key="agent:main:logos:dm:project:alpha",
        description="May modify local DB",
        metadata={"session_id": "sess-alpha", "risk": "Explicit risk text"},
    )

    assert clarify_result.success is True
    assert approval_result.success is True
    clarify_frame = next(item["frame"] for item in fake_server.frames if item["frame"]["type"] == "clarify_request")
    approval_frame = next(item["frame"] for item in fake_server.frames if item["frame"]["type"] == "approval_request")
    status_values = [item["frame"]["payload"]["status"] for item in fake_server.frames if item["frame"]["type"] == "run_status"]
    assert clarify_frame["payload"]["question"] == "Which branch?"
    assert approval_frame["payload"]["command_preview"] == "python manage.py migrate"
    assert approval_frame["payload"]["risk"] == "Explicit risk text"
    assert "awaiting_clarification" in status_values
    assert "awaiting_approval" in status_values


@pytest.mark.asyncio
async def test_text_input_and_send_emit_running_then_idle_status(tmp_path):
    adapter = CapturingLogosAdapter(PlatformConfig(enabled=True, extra={"device_secret": "dev-secret", "store_path": str(tmp_path / "logos.db")}))
    fake_server = FakeServer()
    adapter.ws_server = fake_server  # type: ignore[assignment]

    await adapter.handle_ws_envelope(Envelope(type="text_input", request_id="t1", device_id="iphone", project_key="alpha", payload={"text": "Do it"}))
    await adapter.send("project:alpha", "Done", metadata={"session_id": "project:alpha"})

    statuses = [item["frame"]["payload"]["status"] for item in fake_server.frames if item["frame"]["type"] == "run_status"]
    assert statuses == ["running", "idle"]
