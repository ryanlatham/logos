"""WS3 S4: self-signed TLS material + SPKI pin (Hermes-free, Tier-1)."""

from __future__ import annotations

import base64
import os
import ssl
import stat

from logos.tls import (
    TLS_MODE_OFF,
    TLS_MODE_SELF_SIGNED,
    build_server_ssl_context,
    load_or_create_tls_material,
    spki_sha256_b64,
    tls_mode_from_env,
)


def test_tls_mode_from_env_defaults_off_and_validates():
    assert tls_mode_from_env({}) == TLS_MODE_OFF
    assert tls_mode_from_env({"LOGOS_TLS_MODE": "self_signed"}) == TLS_MODE_SELF_SIGNED
    assert tls_mode_from_env({"LOGOS_TLS_MODE": "SELF_SIGNED"}) == TLS_MODE_SELF_SIGNED
    assert tls_mode_from_env({"LOGOS_TLS_MODE": "bogus"}) == TLS_MODE_OFF


def test_creates_cert_and_key_with_locked_down_key_permissions(tmp_path):
    material = load_or_create_tls_material(tmp_path / "tls")
    assert material.cert_path.exists()
    assert material.key_path.exists()
    mode = stat.S_IMODE(os.stat(material.key_path).st_mode)
    assert mode == 0o600, f"private key must be 0600, got {oct(mode)}"


def test_spki_pin_is_stable_and_base64_sha256(tmp_path):
    material = load_or_create_tls_material(tmp_path / "tls")
    # 44 base64 chars == 32-byte SHA-256 digest.
    assert len(material.spki_sha256) == 44
    raw = base64.b64decode(material.spki_sha256)
    assert len(raw) == 32


def test_reload_is_idempotent_and_preserves_pin(tmp_path):
    directory = tmp_path / "tls"
    first = load_or_create_tls_material(directory)
    second = load_or_create_tls_material(directory)
    # Same files, same pin -> a distributed pin stays valid across adapter restarts.
    assert first.cert_path == second.cert_path
    assert first.spki_sha256 == second.spki_sha256


def test_distinct_directories_yield_distinct_pins(tmp_path):
    a = load_or_create_tls_material(tmp_path / "a")
    b = load_or_create_tls_material(tmp_path / "b")
    assert a.spki_sha256 != b.spki_sha256


def test_spki_matches_certificate_public_key(tmp_path):
    from cryptography import x509

    material = load_or_create_tls_material(tmp_path / "tls")
    certificate = x509.load_pem_x509_certificate(material.cert_path.read_bytes())
    assert spki_sha256_b64(certificate) == material.spki_sha256


def test_build_server_ssl_context_loads_chain(tmp_path):
    material = load_or_create_tls_material(tmp_path / "tls")
    context = build_server_ssl_context(material)
    assert isinstance(context, ssl.SSLContext)
    assert context.minimum_version == ssl.TLSVersion.TLSv1_2


# --- pairing deep-link pin distribution (WS3 S4) ---


def test_pairing_deep_link_round_trips_cert_pin():
    from logos.pairing import build_pairing_deep_link, decode_pairing_deep_link

    pin = "abc123base64pinvaluexxxxxxxxxxxxxxxxxxxxxxxx="
    url = build_pairing_deep_link(
        adapter_url="wss://logos.example:8765/logos",
        device_id="ios-abcdef12",
        pair_token="tok-123",
        expires_at=1000.0,
        cert_spki_sha256=pin,
    )
    decoded = decode_pairing_deep_link(url)
    assert decoded["cert_spki_sha256"] == pin


def test_pairing_deep_link_omits_pin_when_absent():
    from logos.pairing import build_pairing_deep_link, decode_pairing_deep_link

    url = build_pairing_deep_link(
        adapter_url="wss://logos.example:8765/logos",
        device_id="ios-abcdef12",
        pair_token="tok-123",
        expires_at=1000.0,
    )
    # Tailscale/loopback invites carry no pin; decode must surface None (not a crash) so the app
    # falls back to default TLS handling.
    assert decode_pairing_deep_link(url)["cert_spki_sha256"] is None


def test_create_invite_embeds_cert_pin():
    from logos.pairing import create_invite, decode_pairing_deep_link

    invite = create_invite(
        master_secret="master-secret",
        adapter_url="wss://logos.example:8765/logos",
        device_id="ios-abcdef12",
        pair_token="tok-123",
        cert_spki_sha256="pinpinpinpinpinpinpinpinpinpinpinpinpinpinp=",
        now=1000.0,
    )
    assert decode_pairing_deep_link(invite.pairing_url)["cert_spki_sha256"] == "pinpinpinpinpinpinpinpinpinpinpinpinpinpinp="
