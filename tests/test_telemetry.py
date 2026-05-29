"""WS2 phase C: TelemetryLog is context-tagging and redaction-safe. Hermes-free (Tier-1)."""

from __future__ import annotations

import logging

from logos.request_context import request_scope
from logos.telemetry import EVENT_NAMES, TelemetryLog


def test_event_merges_current_request_context():
    log = TelemetryLog()
    with request_scope({"project_key": "archwright", "session_id": "s1", "request_id": "req-1"}):
        record = log.event("run.started")
    assert record["project_key"] == "archwright"
    assert record["session_id"] == "s1"
    assert record["request_id"] == "req-1"
    assert record["event"] == "run.started"


def test_catalog_name_passthrough_and_unknown_namespaced():
    log = TelemetryLog()
    assert log.event("run.reconciled")["event"] == "run.reconciled"
    assert log.event("totally.made.up")["event"] == "logos.event:totally.made.up"


def test_secret_keyed_fields_are_redacted():
    log = TelemetryLog()
    record = log.event("ws.auth_failed", device_secret="supersecret-value", api_key="k-123", project_key="p")
    assert record["device_secret"] == "[REDACTED]"
    assert record["api_key"] == "[REDACTED]"
    assert record["project_key"] == "p"


def test_nested_secret_values_are_redacted():
    log = TelemetryLog()
    record = log.event("apns.send_failed", details={"matched_secret": "leak-me", "status": 410})
    assert record["details"]["matched_secret"] == "[REDACTED]"
    assert record["details"]["status"] == 410


def test_no_secret_value_survives_in_log_output(caplog):
    """The plan's mandated guarantee: a secret passed to telemetry must not appear in the log."""
    log = TelemetryLog()
    secret = "ABCDEF-super-secret-token-0123456789"
    with caplog.at_level(logging.INFO, logger="logos.telemetry"):
        record = log.event("ws.auth_failed", auth_token=secret, note="login attempt")
    assert record["auth_token"] == "[REDACTED]"
    # Neither the returned record nor the emitted log text may contain the raw secret.
    assert secret not in repr(record)
    assert all(secret not in message for message in caplog.messages)


def test_event_catalog_is_frozen_and_nonempty():
    assert isinstance(EVENT_NAMES, frozenset)
    assert {"run.started", "run.interrupted", "run.reconciled", "ws.auth_failed"} <= EVENT_NAMES
