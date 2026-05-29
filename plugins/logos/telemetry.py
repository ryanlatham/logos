"""Structured, redaction-safe telemetry for the Logos adapter (additive; WS2 plan phase C).

A tiny event logger with two guarantees:

1. **Context tagging** — every event is merged over ``current_request_context()`` so the
   originating project/session/request travels with the log line without callers threading IDs.
2. **Redaction** — the merged record is funnelled through ``redact_secrets`` before it is
   logged or returned, so a stray secret value (or a secret-keyed field) can never leak into
   telemetry. Callers should pass JSON-scalar-ish fields only — never raw frames/payloads.

Event names are constrained to a fixed catalog so the structured-log surface stays greppable
and reviewable; an out-of-catalog name is namespaced rather than dropped so signal is never
lost silently. Hermes-free (depends only on request_context + schema).
"""

from __future__ import annotations

import logging
from typing import Any

from .request_context import current_request_context
from .schema import redact_secrets

logger = logging.getLogger("logos.telemetry")

# The only event names the adapter is meant to emit. Keep this in sync with call sites.
EVENT_NAMES = frozenset(
    {
        "ws.auth_failed",
        "ws.encryption_negotiated",
        "ws.encryption_required_rejected",
        "run.started",
        "run.interrupted",
        "run.reconciled",
        "run.cancelled",
        "apns.send_failed",
        "apns.device_dropped",
        "tts.failed",
        "fast_model.fallback",
        "fast_model.direct_response",
    }
)


class TelemetryLog:
    """Emits redaction-safe structured events. Stateless; safe to share across a connection."""

    def __init__(self, log: logging.Logger | None = None) -> None:
        self._log = log or logger

    @staticmethod
    def normalize_event_name(name: str) -> str:
        """Return ``name`` if it's in the catalog, else a namespaced fallback (never dropped)."""
        return name if name in EVENT_NAMES else f"logos.event:{name}"

    def event(self, name: str, **fields: Any) -> dict[str, Any]:
        """Log ``name`` with ``fields`` merged over the current request context.

        Returns the redacted record (handy for assertions). Every value passes through
        ``redact_secrets`` — both secret-keyed fields and nested structures are scrubbed.
        """
        record: dict[str, Any] = {}
        context = current_request_context()
        if context:
            record.update(context)
        record.update(fields)
        safe = redact_secrets(record)
        if not isinstance(safe, dict):  # redact_secrets preserves dicts; defensive only
            safe = {"value": safe}
        event_name = self.normalize_event_name(name)
        self._log.info("logos.telemetry event=%s %s", event_name, safe)
        return {"event": event_name, **safe}
