from __future__ import annotations

import ipaddress
import os
from collections.abc import Iterable
from typing import TYPE_CHECKING, Any
from urllib.parse import urlparse

if TYPE_CHECKING:
    from gateway.config import PlatformConfig

# Configuration constants and parsing helpers for the Logos adapter (extracted from adapter.py).
# The `PlatformConfig` type hints below are evaluated lazily (PEP 563), so this stays a
# Hermes-free leaf module that adapter.py re-exports.

DEFAULT_HOST = "127.0.0.1"
DEFAULT_PORT = 8765
DEFAULT_FINAL_AUDIO_FULL_MAX_CHARS = 600
DEFAULT_FINAL_AUDIO_FULL_MAX_WORDS = 100
DEFAULT_LOGOS_STALE_TIMEOUT_SECONDS = 15 * 60
MAX_LOGOS_STALE_TIMEOUT_SECONDS = 24 * 60 * 60
DEFAULT_LOGOS_KEEPALIVE_THROTTLE_SECONDS = 10.0
LOGOS_TIMEOUT_SECONDS_ENV = "LOGOS_TIMEOUT_SECONDS"
LOGOS_HOME_CHANNEL_ENV = "LOGOS_HOME_CHANNEL"
LOGOS_HOME_CHANNEL_NAME_ENV = "LOGOS_HOME_CHANNEL_NAME"
DEFAULT_LOGOS_HOME_CHANNEL = "project:default"
DEFAULT_LOGOS_HOME_CHANNEL_NAME = "Logos"


def _truthy(value: Any) -> bool:
    if isinstance(value, bool):
        return value
    if isinstance(value, (int, float)):
        return bool(value)
    text = str(value or "").strip().lower()
    return text in {"1", "true", "yes", "on"}


def _safe_filename_component(value: Any) -> str:
    cleaned = "".join(
        ch if ch.isalnum() or ch in {"-", "_", "."} else "-" for ch in str(value or "").strip()
    )
    return cleaned.strip(".-_") or "device"


def _is_loopback_adapter_url(value: str) -> bool:
    try:
        parsed = urlparse(str(value or ""))
    except Exception:
        return False
    host = (parsed.hostname or "").strip().lower()
    if host in {"localhost", "ip6-localhost"}:
        return True
    try:
        return ipaddress.ip_address(host).is_loopback
    except ValueError:
        return False


def _is_plaintext_non_loopback_adapter_url(value: str) -> bool:
    try:
        parsed = urlparse(str(value or ""))
    except Exception:
        return False
    return parsed.scheme == "ws" and not _is_loopback_adapter_url(value)


def _string_set(value: Any) -> set[str]:
    if value is None:
        return set()
    raw_items: Iterable[Any]
    if isinstance(value, str):
        raw_items = value.split(",")
    elif isinstance(value, (list, tuple, set)):
        raw_items = value
    else:
        raw_items = [value]
    return {str(item).strip() for item in raw_items if str(item).strip()}


def _optional_nonempty_str(value: Any) -> str | None:
    if value is None:
        return None
    text = str(value).strip()
    return text or None


def _nonnegative_int(value: Any, default: int) -> int:
    try:
        parsed = int(value)
    except (TypeError, ValueError):
        return int(default)
    if parsed < 0:
        return int(default)
    return parsed


def _positive_int_or_none(value: Any) -> int | None:
    try:
        parsed = int(value)
    except (TypeError, ValueError):
        return None
    if parsed <= 0:
        return None
    return parsed


def _configured_positive_int(*values: Any, default: int, max_value: int | None = None) -> int:
    for value in values:
        parsed = _positive_int_or_none(value)
        if parsed is not None:
            return min(parsed, int(max_value)) if max_value is not None else parsed
    fallback = int(default)
    return min(fallback, int(max_value)) if max_value is not None else fallback


def _validate_config(config: PlatformConfig) -> bool:
    extra = getattr(config, "extra", {}) or {}
    return bool(
        os.getenv("LOGOS_DEVICE_SECRET") or _optional_nonempty_str(extra.get("device_secret"))
    )


def _project_chat_id(project_key: Any) -> str | None:
    text = _optional_nonempty_str(project_key)
    if not text:
        return None
    return text if text.startswith("project:") else f"project:{text}"


def _configured_home_channel(config: PlatformConfig, extra: dict[str, Any]) -> tuple[str, str]:
    """Resolve Logos' process-local home channel.

    Hermes emits a first-message onboarding notice for any platform with no
    home target env var. Logos' chats are per-project, so leaving this unset
    causes that generic notice to repeat in every new project. A stable default
    project gives Logos the same one-home-channel shape as Telegram/Discord
    without requiring Hermes core special-casing.
    """
    explicit_env = _optional_nonempty_str(os.getenv(LOGOS_HOME_CHANNEL_ENV))
    explicit_name = _optional_nonempty_str(os.getenv(LOGOS_HOME_CHANNEL_NAME_ENV))
    if explicit_env:
        return explicit_env, explicit_name or DEFAULT_LOGOS_HOME_CHANNEL_NAME

    home = getattr(config, "home_channel", None)
    home_chat_id = (
        _optional_nonempty_str(getattr(home, "chat_id", None)) if home is not None else None
    )
    home_name = _optional_nonempty_str(getattr(home, "name", None)) if home is not None else None
    if home_chat_id:
        return home_chat_id, home_name or DEFAULT_LOGOS_HOME_CHANNEL_NAME

    configured = extra.get("home_channel")
    if isinstance(configured, dict):
        chat_id = _optional_nonempty_str(configured.get("chat_id")) or _project_chat_id(
            configured.get("project_key")
        )
        name = _optional_nonempty_str(configured.get("name"))
        if chat_id:
            return chat_id, name or DEFAULT_LOGOS_HOME_CHANNEL_NAME
    else:
        chat_id = _optional_nonempty_str(configured)
        if chat_id:
            return chat_id, _optional_nonempty_str(
                extra.get("home_channel_name")
            ) or DEFAULT_LOGOS_HOME_CHANNEL_NAME

    chat_id = _optional_nonempty_str(extra.get("home_chat_id")) or _project_chat_id(
        extra.get("home_project_key")
    )
    if chat_id:
        return chat_id, _optional_nonempty_str(
            extra.get("home_channel_name")
        ) or DEFAULT_LOGOS_HOME_CHANNEL_NAME

    return DEFAULT_LOGOS_HOME_CHANNEL, DEFAULT_LOGOS_HOME_CHANNEL_NAME


def _ensure_home_channel_env(config: PlatformConfig, extra: dict[str, Any]) -> None:
    chat_id, name = _configured_home_channel(config, extra)
    os.environ.setdefault(LOGOS_HOME_CHANNEL_ENV, chat_id)
    os.environ.setdefault(LOGOS_HOME_CHANNEL_NAME_ENV, name)
