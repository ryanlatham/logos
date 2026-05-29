from __future__ import annotations

import hashlib
import inspect
import ipaddress
import logging
import os
import re
import shlex
import socket
import time
import uuid
from pathlib import Path
from typing import Any
from urllib.parse import urlparse

from gateway.config import Platform, PlatformConfig
from gateway.platform_registry import PlatformEntry, platform_registry
from gateway.platforms.base import BasePlatformAdapter, MessageEvent, MessageType, SendResult
from gateway.session import SessionSource

from .apns import APNSClient, PrivateNotificationKind, build_private_apns_payload
from . import commands as command_catalog
from .fast_llm import FastModelResult, build_fast_model, is_safe_direct_response_for_request
from .pairing import (
    DEFAULT_PAIRING_TTL_SECONDS,
    PairingInvite,
    create_invite,
    derive_device_secret,
    pairing_token_hash,
    render_qr_png,
)
from .config import (
    DEFAULT_FINAL_AUDIO_FULL_MAX_CHARS,
    DEFAULT_FINAL_AUDIO_FULL_MAX_WORDS,
    DEFAULT_HOST,
    DEFAULT_LOGOS_HOME_CHANNEL,
    DEFAULT_LOGOS_HOME_CHANNEL_NAME,
    DEFAULT_LOGOS_KEEPALIVE_THROTTLE_SECONDS,
    DEFAULT_LOGOS_STALE_TIMEOUT_SECONDS,
    DEFAULT_PORT,
    LOGOS_HOME_CHANNEL_ENV,
    LOGOS_HOME_CHANNEL_NAME_ENV,
    LOGOS_TIMEOUT_SECONDS_ENV,
    MAX_LOGOS_STALE_TIMEOUT_SECONDS,
    _configured_home_channel,
    _configured_positive_int,
    _ensure_home_channel_env,
    _is_loopback_adapter_url,
    _is_plaintext_non_loopback_adapter_url,
    _nonnegative_int,
    _optional_nonempty_str,
    _positive_int_or_none,
    _project_chat_id,
    _safe_filename_component,
    _string_set,
    _truthy,
    _validate_config,
)
from .notifications import APNS_STALE_DEVICE_REASONS, PrivateNotifier
from .progress_analysis import ProgressAnalyzer
from .providers import FastLLMProvider, TTSProvider
from .fast_routing import FastRoutingMixin
from .interactions import InteractionsMixin
from .request_context import current_request_context, request_scope
from .run_state import RunStateMixin
from .schema import Envelope, ProtocolError, error_frame, parse_frame
from .store import LogosMessage, LogosProject, LogosStore, LogosSummary
from .tts import build_tts
from .ws_server import LogosWebSocketServer

logger = logging.getLogger(__name__)


PROGRESS_MESSAGE_ID_PREFIX = "progress-"




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
                    cron_deliver_env_var=LOGOS_HOME_CHANNEL_ENV,
                    pii_safe=True,
                    emoji="📱",
                )
            )
        return Platform("logos")


