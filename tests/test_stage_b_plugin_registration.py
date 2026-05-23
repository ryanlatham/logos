from __future__ import annotations

import os
from pathlib import Path
from typing import Any

import pytest
from gateway.config import PlatformConfig

from logos import register
from logos.adapter import LogosAdapter


class RecordingContext:
    def __init__(self) -> None:
        self.calls: list[dict[str, Any]] = []
        self.commands: list[dict[str, Any]] = []

    def register_platform(self, **kwargs: Any) -> None:
        self.calls.append(kwargs)

    def register_command(self, **kwargs: Any) -> None:
        self.commands.append(kwargs)


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
    assert call["cron_deliver_env_var"] == "LOGOS_HOME_CHANNEL"
    assert callable(call["adapter_factory"])
    assert callable(call["check_fn"])
    assert call["check_fn"]() is True
    assert len(ctx.commands) == 1
    command = ctx.commands[0]
    assert command["name"] == "logos-pair"
    assert "adapter_url=wss://<host>/" in command["args_hint"]
    assert callable(command["handler"])

@pytest.mark.asyncio
async def test_logos_connect_seeds_default_home_channel_env(tmp_path, monkeypatch):
    monkeypatch.delenv("LOGOS_HOME_CHANNEL", raising=False)
    monkeypatch.delenv("LOGOS_HOME_CHANNEL_NAME", raising=False)
    adapter = LogosAdapter(
        PlatformConfig(
            enabled=True,
            extra={
                "device_secret": "master-secret",
                "host": "127.0.0.1",
                "port": 0,
                "store_path": str(tmp_path / "logos.db"),
            },
        )
    )

    try:
        assert await adapter.connect() is True
        assert os.environ["LOGOS_HOME_CHANNEL"] == "project:default"
        assert os.environ["LOGOS_HOME_CHANNEL_NAME"] == "Logos"
    finally:
        await adapter.disconnect()


def test_registered_logos_pair_command_handler_generates_qr_media(tmp_path, monkeypatch):
    monkeypatch.setenv("HERMES_HOME", str(tmp_path / "hermes-home"))
    monkeypatch.setenv("LOGOS_DEVICE_SECRET", "master-secret")
    monkeypatch.setenv("LOGOS_STORE_PATH", str(tmp_path / "logos.db"))
    monkeypatch.setenv("LOGOS_PUBLIC_URL", "wss://studio.tail752253.ts.net/")

    ctx = RecordingContext()
    register(ctx)
    handler = ctx.commands[0]["handler"]

    response = handler("device_id=iphone-17-pro ttl=120")

    assert "Scan this with your iPhone to pair Logos." in response
    assert "iphone-17-pro" in response
    assert "pair_token" not in response
    assert "master-secret" not in response
    media_path = Path(response.split("MEDIA:", 1)[1].split()[0])
    assert media_path.exists()
    assert media_path.read_bytes().startswith(b"\x89PNG")
