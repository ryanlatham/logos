"""WS2 guardrail: the decomposition must preserve LogosAdapter's name surface.

adapter.py was split into mixins (run_state / dispatch / message_state / interactions /
fast_routing / audio) + leaf modules. The Python test contract requires every name the tests
and Hermes touch to remain reachable on LogosAdapter via the MRO with an unchanged signature.
If a future extraction drops or renames a delegator, this fails loudly here rather than in a
distant integration test. Hermes-dependent (imports LogosAdapter) -> in conftest's skip set.
"""

from __future__ import annotations

import inspect

from gateway.platforms.base import BasePlatformAdapter
from logos.adapter import LogosAdapter
from logos.audio import AudioMixin
from logos.dispatch import DispatchMixin
from logos.fast_routing import FastRoutingMixin
from logos.interactions import InteractionsMixin
from logos.message_state import MessageStateMixin
from logos.run_state import RunStateMixin

# Names that must remain callable attributes of LogosAdapter, grouped by the module that now
# owns them. Keep in sync as modules are extracted — a missing entry is a contract break.
_CONTRACT = {
    "run_state": [
        "send_typing",
        "_clear_request_bookkeeping",
        "_state_update",
        "_run_status_frame",
        "_broadcast_run_status",
        "_handle_run_cancel",
        "on_processing_start",
        "on_processing_complete",
    ],
    "dispatch": [
        "handle_ws_envelope",
        "_handle_commands_get",
        "_handle_commands_complete",
        "_handle_register_device",
        "_handle_final_text",
    ],
    "message_state": [
        "send",
        "edit_message",
        "_broadcast_progress_text",
        "_is_progress_message",
        "_append_final_message_for_transient_edit",
        "_message_state_update",
        "_summary_ready_update",
    ],
    "interactions": [
        "_handle_approval_response",
        "_handle_clarify_response",
        "send_clarify",
        "send_exec_approval",
    ],
    "fast_routing": [
        "_handle_fast_direct_response",
        "_emit_fast_ack",
        "_route_fast_intent",
        "_mirror_control_intent_message",
    ],
    "audio": [
        "_handle_playback_audio",
        "_stream_tts_audio",
    ],
    "facade_core": [
        "connect",
        "disconnect",
        "handle_message",
        "_process_message_background",
        "get_chat_info",
        "reconnect_messages_batch",
        "_handle_messages_get",
        "_handle_list_projects",
        "_handle_new_project",
        "_handle_switch_project",
        "_handle_rename_project",
        "create_pairing_invite",
        "handle_pairing_envelope",
        "_send_private_notification",
        "_dispatch_gateway_text",
        "_project_key_for",
        "_client_session_id_for",
        "is_device_allowed",
        "auth_secrets_for_device",
    ],
}

ALL_NAMES = [name for names in _CONTRACT.values() for name in names]


def test_logos_adapter_subclasses_base_and_mixins():
    mro = LogosAdapter.__mro__
    for mixin in (
        RunStateMixin,
        DispatchMixin,
        MessageStateMixin,
        InteractionsMixin,
        FastRoutingMixin,
        AudioMixin,
        BasePlatformAdapter,
    ):
        assert mixin in mro, f"{mixin.__name__} must remain a LogosAdapter base"


def test_every_contracted_name_is_callable_on_adapter():
    missing = [name for name in ALL_NAMES if not callable(getattr(LogosAdapter, name, None))]
    assert not missing, f"LogosAdapter lost delegated names: {missing}"


def test_contract_has_no_duplicate_names():
    assert len(ALL_NAMES) == len(set(ALL_NAMES))


def test_lifecycle_hooks_are_coroutines():
    # Hermes awaits these — a sync override would break the run-recovery reconciliation.
    for name in ("on_processing_start", "on_processing_complete", "send", "edit_message", "handle_ws_envelope"):
        assert inspect.iscoroutinefunction(getattr(LogosAdapter, name)), f"{name} must stay async"


def test_validate_config_importable():
    # Tests import only LogosAdapter + _validate_config; the latter must remain at module scope.
    from logos.adapter import _validate_config  # noqa: F401

    assert callable(_validate_config)
