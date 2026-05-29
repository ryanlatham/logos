"""Tests for the Logos application-layer crypto (Hermes-free; runs in CI Tier-1).

The known-answer vectors below are the cross-implementation contract: the Swift
`LogosCryptoTests` must reproduce the same derived keys and the same ciphertext
from the same inputs. If you change the KDF/AEAD/AAD/nonce scheme, update both
sides together — a divergence here means iOS and the adapter cannot talk.
"""

from __future__ import annotations

import base64

import pytest

from logos.crypto import (
    AEAD_AES_256_GCM,
    AEAD_CHACHA20_POLY1305,
    CryptoError,
    LogosSessionCrypto,
    derive_session_keys,
    is_encrypted_payload,
)

# --- Known-answer test vectors (must match Swift LogosCryptoTests) ---
KAT_DEVICE_SECRET = "logos-kat-device-secret-v1"
KAT_CLIENT_NONCE = bytes.fromhex("00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff")
KAT_SERVER_NONCE = bytes.fromhex("ffeeddccbbaa99887766554433221100ffeeddccbbaa99887766554433221100")
KAT_C2S_KEY_HEX = "b3cdc50921850a9fa40b205f750381a8578ab9e933ea6a889d97ebead1244f0c"
KAT_S2C_KEY_HEX = "b1f1f071774e7aa39b52b3d10bfba534b918bf8be5123fc5e3dfd2a468c55c80"
KAT_HEADER = {"type": "text_input", "request_id": "kat-req", "device_id": "kat-device", "project_key": "default"}
KAT_PAYLOAD = {"text": "deploy staging", "is_final": True}
KAT_SEAL_CT_B64 = "KhQpY27pF/oEtm8ZvX2XExqDZ0yeT48Gw0ORUDQNsjXBFtJK7ff50uDQLb1mKjEt0O4zNMnWobIJ"


def _client_server(aead: str = AEAD_CHACHA20_POLY1305):
    common = dict(device_secret=KAT_DEVICE_SECRET, client_nonce=KAT_CLIENT_NONCE, server_nonce=KAT_SERVER_NONCE, aead=aead)
    return (
        LogosSessionCrypto.derive_session(role="client", **common),
        LogosSessionCrypto.derive_session(role="server", **common),
    )


def test_kat_derived_keys_match_fixed_vectors():
    c2s, s2c = derive_session_keys(
        device_secret=KAT_DEVICE_SECRET, client_nonce=KAT_CLIENT_NONCE, server_nonce=KAT_SERVER_NONCE
    )
    assert c2s.hex() == KAT_C2S_KEY_HEX
    assert s2c.hex() == KAT_S2C_KEY_HEX
    assert c2s != s2c  # direction separation


def test_kat_client_seal_is_byte_for_byte_reproducible():
    client, _ = _client_server()
    sealed = client.seal_payload(KAT_HEADER, KAT_PAYLOAD)
    assert sealed["enc"] == 1
    assert sealed["n"] == 0
    assert sealed["ct"] == KAT_SEAL_CT_B64
    assert is_encrypted_payload(sealed)


def test_round_trip_both_directions():
    client, server = _client_server()
    # client -> server
    sealed = client.seal_payload(KAT_HEADER, {"text": "hello", "is_final": True})
    assert server.open_payload(KAT_HEADER, sealed) == {"text": "hello", "is_final": True}
    # server -> client (distinct key/direction)
    header2 = {"type": "state_update", "project_key": "default"}
    sealed2 = server.seal_payload(header2, {"op": "message_appended", "message_id": "m1"})
    assert client.open_payload(header2, sealed2) == {"op": "message_appended", "message_id": "m1"}


