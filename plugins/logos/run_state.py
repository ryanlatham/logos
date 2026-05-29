from __future__ import annotations

import logging
import time
from typing import Any

from .config import _optional_nonempty_str
from .request_context import current_request_context
from .schema import redact_secrets

# Run-origin text persisted for retry-after-interruption is capped so a pathological prompt
# can't bloat the run-state row.
MAX_RUN_ORIGIN_TEXT_CHARS = 2000

logger = logging.getLogger(__name__)


class RunStateMixin:
    """Run-status broadcasting, cancellation, and the typing->keepalive bridge (from adapter.py).

    Mixed into LogosAdapter; uses self.{store, ws_server, _project_key_for,
    _project_key_from_chat_id, _client_session_id_for, _dispatch_gateway_text,
    _last_keepalive_sent_at, _keepalive_throttle_seconds, stale_timeout_seconds}.
    """

    async def send_typing(self, chat_id: str, metadata=None) -> None:  # type: ignore[override]
        """Surface Hermes' typing loop as a Logos run keepalive."""

        if self.ws_server is None:
            return
        metadata = dict(metadata or {})
        project_key = self._project_key_from_chat_id(chat_id)
        context = current_request_context()
        context_matches_project = bool(context and context.get("project_key") == project_key)
        session_id = str(
            metadata.get("session_id")
            or metadata.get("session")
            or (context.get("session_id") if context_matches_project else None)
            or chat_id
        )
        request_id = _optional_nonempty_str(
            metadata.get("request_id") or (context.get("request_id") if context_matches_project else None)
        )
        device_id = _optional_nonempty_str(metadata.get("device_id"))
        throttle_key = (project_key, request_id or session_id)
        now = time.monotonic()
        last_sent = self._last_keepalive_sent_at.get(throttle_key)
        if last_sent is not None and now - last_sent < self._keepalive_throttle_seconds:
            return
        self._last_keepalive_sent_at[throttle_key] = now
        await self._broadcast_run_status(
            project_key=project_key,
            session_id=session_id,
            status="running",
            request_id=request_id,
            device_id=device_id,
            payload={
                "keepalive": True,
                "source": "typing",
                "transient": True,
                "stale_timeout_seconds": self.stale_timeout_seconds,
            },
        )

    def _clear_request_bookkeeping(self, *, project_key: str, session_id: str | None, request_id: str | None) -> None:
        if request_id:
            self._last_keepalive_sent_at.pop((project_key, request_id), None)
        if session_id:
            self._last_keepalive_sent_at.pop((project_key, session_id), None)
        if len(self._last_keepalive_sent_at) > 1000:
            for key in list(self._last_keepalive_sent_at)[:500]:
                self._last_keepalive_sent_at.pop(key, None)

    def _state_update(
        self,
        *,
        op: str,
        envelope: Envelope,
        payload: dict[str, Any] | None = None,
    ) -> dict[str, Any]:
        server_seq = self.store.next_server_seq()
        body = {"op": op}
        if payload:
            body.update(payload)
        project_key = self._project_key_for(envelope)
        return {
            "type": "state_update",
            "request_id": envelope.request_id,
            "device_id": envelope.device_id,
            "project_key": project_key,
            "session_id": self._client_session_id_for(envelope, project_key),
            "server_seq": server_seq,
            "payload": body,
        }

    def _run_status_frame(
        self,
        *,
        project_key: str,
        session_id: str | None,
        status: str,
        request_id: str | None = None,
        device_id: str | None = None,
        payload: dict[str, Any] | None = None,
        server_seq: int | None = None,
        updated_at: float | None = None,
    ) -> dict[str, Any]:
        body: dict[str, Any] = {
            "status": status,
            "updated_at": time.time() if updated_at is None else updated_at,
        }
        if payload:
            body.update(payload)
        return {
            "type": "run_status",
            "request_id": request_id,
            "device_id": device_id,
            "project_key": project_key,
            "session_id": session_id,
            "server_seq": self.store.next_server_seq() if server_seq is None else int(server_seq),
            "payload": body,
        }

    async def _broadcast_run_status(
        self,
        *,
        project_key: str,
        session_id: str | None,
        status: str,
        request_id: str | None = None,
        device_id: str | None = None,
        payload: dict[str, Any] | None = None,
    ) -> dict[str, Any]:
        updated_at = time.time()
        stored = self.store.upsert_run_state(
            project_key=project_key,
            session_id=session_id,
            status=status,
            request_id=request_id,
            device_id=device_id,
            payload=dict(payload or {}),
            updated_at=updated_at,
        )
        frame = self._run_status_frame(
            project_key=project_key,
            session_id=session_id,
            status=status,
            request_id=request_id,
            device_id=device_id,
            payload=payload,
            server_seq=stored.server_seq,
            updated_at=updated_at,
        )
        if self.ws_server is not None:
            await self.ws_server.broadcast(frame, project_key=project_key)
        return frame

    async def _handle_run_cancel(self, envelope: Envelope) -> dict[str, Any]:
        project_key = self._project_key_for(envelope)
        session_id = envelope.session_id or f"project:{project_key}"
        await self._broadcast_run_status(
            project_key=project_key,
            session_id=session_id,
            status="cancelling",
            request_id=envelope.request_id,
            device_id=envelope.device_id,
        )
        dispatch_failed = False
        try:
            await self._dispatch_gateway_text(envelope, "/stop", mirror_user=False)
        except Exception:
            dispatch_failed = True
            logger.warning("Logos: failed to dispatch /stop for run_cancel", exc_info=True)
        if not dispatch_failed:
            self.store.resolve_pending_interactions_for_project(project_key)
        terminal_frame = await self._broadcast_run_status(
            project_key=project_key,
            session_id=session_id,
            status="error" if dispatch_failed else "idle",
            request_id=envelope.request_id,
            device_id=envelope.device_id,
            payload={"cancelled": not dispatch_failed, "reason": "stop_dispatch_failed"} if dispatch_failed else {"cancelled": True},
        )
        return terminal_frame

    async def on_processing_start(self, event) -> None:  # type: ignore[override]
        """Record durable run origin so an interrupted run can be recovered/retried.

        Fires when Hermes begins background processing (after handle_message routes the
        input). The "running" status is already broadcast by the dispatch path; here we only
        enrich the persisted row with started_at + the redacted origin text + origin_request_id,
        which COALESCE-preserve across later status-only updates.
        """
        await super().on_processing_start(event)
        context = self._request_context_for_event(event)
        if not context:
            return
        origin_text = redact_secrets(getattr(event, "text", "") or "")
        if isinstance(origin_text, str) and len(origin_text) > MAX_RUN_ORIGIN_TEXT_CHARS:
            origin_text = origin_text[:MAX_RUN_ORIGIN_TEXT_CHARS]
        self.store.upsert_run_state(
            project_key=context["project_key"],
            session_id=context["session_id"],
            status="running",
            request_id=context["request_id"],
            started_at=time.time(),
            origin_text=origin_text if isinstance(origin_text, str) else None,
            origin_request_id=context["request_id"],
        )

    async def on_processing_complete(self, event, outcome) -> None:  # type: ignore[override]
        """Reconcile a run that ended without a final message (honest, idempotent).

        Hermes' final response normally flips the run to ``idle`` via ``send``; this hook fires
        even on failure/cancel/empty-success, so a crashed or cancelled run can't orphan a
        spinner. We act ONLY if the persisted row is still active for THIS request_id (so we
        never double-idle a run a final message already terminated). An interrupted run carries
        its redacted ``retry_text`` so the app can offer a one-tap retry.
        """
        await super().on_processing_complete(event, outcome)
        context = self._request_context_for_event(event)
        if not context:
            return
        project_key = context["project_key"]
        request_id = context["request_id"]
        current = self.store.latest_run_state(project_key)
        if current is None or current.status not in {"running", "queued", "cancelling"}:
            return
        if current.request_id and request_id and current.request_id != request_id:
            return
        outcome_name = getattr(outcome, "name", str(outcome)).upper()
        final_status = {
            "SUCCESS": "completed",
            "FAILURE": "failed",
            "CANCELLED": "cancelled",
        }.get(outcome_name, "completed")
        interrupted = outcome_name != "SUCCESS"
        payload: dict[str, Any] = {"reconciled": True, "final_status": final_status}
        if interrupted:
            payload["interrupted"] = True
            payload["reason"] = f"processing_{final_status}"
            if current.origin_text:
                payload["retry_text"] = current.origin_text
                payload["origin_request_id"] = current.origin_request_id or request_id
        await self._broadcast_run_status(
            project_key=project_key,
            session_id=current.session_id or context["session_id"],
            status="error" if outcome_name == "FAILURE" else "idle",
            request_id=request_id,
            device_id=current.device_id,
            payload=payload,
        )
        telemetry = getattr(self, "_telemetry", None)
        if telemetry is not None:
            event_name = "run.cancelled" if outcome_name == "CANCELLED" else (
                "run.interrupted" if interrupted else "run.reconciled"
            )
            telemetry.event(event_name, final_status=final_status, had_origin_text=bool(current.origin_text))
