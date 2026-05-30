"""Optional direct-WSS transport hardening for the Logos adapter (WS3 S4).

Defense-in-depth on top of the already-shipped app-layer AEAD: when ``LOGOS_TLS_MODE`` asks
for it, the adapter can serve WSS directly from a self-signed certificate instead of relying on
a correctly-configured Tailscale Serve front. The certificate's SPKI-SHA256 pin is distributed
to the app through the (HMAC-signed) pairing deep link so the client can pin the leaf and reject
a man-in-the-middle even without a public CA.

Pure/leaf module: depends only on ``cryptography`` (already a plugin dep via ``apns.py``) and the
stdlib. No Hermes imports, so the cert/pin logic is unit-testable in CI Tier-1.
"""

from __future__ import annotations

import base64
import hashlib
import os
import ssl
import stat
from dataclasses import dataclass
from typing import TYPE_CHECKING

if TYPE_CHECKING:
    import datetime
from pathlib import Path

from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.x509.oid import NameOID

# LOGOS_TLS_MODE values.
TLS_MODE_OFF = "off"
TLS_MODE_SELF_SIGNED = "self_signed"
_VALID_TLS_MODES = {TLS_MODE_OFF, TLS_MODE_SELF_SIGNED}

# Self-signed leaf validity. Long-lived because the trust anchor is the pinned SPKI distributed
# at pairing time, not calendar validity; rotating the key rotates the pin.
_CERT_VALIDITY_DAYS = 3650


@dataclass(frozen=True)
class TLSMaterial:
    """Paths to the serving cert/key plus the SPKI-SHA256 pin clients should expect."""

    cert_path: Path
    key_path: Path
    spki_sha256: str


def tls_mode_from_env(env: dict[str, str] | None = None) -> str:
    """Resolve LOGOS_TLS_MODE (default off). Unknown values fall back to off."""
    source = os.environ if env is None else env
    raw = str(source.get("LOGOS_TLS_MODE", "") or "").strip().lower()
    return raw if raw in _VALID_TLS_MODES else TLS_MODE_OFF


def spki_sha256_b64(certificate: x509.Certificate) -> str:
    """Base64( SHA-256( DER SubjectPublicKeyInfo ) ) — the standard leaf SPKI pin.

    Computed over the public key's SubjectPublicKeyInfo (not the whole cert) so the pin survives
    cert re-issuance that keeps the same key, and matches the iOS CryptoKit/Security computation.
    """
    spki_der = certificate.public_key().public_bytes(
        encoding=serialization.Encoding.DER,
        format=serialization.PublicFormat.SubjectPublicKeyInfo,
    )
    return base64.b64encode(hashlib.sha256(spki_der).digest()).decode("ascii")


def _build_self_signed(
    common_name: str, *, now: datetime.datetime | None = None
) -> tuple[x509.Certificate, ec.EllipticCurvePrivateKey]:
    import datetime

    key = ec.generate_private_key(ec.SECP256R1())
    subject = issuer = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, common_name)])
    not_before = datetime.datetime.now(datetime.UTC) if now is None else now
    not_after = not_before + datetime.timedelta(days=_CERT_VALIDITY_DAYS)
    san = x509.SubjectAlternativeName([x509.DNSName(common_name)])
    certificate = (
        x509.CertificateBuilder()
        .subject_name(subject)
        .issuer_name(issuer)
        .public_key(key.public_key())
        .serial_number(x509.random_serial_number())
        .not_valid_before(not_before - datetime.timedelta(minutes=5))
        .not_valid_after(not_after)
        .add_extension(san, critical=False)
        .add_extension(x509.BasicConstraints(ca=False, path_length=None), critical=True)
        .sign(key, hashes.SHA256())
    )
    return certificate, key


def load_or_create_tls_material(
    directory: str | Path,
    *,
    common_name: str = "logos.local",
) -> TLSMaterial:
    """Load the persisted serving cert/key, generating a fresh self-signed pair if absent.

    The private key is written 0600. Idempotent: a second call returns the same material (and
    therefore the same pin) so the distributed pin stays stable across adapter restarts.
    """
    base = Path(directory).expanduser()
    base.mkdir(parents=True, exist_ok=True)
    cert_path = base / "logos_adapter_cert.pem"
    key_path = base / "logos_adapter_key.pem"

    if cert_path.exists() and key_path.exists():
        certificate = x509.load_pem_x509_certificate(cert_path.read_bytes())
        return TLSMaterial(
            cert_path=cert_path, key_path=key_path, spki_sha256=spki_sha256_b64(certificate)
        )

    certificate, key = _build_self_signed(common_name)
    cert_pem = certificate.public_bytes(serialization.Encoding.PEM)
    key_pem = key.private_bytes(
        encoding=serialization.Encoding.PEM,
        format=serialization.PrivateFormat.PKCS8,
        encryption_algorithm=serialization.NoEncryption(),
    )
    cert_path.write_bytes(cert_pem)
    key_path.write_bytes(key_pem)
    os.chmod(key_path, stat.S_IRUSR | stat.S_IWUSR)
    return TLSMaterial(
        cert_path=cert_path, key_path=key_path, spki_sha256=spki_sha256_b64(certificate)
    )


def build_server_ssl_context(material: TLSMaterial) -> ssl.SSLContext:
    """A TLS server context loaded with the serving cert/key for ``websockets.serve(ssl=...)``."""
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(certfile=str(material.cert_path), keyfile=str(material.key_path))
    context.minimum_version = ssl.TLSVersion.TLSv1_2
    return context
