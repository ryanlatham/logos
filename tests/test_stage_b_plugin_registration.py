from __future__ import annotations

from typing import Any

from logos import register


class RecordingContext:
    def __init__(self) -> None:
        self.calls: list[dict[str, Any]] = []

    def register_platform(self, **kwargs: Any) -> None:
        self.calls.append(kwargs)


def test_register_declares_logos_platform_contract():
    ctx = RecordingContext()

    register(ctx)

    assert len(ctx.calls) == 1
    call = ctx.calls[0]
    assert call["name"] == "logos"
    assert call["label"] == "Logos"
    assert call["required_env"] == ["LOGOS_DEVICE_SECRET"]
    assert call["allowed_users_env"] == "LOGOS_ALLOWED_USERS"
    assert call["allow_all_env"] == "LOGOS_ALLOW_ALL_USERS"
    assert callable(call["adapter_factory"])
    assert callable(call["check_fn"])
    assert call["check_fn"]() is True
