from __future__ import annotations

import json
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from gateway.config import PlatformConfig
from logos.schema import Envelope
from scripts.run_stage_f_mock_adapter import StageFMockLogosAdapter, format_traffic_log_line


def test_stage_f_traffic_log_line_redacts_auth_material() -> None:
    secret = "-".join(["stage", "f", "secret"])
    signature = "a" * 64
    session_key = "-".join(["stage", "f", "session", "key"])
    token = "-".join(["apns", "token", "value"])
    raw = json.dumps(
        {
            "type": "hello",
            "request_id": "hello-1",
            "device_id": "iphone",
            "payload": {
                "secret": secret,
                "signature": signature,
                "session_key": session_key,
                "token": token,
                "text": "visible transcript text",
            },
        }
    )

    line = format_traffic_log_line("<-", raw)

    assert line.startswith("TRAFFIC <- ")
    assert "visible transcript text" not in line
    assert "[TEXT length=23]" in line
    assert secret not in line
    assert signature not in line
    assert token not in line
    assert session_key not in line
    assert line.count("[REDACTED]") == 4


def test_stage_f_traffic_log_line_formats_outbound_frames() -> None:
    line = format_traffic_log_line(
        "->",
        {
            "type": "state_update",
            "payload": {
                "op": "message_appended",
                "message": {"content": "assistant reply"},
            },
        },
    )

    assert line.startswith("TRAFFIC -> ")
    assert "state_update" in line
    assert "assistant reply" not in line
    assert "[TEXT length=15]" in line


def test_stage_f_traffic_log_line_escapes_raw_non_json_frames() -> None:
    line = format_traffic_log_line("<-", "not-json\nTRAFFIC -> forged")

    assert line == 'TRAFFIC <- "not-json\\nTRAFFIC -> forged"'


def test_stage_f_traffic_log_line_keeps_speech_final_metadata_without_transcript() -> None:
    line = format_traffic_log_line(
        "<-",
        {
            "type": "speech",
            "request_id": "speech-1",
            "payload": {
                "text": "send this to Hermes",
                "is_final": True,
                "client_msg_id": "voice-turn-1",
                "partial_seq": 4,
                "started_at_ms": 123,
            },
        },
    )

    assert "send this to Hermes" not in line
    assert '"is_final":true' in line
    assert '"client_msg_id":"voice-turn-1"' in line
    assert '"partial_seq":4' in line
    assert "[TEXT length=19]" in line


@pytest.mark.asyncio
async def test_stage_f_mock_adapter_serves_deterministic_command_catalog(tmp_path) -> None:
    adapter = StageFMockLogosAdapter(
        PlatformConfig(
            enabled=True,
            extra={"device_secret": "stage-f-secret", "store_path": str(tmp_path / "stage-f.db")},
        )
    )

    response = await adapter.handle_ws_envelope(
        Envelope(type="commands_get", request_id="commands-1", device_id="iphone", project_key="default", payload={})
    )

    assert response["type"] == "commands_list"
    triggers = {command["trigger"] for command in response["payload"]["commands"]}
    assert "/resume" in triggers
    assert "/mock_approval" in triggers
    assert response["payload"]["catalog_version"] == "stage-f-commands-v1"


@pytest.mark.asyncio
async def test_stage_f_mock_adapter_serves_deterministic_completion(tmp_path) -> None:
    adapter = StageFMockLogosAdapter(
        PlatformConfig(
            enabled=True,
            extra={"device_secret": "stage-f-secret", "store_path": str(tmp_path / "stage-f.db")},
        )
    )

    response = await adapter.handle_ws_envelope(
        Envelope(type="commands_complete", request_id="complete-1", device_id="iphone", project_key="default", payload={"text": "/res"})
    )

    assert response["type"] == "commands_complete_result"
    assert response["payload"]["items"][0]["replacement_text"] == "/resume "
