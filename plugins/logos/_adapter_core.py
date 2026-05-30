from __future__ import annotations

from typing import TYPE_CHECKING, Any, Protocol

if TYPE_CHECKING:
    from gateway.config import PlatformConfig
    from gateway.platforms.base import MessageEvent, SendResult

    from .apns import APNSClient, PrivateNotificationKind
    from .providers import FastLLMProvider, FastModelResultLike, TTSProvider
    from .schema import Envelope
    from .store import (
        LogosMessage,
        LogosPendingInteraction,
        LogosProject,
        LogosStore,
        LogosSummary,
    )
    from .ws_server import LogosWebSocketServer


class LogosAdapterCore(Protocol):
    """Type-only declaration of the surface shared across the LogosAdapter mixins.

    ``LogosAdapter`` (adapter.py) is composed of six mixins — RunStateMixin,
    MessageStateMixin, FastRoutingMixin, DispatchMixin, InteractionsMixin, AudioMixin —
    that reach for ``self.<x>`` where ``<x>`` is either a data attribute assigned in
    ``LogosAdapter.__init__`` or a method defined on a *sibling* mixin (or on the
    gateway ``BasePlatformAdapter``). mypy type-checks each mixin in isolation, so every
    such access would otherwise be a spurious ``"Mixin" has no attribute "x"``.

    This class declares that shared surface in one place. It is inherited *only* under
    ``TYPE_CHECKING`` (see the ``_MixinBase`` shim in each mixin module); at runtime the
    mixins subclass plain ``object``, so this adds **zero** runtime behavior and leaves
    the real ``LogosAdapter`` MRO byte-identical.
    """

    # --- data attributes (set in LogosAdapter.__init__ / BasePlatformAdapter) ---
    store: LogosStore
    ws_server: LogosWebSocketServer | None
    tts: TTSProvider
    fast_model: FastLLMProvider
    apns: APNSClient
    config: PlatformConfig
    stale_timeout_seconds: int
    _keepalive_throttle_seconds: float
    _last_keepalive_sent_at: dict[tuple[str, str], float]
    _transient_progress_context: dict[tuple[str, str], dict[str, Any]]

    # --- gateway BasePlatformAdapter surface (super() targets / overrides) ---
    async def handle_message(self, event: MessageEvent) -> None: ...
    async def _process_message_background(self, event: MessageEvent, session_key: str) -> None: ...
    async def on_processing_start(self, event: MessageEvent) -> None: ...
    async def on_processing_complete(self, event: MessageEvent, outcome: Any) -> None: ...
    async def send_typing(self, chat_id: str, metadata: dict[str, Any] | None = None) -> None: ...

    # --- adapter-core methods (defined on LogosAdapter in adapter.py) ---
    def _project_key_for(self, envelope: Envelope) -> str: ...
    @staticmethod
    def _project_key_from_chat_id(chat_id: str) -> str: ...
    def _client_session_id_for(self, envelope: Envelope, project_key: str) -> str: ...
    async def _mirror_user_message(
        self,
        envelope: Envelope,
        text: str,
        *,
        project: LogosProject,
        project_key: str,
        session_id: str,
        client_msg_id: str,
    ) -> LogosMessage: ...
    def _summary_for_message(self, message: LogosMessage) -> tuple[LogosSummary, str]: ...
    def _is_short_final_audio_text(self, text: str) -> bool: ...
    async def _dispatch_gateway_text(
        self,
        envelope: Envelope,
        text_override: str | None = None,
        *,
        mirror_user: bool = True,
    ) -> str: ...
    def _request_context_for_event(self, event: MessageEvent) -> dict[str, str] | None: ...
    def _metadata_with_current_request_id(
        self,
        *,
        project_key: str,
        session_id: str,
        metadata: dict[str, Any],
    ) -> dict[str, Any]: ...
    def _looks_like_terminal_error_text(self, content: str) -> bool: ...
    def _human_readable_error_response(self, content: str) -> tuple[str, dict[str, Any]]: ...
    @staticmethod
    def _source_hash(text: str) -> str: ...
    def _progress_kind_for_text(self, content: str) -> str | None: ...
    def _gateway_lifecycle_interruption_reason(self, content: str) -> str | None: ...
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
    ) -> None: ...
    def _latest_pending_interaction(
        self, *, project_key: str, kind: str
    ) -> LogosPendingInteraction | None: ...
    def _find_project_by_title(self, title: str) -> LogosProject | None: ...
    def _project_state_update(
        self, op: str, envelope: Envelope, project: LogosProject
    ) -> dict[str, Any]: ...
    def _approve_gateway_pairing_for_device(
        self, device_id: str | None, display_name: str | None = None
    ) -> bool: ...
    def _handle_messages_get(self, envelope: Envelope) -> dict[str, Any]: ...
    def _handle_list_projects(self, envelope: Envelope) -> dict[str, Any]: ...
    def _handle_new_project(self, envelope: Envelope) -> dict[str, Any]: ...
    def _handle_switch_project(self, envelope: Envelope) -> dict[str, Any]: ...
    def _handle_rename_project(self, envelope: Envelope) -> dict[str, Any]: ...
    def client_config_payload(self) -> dict[str, Any]: ...

    # --- RunStateMixin (run_state.py) ---
    def _state_update(
        self,
        *,
        op: str,
        envelope: Envelope,
        payload: dict[str, Any] | None = None,
    ) -> dict[str, Any]: ...
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
    ) -> dict[str, Any]: ...
    async def _broadcast_run_status(
        self,
        *,
        project_key: str,
        session_id: str | None,
        status: str,
        request_id: str | None = None,
        device_id: str | None = None,
        payload: dict[str, Any] | None = None,
    ) -> dict[str, Any]: ...
    async def _handle_run_cancel(self, envelope: Envelope) -> dict[str, Any]: ...
    def _clear_request_bookkeeping(
        self, *, project_key: str, session_id: str | None, request_id: str | None
    ) -> None: ...

    # --- MessageStateMixin (message_state.py) ---
    async def _broadcast_progress_text(
        self,
        *,
        chat_id: str,
        content: str,
        metadata: dict[str, Any] | None = None,
        request_id: str | None = None,
        kind: str = "tool_progress",
    ) -> SendResult: ...
    def _is_progress_message(self, message: LogosMessage) -> bool: ...
    async def _append_final_message_for_transient_edit(
        self,
        *,
        chat_id: str,
        project_key: str,
        message_id: str,
        content: str,
        progress_message: LogosMessage | None = None,
        final_metadata: dict[str, Any] | None = None,
    ) -> SendResult: ...
    def _message_state_update(self, message: LogosMessage) -> dict[str, Any]: ...
    def _summary_ready_update(
        self, message: LogosMessage, summary: dict[str, Any]
    ) -> dict[str, Any]: ...

    # --- FastRoutingMixin (fast_routing.py) ---
    async def _handle_fast_direct_response(
        self, envelope: Envelope, result: FastModelResultLike
    ) -> bool: ...
    async def _emit_fast_ack(
        self, envelope: Envelope, result: FastModelResultLike
    ) -> dict[str, Any] | None: ...
    async def _route_fast_intent(self, envelope: Envelope, result: FastModelResultLike) -> bool: ...
    async def _mirror_control_intent_message(self, envelope: Envelope) -> None: ...

    # --- DispatchMixin (dispatch.py) ---
    def _handle_commands_get(self, envelope: Envelope) -> dict[str, Any]: ...
    def _handle_commands_complete(self, envelope: Envelope) -> dict[str, Any]: ...
    def _handle_register_device(self, envelope: Envelope) -> dict[str, Any]: ...
    async def _handle_final_text(self, envelope: Envelope) -> None: ...

    # --- InteractionsMixin (interactions.py) ---
    async def _handle_approval_response(self, envelope: Envelope) -> dict[str, Any]: ...
    async def _handle_clarify_response(self, envelope: Envelope) -> dict[str, Any]: ...

    # --- AudioMixin (audio.py) ---
    async def _handle_playback_audio(self, envelope: Envelope) -> dict[str, Any] | None: ...
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
    ) -> dict[str, Any] | None: ...
