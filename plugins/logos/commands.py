from __future__ import annotations

import hashlib
import importlib
from collections.abc import Mapping
from datetime import UTC, datetime
from typing import Any

SCHEMA_VERSION = 1
MAX_COMMANDS = 240
MAX_COMPLETIONS = 30
MAX_TEXT_LENGTH = 500
MAX_FIELD_LENGTH = 160
MAX_ARGS_HINT_LENGTH = 80
MAX_SUBCOMMANDS = 40
PICKER_COMMANDS = {"model", "personality", "skin"}


class CommandCompletionError(ValueError):
    """Raised when a slash completion request is invalid."""


FALLBACK_COMMANDS: tuple[dict[str, Any], ...] = (
    {
        "name": "resume",
        "description": "Resume a previously-named session",
        "category": "Session",
        "args_hint": "[name]",
    },
    {
        "name": "title",
        "description": "Set a title for the current session",
        "category": "Session",
        "args_hint": "[name]",
    },
    {
        "name": "queue",
        "description": "Queue a prompt for the next turn",
        "category": "Session",
        "aliases": ("q",),
        "args_hint": "<prompt>",
    },
    {
        "name": "steer",
        "description": "Inject a message after the next tool call",
        "category": "Session",
        "args_hint": "<prompt>",
    },
    {"name": "stop", "description": "Stop the active run", "category": "Session"},
    {
        "name": "approve",
        "description": "Approve a pending command",
        "category": "Session",
        "args_hint": "[session|always]",
    },
    {"name": "deny", "description": "Deny a pending command", "category": "Session"},
    {"name": "status", "description": "Show session info", "category": "Session"},
    {
        "name": "kanban",
        "description": "Show or update the session kanban board",
        "category": "Session",
        "args_hint": "[status]",
    },
    {"name": "help", "description": "Show gateway help", "category": "Info"},
    {"name": "commands", "description": "List available slash commands", "category": "Info"},
    {
        "name": "goal",
        "description": "Set or inspect a standing goal",
        "category": "Session",
        "args_hint": "[text | pause | resume | clear | status]",
    },
    {
        "name": "subgoal",
        "description": "Add or manage criteria on the active goal",
        "category": "Session",
        "args_hint": "[text | remove N | clear]",
    },
    {
        "name": "model",
        "description": "Show or switch the active model",
        "category": "Configuration",
        "args_hint": "[model]",
    },
    {
        "name": "reasoning",
        "description": "Show or switch reasoning effort",
        "category": "Configuration",
        "args_hint": "[effort]",
    },
    {
        "name": "fast",
        "description": "Show or switch fast-model mode",
        "category": "Configuration",
        "args_hint": "[on|off|model]",
    },
    {
        "name": "voice",
        "description": "Show or switch voice settings",
        "category": "Configuration",
        "args_hint": "[setting]",
    },
    {
        "name": "agents",
        "description": "Show active agents and running tasks",
        "category": "Session",
        "aliases": ("tasks",),
    },
    {
        "name": "background",
        "description": "Run a prompt in the background",
        "category": "Session",
        "aliases": ("bg", "btw"),
        "args_hint": "<prompt>",
    },
    {
        "name": "new",
        "description": "Start a new session",
        "category": "Session",
        "aliases": ("reset",),
        "args_hint": "[name]",
    },
    {"name": "retry", "description": "Retry the last message", "category": "Session"},
    {
        "name": "undo",
        "description": "Remove the last user/assistant exchange",
        "category": "Session",
    },
    {
        "name": "compress",
        "description": "Manually compress conversation context",
        "category": "Session",
        "args_hint": "[focus topic]",
    },
)

LOGOS_COMMANDS: tuple[dict[str, Any], ...] = (
    {
        "name": "logos-pair",
        "description": "Create a Logos device pairing invite",
        "category": "Logos",
        "args_hint": "[device name]",
    },
)


