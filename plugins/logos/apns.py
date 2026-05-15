from __future__ import annotations

import base64
import http.client
import json
import os
import time
from dataclasses import dataclass
from enum import Enum
from pathlib import Path
from typing import Any, Mapping


class PrivateNotificationKind(str, Enum):
    FINISHED = "finished"
    APPROVAL = "approval"
    CLARIFICATION = "clarification"


@dataclass(frozen=True)
class APNSConfig:
    key_id: str | None = None
    team_id: str | None = None
    bundle_id: str | None = None
    auth_key_path: str | None = None
    environment: str = "sandbox"
    timeout_seconds: float = 10.0

    @classmethod
    def from_env(cls, env: Mapping[str, str] | None = None) -> "APNSConfig":
        source: Mapping[str, str] = env if env is not None else os.environ
        return cls(
            key_id=source.get("LOGOS_APNS_KEY_ID") or None,
            team_id=source.get("LOGOS_APNS_TEAM_ID") or None,
            bundle_id=source.get("LOGOS_APNS_BUNDLE_ID") or None,
            auth_key_path=source.get("LOGOS_APNS_AUTH_KEY_PATH") or None,
            environment=source.get("LOGOS_APNS_ENV") or "sandbox",
        )

    @property
    def configured(self) -> bool:
        return bool(self.key_id and self.team_id and self.bundle_id and self.auth_key_path)

    @property
    def host(self) -> str:
        if self.environment == "production":
            return "api.push.apple.com"
        return "api.sandbox.push.apple.com"


@dataclass(frozen=True)
class APNSSendResult:
    success: bool
    skipped: bool = False
    reason: str | None = None
    status: int | None = None
    apns_id: str | None = None


def build_private_apns_payload(
    kind: PrivateNotificationKind | str,
    *,
    project_key: str,
    session_id: str | None = None,
    message_id: str | None = None,
    server_seq: int | None = None,
    request_id: str | None = None,
    sensitive_context: dict[str, Any] | None = None,
) -> dict[str, Any]:
    """Build a private APNS payload.

    `sensitive_context` is accepted only so callers/tests can prove it is ignored.
    Do not copy response text, summaries, commands, questions, file paths, or secrets
    into the push payload. APNS is a wake/attention signal; reconnect + delta sync is
    the source of truth.
    """
    _ = sensitive_context  # deliberately ignored
    parsed = PrivateNotificationKind(kind)
    title_body = {
        PrivateNotificationKind.FINISHED: ("Hermes finished", "Open Logos to view the result."),
        PrivateNotificationKind.APPROVAL: ("Hermes needs approval", "Open Logos to continue."),
        PrivateNotificationKind.CLARIFICATION: ("Hermes needs clarification", "Open Logos to continue."),
    }[parsed]
    title, body = title_body
    payload: dict[str, Any] = {
        "aps": {
            "alert": {"title": title, "body": body},
            "sound": "default",
        },
        "project_key": project_key,
        "kind": parsed.value,
    }
    if session_id:
        payload["session_id"] = session_id
    if message_id:
        payload["message_id"] = message_id
    if server_seq is not None:
        payload["server_seq"] = int(server_seq)
    if request_id:
        payload["request_id"] = request_id
    return payload


class APNSClient:
    def __init__(self, config: APNSConfig | None = None) -> None:
        self.config = config or APNSConfig.from_env()
        self._jwt: str | None = None
        self._jwt_created_at: float = 0.0

    @classmethod
    def from_env(cls, env: Mapping[str, str] | None = None) -> "APNSClient":
        return cls(APNSConfig.from_env(env))

    def send(self, device_token: str, payload: dict[str, Any]) -> APNSSendResult:
        if not self.config.configured:
            return APNSSendResult(success=False, skipped=True, reason="missing_credentials")
        token = str(device_token or "").strip()
        if not token:
            return APNSSendResult(success=False, skipped=True, reason="missing_device_token")
        try:
            jwt = self._provider_token()
            body = json.dumps(payload, separators=(",", ":")).encode("utf-8")
            conn = http.client.HTTPSConnection(self.config.host, timeout=self.config.timeout_seconds)
            headers = {
                "authorization": f"bearer {jwt}",
                "apns-topic": self.config.bundle_id or "",
                "apns-push-type": "alert",
                "apns-priority": "10",
                "content-type": "application/json",
            }
            conn.request("POST", f"/3/device/{token}", body=body, headers=headers)
            response = conn.getresponse()
            response_body = response.read().decode("utf-8", errors="replace")
            apns_id = response.getheader("apns-id")
            if 200 <= response.status < 300:
                return APNSSendResult(success=True, status=response.status, apns_id=apns_id)
            reason = response_body or response.reason
            return APNSSendResult(success=False, status=response.status, apns_id=apns_id, reason=reason)
        except Exception as exc:
            return APNSSendResult(success=False, reason=type(exc).__name__)

    def _provider_token(self) -> str:
        now = time.time()
        if self._jwt and now - self._jwt_created_at < 20 * 60:
            return self._jwt
        if not self.config.configured:
            raise RuntimeError("APNS credentials are not configured")
        try:
            from cryptography.hazmat.primitives import hashes, serialization
            from cryptography.hazmat.primitives.asymmetric import ec
            from cryptography.hazmat.primitives.asymmetric.utils import decode_dss_signature
        except Exception as exc:  # pragma: no cover - depends on optional runtime package
            raise RuntimeError("cryptography package is required for APNS token signing") from exc

        key_path = Path(self.config.auth_key_path or "").expanduser()
        private_key = serialization.load_pem_private_key(key_path.read_bytes(), password=None)
        if not isinstance(private_key, ec.EllipticCurvePrivateKey):
            raise RuntimeError("APNS auth key is not an EC private key")
        header = {"alg": "ES256", "kid": self.config.key_id}
        claims = {"iss": self.config.team_id, "iat": int(now)}
        signing_input = f"{_b64url_json(header)}.{_b64url_json(claims)}".encode("ascii")
        der_signature = private_key.sign(signing_input, ec.ECDSA(hashes.SHA256()))
        r, s = decode_dss_signature(der_signature)
        signature = r.to_bytes(32, "big") + s.to_bytes(32, "big")
        jwt = f"{signing_input.decode('ascii')}.{_b64url(signature)}"
        self._jwt = jwt
        self._jwt_created_at = now
        return jwt


def _b64url_json(value: dict[str, Any]) -> str:
    return _b64url(json.dumps(value, separators=(",", ":")).encode("utf-8"))


def _b64url(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode("ascii")
