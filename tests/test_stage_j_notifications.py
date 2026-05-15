from __future__ import annotations

import asyncio

from gateway.config import PlatformConfig
from logos.adapter import LogosAdapter
from logos.apns import APNSClient, APNSConfig, PrivateNotificationKind, build_private_apns_payload
from logos.schema import Envelope


def adapter_for(tmp_path):
    return LogosAdapter(
        PlatformConfig(
            enabled=True,
            extra={"device_secret": "test-secret", "store_path": str(tmp_path / "logos.db")},
        )
    )


def walk_strings(value):
    if isinstance(value, dict):
        for item in value.values():
            yield from walk_strings(item)
    elif isinstance(value, list):
        for item in value:
            yield from walk_strings(item)
    elif isinstance(value, str):
        yield value


def test_private_completion_payload_contains_only_routing_ids():
    payload = build_private_apns_payload(
        PrivateNotificationKind.FINISHED,
        project_key="archwright-phase-6",
        session_id="session-1",
        message_id="msg-42",
        server_seq=982,
        sensitive_context={"summary": "SECRET answer /Users/ryan/private.txt", "command": "rm -rf nope"},
    )

    assert payload["aps"]["alert"]["title"] == "Hermes finished"
    assert payload["aps"]["alert"]["body"] == "Open Logos to view the result."
    assert payload["project_key"] == "archwright-phase-6"
    assert payload["session_id"] == "session-1"
    assert payload["message_id"] == "msg-42"
    assert payload["server_seq"] == 982
    all_text = "\n".join(walk_strings(payload))
    assert "SECRET" not in all_text
    assert "private.txt" not in all_text
    assert "rm -rf" not in all_text


def test_private_approval_and_clarification_payloads_do_not_include_details():
    approval = build_private_apns_payload(
        PrivateNotificationKind.APPROVAL,
        project_key="default",
        request_id="appr-1",
        sensitive_context={"command_preview": "python dangerous.py --token abc"},
    )
    clarify = build_private_apns_payload(
        PrivateNotificationKind.CLARIFICATION,
        project_key="default",
        request_id="clar-1",
        sensitive_context={"question": "Which secret branch?"},
    )

    assert approval["aps"]["alert"]["title"] == "Hermes needs approval"
    assert approval["kind"] == "approval"
    assert approval["request_id"] == "appr-1"
    assert "dangerous.py" not in "\n".join(walk_strings(approval))
    assert clarify["aps"]["alert"]["title"] == "Hermes needs clarification"
    assert clarify["kind"] == "clarification"
    assert clarify["request_id"] == "clar-1"
    assert "secret branch" not in "\n".join(walk_strings(clarify))


def test_register_device_persists_token_without_echoing_secret_token(tmp_path):
    adapter = adapter_for(tmp_path)
    frame = asyncio.run(
        adapter.handle_ws_envelope(
            Envelope(
                type="register_device",
                request_id="reg-1",
                device_id="iphone-test",
                payload={
                    "display_name": "Ryan's iPhone",
                    "apns_token": "abcdef123456",
                    "apns_environment": "sandbox",
                    "capabilities": ["text", "speech", "notifications"],
                },
            )
        )
    )

    assert frame["type"] == "registered"
    assert frame["request_id"] == "reg-1"
    assert frame["payload"]["device"]["device_id"] == "iphone-test"
    assert frame["payload"]["device"]["apns_registered"] is True
    assert "abcdef123456" not in str(frame)

    stored = adapter.store.get_device("iphone-test")
    assert stored is not None
    assert stored.apns_token == "abcdef123456"
    assert stored.capabilities == ["text", "speech", "notifications"]


def test_apns_client_skips_live_send_when_credentials_absent():
    client = APNSClient(APNSConfig())
    result = client.send("token", {"aps": {"alert": {"title": "Hermes finished"}}})
    assert result.skipped is True
    assert result.success is False
    assert result.reason == "missing_credentials"