def build_command_catalog(
    *,
    include_unavailable: bool = True,
    hermes_commands: Any | None = None,
    config_extra: Mapping[str, Any] | None = None,
) -> dict[str, Any]:
    warnings: list[str] = []
    commands_module = hermes_commands
    fallback_used = False
    if commands_module is None:
        try:
            commands_module = _load_hermes_commands()
        except Exception:
            commands_module = None
            fallback_used = True
            warnings.append("Hermes command registry unavailable; using Logos fallback catalog.")

    specs: list[dict[str, Any]] = []
    if commands_module is not None:
        try:
            specs.extend(
                _builtin_specs_from_hermes(commands_module, include_unavailable=include_unavailable)
            )
        except Exception:
            fallback_used = True
            warnings.append(
                "Hermes command registry could not be read; using Logos fallback catalog."
            )
            specs = []

    if not specs:
        specs.extend(_fallback_specs())

    specs.extend(_plugin_specs_from_hermes(commands_module))
    specs.extend(_quick_alias_specs(config_extra or {}))
    specs.extend(_logos_specs())
    specs = _dedupe_specs(specs)
    if include_unavailable is False:
        specs = [spec for spec in specs if spec.get("available", True)]
    specs = specs[:MAX_COMMANDS]

    version = _catalog_version(specs, fallback_used=fallback_used)
    return {
        "schema_version": SCHEMA_VERSION,
        "catalog_version": version,
        "generated_at": datetime.now(UTC).isoformat(),
        "fallback_used": fallback_used,
        "commands": specs,
        "warnings": warnings,
    }


def complete_slash_command(text: str, *, catalog: Mapping[str, Any]) -> dict[str, Any]:
    _validate_completion_text(text)
    commands = [item for item in catalog.get("commands", []) if isinstance(item, Mapping)]
    if " " in text:
        items = _subcommand_completions(text, commands)
    else:
        items = _command_completions(text, commands)
    return {
        "catalog_version": str(catalog.get("catalog_version") or "fallback"),
        "items": items[:MAX_COMPLETIONS],
        "fallback_used": bool(catalog.get("fallback_used", False)),
        "warnings": list(catalog.get("warnings", []))[:5],
    }


def _load_hermes_commands() -> Any:
    return importlib.import_module("hermes_cli.commands")


def _builtin_specs_from_hermes(
    commands_module: Any, *, include_unavailable: bool
) -> list[dict[str, Any]]:
    registry = getattr(commands_module, "COMMAND_REGISTRY", []) or []
    resolve_gates = getattr(commands_module, "_resolve_config_gates", None)
    gateway_available = getattr(commands_module, "_is_gateway_available", None)
    overrides: set[str] = set()
    if callable(resolve_gates):
        try:
            overrides = set(resolve_gates() or set())
        except Exception:
            overrides = set()

    specs: list[dict[str, Any]] = []
    for command in registry:
        name = _clean_name(getattr(command, "name", ""))
        if not name:
            continue
        available = True
        if callable(gateway_available):
            try:
                available = bool(gateway_available(command, overrides))
            except Exception:
                available = not bool(getattr(command, "cli_only", False))
        else:
            available = not bool(getattr(command, "cli_only", False))
        unavailable_reason = ""
        if name == "sessions":
            available = False
            unavailable_reason = "/sessions is registered by Hermes but is not available through the Logos gateway in this build."
        elif not available:
            continue
        if not available and not include_unavailable:
            continue
        if not available and not unavailable_reason:
            unavailable_reason = (
                "This command is not available through the Logos gateway in this runtime."
            )
        specs.append(
            _spec(
                name=name,
                description=getattr(command, "description", ""),
                category=getattr(command, "category", ""),
                aliases=getattr(command, "aliases", ()) or (),
                args_hint=getattr(command, "args_hint", "") or "",
                subcommands=getattr(command, "subcommands", ()) or (),
                source="builtin",
                available=available,
                unavailable_reason=unavailable_reason,
            )
        )
    return specs


def _plugin_specs_from_hermes(commands_module: Any | None) -> list[dict[str, Any]]:
    if commands_module is None:
        return []
    iterator = getattr(commands_module, "_iter_plugin_command_entries", None)
    if not callable(iterator):
        return []
    specs: list[dict[str, Any]] = []
    try:
        entries = iterator() or []
    except Exception:
        return []
    for entry in entries:
        if not isinstance(entry, tuple) or len(entry) < 2:
            continue
        name = _clean_name(entry[0])
        if not name:
            continue
        args_hint = entry[2] if len(entry) > 2 else ""
        specs.append(
            _spec(
                name=name,
                description=entry[1],
                category="Plugin",
                args_hint=args_hint,
                source="plugin",
            )
        )
    return specs


