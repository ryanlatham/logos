"""Application-layer authenticated encryption for the Logos protocol.

This adds end-to-end confidentiality + integrity to frame *payloads*, on top of
the existing HMAC-signed `hello` handshake and independent of the transport
(WSS / Tailscale). It is intentionally dormant until wired into the WebSocket
server and the iOS client behind capability negotiation; this module is the
self-contained primitive, validated by `tests/test_crypto_roundtrip.py` and a
cross-implementation known-answer test that the Swift `LogosCrypto` must match.

Scheme (v1 — keep this spec in sync with the Swift implementation):
  - AEAD: ChaCha20-Poly1305 (default) or AES-256-GCM. 256-bit key, 96-bit nonce,
    128-bit tag.
  - Session keys: HKDF-SHA256 with the per-device secret as IKM and
    salt = client_nonce || server_nonce (both fresh per connection). Two keys
    are expanded with distinct `info` labels so the two directions never share a
    key:
        c2s_key = HKDF(ikm, salt, info="logos-enc-v1 c2s key", 32)
        s2c_key = HKDF(ikm, salt, info="logos-enc-v1 s2c key", 32)
  - Per-frame nonce = direction_byte(1) || counter(uint64 big-endian) || 0x000000.
    Counters are strictly monotonic per direction; the receiver rejects any
    counter <= the last accepted one (replay / reordering protection). Keys are
    per-connection, so cross-connection replay is already defeated by the fresh
    server nonce.
  - AAD binds the ciphertext to the cleartext routing header + counter, so an
    attacker cannot move a sealed payload to a different type/device/project.
  - Only the `payload` is encrypted; routing fields stay cleartext because the
    server routes/broadcasts on them. `redact_secrets` runs *before* sealing so
    the secret-redaction guarantee holds for encrypted frames too.
"""

from __future__ import annotations

import base64
import json
from typing import Any, Mapping

from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.ciphers.aead import AESGCM, ChaCha20Poly1305
from cryptography.hazmat.primitives.kdf.hkdf import HKDF

from .schema import ProtocolError, redact_secrets

ENC_VERSION = "logos-enc-v1"
AEAD_CHACHA20_POLY1305 = "chacha20-poly1305"
AEAD_AES_256_GCM = "aes-256-gcm"
SUPPORTED_AEADS = (AEAD_CHACHA20_POLY1305, AEAD_AES_256_GCM)

_KEY_LEN = 32
_C2S_INFO = b"logos-enc-v1 c2s key"
_S2C_INFO = b"logos-enc-v1 s2c key"
_DIRECTION_C2S = 0x01
_DIRECTION_S2C = 0x02

ROLE_CLIENT = "client"
ROLE_SERVER = "server"

# Routing header fields kept in cleartext and bound into the AEAD AAD, in order.
_HEADER_FIELDS = ("type", "request_id", "device_id", "project_key", "session_id", "server_seq")


class CryptoError(ProtocolError):
    """Raised when sealing/opening an encrypted Logos payload fails."""


def _hkdf(ikm: bytes, salt: bytes, info: bytes, length: int = _KEY_LEN) -> bytes:
    return HKDF(algorithm=hashes.SHA256(), length=length, salt=salt, info=info).derive(ikm)


def _device_secret_ikm(device_secret: str) -> bytes:
    # Match the HMAC key derivation used by the signed hello (secret is trimmed UTF-8).
    return str(device_secret or "").strip().encode("utf-8")


def derive_session_keys(*, device_secret: str, client_nonce: bytes, server_nonce: bytes) -> tuple[bytes, bytes]:
    """Return (c2s_key, s2c_key) for a session. Pure function — the KAT anchor."""
    if not client_nonce or not server_nonce:
        raise CryptoError("client_nonce and server_nonce are required")
    ikm = _device_secret_ikm(device_secret)
    if not ikm:
        raise CryptoError("device_secret is required")
    salt = bytes(client_nonce) + bytes(server_nonce)
    return _hkdf(ikm, salt, _C2S_INFO), _hkdf(ikm, salt, _S2C_INFO)


