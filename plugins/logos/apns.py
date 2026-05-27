from __future__ import annotations

import base64
import json
import os
import time
from dataclasses import dataclass
from enum import Enum
from pathlib import Path
from typing import Any, Callable, Mapping


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
        return apns_host_for_environment(self.environment)


def apns_host_for_environment(environment: str | None) -> str:
    if str(environment or "").strip().lower() == "production":
        return "api.push.apple.com"
    return "api.sandbox.push.apple.com"


@dataclass(frozen=True)
class APNSSendResult:
    success: bool
    skipped: bool = False
    reason: str | None = None
    status: int | None = None
    apns_id: str | None = None
    environment: str | None = None
    host: str | None = None
    http_version: str | None = None
    temporary_failure: bool = False


APNS_PROVIDER_TOKEN_ERROR_REASONS = {
    "ExpiredProviderToken",
    "InvalidProviderToken",
    "MissingProviderToken",
}


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
    def __init__(
        self,
        config: APNSConfig | None = None,
        *,
        http_client_factory: Callable[..., Any] | None = None,
    ) -> None:
        self.config = config or APNSConfig.from_env()
        self._jwt: str | None = None
        self._jwt_created_at: float = 0.0
        self._http_client_factory = http_client_factory or _default_http_client_factory
        self._clients: dict[str, Any] = {}

    @classmethod
    def from_env(cls, env: Mapping[str, str] | None = None) -> "APNSClient":
        return cls(APNSConfig.from_env(env))

    async def send(self, device_token: str, payload: dict[str, Any], *, environment: str | None = None) -> APNSSendResult:
        resolved_environment = _normalize_environment(environment or self.config.environment)
        host = apns_host_for_environment(resolved_environment)
        if not self.config.configured:
            return APNSSendResult(
                success=False,
                skipped=True,
                reason="missing_credentials",
                environment=resolved_environment,
                host=host,
            )
        token = str(device_token or "").strip()
        if not token:
            return APNSSendResult(
                success=False,
                skipped=True,
                reason="missing_device_token",
                environment=resolved_environment,
                host=host,
            )
        try:
            jwt = self._provider_token()
            body = json.dumps(payload, separators=(",", ":")).encode("utf-8")
            client = self._client_for(resolved_environment)
            headers = {
                "authorization": f"bearer {jwt}",
                "apns-topic": self.config.bundle_id or "",
                "apns-push-type": "alert",
                "apns-priority": "10",
                "content-type": "application/json",
            }
            response = await client.post(f"/3/device/{token}", content=body, headers=headers)
            status = int(getattr(response, "status_code", 0) or 0)
            response_headers = getattr(response, "headers", {}) or {}
            apns_id = response_headers.get("apns-id") or response_headers.get("apns-request-id")
            reason = _apns_response_reason(response)
            http_version = str(getattr(response, "http_version", "") or "") or None
            success = 200 <= status < 300
            result = APNSSendResult(
                success=success,
                status=status,
                apns_id=apns_id,
                reason=None if success else reason,
                environment=resolved_environment,
                host=host,
                http_version=http_version,
                temporary_failure=_is_temporary_apns_status(status),
            )
            if reason in APNS_PROVIDER_TOKEN_ERROR_REASONS:
                await self._reset_auth_state()
            return result
        except Exception as exc:
            return APNSSendResult(
                success=False,
                reason=type(exc).__name__,
                environment=resolved_environment,
                host=host,
                temporary_failure=_is_temporary_transport_error(exc),
            )

    async def aclose(self) -> None:
        clients = list(self._clients.values())
        self._clients.clear()
        for client in clients:
            close = getattr(client, "aclose", None)
            if close is None:
                continue
            result = close()
            if hasattr(result, "__await__"):
                await result

    def _client_for(self, environment: str) -> Any:
        client = self._clients.get(environment)
        if client is None:
            host = apns_host_for_environment(environment)
            client = self._http_client_factory(host=host, timeout=self.config.timeout_seconds, http2=True)
            self._clients[environment] = client
        return client

    async def _reset_auth_state(self) -> None:
        self._jwt = None
        self._jwt_created_at = 0.0
        await self.aclose()

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


def _normalize_environment(environment: str | None) -> str:
    return "production" if str(environment or "").strip().lower() == "production" else "sandbox"


def _default_http_client_factory(*, host: str, timeout: float, http2: bool) -> Any:
    try:
        import h2  # noqa: F401
        import httpx
    except Exception as exc:  # pragma: no cover - depends on optional runtime package
        raise RuntimeError("httpx with HTTP/2 support is required for APNS delivery") from exc
    return httpx.AsyncClient(base_url=f"https://{host}", http2=http2, timeout=timeout)


def _apns_response_reason(response: Any) -> str | None:
    content = getattr(response, "content", b"")
    if content:
        try:
            parsed = response.json()
        except Exception:
            parsed = None
        if isinstance(parsed, dict):
            for key in ("reason", "error", "message"):
                value = parsed.get(key)
                if value:
                    return str(value)
        text = str(getattr(response, "text", "") or "").strip()
        if text:
            return text
    phrase = str(getattr(response, "reason_phrase", "") or "").strip()
    return phrase or None


def _is_temporary_apns_status(status: int | None) -> bool:
    if status is None:
        return False
    return int(status) == 429 or int(status) >= 500


def _is_temporary_transport_error(exc: Exception) -> bool:
    if "Timeout" in type(exc).__name__:
        return True
    try:
        import httpx
    except Exception:
        return False
    return isinstance(exc, httpx.TransportError)
