from __future__ import annotations

import time
import uuid
from typing import TYPE_CHECKING, Any

from gateway.platforms.base import SendResult

from .apns import PrivateNotificationKind
from .config import _safe_filename_component
from .store import LogosMessage

if TYPE_CHECKING:
    from ._adapter_core import LogosAdapterCore

    _MixinBase = LogosAdapterCore
else:
    _MixinBase = object

# Transient/durable tool-progress rows carry this message-id prefix so the receiver and store
# can distinguish them from final assistant messages.
PROGRESS_MESSAGE_ID_PREFIX = "progress-"


class MessageStateMixin(_MixinBase):
    """Outbound message lifecycle moved verbatim from adapter.py (the highest-fidelity logic).

    Progress-text rollup, send / edit_message, transient->final promotion, and the
    state_update / summary_ready frame builders. Mixed into LogosAdapter; uses self.{store,
    ws_server, _transient_progress_context, _project_key_from_chat_id,
    _metadata_with_current_request_id, _looks_like_terminal_error_text,
    _human_readable_error_response, _source_hash, _progress_kind_for_text,
    _gateway_lifecycle_interruption_reason, _broadcast_run_status, _summary_for_message,
    _send_private_notification, _clear_request_bookkeeping}.
    """

    async def _broadcast_progress_text(
        self,
        *,
        chat_id: str,
        content: str,
        metadata: dict[str, Any] | None = None,
        request_id: str | None = None,
        kind: str = "tool_progress",
    ) -> SendResult:
        metadata = dict(metadata or {})
        project_key = self._project_key_from_chat_id(chat_id)
        provided_progress_id = request_id or metadata.get("message_id")
        context_key = (
            (project_key, str(provided_progress_id)) if provided_progress_id is not None else None
        )
        previous_context = (
            self._transient_progress_context.get(context_key, {}) if context_key is not None else {}
        )
        previous_metadata = dict(previous_context.get("metadata") or {})
        session_id = str(
            metadata.get("session_id")
            or metadata.get("session")
            or previous_context.get("session_id")
            or chat_id
        )
        if provided_progress_id is None and kind == "gateway_status":
            provided_progress_id = (
                f"{PROGRESS_MESSAGE_ID_PREFIX}gateway-status-{_safe_filename_component(session_id)}"
            )
        progress_id = str(provided_progress_id or f"{PROGRESS_MESSAGE_ID_PREFIX}{uuid.uuid4()}")
        progress_metadata = {**previous_metadata, **metadata}
        root_request_id = str(progress_metadata.get("request_id") or progress_id)
        durable = kind != "gateway_status"
        progress_kind = str(progress_metadata.get("progress_kind") or kind)
        if durable:
            progress_metadata.update(
                {
                    "source": "tool_progress",
                    "kind": kind,
                    "progress_kind": progress_kind,
                    "finalized": False,
                    "request_id": root_request_id,
                    "transient": False,
                }
            )
        self._transient_progress_context[(project_key, progress_id)] = {
            "session_id": session_id,
            "metadata": progress_metadata,
            "kind": kind,
        }
        if len(self._transient_progress_context) > 1000:
            for stale_key in list(self._transient_progress_context)[:500]:
                self._transient_progress_context.pop(stale_key, None)
        stored_progress: LogosMessage | None = None
        server_seq: int
        if durable:
            existing = self.store.get_message(session_id, progress_id)
            if existing is None:
                stored_progress = self.store.append_message(
                    project_key=project_key,
                    session_id=session_id,
                    message_id=progress_id,
                    role="assistant",
                    content=content,
                    metadata=progress_metadata,
                )
            else:
                stored_progress = self.store.update_message(
                    session_id=session_id,
                    message_id=progress_id,
                    content=content,
                    metadata=progress_metadata,
                )
            if stored_progress is None:
                return SendResult(
                    success=False, message_id=progress_id, error="progress message not found"
                )
            existing_project = self.store.get_project(project_key)
            self.store.upsert_project(
                project_key=project_key,
                title=existing_project.title if existing_project else project_key,
                current_session_id=session_id,
                lineage_root_session_id=str(
                    progress_metadata.get("lineage_root_session_id")
                    or progress_metadata.get("root_session_id")
                    or session_id
                ),
            )
            server_seq = stored_progress.server_seq
        else:
            server_seq = self.store.next_server_seq()
        frame: dict[str, Any] = {
            "type": "tool_progress",
            "request_id": root_request_id,
            "project_key": project_key,
            "session_id": session_id,
            "server_seq": server_seq,
            "payload": {
                "kind": kind,
                "progress_kind": progress_kind,
                "message_id": progress_id,
                "text": content,
                "transient": not durable,
            },
        }
        if stored_progress is not None:
            frame["payload"]["message"] = stored_progress.to_protocol()
            frame["payload"]["finalized"] = False
        if self.ws_server is not None:
            await self.ws_server.broadcast(frame, project_key=project_key)
        return SendResult(success=True, message_id=progress_id, raw_response=frame)

    async def send(
        self,
        chat_id: str,
        content: str,
        reply_to: str | None = None,
        metadata: dict[str, Any] | None = None,
    ) -> SendResult:
        metadata = dict(metadata or {})
        project_key = self._project_key_from_chat_id(chat_id)
        session_id = str(metadata.get("session_id") or metadata.get("session") or chat_id)
        metadata = self._metadata_with_current_request_id(
            project_key=project_key, session_id=session_id, metadata=metadata
        )
        session_id = str(metadata.get("session_id") or metadata.get("session") or session_id)
        if self._looks_like_terminal_error_text(content):
            await self._broadcast_progress_text(
                chat_id=chat_id, content=content, metadata=metadata, kind="gateway_status"
            )
            explanation, explanation_protocol = self._human_readable_error_response(content)
            metadata = dict(metadata)
            metadata.update(
                {
                    "source": "hermes_error",
                    "finalized": True,
                    "final_status": "failed",
                    "error": True,
                    "raw_error_hash": self._source_hash(content),
                }
            )
            if explanation_protocol:
                metadata["fast_error_explanation"] = explanation_protocol
            content = explanation
        progress_kind = self._progress_kind_for_text(content)
        if progress_kind is not None:
            sent = await self._broadcast_progress_text(
                chat_id=chat_id, content=content, metadata=metadata, kind=progress_kind
            )
            lifecycle_reason = self._gateway_lifecycle_interruption_reason(content)
            if lifecycle_reason is not None:
                await self._broadcast_run_status(
                    project_key=project_key,
                    session_id=session_id,
                    status="idle",
                    request_id=str(metadata.get("request_id") or "") or None,
                    device_id=str(metadata.get("device_id") or "") or None,
                    payload={
                        "interrupted": True,
                        "final_status": "interrupted",
                        "reason": lifecycle_reason,
                    },
                )
            return sent
        final_metadata = dict(metadata)
        final_metadata["finalized"] = True
        final_metadata.setdefault("source", "hermes")
        if reply_to:
            final_metadata["reply_to"] = reply_to
        hermes_message_id = metadata.get("message_id") or metadata.get("hermes_message_id")
        if hermes_message_id is not None:
            existing = self.store.get_message(session_id, str(hermes_message_id))
            if existing is not None and self._is_progress_message(existing):
                return await self._append_final_message_for_transient_edit(
                    chat_id=chat_id,
                    project_key=project_key,
                    message_id=str(hermes_message_id),
                    content=content,
                    progress_message=existing,
                    final_metadata=final_metadata,
                )
        stored = self.store.append_message(
            project_key=project_key,
            session_id=session_id,
            message_id=hermes_message_id,
            role="assistant",
            content=content,
            metadata=final_metadata,
        )
        frame = self._message_state_update(stored)
        summary, _summary_status = self._summary_for_message(stored)
        summary_frame = self._summary_ready_update(stored, summary.to_protocol())
        existing_project = self.store.get_project(project_key)
        self.store.upsert_project(
            project_key=project_key,
            title=existing_project.title if existing_project else project_key,
            current_session_id=session_id,
            lineage_root_session_id=str(
                final_metadata.get("lineage_root_session_id")
                or final_metadata.get("root_session_id")
                or session_id
            ),
            last_seen_message_id=stored.message_id,
            last_seen_server_seq=stored.server_seq,
            last_preview=content[:240],
        )
        if self.ws_server is not None:
            await self.ws_server.broadcast(frame, project_key=project_key)
            await self.ws_server.broadcast(summary_frame, project_key=project_key)
            await self._broadcast_run_status(
                project_key=project_key,
                session_id=session_id,
                status="idle",
                request_id=str(final_metadata.get("request_id") or "") or None,
            )
        await self._send_private_notification(
            PrivateNotificationKind.FINISHED,
            project_key=project_key,
            session_id=session_id,
            message_id=stored.message_id,
            server_seq=stored.server_seq,
            request_id=str(final_metadata.get("request_id") or "") or None,
            sensitive_context={"content": content, "summary": summary.summary_text},
        )
        self._clear_request_bookkeeping(
            project_key=project_key,
            session_id=session_id,
            request_id=str(final_metadata.get("request_id") or "") or None,
        )
        return SendResult(success=True, message_id=stored.message_id, raw_response=frame)

    async def edit_message(
        self,
        chat_id: str,
        message_id: str,
        content: str,
        *,
        finalize: bool = False,
    ) -> SendResult:
        project_key = self._project_key_from_chat_id(chat_id)
        message_id_str = str(message_id)
        progress_kind = self._progress_kind_for_text(content)
        existing = self.store.get_message_by_project(project_key, message_id_str)
        if not finalize and (
            progress_kind is not None or message_id_str.startswith(PROGRESS_MESSAGE_ID_PREFIX)
        ):
            progress_metadata: dict[str, Any] = {}
            if existing is not None:
                progress_metadata.update(existing.metadata)
                progress_metadata["session_id"] = existing.session_id
            return await self._broadcast_progress_text(
                chat_id=chat_id,
                content=content,
                metadata=progress_metadata,
                request_id=message_id_str,
                kind=progress_kind or "tool_progress",
            )
        if existing is None:
            if not finalize:
                return SendResult(success=False, message_id=None, error="message not found")
            return await self._append_final_message_for_transient_edit(
                chat_id=chat_id,
                project_key=project_key,
                message_id=message_id_str,
                content=content,
            )
        if finalize and self._is_progress_message(existing):
            return await self._append_final_message_for_transient_edit(
                chat_id=chat_id,
                project_key=project_key,
                message_id=message_id_str,
                content=content,
                progress_message=existing,
            )
        updated_metadata = dict(existing.metadata or {})
        updated_metadata.update({"edited_at": time.time(), "finalized": bool(finalize)})
        if finalize:
            updated_metadata.setdefault("source", "hermes")
        updated = self.store.update_message(
            session_id=existing.session_id,
            message_id=existing.message_id,
            content=content,
            metadata=updated_metadata,
        )
        if updated is None:
            return SendResult(success=False, message_id=message_id, error="message not found")
        existing_project = self.store.get_project(project_key)
        self.store.upsert_project(
            project_key=project_key,
            title=existing_project.title if existing_project else project_key,
            current_session_id=updated.session_id,
            last_seen_message_id=updated.message_id,
            last_seen_server_seq=updated.server_seq,
            last_preview=content[:240],
        )
        frame = {
            "type": "state_update",
            "request_id": str(updated.metadata.get("request_id") or updated.message_id),
            "project_key": project_key,
            "session_id": updated.session_id,
            "server_seq": updated.server_seq,
            "payload": {
                "op": "message_updated",
                "message": updated.to_protocol(),
            },
        }
        summary_frame: dict[str, Any] | None = None
        if finalize:
            summary, _summary_status = self._summary_for_message(updated)
            summary_frame = self._summary_ready_update(updated, summary.to_protocol())
        if self.ws_server is not None:
            await self.ws_server.broadcast(frame, project_key=project_key)
            if summary_frame is not None:
                await self.ws_server.broadcast(summary_frame, project_key=project_key)
                await self._broadcast_run_status(
                    project_key=project_key,
                    session_id=updated.session_id,
                    status="idle",
                )
        if finalize and summary_frame is not None:
            await self._send_private_notification(
                PrivateNotificationKind.FINISHED,
                project_key=project_key,
                session_id=updated.session_id,
                message_id=updated.message_id,
                server_seq=updated.server_seq,
                request_id=str(updated.metadata.get("request_id") or "") or None,
                sensitive_context={"content": content, "summary": summary.summary_text},
            )
            self._clear_request_bookkeeping(
                project_key=project_key,
                session_id=updated.session_id,
                request_id=str(updated.metadata.get("request_id") or "") or None,
            )
        return SendResult(success=True, message_id=updated.message_id, raw_response=frame)

    @staticmethod
    def _is_progress_message(message: LogosMessage) -> bool:
        metadata = dict(message.metadata or {})
        source = str(metadata.get("source") or "")
        if source in {"tool_progress", "progress"}:
            return True
        return bool(metadata.get("progress_kind") and metadata.get("finalized") is False)

    async def _append_final_message_for_transient_edit(
        self,
        *,
        chat_id: str,
        project_key: str,
        message_id: str,
        content: str,
        progress_message: LogosMessage | None = None,
        final_metadata: dict[str, Any] | None = None,
    ) -> SendResult:
        context = self._transient_progress_context.pop((project_key, message_id), {})
        session_id = str(
            (progress_message.session_id if progress_message is not None else None)
            or context.get("session_id")
            or chat_id
        )
        metadata = dict(
            (progress_message.metadata if progress_message is not None else None)
            or context.get("metadata")
            or {}
        )
        if final_metadata:
            metadata.update(dict(final_metadata))
        root_request_id = str(metadata.get("request_id") or message_id)
        for progress_key in (
            "progress_kind",
            "kind",
            "transient",
            "message_id",
            "hermes_message_id",
        ):
            metadata.pop(progress_key, None)
        if metadata.get("source") in {"tool_progress", "progress"}:
            metadata.pop("source", None)
        metadata.update(
            {"edited_at": time.time(), "finalized": True, "request_id": root_request_id}
        )
        metadata.setdefault("source", "hermes")
        final_message_id = str(metadata.pop("final_message_id", "") or f"{message_id}-final")
        stored = self.store.append_message(
            project_key=project_key,
            session_id=session_id,
            message_id=final_message_id,
            role="assistant",
            content=content,
            metadata=metadata,
        )
        frame = self._message_state_update(stored)
        summary, _summary_status = self._summary_for_message(stored)
        summary_frame = self._summary_ready_update(stored, summary.to_protocol())
        existing_project = self.store.get_project(project_key)
        self.store.upsert_project(
            project_key=project_key,
            title=existing_project.title if existing_project else project_key,
            current_session_id=session_id,
            lineage_root_session_id=str(
                metadata.get("lineage_root_session_id")
                or metadata.get("root_session_id")
                or session_id
            ),
            last_seen_message_id=stored.message_id,
            last_seen_server_seq=stored.server_seq,
            last_preview=content[:240],
        )
        if self.ws_server is not None:
            await self.ws_server.broadcast(frame, project_key=project_key)
            await self.ws_server.broadcast(summary_frame, project_key=project_key)
            await self._broadcast_run_status(
                project_key=project_key,
                session_id=session_id,
                status="idle",
                request_id=root_request_id,
            )
        await self._send_private_notification(
            PrivateNotificationKind.FINISHED,
            project_key=project_key,
            session_id=session_id,
            message_id=stored.message_id,
            server_seq=stored.server_seq,
            request_id=root_request_id,
            sensitive_context={"content": content, "summary": summary.summary_text},
        )
        self._clear_request_bookkeeping(
            project_key=project_key,
            session_id=session_id,
            request_id=root_request_id,
        )
        return SendResult(success=True, message_id=stored.message_id, raw_response=frame)

    def _message_state_update(self, message: LogosMessage) -> dict[str, Any]:
        return {
            "type": "state_update",
            "request_id": str(message.metadata.get("request_id") or message.message_id),
            "project_key": message.project_key,
            "session_id": message.session_id,
            "server_seq": message.server_seq,
            "payload": {
                "op": "message_appended",
                "message": message.to_protocol(),
            },
        }

    def _summary_ready_update(
        self, message: LogosMessage, summary: dict[str, Any]
    ) -> dict[str, Any]:
        return {
            "type": "state_update",
            "project_key": message.project_key,
            "session_id": message.session_id,
            "server_seq": message.server_seq,
            "payload": {
                "op": "summary_ready",
                "message_id": message.message_id,
                "summary": summary,
                "transient": False,
            },
        }
