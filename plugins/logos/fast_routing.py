from __future__ import annotations

import uuid
from typing import TYPE_CHECKING, Any

from .fast_llm import is_safe_direct_response_for_request
from .providers import FastModelResultLike
from .schema import Envelope

if TYPE_CHECKING:
    from ._adapter_core import LogosAdapterCore

    _MixinBase = LogosAdapterCore
else:
    _MixinBase = object


class FastRoutingMixin(_MixinBase):
    """Fast-model direct responses, acks, and intent routing (from adapter.py).

    Mixed into LogosAdapter; uses self.{store, ws_server, tts, _project_key_for,
    _client_session_id_for, _mirror_user_message, _message_state_update, _state_update,
    _stream_tts_audio, _handle_run_cancel, _latest_pending_interaction,
    _handle_approval_response, _find_project_by_title, _project_state_update,
    _broadcast_run_status, _dispatch_gateway_text}.
    """

    async def _handle_fast_direct_response(
        self, envelope: Envelope, result: FastModelResultLike
    ) -> bool:
        response_text = result.direct_response_text
        response_kind = result.direct_response_kind
        text = envelope.payload.get("text")
        if any(
            [
                result.switch_intent,
                result.create_intent,
                result.resume_intent,
                result.cancel_intent,
                result.approval_decision,
            ]
        ):
            return False
        if not response_text or not response_kind or not isinstance(text, str) or not text.strip():
            return False
        if not is_safe_direct_response_for_request(text, response_kind, response_text):
            return False
        project_key = self._project_key_for(envelope)
        project = self.store.get_project(project_key) or self.store.upsert_project(
            project_key=project_key, title=project_key
        )
        client_msg_id = str(
            envelope.payload.get("client_msg_id") or envelope.request_id or uuid.uuid4()
        )
        session_id = self._client_session_id_for(envelope, project_key)
        await self._mirror_user_message(
            envelope,
            text,
            project=project,
            project_key=project_key,
            session_id=session_id,
            client_msg_id=client_msg_id,
        )
        assistant_message_id = f"fast-{envelope.request_id or uuid.uuid4()}"
        stored_assistant = self.store.append_message(
            project_key=project_key,
            session_id=session_id,
            message_id=assistant_message_id,
            role="assistant",
            content=response_text,
            metadata={
                "source": "fast_response",
                "finalized": True,
                "fast_response_kind": response_kind,
                "fast_model": result.to_protocol(),
                "request_id": envelope.request_id,
            },
        )
        existing_project = self.store.get_project(project_key)
        self.store.upsert_project(
            project_key=project_key,
            title=existing_project.title if existing_project else project.title,
            current_session_id=session_id,
            lineage_root_session_id=session_id,
            last_seen_message_id=stored_assistant.message_id,
            last_seen_server_seq=stored_assistant.server_seq,
            last_preview=response_text[:240],
        )
        if self.ws_server is not None:
            await self.ws_server.broadcast(
                self._message_state_update(stored_assistant), project_key=project_key
            )
        return True

    async def _emit_fast_ack(
        self, envelope: Envelope, result: FastModelResultLike
    ) -> dict[str, Any] | None:
        if not result.ack or not result.ack_text:
            return None
        project_key = self._project_key_for(envelope)
        session_id = self._client_session_id_for(envelope, project_key)
        audio_id = f"ack-{envelope.request_id or uuid.uuid4()}"
        frame = self._state_update(
            op="fast_ack",
            envelope=envelope,
            payload={
                "ack_text": result.ack_text,
                "fast_model": result.to_protocol(),
                "audio_id": audio_id,
                "transient": True,
                "ttl_ms": 5000,
                "clear_on": [
                    "assistant_message",
                    "run_terminal",
                    "project_change",
                    "interaction_resolved",
                ],
            },
        )
        if self.ws_server is not None:
            await self.ws_server.broadcast(frame, project_key=project_key)
        if bool(envelope.payload.get("ack_audio")) or envelope.type == "speech":
            await self._stream_tts_audio(
                text=result.ack_text,
                audio_id=audio_id,
                project_key=project_key,
                session_id=session_id,
                request_id=envelope.request_id,
                device_id=envelope.device_id,
                message_id=None,
                mode="ack",
                source=getattr(self.tts, "source_name", "tts"),
            )
        return frame

    async def _route_fast_intent(self, envelope: Envelope, result: FastModelResultLike) -> bool:
        if result.cancel_intent:
            await self._mirror_control_intent_message(envelope)
            await self._handle_run_cancel(envelope)
            return True
        if result.approval_decision:
            project_key = self._project_key_for(envelope)
            pending = self._latest_pending_interaction(project_key=project_key, kind="approval")
            if pending is None:
                return False
            response = Envelope(
                type="approval_response",
                request_id=pending.request_id,
                device_id=envelope.device_id,
                project_key=project_key,
                session_id=pending.session_id,
                payload={"decision": result.approval_decision, "approval_id": pending.request_id},
            )
            await self._handle_approval_response(response)
            return True
        if result.create_intent:
            title = result.create_intent.get("title", "").strip()
            if title:
                project = self.store.create_project(title)
                if envelope.device_id:
                    self.store.set_active_project(
                        device_id=envelope.device_id, project_key=project.project_key
                    )
                frame = self._project_state_update("project_created", envelope, project)
                if self.ws_server is not None:
                    await self.ws_server.broadcast(frame, project_key=project.project_key)
                return True
        if result.switch_intent:
            title = result.switch_intent.get("project_title", "").strip()
            matched_project = self._find_project_by_title(title) if title else None
            if matched_project is not None:
                active = self.store.set_active_project(
                    device_id=envelope.device_id or "logos-device",
                    project_key=matched_project.project_key,
                )
                frame = self._project_state_update("active_project_changed", envelope, active)
                if self.ws_server is not None:
                    await self.ws_server.broadcast(frame, project_key=active.project_key)
                return True
        if result.resume_intent:
            target = result.resume_intent.get("target", "").strip()
            if target:
                await self._broadcast_run_status(
                    project_key=self._project_key_for(envelope),
                    session_id=envelope.session_id or f"project:{self._project_key_for(envelope)}",
                    status="running",
                    request_id=envelope.request_id,
                    device_id=envelope.device_id,
                    payload={"intent": "resume"},
                )
                await self._dispatch_gateway_text(envelope, f"/resume {target}")
                return True
        return False

    async def _mirror_control_intent_message(self, envelope: Envelope) -> None:
        text = envelope.payload.get("text")
        if not isinstance(text, str) or not text.strip():
            return
        project_key = self._project_key_for(envelope)
        project = self.store.get_project(project_key) or self.store.upsert_project(
            project_key=project_key, title=project_key
        )
        await self._mirror_user_message(
            envelope,
            text.strip(),
            project=project,
            project_key=project_key,
            session_id=self._client_session_id_for(envelope, project_key),
            client_msg_id=str(
                envelope.payload.get("client_msg_id") or envelope.request_id or uuid.uuid4()
            ),
        )
