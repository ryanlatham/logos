from __future__ import annotations

from dataclasses import dataclass
from typing import Any

import pytest

from gateway.config import PlatformConfig
from logos.adapter import LogosAdapter
from logos.schema import CLIENT_FRAME_TYPES, SERVER_FRAME_TYPES, Envelope


@dataclass(frozen=True)
class FakeCommandDef:
    name: str
    description: str
    category: str
    aliases: tuple[str, ...] = ()
    args_hint: str = ""
    subcommands: tuple[str, ...] = ()
    cli_only: bool = False
    gateway_only: bool = False
    gateway_config_gate: str | None = None


class FakeHermesCommands:
    COMMAND_REGISTRY = [
        FakeCommandDef("resume", "Resume a named session", "Session", args_hint="[name]"),
        FakeCommandDef("approve", "Approve a pending command", "Session", gateway_only=True, args_hint="[session|always]"),
        FakeCommandDef("secret", "CLI-only secret command", "Config", cli_only=True),
        FakeCommandDef("sessions", "Browse previous sessions", "Session"),
        FakeCommandDef("queue", "Queue a prompt", "Session", aliases=("q",), args_hint="<prompt>"),
        FakeCommandDef("model", "Select a model", "Configuration", subcommands=("openai/gpt-5", "anthropic/claude")),
    ]

    @staticmethod
    def _resolve_config_gates() -> set[str]:
        return set()

    @staticmethod
    def _is_gateway_available(command: FakeCommandDef, config_overrides: set[str] | None = None) -> bool:
        return not command.cli_only or bool(command.gateway_config_gate and command.name in (config_overrides or set()))


def test_protocol_declares_command_catalog_frames() -> None:
    assert "commands_get" in CLIENT_FRAME_TYPES
    assert "commands_complete" in CLIENT_FRAME_TYPES
    assert "commands_list" in SERVER_FRAME_TYPES
    assert "commands_complete_result" in SERVER_FRAME_TYPES


def test_dynamic_catalog_uses_registry_filters_gateway_and_marks_sessions_unavailable() -> None:
    from logos.commands import build_command_catalog

    catalog = build_command_catalog(
        include_unavailable=True,
        hermes_commands=FakeHermesCommands,
        config_extra={
            "quick_commands": {
                "deploy": {"type": "exec", "command": "deploy.sh"},
                "last": {"type": "alias", "target": "/resume latest"},
            }
        },
    )

    by_trigger = {command["trigger"]: command for command in catalog["commands"]}

    assert by_trigger["/resume"]["source"] == "builtin"
    assert by_trigger["/resume"]["adds_trailing_space"] is True
    assert by_trigger["/approve"]["available"] is True
    assert "/secret" not in by_trigger
    assert "/deploy" not in by_trigger
    assert by_trigger["/last"]["source"] == "quick_alias"
    assert by_trigger["/sessions"]["available"] is False
    assert "not available" in by_trigger["/sessions"]["unavailable_reason"]
    assert by_trigger["/logos-pair"]["source"] == "logos"
    assert catalog["schema_version"] == 1
    assert catalog["catalog_version"]


def test_catalog_can_omit_unavailable_commands() -> None:
    from logos.commands import build_command_catalog

    catalog = build_command_catalog(include_unavailable=False, hermes_commands=FakeHermesCommands)

    triggers = {command["trigger"] for command in catalog["commands"]}
    assert "/sessions" not in triggers


def test_completion_returns_absolute_replacements_and_alias_matches() -> None:
    from logos.commands import build_command_catalog, complete_slash_command

    catalog = build_command_catalog(include_unavailable=True, hermes_commands=FakeHermesCommands)

    resume_result = complete_slash_command("/res", catalog=catalog)
    resume = resume_result["items"][0]
    assert resume["canonical"] == "/resume"
    assert resume["replacement_text"] == "/resume "
    assert resume["replacement_start"] == 0
    assert resume["replacement_end"] == 4
    assert resume["adds_trailing_space"] is True

    alias_result = complete_slash_command("/q", catalog=catalog)
    assert alias_result["items"][0]["canonical"] == "/queue"
    assert alias_result["items"][0]["replacement_text"] == "/queue "

    subcommand_result = complete_slash_command("/model o", catalog=catalog)
    assert subcommand_result["items"][0]["replacement_text"] == "/model openai/gpt-5"
    assert subcommand_result["items"][0]["replacement_start"] == len("/model ")


@pytest.mark.parametrize("text", ["", "hello", "/bad\ncommand"])
def test_completion_rejects_invalid_input(text: str) -> None:
    from logos.commands import CommandCompletionError, complete_slash_command

    with pytest.raises(CommandCompletionError):
        complete_slash_command(text, catalog={"catalog_version": "test", "commands": []})


@pytest.mark.asyncio
async def test_adapter_serves_command_catalog_and_completion_frames(tmp_path, monkeypatch) -> None:
    import logos.commands as command_module

    monkeypatch.setattr(command_module, "_load_hermes_commands", lambda: FakeHermesCommands)

    adapter = LogosAdapter(
        PlatformConfig(
            enabled=True,
            extra={
                "device_secret": "dev-secret",
                "host": "127.0.0.1",
                "port": 0,
                "store_path": str(tmp_path / "logos.db"),
            },
        )
    )

    catalog_frame = await adapter.handle_ws_envelope(
        Envelope(
            type="commands_get",
            request_id="commands-1",
            device_id="iphone",
            project_key="default",
            payload={"include_unavailable": True},
        )
    )
    assert catalog_frame["type"] == "commands_list"
    assert catalog_frame["request_id"] == "commands-1"
    assert any(command["trigger"] == "/resume" for command in catalog_frame["payload"]["commands"])

    complete_frame = await adapter.handle_ws_envelope(
        Envelope(
            type="commands_complete",
            request_id="complete-1",
            device_id="iphone",
            project_key="default",
            payload={"text": "/res", "catalog_version": catalog_frame["payload"]["catalog_version"]},
        )
    )
    assert complete_frame["type"] == "commands_complete_result"
    assert complete_frame["request_id"] == "complete-1"
    assert complete_frame["payload"]["items"][0]["replacement_text"] == "/resume "


@pytest.mark.asyncio
async def test_unknown_slash_text_still_uses_gateway_text_path(tmp_path) -> None:
    class CapturingAdapter(LogosAdapter):
        def __init__(self, config: PlatformConfig):
            super().__init__(config)
            self.captured_events: list[Any] = []

        async def handle_message(self, event):  # type: ignore[override]
            self.captured_events.append(event)

    adapter = CapturingAdapter(
        PlatformConfig(
            enabled=True,
            extra={
                "device_secret": "dev-secret",
                "host": "127.0.0.1",
                "port": 0,
                "store_path": str(tmp_path / "logos.db"),
            },
        )
    )

    await adapter.handle_ws_envelope(
        Envelope(
            type="text_input",
            request_id="req-foo",
            device_id="iphone",
            project_key="default",
            payload={"text": "/foo", "is_final": True, "client_msg_id": "client-foo"},
        )
    )

    assert adapter.captured_events[0].text == "/foo"