def _fallback_specs() -> list[dict[str, Any]]:
    return [
        _spec(
            name=str(command["name"]),
            description=command.get("description", ""),
            category=command.get("category", ""),
            aliases=command.get("aliases", ()),
            args_hint=command.get("args_hint", ""),
            source="fallback",
        )
        for command in FALLBACK_COMMANDS
    ]


def _logos_specs() -> list[dict[str, Any]]:
    return [
        _spec(
            name=str(command["name"]),
            description=command.get("description", ""),
            category=command.get("category", ""),
            args_hint=command.get("args_hint", ""),
            source="logos",
        )
        for command in LOGOS_COMMANDS
    ]


def _quick_alias_specs(config_extra: Mapping[str, Any]) -> list[dict[str, Any]]:
    quick_commands = config_extra.get("quick_commands")
    if not isinstance(quick_commands, Mapping):
        return []
    specs: list[dict[str, Any]] = []
    for raw_name, raw_config in quick_commands.items():
        if not isinstance(raw_config, Mapping) or raw_config.get("type") != "alias":
            continue
        name = _clean_name(raw_name)
        target = str(raw_config.get("target") or "").strip()
        if not name or not target:
            continue
        target_display = target if target.startswith("/") else f"/{target}"
        specs.append(
            _spec(
                name=name,
                description=f"Alias for {target_display}",
                category="Quick Commands",
                source="quick_alias",
                args_hint="[args]",
            )
        )
    return specs


def _spec(
    *,
    name: str,
    description: Any,
    category: Any,
    aliases: Any = (),
    args_hint: Any = "",
    subcommands: Any = (),
    source: str,
    available: bool = True,
    unavailable_reason: str = "",
) -> dict[str, Any]:
    clean_name = _clean_name(name)
    clean_aliases = [_slash(_clean_name(alias)) for alias in aliases if _clean_name(alias)]
    clean_args = _clean_text(str(args_hint or ""), MAX_ARGS_HINT_LENGTH)
    clean_subcommands = [
        _clean_text(str(subcommand), MAX_FIELD_LENGTH)
        for subcommand in list(subcommands or [])[:MAX_SUBCOMMANDS]
        if str(subcommand).strip()
    ]
    requires_args = clean_args.startswith("<")
    adds_trailing_space = bool(clean_args) and clean_name not in PICKER_COMMANDS
    return {
        "id": f"{source}:{clean_name}",
        "trigger": _slash(clean_name),
        "canonical": _slash(clean_name),
        "aliases": clean_aliases,
        "description": _clean_text(str(description or f"Run /{clean_name}"), MAX_FIELD_LENGTH),
        "category": _clean_text(str(category or "Commands"), MAX_FIELD_LENGTH),
        "args_hint": clean_args,
        "subcommands": clean_subcommands,
        "source": source,
        "available": bool(available),
        "unavailable_reason": _clean_text(str(unavailable_reason or ""), MAX_FIELD_LENGTH),
        "requires_args": requires_args,
        "adds_trailing_space": adds_trailing_space,
        "deprecated": False,
    }


def _command_completions(text: str, commands: list[Mapping[str, Any]]) -> list[dict[str, Any]]:
    token = text[1:].lower()
    ranked: list[tuple[int, str, dict[str, Any]]] = []
    for command in commands:
        trigger = str(command.get("trigger") or "")
        if not trigger:
            continue
        names = [
            trigger,
            *[str(alias) for alias in command.get("aliases", []) if isinstance(alias, str)],
        ]
        best_score: int | None = None
        for name in names:
            raw = name.lstrip("/").lower()
            if raw == token:
                best_score = 0
                break
            if raw.startswith(token):
                best_score = 1 if best_score is None else min(best_score, 1)
            elif token and _fuzzy_match(token, raw):
                best_score = 2 if best_score is None else min(best_score, 2)
        if best_score is None:
            continue
        if command.get("available", True) is False:
            best_score += 10
        ranked.append((best_score, trigger, _completion_item(command, 0, len(text))))
    ranked.sort(key=lambda item: (item[0], item[1]))
    return [item for _, _, item in ranked]


