from __future__ import annotations

import base64
import hashlib
import hmac
import json
import secrets
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any
from urllib.parse import urlparse

PAIRING_PAYLOAD_VERSION = 1
PAIRING_CONTEXT = "logos-device:v1:"
PAIRING_TOKEN_CONTEXT = "logos-pair-token:v1:"
DEFAULT_PAIRING_TTL_SECONDS = 120


@dataclass(frozen=True)
class PairingInvite:
    adapter_url: str
    device_id: str
    pair_token: str
    pairing_url: str
    expires_at: float
    device_secret_hash: str


def derive_device_secret(master_secret: str, device_id: str) -> str:
    """Derive a stable per-device secret from the server-side Logos master secret."""

    normalized_master = str(master_secret or "").strip()
    normalized_device = str(device_id or "").strip()
    if not normalized_master:
        raise ValueError("master_secret is required")
    if not normalized_device:
        raise ValueError("device_id is required")
    return hmac.new(
        normalized_master.encode("utf-8"),
        f"{PAIRING_CONTEXT}{normalized_device}".encode(),
        hashlib.sha256,
    ).hexdigest()


def pairing_token_hash(pair_token: str) -> str:
    token = str(pair_token or "").strip()
    if not token:
        raise ValueError("pair_token is required")
    return hashlib.sha256(f"{PAIRING_TOKEN_CONTEXT}{token}".encode()).hexdigest()


def generate_pairing_token() -> str:
    return secrets.token_urlsafe(32)


def build_pairing_deep_link(
    *,
    adapter_url: str,
    device_id: str,
    pair_token: str,
    expires_at: float,
    autoconnect: bool = True,
    cert_spki_sha256: str | None = None,
) -> str:
    normalized_url = _normalized_adapter_url(adapter_url)
    normalized_device_id = str(device_id or "").strip()
    token = str(pair_token or "").strip()
    if not normalized_device_id:
        raise ValueError("device_id is required")
    if not token:
        raise ValueError("pair_token is required")
    payload = {
        "v": PAIRING_PAYLOAD_VERSION,
        "adapter_url": normalized_url,
        "device_id": normalized_device_id,
        "pair_token": token,
        "expires_at": float(expires_at),
        "autoconnect": bool(autoconnect),
    }
    # Optional WS3 S4 transport pin: present only for direct-WSS deployments. Back-compatible —
    # Tailscale/loopback invites simply omit it and the app falls back to default TLS handling.
    pin = str(cert_spki_sha256 or "").strip()
    if pin:
        payload["cert_spki_sha256"] = pin
    encoded = _base64url_encode_json(payload)
    return f"logos://pair#{encoded}"


def decode_pairing_deep_link(url: str) -> dict[str, Any]:
    parsed = urlparse(str(url))
    if parsed.scheme != "logos" or parsed.netloc != "pair" or not parsed.fragment:
        raise ValueError("not a Logos pairing deep link")
    payload = _base64url_decode_json(parsed.fragment)
    if payload.get("v") != PAIRING_PAYLOAD_VERSION:
        raise ValueError("unsupported Logos pairing payload version")
    adapter_url = _normalized_adapter_url(payload.get("adapter_url"))
    device_id = str(payload.get("device_id") or "").strip()
    pair_token = str(payload.get("pair_token") or "").strip()
    if not device_id:
        raise ValueError("pairing payload missing device_id")
    if not pair_token and not str(payload.get("device_secret") or "").strip():
        raise ValueError("pairing payload missing pair_token or device_secret")
    return {
        "v": PAIRING_PAYLOAD_VERSION,
        "adapter_url": adapter_url,
        "device_id": device_id,
        "pair_token": pair_token,
        "expires_at": float(payload.get("expires_at") or 0.0),
        "autoconnect": bool(payload.get("autoconnect", True)),
        "cert_spki_sha256": str(payload.get("cert_spki_sha256") or "").strip() or None,
    }


def render_qr_png(data: str, output_path: str | Path) -> Path:
    """Render a QR code PNG. Requires qrcode/Pillow, both present in the Hermes venv."""

    try:
        import qrcode
        from qrcode import constants as qrcode_constants
    except ImportError as exc:  # pragma: no cover - defensive in case plugin is copied elsewhere
        raise RuntimeError("qrcode package is required to render Logos pairing QR codes") from exc

    path = Path(output_path).expanduser()
    path.parent.mkdir(parents=True, exist_ok=True)
    qr = qrcode.QRCode(
        version=None,
        error_correction=qrcode_constants.ERROR_CORRECT_M,
        box_size=10,
        border=4,
    )
    qr.add_data(data)
    qr.make(fit=True)
    image = qr.make_image(fill_color="black", back_color="white")
    with path.open("wb") as handle:
        image.save(handle, format="PNG")
    return path


def new_device_id(prefix: str = "ios") -> str:
    clean_prefix = (
        "".join(
            ch for ch in str(prefix or "ios").lower() if ch.isalnum() or ch in {"-", "_"}
        ).strip("-_")
        or "ios"
    )
    return f"{clean_prefix}-{secrets.token_hex(4)}"


def create_invite(
    *,
    master_secret: str,
    adapter_url: str,
    device_id: str | None = None,
    pair_token: str | None = None,
    ttl_seconds: int = DEFAULT_PAIRING_TTL_SECONDS,
    now: float | None = None,
    autoconnect: bool = True,
    cert_spki_sha256: str | None = None,
) -> PairingInvite:
    issued_at = time.time() if now is None else float(now)
    ttl = max(30, min(int(ttl_seconds), 900))
    normalized_device_id = str(device_id or "").strip() or new_device_id()
    token = str(pair_token or "").strip() or generate_pairing_token()
    expires_at = issued_at + ttl
    device_secret = derive_device_secret(master_secret, normalized_device_id)
    device_secret_hash = hashlib.sha256(device_secret.encode("utf-8")).hexdigest()
    pairing_url = build_pairing_deep_link(
        adapter_url=adapter_url,
        device_id=normalized_device_id,
        pair_token=token,
        expires_at=expires_at,
        autoconnect=autoconnect,
        cert_spki_sha256=cert_spki_sha256,
    )
    return PairingInvite(
        adapter_url=_normalized_adapter_url(adapter_url),
        device_id=normalized_device_id,
        pair_token=token,
        pairing_url=pairing_url,
        expires_at=expires_at,
        device_secret_hash=device_secret_hash,
    )


def _normalized_adapter_url(value: Any) -> str:
    text = str(value or "").strip()
    if not text:
        raise ValueError("adapter_url is required")
    parsed = urlparse(text)
    if parsed.scheme not in {"ws", "wss"}:
        raise ValueError("adapter_url must use ws:// or wss://")
    if not parsed.netloc:
        raise ValueError("adapter_url must include a host")
    return text


def _base64url_encode_json(payload: dict[str, Any]) -> str:
    raw = json.dumps(payload, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode(
        "utf-8"
    )
    return base64.urlsafe_b64encode(raw).decode("ascii").rstrip("=")


def _base64url_decode_json(encoded: str) -> dict[str, Any]:
    padded = str(encoded) + "=" * (-len(str(encoded)) % 4)
    try:
        raw = base64.urlsafe_b64decode(padded.encode("ascii"))
        payload = json.loads(raw.decode("utf-8"))
    except Exception as exc:
        raise ValueError("invalid Logos pairing payload") from exc
    if not isinstance(payload, dict):
        raise ValueError("invalid Logos pairing payload")
    return payload
