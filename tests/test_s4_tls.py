"""WS3 S4: the adapter distributes the direct-WSS SPKI pin in pairing invites under
LOGOS_TLS_MODE=self_signed, and stays plain (no pin) otherwise. Hermes-dependent (LogosAdapter)
— listed in conftest's Tier-1 skip set.
"""

from __future__ import annotations

import pytest

from gateway.config import PlatformConfig
from logos.adapter import LogosAdapter
from logos.pairing import decode_pairing_deep_link


def _adapter(tmp_path, name="tls.db") -> LogosAdapter:
    return LogosAdapter(
        PlatformConfig(enabled=True, extra={"device_secret": "dev-secret", "store_path": str(tmp_path / name)})
    )


def test_invite_embeds_cert_pin_when_self_signed(tmp_path, monkeypatch):
    monkeypatch.setenv("LOGOS_TLS_MODE", "self_signed")
    monkeypatch.setenv("HERMES_HOME", str(tmp_path / "home"))
    adapter = _adapter(tmp_path)

    invite = adapter.create_pairing_invite(adapter_url="wss://logos.example:8765/logos", now=1000.0)
    decoded = decode_pairing_deep_link(invite.pairing_url)

    pin = decoded["cert_spki_sha256"]
    assert pin, "self_signed mode must distribute a cert pin"
    # The distributed pin must match the adapter's loaded TLS material.
    assert pin == adapter._ensure_tls_material().spki_sha256
    assert len(pin) == 44  # base64 SHA-256


def test_invite_has_no_pin_when_tls_off(tmp_path, monkeypatch):
    monkeypatch.delenv("LOGOS_TLS_MODE", raising=False)
    monkeypatch.setenv("HERMES_HOME", str(tmp_path / "home"))
    adapter = _adapter(tmp_path)

    invite = adapter.create_pairing_invite(adapter_url="wss://logos.example:8765/logos", now=1000.0)
    assert decode_pairing_deep_link(invite.pairing_url)["cert_spki_sha256"] is None
    assert adapter._ensure_tls_material() is None


def test_tls_material_is_stable_across_calls(tmp_path, monkeypatch):
    monkeypatch.setenv("LOGOS_TLS_MODE", "self_signed")
    monkeypatch.setenv("HERMES_HOME", str(tmp_path / "home"))
    adapter = _adapter(tmp_path)
    first = adapter._ensure_tls_material()
    second = adapter._ensure_tls_material()
    assert first is second  # cached; the pairing pin stays stable for the adapter's lifetime
