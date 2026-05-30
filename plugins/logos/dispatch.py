from __future__ import annotations

import logging
from typing import TYPE_CHECKING, Any

from . import commands as command_catalog
from .config import _optional_nonempty_str
from .schema import Envelope, error_frame

if TYPE_CHECKING:
    from ._adapter_core import LogosAdapterCore

    _MixinBase = LogosAdapterCore
else:
    _MixinBase = object

logger = logging.getLogger(__name__)


class DispatchMixin(_MixinBase):
    """The WebSocket envelope router + the commands/register/final-text handlers (from adapter.py).

    Mixed into LogosAdapter; handle_ws_envelope switches on envelope.type and delegates to
    handlers defined here and across the other mixins (audio/interactions/fast-routing/run-state)
    and the adapter core. All cross-handler calls resolve via self through the LogosAdapter MRO.
    """

    async def handle_ws_envelope(self, envelope: Envelope) -> dict[str, Any] | None:
        if envelope.type in {"text_input", "text_message"}:
            await self._handle_final_text(envelope)
            return None
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
            await self._handle_final_text(envelope)
            return None
        if envelope.type == "messages_get":
            return self._handle_messages_get(envelope)
        if envelope.type == "commands_get":
            return self._handle_commands_get(envelope)
        if envelope.type == "commands_complete":
            return self._handle_commands_complete(envelope)
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
                "payload": {
                    "authenticated": True,
                    "server": "logos",
                    "client_config": self.client_config_payload(),
                },
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

    def _handle_commands_get(self, envelope: Envelope) -> dict[str, Any]:
        include_unavailable = bool(envelope.payload.get("include_unavailable", True))
        try:
            payload = command_catalog.build_command_catalog(
                include_unavailable=include_unavailable,
                config_extra=getattr(self.config, "extra", {}) or {},
            )
        except Exception:
            logger.debug("Logos: command catalog build failed", exc_info=True)
            payload = command_catalog.build_command_catalog(
                include_unavailable=include_unavailable,
                hermes_commands=None,
                config_extra={},
            )
            payload["fallback_used"] = True
            payload.setdefault("warnings", []).append(
                "Command catalog failed; using fallback catalog."
            )
        payload["request_id"] = envelope.request_id
        return {
            "type": "commands_list",
            "request_id": envelope.request_id,
            "device_id": envelope.device_id,
            "project_key": envelope.project_key,
            "payload": payload,
        }

    def _handle_commands_complete(self, envelope: Envelope) -> dict[str, Any]:
        text = envelope.payload.get("text")
        if not isinstance(text, str):
            return error_frame(
                "invalid_commands_complete",
                "commands_complete requires text",
                request_id=envelope.request_id,
                device_id=envelope.device_id,
                project_key=envelope.project_key,
            )
        try:
            catalog = command_catalog.build_command_catalog(
                include_unavailable=True,
                config_extra=getattr(self.config, "extra", {}) or {},
            )
            payload = command_catalog.complete_slash_command(text, catalog=catalog)
        except command_catalog.CommandCompletionError as exc:
            return error_frame(
                "invalid_commands_complete",
                str(exc),
                request_id=envelope.request_id,
                device_id=envelope.device_id,
                project_key=envelope.project_key,
            )
        except Exception:
            logger.debug("Logos: command completion failed", exc_info=True)
            fallback_catalog = command_catalog.build_command_catalog(
                include_unavailable=True,
                hermes_commands=None,
                config_extra={},
            )
            payload = command_catalog.complete_slash_command(text, catalog=fallback_catalog)
            payload["fallback_used"] = True
            payload.setdefault("warnings", []).append(
                "Command completion failed; using fallback catalog."
            )
        payload["request_id"] = envelope.request_id
        return {
            "type": "commands_complete_result",
            "request_id": envelope.request_id,
            "device_id": envelope.device_id,
            "project_key": envelope.project_key,
            "payload": payload,
        }

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
        capabilities = (
            [str(item) for item in capabilities_raw] if isinstance(capabilities_raw, list) else []
        )
        shared_hash = None
        device = self.store.upsert_device(
            device_id=device_id,
            display_name=_optional_nonempty_str(envelope.payload.get("display_name")),
            shared_secret_hash=shared_hash,
            apns_token=_optional_nonempty_str(envelope.payload.get("apns_token")),
            apns_environment=_optional_nonempty_str(envelope.payload.get("apns_environment")),
            capabilities=capabilities,
        )
        self._approve_gateway_pairing_for_device(device_id, device.display_name)
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
                "client_config": self.client_config_payload(),
            },
        }

    async def _handle_final_text(self, envelope: Envelope) -> None:
        project_key = self._project_key_for(envelope)
        text = envelope.payload.get("text")
        text_value = text if isinstance(text, str) else ""
        session_id = self._client_session_id_for(envelope, project_key)
        fast_result = self.fast_model.analyze_input(text_value)
        if await self._handle_fast_direct_response(envelope, fast_result):
            return None
        await self._emit_fast_ack(envelope, fast_result)
        routed = await self._route_fast_intent(envelope, fast_result)
        if routed:
            return None
        await self._broadcast_run_status(
            project_key=project_key,
            session_id=session_id,
            status="running",
            request_id=envelope.request_id,
            device_id=envelope.device_id,
        )
        await self._dispatch_gateway_text(envelope)
        return None