class LogosSessionCrypto:
    """Per-connection sealer/opener for one role (client or server)."""

    def __init__(self, *, c2s_key: bytes, s2c_key: bytes, role: str, aead: str = AEAD_CHACHA20_POLY1305) -> None:
        if role not in (ROLE_CLIENT, ROLE_SERVER):
            raise CryptoError(f"invalid role: {role!r}")
        if aead not in SUPPORTED_AEADS:
            raise CryptoError(f"unsupported aead: {aead!r}")
        self._c2s_key = bytes(c2s_key)
        self._s2c_key = bytes(s2c_key)
        self.role = role
        self.aead = aead
        # A client sends on c2s and receives on s2c; the server is the mirror image.
        if role == ROLE_CLIENT:
            self._send_key, self._send_dir = self._c2s_key, _DIRECTION_C2S
            self._recv_key, self._recv_dir = self._s2c_key, _DIRECTION_S2C
        else:
            self._send_key, self._send_dir = self._s2c_key, _DIRECTION_S2C
            self._recv_key, self._recv_dir = self._c2s_key, _DIRECTION_C2S
        self._send_counter = 0
        self._recv_last = -1

    @classmethod
    def derive_session(
        cls,
        *,
        device_secret: str,
        client_nonce: bytes,
        server_nonce: bytes,
        role: str,
        aead: str = AEAD_CHACHA20_POLY1305,
    ) -> "LogosSessionCrypto":
        c2s_key, s2c_key = derive_session_keys(
            device_secret=device_secret, client_nonce=client_nonce, server_nonce=server_nonce
        )
        return cls(c2s_key=c2s_key, s2c_key=s2c_key, role=role, aead=aead)

    def _cipher(self, key: bytes) -> Any:
        return ChaCha20Poly1305(key) if self.aead == AEAD_CHACHA20_POLY1305 else AESGCM(key)

    @staticmethod
    def _nonce(direction: int, counter: int) -> bytes:
        if counter < 0 or counter > 0xFFFFFFFFFFFFFFFF:
            raise CryptoError("counter out of range")
        return bytes([direction]) + counter.to_bytes(8, "big") + b"\x00\x00\x00"

    @staticmethod
    def _aad(header: Mapping[str, Any], counter: int) -> bytes:
        # Length-prefixed encoding (4-byte big-endian length + UTF-8 bytes per field) so the
        # AAD is injective: routing fields are free-form strings (may contain any byte incl.
        # newlines), and a naive separator-join would let two distinct header tuples collide,
        # allowing a sealed payload to be relocated to a different route with a valid tag.
        fields = [ENC_VERSION]
        for field in _HEADER_FIELDS:
            value = header.get(field)
            fields.append("" if value is None else str(value))
        fields.append(str(counter))
        out = bytearray()
        for field in fields:
            encoded = field.encode("utf-8")
            out += len(encoded).to_bytes(4, "big")
            out += encoded
        return bytes(out)

    def seal_payload(self, header: Mapping[str, Any], payload: Mapping[str, Any]) -> dict[str, Any]:
        """Encrypt `payload`, returning the replacement `{enc, n, ct}` payload object."""
        counter = self._send_counter
        self._send_counter += 1
        redacted = redact_secrets(dict(payload))
        plaintext = json.dumps(redacted, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
        aad = self._aad(header, counter)
        nonce = self._nonce(self._send_dir, counter)
        ciphertext = self._cipher(self._send_key).encrypt(nonce, plaintext, aad)
        return {"enc": 1, "n": counter, "ct": base64.b64encode(ciphertext).decode("ascii")}

    def open_payload(self, header: Mapping[str, Any], enc_payload: Mapping[str, Any]) -> dict[str, Any]:
        """Decrypt an `{enc, n, ct}` payload, enforcing monotonic counters."""
        counter = enc_payload.get("n")
        if not isinstance(counter, int) or isinstance(counter, bool):
            raise CryptoError("encrypted payload is missing a valid counter")
        if counter <= self._recv_last:
            raise CryptoError("replayed or reordered encrypted frame")
        ct_b64 = enc_payload.get("ct")
        if not isinstance(ct_b64, str) or not ct_b64:
            raise CryptoError("encrypted payload is missing ciphertext")
        try:
            ciphertext = base64.b64decode(ct_b64, validate=True)
        except Exception as exc:  # noqa: BLE001 - normalize to a protocol error
            raise CryptoError("invalid ciphertext encoding") from exc
        aad = self._aad(header, counter)
        nonce = self._nonce(self._recv_dir, counter)
        try:
            plaintext = self._cipher(self._recv_key).decrypt(nonce, ciphertext, aad)
        except Exception as exc:  # noqa: BLE001 - InvalidTag and friends
            raise CryptoError("AEAD authentication failed") from exc
        self._recv_last = counter
        try:
            payload = json.loads(plaintext)
        except json.JSONDecodeError as exc:
            raise CryptoError("decrypted payload is not valid JSON") from exc
        if not isinstance(payload, dict):
            raise CryptoError("decrypted payload is not an object")
        return payload

    @property
    def send_counter(self) -> int:
        return self._send_counter

    @property
    def last_received_counter(self) -> int:
        return self._recv_last


def is_encrypted_payload(payload: Any) -> bool:
    """True if `payload` is a sealed `{enc:1, n, ct}` envelope."""
    return isinstance(payload, Mapping) and payload.get("enc") == 1 and "ct" in payload