class LogosAdapter(RunStateMixin, InteractionsMixin, FastRoutingMixin, BasePlatformAdapter):
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
        self.device_secret = str(os.getenv("LOGOS_DEVICE_SECRET") or extra.get("device_secret") or "").strip()
        self.allow_all_users = _truthy(os.getenv("LOGOS_ALLOW_ALL_USERS")) or _truthy(extra.get("allow_all_users"))
        self.allowed_users = _string_set(os.getenv("LOGOS_ALLOWED_USERS")) | _string_set(extra.get("allowed_users")) | _string_set(extra.get("allowed_devices"))
        self.ws_server: LogosWebSocketServer | None = None
        self.store = LogosStore(self._store_path(extra))
        self.store.interrupt_active_run_states(reason="adapter_restarted")
        self.tts: TTSProvider = build_tts(extra)
        self.fast_model: FastLLMProvider = build_fast_model(extra)
        self._progress = ProgressAnalyzer()
        final_audio_full_max_chars = os.getenv("LOGOS_FINAL_AUDIO_FULL_MAX_CHARS")
        final_audio_full_max_words = os.getenv("LOGOS_FINAL_AUDIO_FULL_MAX_WORDS")
        self.final_audio_full_max_chars = _nonnegative_int(
            final_audio_full_max_chars if final_audio_full_max_chars is not None else extra.get("final_audio_full_max_chars"),
            DEFAULT_FINAL_AUDIO_FULL_MAX_CHARS,
        )
        self.final_audio_full_max_words = _nonnegative_int(
            final_audio_full_max_words if final_audio_full_max_words is not None else extra.get("final_audio_full_max_words"),
            DEFAULT_FINAL_AUDIO_FULL_MAX_WORDS,
        )
        self.stale_timeout_seconds = _configured_positive_int(
            os.getenv(LOGOS_TIMEOUT_SECONDS_ENV),
            extra.get("timeout_seconds"),
            default=DEFAULT_LOGOS_STALE_TIMEOUT_SECONDS,
            max_value=MAX_LOGOS_STALE_TIMEOUT_SECONDS,
        )
        self._keepalive_throttle_seconds = min(
            DEFAULT_LOGOS_KEEPALIVE_THROTTLE_SECONDS,
            max(1.0, float(self.stale_timeout_seconds) / 3.0),
        )
        self.apns = APNSClient.from_env()
        self._notifier = PrivateNotifier()
        self.latest_pairing_invite: PairingInvite | None = None
        self._transient_progress_context: dict[tuple[str, str], dict[str, Any]] = {}
        self._last_keepalive_sent_at: dict[tuple[str, str], float] = {}

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

    def client_config_payload(self) -> dict[str, Any]:
        return {"stale_timeout_seconds": self.stale_timeout_seconds}

    @staticmethod
    def _is_safe_bind_host(host: str) -> bool:
        if _truthy(os.getenv("LOGOS_ALLOW_UNSAFE_BIND")):
            logger.warning("Logos: LOGOS_ALLOW_UNSAFE_BIND enabled for host %s", host)
            return True
        normalized = str(host or "").strip().lower()
        if normalized in {"localhost", "127.0.0.1", "::1"}:
            return True
        try:
            return LogosAdapter._is_safe_ip_address(ipaddress.ip_address(normalized))
        except ValueError:
            pass
        if normalized in {"", "0.0.0.0", "::"}:
            return False
        try:
            infos = socket.getaddrinfo(normalized, None, proto=socket.IPPROTO_TCP)
        except OSError:
            return False
        addresses: set[Any] = set()
        for info in infos:
            sockaddr = info[4]
            if not sockaddr:
                continue
            try:
                addresses.add(ipaddress.ip_address(str(sockaddr[0])))
            except ValueError:
                return False
        return bool(addresses) and all(LogosAdapter._is_safe_ip_address(address) for address in addresses)

    @staticmethod
    def _is_safe_ip_address(address: Any) -> bool:
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
        if self.allow_all_users:
            return True
        if self.allowed_users:
            return device_id in self.allowed_users
        existing = self.store.get_device(device_id)
        return bool(existing and existing.revoked_at is None)

    def auth_secrets_for_device(self, device_id: str | None) -> list[tuple[str, str]]:
        """Return candidate hello secrets for a device, preferring per-device credentials."""

        normalized_device = str(device_id or "").strip()
        if not self.device_secret:
            return []
        if not normalized_device:
            return [(self.device_secret, "shared_master")]
        existing = self.store.get_device(normalized_device)
        per_device_secret = derive_device_secret(self.device_secret, normalized_device)
        per_device_hash = hashlib.sha256(per_device_secret.encode("utf-8")).hexdigest()
        master_hash = hashlib.sha256(self.device_secret.encode("utf-8")).hexdigest()
        if existing and existing.revoked_at is not None:
            return []
        if existing and existing.shared_secret_hash:
            if existing.shared_secret_hash == per_device_hash:
                return [(per_device_secret, "per_device")]
            if existing.shared_secret_hash == master_hash:
                return [(self.device_secret, "legacy_shared")]
            return []
        return [(self.device_secret, "shared_master")]

    def _approve_gateway_pairing_for_device(self, device_id: str | None, display_name: str | None = None) -> bool:
        """Bridge Logos QR/device auth into Hermes' generic gateway authorization store."""

        normalized_device = str(device_id or "").strip()
        if not normalized_device or not self.is_device_allowed(normalized_device):
            return False
        try:
            from gateway.pairing import PairingStore
        except Exception:
            logger.debug("Logos: gateway pairing store unavailable for device authorization", exc_info=True)
            return False

        platform_name = self.platform.value if self.platform else "logos"
        try:
            store = PairingStore()
            with store._lock:  # noqa: SLF001 - plugin bridge uses Hermes' existing gateway-pairing persistence.
                if store.is_approved(platform_name, normalized_device):
                    return False
                store._approve_user(platform_name, normalized_device, display_name or normalized_device)  # noqa: SLF001
                return True
        except Exception:
            logger.warning("Logos: failed to authorize QR-paired device in gateway pairing store", exc_info=True)
            return False

    def create_pairing_invite(
        self,
        *,
        adapter_url: str | None = None,
        device_id: str | None = None,
        ttl_seconds: int = DEFAULT_PAIRING_TTL_SECONDS,
        now: float | None = None,
        autoconnect: bool = True,
    ) -> PairingInvite:
        url = adapter_url or self._public_adapter_url()
        invite = create_invite(
            master_secret=self.device_secret,
            adapter_url=url,
            device_id=device_id,
            ttl_seconds=ttl_seconds,
            now=now,
            autoconnect=autoconnect,
        )
        self.store.upsert_pairing_token(
            token_hash=pairing_token_hash(invite.pair_token),
            device_id=invite.device_id,
            shared_secret_hash=invite.device_secret_hash,
            expires_at=invite.expires_at,
            created_at=now,
        )
        self.latest_pairing_invite = invite
        return invite

    def build_pairing_command_response(
        self,
        raw_args: str = "",
        *,
        image_dir: str | Path | None = None,
        now: float | None = None,
    ) -> str:
        options = self._parse_pairing_args(raw_args)
        ttl_seconds = int(options.get("ttl") or options.get("ttl_seconds") or DEFAULT_PAIRING_TTL_SECONDS)
        device_id = options.get("device_id") or options.get("device")
        adapter_url = options.get("adapter_url") or options.get("url") or None
        invite = self.create_pairing_invite(
            adapter_url=adapter_url,
            device_id=device_id,
            ttl_seconds=ttl_seconds,
            now=now,
            autoconnect=not _truthy(options.get("no_autoconnect")),
        )
        output_dir = Path(image_dir).expanduser() if image_dir else Path(os.getenv("HERMES_HOME") or Path.home() / ".hermes") / "cache" / "logos"
        safe_device_id = _safe_filename_component(invite.device_id)
        png_path = render_qr_png(invite.pairing_url, output_dir / f"pairing-{safe_device_id}-{int(invite.expires_at)}.png")
        remaining = max(0, int(invite.expires_at - (time.time() if now is None else float(now))))
        warnings: list[str] = []
        if _is_loopback_adapter_url(invite.adapter_url):
            warnings.append(
                "⚠️ Adapter URL is loopback. This is fine for Simulator, but a physical iPhone will point at itself. "
                "Set LOGOS_PUBLIC_URL or pass adapter_url=wss://<mac>.<tailnet>.ts.net/ for device pairing."
            )
        elif _is_plaintext_non_loopback_adapter_url(invite.adapter_url):
            warnings.append(
                "⚠️ Adapter URL uses plaintext ws://. The iOS pairing client rejects non-loopback plaintext pairing URLs; use wss://."
            )
        warning_text = "".join(f"{warning}\n" for warning in warnings)
        return (
            "Scan this with your iPhone to pair Logos.\n\n"
            f"Device ID: `{invite.device_id}`\n"
            f"Adapter: `{invite.adapter_url}`\n"
            f"Expires in: {remaining} seconds\n"
            f"{warning_text}\n"
            "This QR uses a short-lived one-time token; the long-lived per-device secret is not printed here.\n\n"
            f"MEDIA:{png_path}"
        )

    async def handle_pairing_envelope(self, envelope: Envelope) -> dict[str, Any]:
        token = str(envelope.payload.get("pair_token") or "").strip()
        device_id = str(envelope.payload.get("device_id") or envelope.device_id or "").strip()
        display_name = _optional_nonempty_str(envelope.payload.get("display_name"))
        if not token:
            return self._pairing_error(envelope, "missing_pair_token", "Pairing token is required")
        if not device_id:
            return self._pairing_error(envelope, "missing_device_id", "Device ID is required")
        token_hash = pairing_token_hash(token)
        record = self.store.get_pairing_token(token_hash)
        if record is None:
            return self._pairing_error(envelope, "token_not_found", "Pairing token was not found")
        now = time.time()
        if record.device_id != device_id:
            return self._pairing_error(envelope, "device_mismatch", "Pairing token was issued for a different device")
        if record.is_consumed:
            return self._pairing_error(envelope, "token_consumed", "Pairing token was already used")
        if record.is_expired(now):
            return self._pairing_error(envelope, "token_expired", "Pairing token has expired")
        device_secret = derive_device_secret(self.device_secret, device_id)
        device_secret_hash = hashlib.sha256(device_secret.encode("utf-8")).hexdigest()
        if record.shared_secret_hash != device_secret_hash:
            return self._pairing_error(envelope, "credential_mismatch", "Pairing token credential binding does not match this adapter")
        consumed = self.store.mark_pairing_token_consumed(token_hash, consumed_at=now, expires_after=now)
        if consumed is None:
            return self._pairing_error(envelope, "token_consumed", "Pairing token was already used or expired")
        self.store.upsert_device(
            device_id=device_id,
            display_name=display_name,
            shared_secret_hash=device_secret_hash,
            capabilities=[],
        )
        self._approve_gateway_pairing_for_device(device_id, display_name)
        return {
            "type": "pairing_complete",
            "request_id": envelope.request_id,
            "device_id": device_id,
            "payload": {
                "adapter_url": envelope.payload.get("adapter_url") or self._public_adapter_url(),
                "device_id": device_id,
                "device_secret": device_secret,
                "credential_scope": "per_device",
            },
        }

    def _pairing_error(self, envelope: Envelope, reason: str, message: str) -> dict[str, Any]:
        frame = error_frame(
            "pairing_failed",
            message,
            request_id=envelope.request_id,
            device_id=envelope.device_id,
            project_key=envelope.project_key,
            raw=envelope.to_dict(),
        )
        frame["payload"]["reason"] = reason
        return frame

    def _public_adapter_url(self) -> str:
        value = _optional_nonempty_str(os.getenv("LOGOS_PUBLIC_URL"))
        if value:
            return value
        return self.ws_url

    @staticmethod
    def _parse_pairing_args(raw_args: str) -> dict[str, str]:
        options: dict[str, str] = {}
        for item in shlex.split(raw_args or ""):
            if "=" in item:
                key, value = item.split("=", 1)
                options[key.strip().replace("-", "_")] = value.strip()
            elif item.strip():
                options.setdefault("device_id", item.strip())
        return options

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
            enc_mode=os.getenv("LOGOS_ENC_MODE", "negotiate").strip().lower() or "negotiate",
        )
        try:
            await self.ws_server.start()
        except Exception as exc:
            self._set_fatal_error("connect_failed", str(exc), retryable=True)
            return False
        _ensure_home_channel_env(self.config, getattr(self.config, "extra", {}) or {})
        self._mark_connected()
        logger.info("Logos: WebSocket server listening on %s", self.ws_url)
        return True

    async def disconnect(self) -> None:
        if self.ws_server is not None:
            await self.ws_server.stop()
            self.ws_server = None
        close_apns = getattr(self.apns, "aclose", None)
        if close_apns is not None:
            result = close_apns()
            if inspect.isawaitable(result):
                await result
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
                "payload": {"authenticated": True, "server": "logos", "client_config": self.client_config_payload()},
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
            payload.setdefault("warnings", []).append("Command catalog failed; using fallback catalog.")
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
            payload.setdefault("warnings", []).append("Command completion failed; using fallback catalog.")
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
        capabilities = [str(item) for item in capabilities_raw] if isinstance(capabilities_raw, list) else []
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

    async def _mirror_user_message(
        self,
        envelope: Envelope,
        text: str,
        *,
        project: LogosProject,
        project_key: str,
        session_id: str,
        client_msg_id: str,
    ) -> LogosMessage:
        if envelope.device_id:
            self.store.set_active_project(device_id=envelope.device_id, project_key=project_key)
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
        return stored_user

    def _client_session_id_for(self, envelope: Envelope, project_key: str) -> str:
        default_session_id = f"project:{project_key}"
        requested = str(envelope.session_id or "").strip()
        if not requested:
            return default_session_id
        if requested.startswith("project:") and requested != default_session_id:
            return default_session_id
        for project in self.store.list_projects(limit=500):
            if project.project_key == project_key:
                continue
            if requested in {project.current_session_id, project.lineage_root_session_id, f"project:{project.project_key}"}:
                return default_session_id
        return requested

    def _request_context_for_event(self, event: MessageEvent) -> dict[str, str] | None:
        raw_message = event.raw_message if isinstance(event.raw_message, dict) else {}
        request_id = str(raw_message.get("request_id") or "").strip()
        if not request_id:
            return None
        project_key = str(raw_message.get("project_key") or self._project_key_from_chat_id(event.source.chat_id)).strip()
        session_id = str(raw_message.get("session_id") or event.source.chat_id).strip()
        return {"project_key": project_key, "session_id": session_id, "request_id": request_id}

    async def handle_message(self, event: MessageEvent) -> None:  # type: ignore[override]
        with request_scope(self._request_context_for_event(event)):
            await super().handle_message(event)

    async def _process_message_background(self, event: MessageEvent, session_key: str) -> None:  # type: ignore[override]
        with request_scope(self._request_context_for_event(event)):
            await super()._process_message_background(event, session_key)

    def _metadata_with_current_request_id(
        self,
        *,
        project_key: str,
        session_id: str,
        metadata: dict[str, Any],
    ) -> dict[str, Any]:
        metadata = dict(metadata or {})
        if metadata.get("request_id"):
            return metadata
        context = current_request_context()
        if not context or context.get("project_key") != project_key:
            return metadata
        context_session = context.get("session_id")
        if not context_session:
            return metadata
        explicit_session = str(metadata.get("session_id") or metadata.get("session") or "").strip()
        if explicit_session and explicit_session != context_session:
            return metadata
        if not explicit_session:
            metadata["session_id"] = context_session
            session_id = context_session
        if str(session_id or "").strip() != context_session:
            return metadata
        request_id = context.get("request_id")
        if request_id:
            metadata["request_id"] = request_id
        return metadata


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
        self._approve_gateway_pairing_for_device(device_id, _optional_nonempty_str(envelope.payload.get("display_name")))
        client_msg_id = str(envelope.payload.get("client_msg_id") or envelope.request_id or uuid.uuid4())
        session_id = self._client_session_id_for(envelope, project_key)
        if mirror_user:
            await self._mirror_user_message(
                envelope,
                text,
                project=project,
                project_key=project_key,
                session_id=session_id,
                client_msg_id=client_msg_id,
            )
        raw_message = envelope.to_dict()
        raw_message["session_id"] = session_id
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

    @staticmethod
    def _source_hash(text: str) -> str:
        return hashlib.sha256(str(text or "").encode("utf-8")).hexdigest()

    def _is_short_final_audio_text(self, text: str) -> bool:
        normalized = str(text or "").strip()
        if not normalized:
            return False
        return (
            len(normalized) <= self.final_audio_full_max_chars
            and len(normalized.split()) <= self.final_audio_full_max_words
        )

    def _summary_for_message(self, message: LogosMessage) -> tuple[LogosSummary, str]:
        expected_source_hash = self._source_hash(message.content)
        existing = self.store.get_summary(message.session_id, message.message_id)
        if existing is not None and existing.source_hash == expected_source_hash:
            return existing, "reused"

        summary_result = self.fast_model.summarize(message.content)
        summary = self.store.upsert_summary(
            message=message,
            summary_text=summary_result.summary_text,
            source_hash=expected_source_hash,
        )
        return summary, "regenerated" if existing is not None else "generated"


    # Progress/gateway-status classification delegates to ProgressAnalyzer (progress_analysis.py).
    def _looks_like_tool_progress_text(self, content: str) -> bool:
        return self._progress._looks_like_tool_progress_text(content)

    def _looks_like_gateway_status_text(self, content: str) -> bool:
        return self._progress._looks_like_gateway_status_text(content)

    def _gateway_lifecycle_interruption_reason(self, content: str) -> str | None:
        return self._progress._gateway_lifecycle_interruption_reason(content)

    def _looks_like_terminal_error_text(self, content: str) -> bool:
        return self._progress._looks_like_terminal_error_text(content)

    def _progress_kind_for_text(self, content: str) -> str | None:
        return self._progress._progress_kind_for_text(content)

    def _human_readable_error_response(self, content: str) -> tuple[str, dict[str, Any]]:
        explain_error = getattr(self.fast_model, "explain_error", None)
        if callable(explain_error):
            try:
                result = explain_error(content)
                message_text = str(getattr(result, "message_text", "") or "").strip()
                protocol = result.to_protocol() if hasattr(result, "to_protocol") else {}
                if message_text:
                    return message_text, dict(protocol or {})
            except Exception:
                logger.warning("Logos fast model failed to explain Hermes error", exc_info=True)
        raw = str(content or "").strip().lstrip("⚠️⚠❌ ").strip() or "an internal error"
        return (
            "Hermes hit an unrecoverable error before it could answer. "
            f"The underlying error was: {raw}. Please retry, or switch models if it keeps happening.",
            {},
        )

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
        context_key = (project_key, str(provided_progress_id)) if provided_progress_id is not None else None
        previous_context = self._transient_progress_context.get(context_key, {}) if context_key is not None else {}
        previous_metadata = dict(previous_context.get("metadata") or {})
        session_id = str(metadata.get("session_id") or metadata.get("session") or previous_context.get("session_id") or chat_id)
        if provided_progress_id is None and kind == "gateway_status":
            provided_progress_id = f"{PROGRESS_MESSAGE_ID_PREFIX}gateway-status-{_safe_filename_component(session_id)}"
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
                return SendResult(success=False, message_id=progress_id, error="progress message not found")
            existing_project = self.store.get_project(project_key)
            self.store.upsert_project(
                project_key=project_key,
                title=existing_project.title if existing_project else project_key,
                current_session_id=session_id,
                lineage_root_session_id=str(progress_metadata.get("lineage_root_session_id") or progress_metadata.get("root_session_id") or session_id),
            )
            server_seq = stored_progress.server_seq
        else:
            server_seq = self.store.next_server_seq()
        frame = {
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
        metadata = self._metadata_with_current_request_id(project_key=project_key, session_id=session_id, metadata=metadata)
        session_id = str(metadata.get("session_id") or metadata.get("session") or session_id)
        if self._looks_like_terminal_error_text(content):
            await self._broadcast_progress_text(chat_id=chat_id, content=content, metadata=metadata, kind="gateway_status")
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
            sent = await self._broadcast_progress_text(chat_id=chat_id, content=content, metadata=metadata, kind=progress_kind)
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
            lineage_root_session_id=str(final_metadata.get("lineage_root_session_id") or final_metadata.get("root_session_id") or session_id),
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
        if not finalize and (progress_kind is not None or message_id_str.startswith(PROGRESS_MESSAGE_ID_PREFIX)):
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
        session_id = str((progress_message.session_id if progress_message is not None else None) or context.get("session_id") or chat_id)
        metadata = dict((progress_message.metadata if progress_message is not None else None) or context.get("metadata") or {})
        if final_metadata:
            metadata.update(dict(final_metadata))
        root_request_id = str(metadata.get("request_id") or message_id)
        for progress_key in ("progress_kind", "kind", "transient", "message_id", "hermes_message_id"):
            metadata.pop(progress_key, None)
        if metadata.get("source") in {"tool_progress", "progress"}:
            metadata.pop("source", None)
        metadata.update({"edited_at": time.time(), "finalized": True, "request_id": root_request_id})
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

    async def _send_private_notification(
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
        await self._notifier.send(
            self.store,
            self.apns,
            kind,
            project_key=project_key,
            session_id=session_id,
            message_id=message_id,
            server_seq=server_seq,
            request_id=request_id,
            sensitive_context=sensitive_context,
        )



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
                project_key=self._project_key_for_hello(hello),
                session_id=hello.session_id,
                payload={"after_server_seq": after_seq, "limit": hello.payload.get("limit", 100)},
            )
        )

    async def _handle_playback_audio(self, envelope: Envelope) -> dict[str, Any] | None:
        project_key = self._project_key_for(envelope)
        payload = envelope.payload
        session_id = str(envelope.session_id or payload.get("session_id") or f"project:{project_key}")
        message_id = payload.get("message_id")
        requested_mode = str(payload.get("mode") or "summary").strip().lower() or "summary"
        selected_mode = requested_mode
        selection_reason = f"requested_{requested_mode}"
        text = None
        if message_id:
            message = self.store.get_message(session_id, str(message_id))
            if message is None:
                return error_frame(
                    "message_not_found",
                    f"no Logos message found for {session_id}/{message_id}",
                    request_id=envelope.request_id,
                    device_id=envelope.device_id,
                    project_key=project_key,
                )
            if message.project_key != project_key:
                return error_frame(
                    "message_project_mismatch",
                    "playback_audio message does not belong to the requested project",
                    request_id=envelope.request_id,
                    device_id=envelope.device_id,
                    project_key=project_key,
                )
            if requested_mode == "final_auto":
                if self._is_short_final_audio_text(message.content):
                    selected_mode = "full"
                    selection_reason = "short_final_full"
                    text = message.content
                else:
                    summary, summary_status = self._summary_for_message(message)
                    selected_mode = "summary"
                    selection_reason = f"long_final_summary_{summary_status}"
                    text = summary.summary_text
            elif requested_mode == "summary":
                summary, summary_status = self._summary_for_message(message)
                selected_mode = "summary"
                selection_reason = f"requested_summary_{summary_status}"
                text = summary.summary_text
            else:
                selected_mode = requested_mode
                selection_reason = "requested_full" if requested_mode == "full" else f"requested_{requested_mode}"
                text = message.content
        else:
            text = payload.get("text") or payload.get("summary_text")
            if requested_mode == "final_auto":
                selected_mode = "full"
                selection_reason = "payload_text_full"
        if not isinstance(text, str) or not text.strip():
            return error_frame(
                "missing_audio_source",
                "playback_audio requires payload.text or payload.message_id",
                request_id=envelope.request_id,
                device_id=envelope.device_id,
                project_key=project_key,
            )
        audio_id = str(payload.get("audio_id") or f"audio-{uuid.uuid4()}")
        return await self._stream_tts_audio(
            text=text,
            audio_id=audio_id,
            project_key=project_key,
            session_id=session_id,
            request_id=envelope.request_id,
            device_id=envelope.device_id,
            message_id=str(message_id) if message_id else None,
            mode=selected_mode,
            requested_mode=requested_mode,
            selection_reason=selection_reason,
            source=getattr(self.tts, "source_name", "tts"),
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
        requested_mode: str | None = None,
        selection_reason: str | None = None,
    ) -> dict[str, Any] | None:
        requested_mode = requested_mode or mode
        selection_reason = selection_reason or f"requested_{requested_mode}"
        try:
            chunks = self.tts.iter_chunks(text=text, audio_id=audio_id)
        except Exception as exc:
            error_type = exc.__class__.__name__
            logger.warning(
                "Logos TTS failed for audio_id=%s provider=%s error_type=%s",
                audio_id,
                source,
                error_type,
            )
            return error_frame(
                "tts_failed",
                f"TTS failed for provider {source} ({error_type})",
                request_id=request_id,
                device_id=device_id,
                project_key=project_key,
            )
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
                    "requested_mode": requested_mode,
                    "selection_reason": selection_reason,
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
                "requested_mode": requested_mode,
                "selection_reason": selection_reason,
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
            messages = [message for message in messages if message.project_key == project_key]
        else:
            after_server_seq = int(payload.get("after_server_seq", payload.get("last_seen_server_seq", 0)) or 0)
            messages = self.store.messages_after_server_seq(project_key, after_server_seq, limit=limit + 1)
        has_more = len(messages) > limit
        messages = messages[:limit]
        pending_interactions = [item.to_protocol() for item in self.store.list_pending_interactions(project_key)]
        run_state = self.store.latest_run_state(project_key)
        return {
            "type": "messages_batch",
            "request_id": envelope.request_id,
            "device_id": envelope.device_id,
            "project_key": project_key,
            "session_id": envelope.session_id or payload.get("session_id"),
            "payload": {
                "messages": [message.to_protocol() for message in messages],
                "pending_interactions": pending_interactions,
                "run_status": run_state.to_protocol() if run_state is not None else None,
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

    def _project_key_for_hello(self, envelope: Envelope) -> str:
        raw = envelope.project_key or "default"
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


def _platform_config_for_command() -> PlatformConfig:
    try:
        from gateway.config import load_gateway_config

        gateway_config = load_gateway_config()
        return gateway_config.platforms.get(_platform()) or PlatformConfig(enabled=True, extra={})
    except Exception:
        logger.debug("Logos: falling back to env-only platform config for pairing command", exc_info=True)
        return PlatformConfig(enabled=True, extra={})


def _handle_pair_command(raw_args: str) -> str:
    adapter = LogosAdapter(_platform_config_for_command())
    return adapter.build_pairing_command_response(raw_args or "")


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
        cron_deliver_env_var=LOGOS_HOME_CHANNEL_ENV,
        pii_safe=True,
        emoji="📱",
    )
    ctx.register_command(
        name="logos-pair",
        handler=_handle_pair_command,
        description="Generate a short-lived Logos iPhone pairing QR code.",
        args_hint="device_id=<id> ttl=120 adapter_url=wss://<host>/",
    )
