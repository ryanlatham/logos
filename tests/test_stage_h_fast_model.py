from __future__ import annotations

import pytest

from gateway.config import PlatformConfig
from logos.adapter import LogosAdapter
from logos.fast_llm import (
    DeterministicFastModel,
    FastModelResult,
    OllamaFastModel,
    build_fast_model,
    parse_fast_model_json,
)
from logos.schema import Envelope


class CaptureServer:
    def __init__(self):
        self.frames = []

    async def broadcast(self, frame, *, project_key=None):
        self.frames.append(frame)


def test_deterministic_fast_model_extracts_safe_control_intents():
    model = DeterministicFastModel()

    switch_result = model.analyze_input("switch to allox")
    assert switch_result.switch_intent == {"project_title": "allox"}
    assert switch_result.cancel_intent is False
    assert switch_result.ack is True

    create_result = model.analyze_input("create project mobile polish")
    assert create_result.create_intent == {"title": "mobile polish"}

    resume_result = model.analyze_input("resume archwright phase six")
    assert resume_result.resume_intent == {"target": "archwright phase six"}

    cancel_result = model.analyze_input("stop")
    assert cancel_result.cancel_intent is True

    approve_result = model.analyze_input("approve")
    assert approve_result.approval_decision == "approve"

    deny_result = model.analyze_input("deny that")
    assert deny_result.approval_decision == "deny"

    ambiguous = model.analyze_input("maybe look at allox later")
    assert ambiguous.switch_intent is None
    assert ambiguous.create_intent is None
    assert ambiguous.resume_intent is None
    assert ambiguous.cancel_intent is False
    assert ambiguous.approval_decision is None


def test_fast_model_json_validation_is_strict():
    parsed = parse_fast_model_json('{"ack":true,"ack_text":"On it.","cancel_intent":false,"confidence":0.7}')
    assert isinstance(parsed, FastModelResult)
    assert parsed.ack_text == "On it."

    with pytest.raises(ValueError):
        parse_fast_model_json('{"ack":"yes","confidence":0.2}')

    with pytest.raises(ValueError):
        parse_fast_model_json('{"ack":true,"confidence":2}')


def test_ollama_fast_model_uses_transport_and_strict_json_fallback():
    calls: list[str] = []

    def good_transport(*, endpoint, model, prompt, timeout_seconds):
        calls.append(prompt)
        return '{"ack":true,"ack_text":"Working.","cancel_intent":false,"approval_decision":"approve","confidence":0.91}'

    model = OllamaFastModel(
        model="local-test",
        endpoint="http://127.0.0.1:11434",
        timeout_seconds=0.05,
        min_confidence=0.5,
        transport=good_transport,
        fallback=DeterministicFastModel(),
    )

    result = model.analyze_input("approve it")
    assert result.approval_decision == "approve"
    assert result.ack_text == "Working."
    assert calls and "approve it" in calls[-1]

    def missing_ack_text_transport(*, endpoint, model, prompt, timeout_seconds):
        return '{"ack":true,"ack_text":null,"switch_intent":{"project_title":"alpha"},"cancel_intent":false,"confidence":0.91}'

    missing_ack_model = OllamaFastModel(
        transport=missing_ack_text_transport,
        timeout_seconds=0.05,
        min_confidence=0.5,
        fallback=DeterministicFastModel(),
    )
    missing_ack = missing_ack_model.analyze_input("check the logs")
    assert missing_ack.switch_intent == {"project_title": "alpha"}
    assert missing_ack.ack is True
    assert missing_ack.ack_text == "I'll check."

    def malformed_transport(*, endpoint, model, prompt, timeout_seconds):
        return "not json"

    fallback_model = OllamaFastModel(
        transport=malformed_transport,
        timeout_seconds=0.05,
        fallback=DeterministicFastModel(),
    )
    assert fallback_model.analyze_input("stop").cancel_intent is True

    def low_confidence_transport(*, endpoint, model, prompt, timeout_seconds):
        return '{"ack":true,"ack_text":"Maybe.","cancel_intent":true,"confidence":0.1}'

    cautious_model = OllamaFastModel(
        transport=low_confidence_transport,
        timeout_seconds=0.05,
        min_confidence=0.5,
        fallback=DeterministicFastModel(),
    )
    assert cautious_model.analyze_input("hello there").cancel_intent is False


