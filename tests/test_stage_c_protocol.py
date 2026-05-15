from __future__ import annotations

from logos.schema import CLIENT_FRAME_TYPES, SERVER_FRAME_TYPES, protocol_json_schema


def test_stage_c_protocol_lists_core_client_and_server_frame_types():
    expected_client = {
        "speech",
        "text_input",
        "switch_project",
        "list_projects",
        "new_project",
        "rename_project",
        "messages_get",
        "approval_response",
        "clarify_response",
        "run_cancel",
    }
    expected_server = {
        "messages_batch",
        "state_update",
        "run_status",
        "playback_audio",
        "audio_chunk",
        "approval_request",
        "clarify_request",
        "error",
    }

    assert expected_client <= CLIENT_FRAME_TYPES
    assert expected_server <= SERVER_FRAME_TYPES


def test_protocol_json_schema_is_swift_compatible_envelope_contract():
    schema = protocol_json_schema()

    assert schema["type"] == "object"
    assert "type" in schema["required"]
    assert set(schema["properties"]) >= {"type", "request_id", "device_id", "project_key", "session_id", "server_seq", "payload"}
    assert schema["properties"]["payload"]["type"] == "object"