def test_counter_increments_and_replay_is_rejected():
    client, server = _client_server()
    s0 = client.seal_payload(KAT_HEADER, {"text": "one"})
    s1 = client.seal_payload(KAT_HEADER, {"text": "two"})
    assert (s0["n"], s1["n"]) == (0, 1)
    assert server.open_payload(KAT_HEADER, s0) == {"text": "one"}
    assert server.open_payload(KAT_HEADER, s1) == {"text": "two"}
    # Replaying counter 0 after 1 has been accepted is rejected.
    with pytest.raises(CryptoError):
        server.open_payload(KAT_HEADER, s0)


def test_tampered_ciphertext_fails():
    client, server = _client_server()
    sealed = client.seal_payload(KAT_HEADER, {"text": "secret-ish"})
    raw = bytearray(base64.b64decode(sealed["ct"]))
    raw[0] ^= 0x01  # flip a bit
    sealed["ct"] = base64.b64encode(bytes(raw)).decode("ascii")
    with pytest.raises(CryptoError):
        server.open_payload(KAT_HEADER, sealed)


def test_moving_frame_to_different_header_fails():
    client, server = _client_server()
    sealed = client.seal_payload(KAT_HEADER, {"text": "routed"})
    moved_header = dict(KAT_HEADER, device_id="someone-else")  # AAD mismatch
    with pytest.raises(CryptoError):
        server.open_payload(moved_header, sealed)


def test_tampered_counter_fails():
    client, server = _client_server()
    sealed = client.seal_payload(KAT_HEADER, {"text": "n-bound"})
    sealed["n"] = 5  # nonce + AAD are bound to the counter
    with pytest.raises(CryptoError):
        server.open_payload(KAT_HEADER, sealed)


def test_secrets_are_redacted_before_sealing():
    client, server = _client_server()
    sealed = client.seal_payload(KAT_HEADER, {"text": "hi", "device_secret": "super-secret-value"})
    opened = server.open_payload(KAT_HEADER, sealed)
    assert opened["text"] == "hi"
    assert opened["device_secret"] == "[REDACTED]"


def test_aes_256_gcm_round_trips():
    client, server = _client_server(aead=AEAD_AES_256_GCM)
    sealed = client.seal_payload(KAT_HEADER, {"text": "gcm"})
    assert server.open_payload(KAT_HEADER, sealed) == {"text": "gcm"}


def test_aad_is_injective_newline_header_does_not_relocate():
    # Under a naive "\n".join AAD these two distinct headers collide
    # (project_key "a" + session_id "b"  vs  project_key "a\nb"), which would let a sealed
    # payload be relocated across routes. The length-prefixed AAD must reject the move.
    client, server = _client_server()
    header_a = {"type": "text_input", "request_id": "r", "device_id": "d", "project_key": "a", "session_id": "b"}
    header_b = {"type": "text_input", "request_id": "r", "device_id": "d", "project_key": "a\nb"}
    assert LogosSessionCrypto._aad(header_a, 0) != LogosSessionCrypto._aad(header_b, 0)
    sealed = client.seal_payload(header_a, {"text": "x"})
    with pytest.raises(CryptoError):
        server.open_payload(header_b, sealed)


def test_secrets_redacted_inside_arrays():
    client, server = _client_server()
    sealed = client.seal_payload(KAT_HEADER, {"items": [{"api_key": "SENSITIVE"}], "auth_token": "T"})
    opened = server.open_payload(KAT_HEADER, sealed)
    assert opened["items"][0]["api_key"] == "[REDACTED]"
    assert opened["auth_token"] == "[REDACTED]"


def test_missing_or_invalid_fields_raise():
    _, server = _client_server()
    with pytest.raises(CryptoError):
        server.open_payload(KAT_HEADER, {"enc": 1, "ct": "not-base64!!"})
    with pytest.raises(CryptoError):
        server.open_payload(KAT_HEADER, {"enc": 1, "n": 0})  # no ct
    with pytest.raises(CryptoError):
        server.open_payload(KAT_HEADER, {"enc": 1, "n": True, "ct": "AAAA"})  # bool is not a valid counter