def test_build_fast_model_selects_configured_real_provider(monkeypatch):
    monkeypatch.setenv("LOGOS_FAST_MODEL_PROVIDER", "ollama")
    model = build_fast_model({"fast_model_transport": lambda **kwargs: '{"ack":true,"cancel_intent":false,"confidence":0.8}'})
    assert isinstance(model, OllamaFastModel)


def test_fast_model_summary_redacts_secrets_and_limits_length():
    model = DeterministicFastModel(summary_max_chars=90)
    token = "sk-" + "test-secret-12345"
    summary = model.summarize(f"Token {token} should not leak. " + "Long detail. " * 20)
    assert token not in summary.summary_text
    assert "[REDACTED]" in summary.summary_text
    assert len(summary.summary_text) <= 90
    assert summary.source_hash


@pytest.mark.asyncio
async def test_adapter_emits_fast_ack_and_summary_ready(tmp_path):
    adapter = LogosAdapter(
        PlatformConfig(
            enabled=True,
            extra={"device_secret": "test-secret", "store_path": str(tmp_path / "logos.db")},
        )
    )
    capture = CaptureServer()
    adapter.ws_server = capture

    summary_token = "sk-" + "demo-key"
    await adapter.send("project:alpha", f"Finished the task. Secret {summary_token} should be redacted.", metadata={"session_id": "sess-alpha", "message_id": "msg-1"})

    summary_frames = [frame for frame in capture.frames if frame["type"] == "state_update" and frame["payload"].get("op") == "summary_ready"]
    assert summary_frames
    stored_summary = adapter.store.get_summary("sess-alpha", "msg-1")
    assert stored_summary is not None
    assert summary_token not in stored_summary.summary_text

    capture.frames.clear()
    await adapter.handle_ws_envelope(
        Envelope(
            type="text_input",
            request_id="req-ack",
            device_id="iphone",
            project_key="alpha",
            payload={"text": "check the logs", "client_msg_id": "client-1"},
        )
    )
    ack_frames = [frame for frame in capture.frames if frame["type"] == "state_update" and frame["payload"].get("op") == "fast_ack"]
    assert ack_frames
    assert ack_frames[0]["payload"]["ack_text"]


@pytest.mark.asyncio
async def test_adapter_routes_safe_fast_control_intents(tmp_path):
    adapter = LogosAdapter(
        PlatformConfig(
            enabled=True,
            extra={"device_secret": "test-secret", "store_path": str(tmp_path / "logos.db")},
        )
    )
    capture = CaptureServer()
    adapter.ws_server = capture
    adapter.store.upsert_project(project_key="allox", title="allox")

    dispatched = []

    async def fake_dispatch(envelope, text_override=None, **kwargs):
        dispatched.append(text_override or envelope.payload.get("text"))
        return envelope.project_key or "default"

    adapter._dispatch_gateway_text = fake_dispatch  # type: ignore[method-assign]

    await adapter.handle_ws_envelope(
        Envelope(type="text_input", request_id="switch", device_id="iphone", project_key="default", payload={"text": "switch to allox"})
    )
    assert adapter.store.get_active_project("iphone").project_key == "allox"
    assert not dispatched

    await adapter.handle_ws_envelope(
        Envelope(type="text_input", request_id="resume", device_id="iphone", project_key="allox", payload={"text": "resume archwright"})
    )
    assert dispatched[-1] == "/resume archwright"

    await adapter.handle_ws_envelope(
        Envelope(type="text_input", request_id="stop", device_id="iphone", project_key="allox", payload={"text": "stop"})
    )
    assert dispatched[-1] == "/stop"
