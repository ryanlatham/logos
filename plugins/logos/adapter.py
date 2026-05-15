from __future__ import annotations

import hashlib
import ipaddress
import logging
import os
import time
import uuid
from pathlib import Path
from typing import Any

from gateway.config import Platform, PlatformConfig
from gateway.platform_registry import PlatformEntry, platform_registry
from gateway.platforms.base import BasePlatformAdapter, MessageEvent, MessageType, SendResult
from gateway.session import SessionSource

from .apns import APNSClient, PrivateNotificationKind, build_private_apns_payload
from .fast_llm import DeterministicFastModel, FastModelResult
from .schema import Envelope, ProtocolError, error_frame, parse_frame
from .store import LogosMessage, LogosProject, LogosStore
from .tts import DeterministicStubTTS
from .ws_server import LogosWebSocketServer

logger = logging.getLogger(__name__)


DEFAULT_HOST = "127.0.0.1"
DEFAULT_PORT = 8765


def _truthy(value: str | None) -> bool:
    return bool(value and value.strip().lower() in {"1", "true", "yes", "on"})


def _optional_nonempty_str(value: Any) -> str | None:
    if value is None:
        return None
    text = str(value).strip()
    return text or None


def _validate_config(config: PlatformConfig) -> bool:
    _ = config
    return bool(os.getenv("LOGOS_DEVICE_SECRET"))


def _platform() -> Platform:
    """Return Platform('logos'), registering a minimal test entry if needed."""
    try:
        return Platform("logos")
    except ValueError:
        if not platform_registry.is_registered("logos"):
            platform_registry.register(
                PlatformEntry(
                    name="logos",
                    label="Logos",
                    adapter_factory=lambda cfg: LogosAdapter(cfg),
                    check_fn=lambda: True,
                    validate_config=_validate_config,
                    required_env=["LOGOS_DEVICE_SECRET"],
                    allowed_users_env="LOGOS_ALLOWED_USERS",
                    allow_all_env="LOGOS_ALLOW_ALL_USERS",
                    pii_safe=True,
                    emoji="📱",
                )
            )
        return Platform("logos")


