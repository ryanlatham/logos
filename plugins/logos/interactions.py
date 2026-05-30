from __future__ import annotations

import logging
from typing import TYPE_CHECKING, Any

from gateway.platforms.base import SendResult

from .apns import PrivateNotificationKind
from .schema import Envelope, error_frame

if TYPE_CHECKING:
    from ._adapter_core import LogosAdapterCore

    _MixinBase = LogosAdapterCore
else:
    _MixinBase = object

logger = logging.getLogger(__name__)


class InteractionsMixin(_MixinBase):
    """Approval/clarification responses + Hermes send_clarify/send_exec_approval callbacks (from adapter.py).

    Mixed into LogosAdapter; uses self.{store, _project_key_for, _client_session_id_for,
    _dispatch_gateway_text, _broadcast_run_status, _latest_pending_interaction}.
    """

    async def _handle_approval_response(self, envelope: Envelope) -> dict[str, Any]:
        decision = str(envelope.payload.get("decision") or "").strip().lower()
        if decision in {"approve", "allow", "yes", "y"}:
            command = "/approve"
            normalized_decision = "approve"
        elif decision in {"deny", "reject", "cancel", "no", "n"}:
            command = "/deny"
            normalized_decision = "deny"
        else:
            return error_frame(
                "invalid_approval_decision",
                "approval_response decision must be approve or deny",
                request_id=envelope.request_id,
                device_id=envelope.device_id,
                project_key=envelope.project_key,
            )
        project_key = self._project_key_for(envelope)
        request_id = str(envelope.request_id or envelope.payload.get("approval_id") or "")
        pending = self.store.get_pending_interaction(request_id) if request_id else None
        if pending is None or pending.kind != "approval" or pending.project_key != project_key:
            return error_frame(
                "approval_not_pending",
                "approval_response requires a matching pending approval for this project",
                request_id=envelope.request_id,
                device_id=envelope.device_id,
                project_key=project_key,
            )
        resolved_directly = False
        session_key = str(pending.payload.get("session_key") or "").strip()
        if session_key:
            try:
                from tools.approval import resolve_gateway_approval

                approval_choice = "once" if normalized_decision == "approve" else "deny"
                resolved_directly = bool(resolve_gateway_approval(session_key, approval_choice))
            except Exception:
                resolved_directly = False
        if not resolved_directly:
            project_key = await self._dispatch_gateway_text(envelope, command, mirror_user=False)
        self.store.resolve_pending_interaction(request_id)
        return await self._broadcast_run_status(
            project_key=project_key,
            session_id=envelope.session_id or f"project:{project_key}",
            status="running",
            request_id=envelope.request_id,
            device_id=envelope.device_id,
            payload={"approval_decision": normalized_decision},
        )

    async def _handle_clarify_response(self, envelope: Envelope) -> dict[str, Any]:
        text = envelope.payload.get("text")
        if not isinstance(text, str) or not text.strip():
            return error_frame(
                "invalid_clarify_response",
                "clarify_response requires payload.text",
                request_id=envelope.request_id,
                device_id=envelope.device_id,
                project_key=envelope.project_key,
            )
        clarify_id = str(envelope.payload.get("clarify_id") or envelope.request_id or "")
        project_key = self._project_key_for(envelope)
        pending = self.store.get_pending_interaction(clarify_id) if clarify_id else None
        if pending is not None and (
            pending.kind != "clarification" or pending.project_key != project_key
        ):
            return error_frame(
                "clarify_not_pending",
                "clarify_response requires a matching pending clarification for this project",
                request_id=envelope.request_id,
                device_id=envelope.device_id,
                project_key=project_key,
            )
        resolved = False
        if pending is not None:
            try:
                from tools.clarify_gateway import resolve_gateway_clarify

                resolved = bool(resolve_gateway_clarify(clarify_id, text))
            except Exception:
                resolved = False
        if not resolved:
            project_key = await self._dispatch_gateway_text(envelope, text)
        if pending is not None and resolved:
            self.store.resolve_pending_interaction(clarify_id)
        return await self._broadcast_run_status(
            project_key=project_key,
            session_id=envelope.session_id or f"project:{project_key}",
            status="running",
            request_id=envelope.request_id,
            device_id=envelope.device_id,
            payload={"clarify_resolved": resolved, "clarify_id": clarify_id or None},
        )

    async def send_clarify(
        self,
        chat_id: str,
        question: str,
        choices: list[Any] | None,
        clarify_id: str,
        session_key: str,
        metadata: dict[str, Any] | None = None,
    ) -> SendResult:
        metadata = dict(metadata or {})
        project_key = self._project_key_from_chat_id(chat_id)
        session_id = str(metadata.get("session_id") or metadata.get("session") or chat_id)
        private_payload = {
            "clarify_id": clarify_id,
            "question": question,
            "choices": list(choices or []),
            "allow_free_text": True,
            "session_key": session_key,
        }
        public_payload = dict(private_payload)
        public_payload.pop("session_key", None)
        frame: dict[str, Any] = {
            "type": "clarify_request",
            "request_id": clarify_id,
            "project_key": project_key,
            "session_id": session_id,
            "server_seq": self.store.next_server_seq(),
            "payload": public_payload,
        }
        self.store.upsert_pending_interaction(
            request_id=clarify_id,
            kind="clarification",
            project_key=project_key,
            session_id=session_id,
            frame_type="clarify_request",
            payload=private_payload,
            server_seq=int(frame["server_seq"]),
        )
        try:
            from tools.clarify_gateway import mark_awaiting_text

            mark_awaiting_text(clarify_id)
        except Exception:
            pass
        if self.ws_server is not None:
            await self.ws_server.broadcast(frame, project_key=project_key)
        await self._broadcast_run_status(
            project_key=project_key,
            session_id=session_id,
            status="awaiting_clarification",
            payload={"clarify_id": clarify_id},
        )
        await self._send_private_notification(
            PrivateNotificationKind.CLARIFICATION,
            project_key=project_key,
            session_id=session_id,
            request_id=clarify_id,
            server_seq=int(frame["server_seq"]),
            sensitive_context={"question": question, "choices": list(choices or [])},
        )
        return SendResult(success=True, message_id=clarify_id, raw_response=frame)

    async def send_exec_approval(
        self,
        chat_id: str,
        command: str,
        session_key: str,
        description: str,
        metadata: dict[str, Any] | None = None,
    ) -> SendResult:
        metadata = dict(metadata or {})
        project_key = self._project_key_from_chat_id(chat_id)
        session_id = str(metadata.get("session_id") or metadata.get("session") or chat_id)
        server_seq = self.store.next_server_seq()
        approval_id = str(metadata.get("approval_id") or f"appr-{server_seq}")
        private_payload = {
            "approval_id": approval_id,
            "title": "Approve shell command?",
            "summary": description,
            "command_preview": command,
            "risk": str(metadata.get("risk") or description),
            "session_key": session_key,
        }
        public_payload = dict(private_payload)
        public_payload.pop("session_key", None)
        frame = {
            "type": "approval_request",
            "request_id": approval_id,
            "project_key": project_key,
            "session_id": session_id,
            "server_seq": server_seq,
            "payload": public_payload,
        }
        self.store.upsert_pending_interaction(
            request_id=approval_id,
            kind="approval",
            project_key=project_key,
            session_id=session_id,
            frame_type="approval_request",
            payload=private_payload,
            server_seq=server_seq,
        )
        if self.ws_server is not None:
            await self.ws_server.broadcast(frame, project_key=project_key)
        await self._broadcast_run_status(
            project_key=project_key,
            session_id=session_id,
            status="awaiting_approval",
            payload={"approval_id": approval_id},
        )
        await self._send_private_notification(
            PrivateNotificationKind.APPROVAL,
            project_key=project_key,
            session_id=session_id,
            request_id=approval_id,
            server_seq=server_seq,
            sensitive_context={
                "command": command,
                "description": description,
                "metadata": metadata,
            },
        )
        return SendResult(success=True, message_id=approval_id, raw_response=frame)
