from __future__ import annotations

import json

import pytest

from logos.schema import ProtocolError, error_frame, parse_frame, serialize_frame


def test_parse_hello_envelope_preserves_routing_fields():
    raw = json.dumps(
        {
            "type": "hello",
            "request_id": "req-1",
            "device_id": "iphone-17-pro",
            "project_key": "archwright",
            "session_id": "sess-1",
            "payload": {"secret": "dev-secret", "capabilities": {"text": True}},
        }
    )

    envelope = parse_frame(raw)

    assert envelope.type == "hello"
    assert envelope.request_id == "req-1"
    assert envelope.device_id == "iphone-17-pro"
    assert envelope.project_key == "archwright"
    assert envelope.session_id == "sess-1"
    assert envelope.payload["capabilities"] == {"text": True}


def test_parse_frame_rejects_missing_type():
    with pytest.raises(ProtocolError, match="type"):
        parse_frame('{"payload": {}}')


def test_serialize_frame_round_trips_minimal_state_update():
    frame = {
        "type": "state_update",
        "request_id": "req-2",
        "device_id": "iphone-17-pro",
        "project_key": "archwright",
        "server_seq": 4,
        "payload": {"op": "message_appended", "content": "Done"},
    }

    decoded = json.loads(serialize_frame(frame))

    assert decoded == frame


def test_error_frame_redacts_secret_values():
    raw = {"type": "hello", "payload": {"secret": "do-not-leak"}}

    encoded = serialize_frame(error_frame("auth_failed", "bad secret do-not-leak", raw=raw))

    assert "do-not-leak" not in encoded
    assert "[REDACTED]" in encoded
    assert json.loads(encoded)["type"] == "error"