class LogosAdapter(BasePlatformAdapter):
    """Hermes platform adapter for the Logos iPhone WebSocket bridge."""

    def __init__(self, config: PlatformConfig, **_: Any) -> None:
        super().__init__(config=config, platform=_platform())
        extra = getattr(config, "extra", {}) or {}
        self.host = os.getenv("LOGOS_HOST") or str(extra.get("host") or DEFAULT_HOST)
        port_value = os.getenv("LOGOS_PORT")
        if port_value is None:
            port_value = extra.get("port", DEFAULT_PORT)
        if port_value in (None, ""):
            port_value = DEFAULT_PORT
        self.port = int(port_value)
        self.device_secret = str(os.getenv("LOGOS_DEVICE_SECRET") or "")
        self.ws_server: LogosWebSocketServer | None = None
        self.store = LogosStore(self._store_path(extra))
        self.tts = DeterministicStubTTS()
        self.fast_model = DeterministicFastModel()
        self.apns = APNSClient.from_env()

    @staticmethod
    def envelope_from_dict(data: dict[str, Any]) -> Envelope:
        return parse_frame(data)

    @property
    def name(self) -> str:
        return "Logos"

    @property
    def ws_url(self) -> str:
        if not self.ws_server:
            return f"ws://{self.host}:{self.port}"
        return self.ws_server.url

    @staticmethod
    def _is_safe_bind_host(host: str) -> bool:
        if _truthy(os.getenv("LOGOS_ALLOW_UNSAFE_BIND")):
            logger.warning("Logos: LOGOS_ALLOW_UNSAFE_BIND enabled for host %s", host)
            return True
        normalized = str(host or "").strip().lower()
        if normalized in {"localhost", "127.0.0.1", "::1"}:
            return True
        try:
            address = ipaddress.ip_address(normalized)
        except ValueError:
            return False
        if address.is_unspecified or address.is_multicast:
            return False
        tailscale_cgnat = ipaddress.ip_network("100.64.0.0/10")
        return bool(
            address.is_loopback
            or address.is_private
            or address.is_link_local
            or address in tailscale_cgnat
        )

    def is_device_allowed(self, device_id: str) -> bool:
        device_id = str(device_id or "").strip()
        if not device_id:
            return False
        if _truthy(os.getenv("LOGOS_ALLOW_ALL_USERS")):
            return True
        allowed_raw = os.getenv("LOGOS_ALLOWED_USERS") or ""
        allowed = {item.strip() for item in allowed_raw.split(",") if item.strip()}
        if allowed:
            return device_id in allowed
        existing = self.store.get_device(device_id)
        return bool(existing and existing.revoked_at is None)

    async def connect(self) -> bool:
        if not self.device_secret:
            self._set_fatal_error(
                "config_missing",
                "LOGOS_DEVICE_SECRET must be set in the runtime environment",
                retryable=False,
            )
            return False
        if not self._is_safe_bind_host(self.host):
            self._set_fatal_error(
                "unsafe_bind_host",
                f"Refusing to bind Logos WebSocket to unsafe host {self.host!r}; use loopback, private/Tailscale IP, or set LOGOS_ALLOW_UNSAFE_BIND=1",
                retryable=False,
            )
            return False
        self.ws_server = LogosWebSocketServer(
            self,
            host=self.host,
            port=self.port,
            device_secret=self.device_secret,
        )
        try:
            await self.ws_server.start()
        except Exception as exc:
            self._set_fatal_error("connect_failed", str(exc), retryable=True)
            return False
        self._mark_connected()
        logger.info("Logos: WebSocket server listening on %s", self.ws_url)
        return True

    async def disconnect(self) -> None:
        if self.ws_server is not None:
            await self.ws_server.stop()
            self.ws_server = None
        self._mark_disconnected()

    async def handle_ws_envelope(self, envelope: Envelope) -> dict[str, Any] | None:
        if envelope.type in {"text_input", "text_message"}:
            return await self._handle_final_text(envelope)
        if envelope.type == "speech":
            if not bool(envelope.payload.get("is_final", False)):
                return self._state_update(
                    op="speech_partial_received",
                    envelope=envelope,
                    payload={
                        "client_msg_id": envelope.payload.get("client_msg_id"),
                        "partial_seq": envelope.payload.get("partial_seq"),
                    },
                )
            return await self._handle_final_text(envelope)
        if envelope.type == "messages_get":
            return self._handle_messages_get(envelope)
        if envelope.type == "playback_audio":
            return await self._handle_playback_audio(envelope)
        if envelope.type == "list_projects":
            return self._handle_list_projects(envelope)
        if envelope.type == "new_project":
            return self._handle_new_project(envelope)
        if envelope.type == "switch_project":
            return self._handle_switch_project(envelope)
        if envelope.type == "rename_project":
            return self._handle_rename_project(envelope)
        if envelope.type == "run_cancel":
            return await self._handle_run_cancel(envelope)
        if envelope.type == "approval_response":
            return await self._handle_approval_response(envelope)
        if envelope.type == "clarify_response":
            return await self._handle_clarify_response(envelope)
        if envelope.type == "hello":
            return {
                "type": "hello",
                "request_id": envelope.request_id,
                "device_id": envelope.device_id,
                "project_key": envelope.project_key,
                "payload": {"authenticated": True, "server": "logos"},
            }
        if envelope.type == "register_device":
            return self._handle_register_device(envelope)
        if envelope.type == "app_focus_change":
            return self._state_update(
                op="app_focus_changed",
                envelope=envelope,
                payload={"focus": envelope.payload.get("focus") or envelope.payload.get("state")},
            )
        return error_frame(
            "unsupported_type",
            f"unsupported Logos frame type: {envelope.type}",
            request_id=envelope.request_id,
            device_id=envelope.device_id,
            project_key=envelope.project_key,
        )

    def _handle_register_device(self, envelope: Envelope) -> dict[str, Any]:
        device_id = str(envelope.device_id or envelope.payload.get("device_id") or "").strip()
        if not device_id:
            return error_frame(
                "invalid_device",
                "register_device requires device_id",
                request_id=envelope.request_id,
                device_id=envelope.device_id,
                project_key=envelope.project_key,
            )
        capabilities_raw = envelope.payload.get("capabilities") or []
        capabilities = [str(item) for item in capabilities_raw] if isinstance(capabilities_raw, list) else []
        shared_hash = hashlib.sha256(self.device_secret.encode("utf-8")).hexdigest() if self.device_secret else None
        device = self.store.upsert_device(
            device_id=device_id,
            display_name=_optional_nonempty_str(envelope.payload.get("display_name")),
            shared_secret_hash=shared_hash,
            apns_token=_optional_nonempty_str(envelope.payload.get("apns_token")),
            apns_environment=_optional_nonempty_str(envelope.payload.get("apns_environment")),
            capabilities=capabilities,
        )
        return {
            "type": "registered",
            "request_id": envelope.request_id,
            "device_id": device_id,
            "project_key": envelope.project_key,
            "payload": {
                "device": device.to_protocol(),
                "server_capabilities": [
                    "text",
                    "speech",
                    "projects",
                    "approval",
                    "clarification",
                    "playback_audio",
                    "private_notifications",
                ],
                "apns_configured": self.apns.config.configured,
                "private_payloads": True,
            },
        }

    async def _handle_final_text(self, envelope: Envelope) -> None:
        project_key = self._project_key_for(envelope)
        text = envelope.payload.get("text")
        fast_result = self.fast_model.analyze_input(text if isinstance(text, str) else "")
        await self._emit_fast_ack(envelope, fast_result)
        routed = await self._route_fast_intent(envelope, fast_result)
        if routed:
            return None
        await self._broadcast_run_status(
            project_key=project_key,
            session_id=envelope.session_id or f"project:{project_key}",
            status="running",
            request_id=envelope.request_id,
            device_id=envelope.device_id,
        )
        await self._dispatch_gateway_text(envelope)
        return None

    async def _emit_fast_ack(self, envelope: Envelope, result: FastModelResult) -> dict[str, Any] | None:
        if not result.ack or not result.ack_text:
            return None
        project_key = self._project_key_for(envelope)
        session_id = envelope.session_id or f"project:{project_key}"
        audio_id = f"ack-{envelope.request_id or uuid.uuid4()}"
        frame = self._state_update(
            op="fast_ack",
            envelope=envelope,
            payload={
                "ack_text": result.ack_text,
                "fast_model": result.to_protocol(),
                "audio_id": audio_id,
                "transient": True,
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
                source="deterministic_stub_fast_ack",
            )
        return frame

    async def _route_fast_intent(self, envelope: Envelope, result: FastModelResult) -> bool:
        if result.cancel_intent:
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
                    self.store.set_active_project(device_id=envelope.device_id, project_key=project.project_key)
                frame = self._project_state_update("project_created", envelope, project)
                if self.ws_server is not None:
                    await self.ws_server.broadcast(frame, project_key=project.project_key)
                return True
        if result.switch_intent:
            title = result.switch_intent.get("project_title", "").strip()
            project = self._find_project_by_title(title) if title else None
            if project is not None:
                active = self.store.set_active_project(device_id=envelope.device_id or "logos-device", project_key=project.project_key)
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

    def _find_project_by_title(self, title: str) -> LogosProject | None:
        normalized = str(title or "").strip().lower()
        if not normalized:
            return None
        matches = [
            project
            for project in self.store.list_projects(limit=100)
            if project.project_key.lower() == normalized or project.title.lower() == normalized
        ]
        if len(matches) == 1:
            return matches[0]
        return None

    def _latest_pending_interaction(self, *, project_key: str, kind: str):
        matches = [item for item in self.store.list_pending_interactions(project_key) if item.kind == kind]
        return matches[-1] if matches else None

    async def _dispatch_gateway_text(self, envelope: Envelope, text_override: str | None = None, *, mirror_user: bool = True) -> str:
        text = text_override if text_override is not None else envelope.payload.get("text")
        if not isinstance(text, str) or not text.strip():
            raise ProtocolError("gateway text dispatch requires non-empty text")
        project_key = self._project_key_for(envelope)
        project = self.store.get_project(project_key) or self.store.upsert_project(project_key=project_key, title=project_key)
        if envelope.device_id:
            self.store.set_active_project(device_id=envelope.device_id, project_key=project_key)
        device_id = envelope.device_id or str(envelope.payload.get("device_id") or "logos-device")
        client_msg_id = str(envelope.payload.get("client_msg_id") or envelope.request_id or uuid.uuid4())
        session_id = str(envelope.session_id or f"project:{project_key}")
        if mirror_user:
            stored_user = self.store.append_message(
                project_key=project_key,
                session_id=session_id,
                message_id=client_msg_id,
                role="user",
                content=text,
                metadata={"client_msg_id": client_msg_id, "source": envelope.type},
            )
            existing_project = self.store.get_project(project_key)
            self.store.upsert_project(
                project_key=project_key,
                title=existing_project.title if existing_project else project.title,
                current_session_id=session_id,
                lineage_root_session_id=session_id,
                last_seen_message_id=stored_user.message_id,
                last_seen_server_seq=stored_user.server_seq,
                last_preview=text[:240],
            )
            if self.ws_server is not None:
                await self.ws_server.broadcast(self._message_state_update(stored_user), project_key=project_key)
        raw_message = envelope.to_dict()
        raw_payload = dict(raw_message.get("payload") or {})
        raw_payload["text"] = text
        raw_message["payload"] = raw_payload
        event = MessageEvent(
            text=text,
            message_type=MessageType.TEXT,
            source=SessionSource(
                platform=self.platform,
                chat_id=f"project:{project_key}",
                chat_name=project.title,
                chat_type="dm",
                user_id=device_id,
                user_name=str(envelope.payload.get("display_name") or device_id),
                message_id=client_msg_id,
            ),
            raw_message=raw_message,
            message_id=client_msg_id,
        )
        await self.handle_message(event)
        return project_key

    async def get_chat_info(self, chat_id: str) -> dict[str, Any]:
        project_key = self._project_key_from_chat_id(chat_id)
        return {"name": project_key, "type": "dm", "project_key": project_key}

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
        hermes_message_id = metadata.get("message_id") or metadata.get("hermes_message_id")
        stored = self.store.append_message(
            project_key=project_key,
            session_id=session_id,
            message_id=hermes_message_id,
            role="assistant",
            content=content,
            metadata={**metadata, "reply_to": reply_to} if reply_to else metadata,
        )
        frame = self._message_state_update(stored)
        summary_result = self.fast_model.summarize(content)
        summary = self.store.upsert_summary(
            message=stored,
            summary_text=summary_result.summary_text,
            source_hash=summary_result.source_hash,
        )
        summary_frame = self._summary_ready_update(stored, summary.to_protocol())
        existing_project = self.store.get_project(project_key)
        self.store.upsert_project(
            project_key=project_key,
            title=existing_project.title if existing_project else project_key,
            current_session_id=session_id,
            lineage_root_session_id=str(metadata.get("lineage_root_session_id") or metadata.get("root_session_id") or session_id),
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
            )
        self._send_private_notification(
            PrivateNotificationKind.FINISHED,
            project_key=project_key,
            session_id=session_id,
            message_id=stored.message_id,
            server_seq=stored.server_seq,
            sensitive_context={"content": content, "summary": summary.summary_text},
        )
        return SendResult(success=True, message_id=stored.message_id, raw_response=frame)

    def _message_state_update(self, message: LogosMessage) -> dict[str, Any]:
        return {
            "type": "state_update",
            "project_key": message.project_key,
            "session_id": message.session_id,
            "server_seq": message.server_seq,
            "payload": {
                "op": "message_appended",
                "message": message.to_protocol(),
            },
        }

    def _summary_ready_update(self, message: LogosMessage, summary: dict[str, Any]) -> dict[str, Any]:
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

    def _send_private_notification(
        self,
        kind: PrivateNotificationKind,
        *,
        project_key: str,
        session_id: str | None = None,
        message_id: str | None = None,
        server_seq: int | None = None,
        request_id: str | None = None,
        sensitive_context: dict[str, Any] | None = None,
    ) -> None:
        payload = build_private_apns_payload(
            kind,
            project_key=project_key,
            session_id=session_id,
            message_id=message_id,
            server_seq=server_seq,
            request_id=request_id,
            sensitive_context=sensitive_context,
        )
        for device in self.store.list_devices(active_only=True):
            if not device.apns_token:
                continue
            result = self.apns.send(device.apns_token, payload)
            if not result.success and not result.skipped:
                logger.warning("Logos APNS send failed for device_id=%s status=%s reason=%s", device.device_id, result.status, result.reason)

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
        return {
            "type": "state_update",
            "request_id": envelope.request_id,
            "device_id": envelope.device_id,
            "project_key": self._project_key_for(envelope),
            "session_id": envelope.session_id,
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
    ) -> dict[str, Any]:
        body: dict[str, Any] = {
            "status": status,
            "updated_at": time.time(),
        }
        if payload:
            body.update(payload)
        return {
            "type": "run_status",
            "request_id": request_id,
            "device_id": device_id,
            "project_key": project_key,
            "session_id": session_id,
            "server_seq": self.store.next_server_seq(),
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
        frame = self._run_status_frame(
            project_key=project_key,
            session_id=session_id,
            status=status,
            request_id=request_id,
            device_id=device_id,
            payload=payload,
        )
        if self.ws_server is not None:
            await self.ws_server.broadcast(frame, project_key=project_key)
        return frame

    async def _handle_run_cancel(self, envelope: Envelope) -> dict[str, Any]:
        project_key = self._project_key_for(envelope)
        session_id = envelope.session_id or f"project:{project_key}"
        frame = await self._broadcast_run_status(
            project_key=project_key,
            session_id=session_id,
            status="cancelling",
            request_id=envelope.request_id,
            device_id=envelope.device_id,
        )
        await self._dispatch_gateway_text(envelope, "/stop", mirror_user=False)
        return frame

    async def _handle_approval_response(self, envelope: Envelope) -> dict[str, Any]:
        decision = str(envelope.payload.get("decision") or "").strip().lower()
        if decision in {"approve", "allow", "yes", "y"}:
            command = "/approve"
        elif decision in {"deny", "reject", "cancel", "no", "n"}:
            command = "/deny"
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
        project_key = await self._dispatch_gateway_text(envelope, command, mirror_user=False)
        self.store.resolve_pending_interaction(request_id)
        return await self._broadcast_run_status(
            project_key=project_key,
            session_id=envelope.session_id or f"project:{project_key}",
            status="running",
            request_id=envelope.request_id,
            device_id=envelope.device_id,
            payload={"approval_decision": decision},
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
        pending = self.store.get_pending_interaction(clarify_id) if clarify_id else None
        resolved = False
        if clarify_id:
            try:
                from tools.clarify_gateway import resolve_gateway_clarify

                resolved = bool(resolve_gateway_clarify(clarify_id, text))
            except Exception:
                resolved = False
        project_key = self._project_key_for(envelope)
        if not resolved:
            project_key = await self._dispatch_gateway_text(envelope, text)
        if pending is not None and pending.kind == "clarification" and pending.project_key == project_key:
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
        frame = {
            "type": "clarify_request",
            "request_id": clarify_id,
            "project_key": project_key,
            "session_id": session_id,
            "server_seq": self.store.next_server_seq(),
            "payload": {
                "clarify_id": clarify_id,
                "question": question,
                "choices": list(choices or []),
                "allow_free_text": True,
                "session_key": session_key,
            },
        }
        self.store.upsert_pending_interaction(
            request_id=clarify_id,
            kind="clarification",
            project_key=project_key,
            session_id=session_id,
            frame_type="clarify_request",
            payload=frame["payload"],
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
        self._send_private_notification(
            PrivateNotificationKind.CLARIFICATION,
            project_key=project_key,
            session_id=session_id,
            request_id=clarify_id,
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
        frame = {
            "type": "approval_request",
            "request_id": approval_id,
            "project_key": project_key,
            "session_id": session_id,
            "server_seq": server_seq,
            "payload": {
                "approval_id": approval_id,
                "title": "Approve shell command?",
                "summary": description,
                "command_preview": command,
                "risk": str(metadata.get("risk") or description),
                "session_key": session_key,
            },
        }
        self.store.upsert_pending_interaction(
            request_id=approval_id,
            kind="approval",
            project_key=project_key,
            session_id=session_id,
            frame_type="approval_request",
            payload=frame["payload"],
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
        self._send_private_notification(
            PrivateNotificationKind.APPROVAL,
            project_key=project_key,
            session_id=session_id,
            request_id=approval_id,
            sensitive_context={"command": command, "description": description, "metadata": metadata},
        )
        return SendResult(success=True, message_id=approval_id, raw_response=frame)

    def _handle_list_projects(self, envelope: Envelope) -> dict[str, Any]:
        limit = self._bounded_limit(envelope.payload.get("limit", 50))
        projects = [project.to_protocol() for project in self.store.list_projects(limit=limit)]
        active = self.store.get_active_project(envelope.device_id) if envelope.device_id else None
        return {
            "type": "projects_list",
            "request_id": envelope.request_id,
            "device_id": envelope.device_id,
            "project_key": active.project_key if active else envelope.project_key,
            "payload": {
                "projects": projects,
                "active_project_key": active.project_key if active else None,
            },
        }

    def _handle_new_project(self, envelope: Envelope) -> dict[str, Any]:
        title = str(envelope.payload.get("title") or envelope.payload.get("project_key") or "").strip()
        if not title:
            return error_frame("invalid_project", "new_project requires payload.title", request_id=envelope.request_id, device_id=envelope.device_id)
        project = self.store.create_project(title)
        if envelope.device_id:
            self.store.set_active_project(device_id=envelope.device_id, project_key=project.project_key)
        return self._project_state_update("project_created", envelope, project)

    def _handle_switch_project(self, envelope: Envelope) -> dict[str, Any]:
        project_key = str(envelope.payload.get("project_key") or envelope.project_key or "").strip()
        if not project_key:
            return error_frame("invalid_project", "switch_project requires project_key", request_id=envelope.request_id, device_id=envelope.device_id)
        project = self.store.set_active_project(device_id=envelope.device_id or "logos-device", project_key=project_key)
        return self._project_state_update("active_project_changed", envelope, project)

    def _handle_rename_project(self, envelope: Envelope) -> dict[str, Any]:
        project_key = self._project_key_for(envelope)
        title = str(envelope.payload.get("title") or "").strip()
        if not title:
            return error_frame("invalid_project", "rename_project requires payload.title", request_id=envelope.request_id, device_id=envelope.device_id, project_key=project_key)
        project = self.store.rename_project(project_key, title)
        return self._project_state_update("project_renamed", envelope, project)

    def _project_state_update(self, op: str, envelope: Envelope, project: LogosProject) -> dict[str, Any]:
        return {
            "type": "state_update",
            "request_id": envelope.request_id,
            "device_id": envelope.device_id,
            "project_key": project.project_key,
            "session_id": project.current_session_id,
            "server_seq": self.store.next_server_seq(),
            "payload": {"op": op, "project": project.to_protocol()},
        }

    async def reconnect_messages_batch(self, hello: Envelope) -> dict[str, Any] | None:
        after_seq = hello.payload.get("after_server_seq", hello.payload.get("last_seen_server_seq"))
        if after_seq is None:
            return None
        return self._handle_messages_get(
            Envelope(
                type="messages_get",
                request_id=hello.request_id,
                device_id=hello.device_id,
                project_key=hello.project_key or hello.payload.get("project_key"),
                session_id=hello.session_id,
                payload={"after_server_seq": after_seq, "limit": hello.payload.get("limit", 100)},
            )
        )

    async def _handle_playback_audio(self, envelope: Envelope) -> dict[str, Any] | None:
        project_key = self._project_key_for(envelope)
        payload = envelope.payload
        session_id = str(envelope.session_id or payload.get("session_id") or f"project:{project_key}")
        message_id = payload.get("message_id")
        mode = str(payload.get("mode") or "summary")
        text = payload.get("text") or payload.get("summary_text")
        if message_id and mode == "summary":
            message = self.store.get_message(session_id, str(message_id))
            if message is None:
                return error_frame(
                    "message_not_found",
                    f"no Logos message found for {session_id}/{message_id}",
                    request_id=envelope.request_id,
                    device_id=envelope.device_id,
                    project_key=project_key,
                )
            summary = self.store.get_summary(message.session_id, message.message_id)
            if summary is None:
                summary_result = self.fast_model.summarize(message.content)
                summary = self.store.upsert_summary(
                    message=message,
                    summary_text=summary_result.summary_text,
                    source_hash=summary_result.source_hash,
                )
            text = summary.summary_text
        if not isinstance(text, str) or not text.strip():
            if not message_id:
                return error_frame(
                    "missing_audio_source",
                    "playback_audio requires payload.text or payload.message_id",
                    request_id=envelope.request_id,
                    device_id=envelope.device_id,
                    project_key=project_key,
                )
            message = self.store.get_message(session_id, str(message_id))
            if message is None:
                return error_frame(
                    "message_not_found",
                    f"no Logos message found for {session_id}/{message_id}",
                    request_id=envelope.request_id,
                    device_id=envelope.device_id,
                    project_key=project_key,
                )
            if mode == "summary":
                summary = self.store.get_summary(message.session_id, message.message_id)
                if summary is None:
                    summary_result = self.fast_model.summarize(message.content)
                    summary = self.store.upsert_summary(
                        message=message,
                        summary_text=summary_result.summary_text,
                        source_hash=summary_result.source_hash,
                    )
                text = summary.summary_text
            else:
                text = message.content
        audio_id = str(payload.get("audio_id") or f"audio-{uuid.uuid4()}")
        return await self._stream_tts_audio(
            text=text,
            audio_id=audio_id,
            project_key=project_key,
            session_id=session_id,
            request_id=envelope.request_id,
            device_id=envelope.device_id,
            message_id=str(message_id) if message_id else None,
            mode=mode,
            source="deterministic_stub_tts",
        )

    async def _stream_tts_audio(
        self,
        *,
        text: str,
        audio_id: str,
        project_key: str,
        session_id: str,
        request_id: str | None,
        device_id: str | None,
        message_id: str | None,
        mode: str,
        source: str,
    ) -> dict[str, Any] | None:
        chunks = self.tts.iter_chunks(text=text, audio_id=audio_id)
        if not chunks:
            return error_frame(
                "tts_empty_audio",
                "TTS produced no audio chunks",
                request_id=request_id,
                device_id=device_id,
                project_key=project_key,
            )
        for chunk in chunks:
            frame = {
                "type": "audio_chunk",
                "request_id": request_id,
                "device_id": device_id,
                "project_key": project_key,
                "session_id": session_id,
                "server_seq": self.store.next_server_seq(),
                "payload": {
                    "audio_id": audio_id,
                    "message_id": message_id,
                    "chunk_index": chunk.index,
                    "mime_type": chunk.mime_type,
                    "encoding": chunk.encoding,
                    "mode": mode,
                    "data": chunk.data_b64,
                },
            }
            if self.ws_server is not None:
                await self.ws_server.broadcast(frame, project_key=project_key)
        end_frame = {
            "type": "audio_end",
            "request_id": request_id,
            "device_id": device_id,
            "project_key": project_key,
            "session_id": session_id,
            "server_seq": self.store.next_server_seq(),
            "payload": {
                "audio_id": audio_id,
                "message_id": message_id,
                "chunk_count": len(chunks),
                "mime_type": chunks[0].mime_type,
                "mode": mode,
                "source": source,
            },
        }
        if self.ws_server is not None:
            await self.ws_server.broadcast(end_frame, project_key=project_key)
            return None
        return end_frame

    def _handle_messages_get(self, envelope: Envelope) -> dict[str, Any]:
        project_key = self._project_key_for(envelope)
        payload = envelope.payload
        limit = self._bounded_limit(payload.get("limit", 100))
        before_message_id = payload.get("before_message_id")
        if before_message_id:
            session_id = str(envelope.session_id or payload.get("session_id") or f"project:{project_key}")
            messages = self.store.messages_before_message_id(session_id, str(before_message_id), limit=limit + 1)
        else:
            after_server_seq = int(payload.get("after_server_seq", payload.get("last_seen_server_seq", 0)) or 0)
            messages = self.store.messages_after_server_seq(project_key, after_server_seq, limit=limit + 1)
        has_more = len(messages) > limit
        messages = messages[:limit]
        pending_interactions = [item.to_protocol() for item in self.store.list_pending_interactions(project_key)]
        return {
            "type": "messages_batch",
            "request_id": envelope.request_id,
            "device_id": envelope.device_id,
            "project_key": project_key,
            "session_id": envelope.session_id or payload.get("session_id"),
            "payload": {
                "messages": [message.to_protocol() for message in messages],
                "pending_interactions": pending_interactions,
                "has_more": has_more,
                "after_server_seq": payload.get("after_server_seq", payload.get("last_seen_server_seq")),
                "before_message_id": before_message_id,
            },
        }

    @staticmethod
    def _bounded_limit(value: Any) -> int:
        try:
            parsed = int(value)
        except (TypeError, ValueError):
            parsed = 100
        return max(1, min(parsed, 500))

    @staticmethod
    def _store_path(extra: dict[str, Any]) -> Path:
        configured = os.getenv("LOGOS_STORE_PATH") or extra.get("store_path")
        if configured:
            return Path(str(configured)).expanduser()
        hermes_home = Path(os.getenv("HERMES_HOME") or Path.home() / ".hermes")
        return hermes_home / "logos" / "logos.db"

    def _project_key_for(self, envelope: Envelope) -> str:
        raw = envelope.project_key or envelope.payload.get("project_key")
        if not raw and envelope.device_id:
            active = self.store.get_active_project(envelope.device_id)
            raw = active.project_key if active else None
        raw = raw or "default"
        project_key = str(raw).strip()
        if not project_key:
            raise ProtocolError("project_key cannot be empty")
        return project_key

    @staticmethod
    def _project_key_from_chat_id(chat_id: str) -> str:
        if chat_id.startswith("project:"):
            value = chat_id.split(":", 1)[1]
            return value or "default"
        return chat_id or "default"


def register(ctx: Any) -> None:
    ctx.register_platform(
        name="logos",
        label="Logos",
        adapter_factory=lambda cfg: LogosAdapter(cfg),
        check_fn=lambda: True,
        validate_config=_validate_config,
        required_env=["LOGOS_DEVICE_SECRET"],
        allowed_users_env="LOGOS_ALLOWED_USERS",
        allow_all_env="LOGOS_ALLOW_ALL_USERS",
        pii_safe=True,
        emoji="📱",
    )