def _subcommand_completions(text: str, commands: list[Mapping[str, Any]]) -> list[dict[str, Any]]:
    base, partial = text.split(" ", 1)
    base_lower = base.lower()
    command = next(
        (
            item
            for item in commands
            if str(item.get("trigger") or "").lower() == base_lower
            or base_lower
            in [str(alias).lower() for alias in item.get("aliases", []) if isinstance(alias, str)]
        ),
        None,
    )
    if command is None:
        return []
    if " " in partial:
        return []
    partial_lower = partial.lower()
    start = len(base) + 1
    items: list[dict[str, Any]] = []
    for subcommand in command.get("subcommands", [])[:MAX_SUBCOMMANDS]:
        sub_text = str(subcommand)
        if not sub_text.lower().startswith(partial_lower) or sub_text.lower() == partial_lower:
            continue
        replacement = f"{command.get('canonical') or command.get('trigger')} {sub_text}"
        items.append(
            {
                "canonical": str(command.get("canonical") or command.get("trigger")),
                "replacement_text": replacement,
                "replacement_start": start,
                "replacement_end": len(text),
                "display": sub_text,
                "detail": str(command.get("description") or ""),
                "kind": "subcommand",
                "adds_trailing_space": False,
            }
        )
    return items


def _completion_item(
    command: Mapping[str, Any], replacement_start: int, replacement_end: int
) -> dict[str, Any]:
    canonical = str(command.get("canonical") or command.get("trigger") or "")
    replacement = canonical + (" " if command.get("adds_trailing_space", False) else "")
    detail = str(command.get("args_hint") or command.get("description") or "")
    if command.get("available", True) is False and command.get("unavailable_reason"):
        detail = str(command["unavailable_reason"])
    return {
        "canonical": canonical,
        "replacement_text": replacement,
        "replacement_start": replacement_start,
        "replacement_end": replacement_end,
        "display": canonical,
        "detail": _clean_text(detail, MAX_FIELD_LENGTH),
        "kind": "command",
        "adds_trailing_space": bool(command.get("adds_trailing_space", False)),
    }


def _validate_completion_text(text: str) -> None:
    if not isinstance(text, str) or not text or not text.startswith("/"):
        raise CommandCompletionError("completion text must begin with /")
    if len(text) > MAX_TEXT_LENGTH:
        raise CommandCompletionError("completion text is too long")
    if any(ord(char) < 32 for char in text):
        raise CommandCompletionError("completion text contains control characters")


def _dedupe_specs(specs: list[dict[str, Any]]) -> list[dict[str, Any]]:
    result: list[dict[str, Any]] = []
    seen: set[str] = set()
    for spec in specs:
        trigger = str(spec.get("trigger") or "")
        if not trigger or trigger in seen:
            continue
        seen.add(trigger)
        result.append(spec)
    return result


def _catalog_version(specs: list[dict[str, Any]], *, fallback_used: bool) -> str:
    digest = hashlib.sha256()
    digest.update(str(fallback_used).encode("utf-8"))
    for spec in specs:
        digest.update(str(spec.get("trigger", "")).encode("utf-8"))
        digest.update(str(spec.get("available", "")).encode("utf-8"))
        digest.update(str(spec.get("aliases", "")).encode("utf-8"))
        digest.update(str(spec.get("args_hint", "")).encode("utf-8"))
    return digest.hexdigest()[:16]


def _clean_name(value: Any) -> str:
    text = str(value or "").strip().lstrip("/")
    if not text:
        return ""
    allowed = []
    for char in text:
        if char.isalnum() or char in {"-", "_"}:
            allowed.append(char)
    return "".join(allowed)[:60]


def _slash(value: str) -> str:
    return f"/{value.lstrip('/')}"


def _clean_text(value: str, limit: int) -> str:
    text = " ".join(str(value or "").replace("\n", " ").replace("\r", " ").split())
    return text[:limit]


def _fuzzy_match(needle: str, haystack: str) -> bool:
    index = 0
    for char in haystack:
        if index < len(needle) and char == needle[index]:
            index += 1
    return index == len(needle)
