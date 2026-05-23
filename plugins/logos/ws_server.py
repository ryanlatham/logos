from __future__ import annotations

import asyncio
import hashlib
import hmac
import json
import logging
import time
from dataclasses import replace
from typing import Any

import websockets
from websockets.exceptions import ConnectionClosed

from .schema import Envelope, ProtocolError, error_frame, parse_frame, serialize_frame

logger = logging.getLogger(__name__)

AUTH_VERSION = "logos-v1"
MAX_HELLO_SKEW_SECONDS = 300
NONCE_TTL_SECONDS = MAX_HELLO_SKEW_SECONDS * 2


def canonical_hello_message(
    *,
    device_id: str | None,
    request_id: str | None,
    project_key: str | None,
    timestamp_ms: int,
    nonce: str,
) -> str:
    """Return the stable string signed by Logos hello frames."""

    return "\n".join(
        [
            AUTH_VERSION,
            device_id or "",
            request_id or "",
            project_key or "",
            str(int(timestamp_ms)),
            nonce,
        ]
    )


def sign_hello(
    secret: str,
    *,
    device_id: str | None,
    request_id: str | None,
    project_key: str | None,
    timestamp_ms: int,
    nonce: str,
) -> str:
    message = canonical_hello_message(
        device_id=device_id,
        request_id=request_id,
        project_key=project_key,
        timestamp_ms=timestamp_ms,
        nonce=nonce,
    )
    return hmac.new(secret.strip().encode("utf-8"), message.encode("utf-8"), hashlib.sha256).hexdigest()


class LogosWebSocketServer:
    """Authenticated WebSocket control plane for Logos."""

    def __init__(self, adapter: Any, *, host: str, port: int, device_secret: str) -> None:
        self.adapter = adapter
        self.host = host
        self.port = int(port)
        self.device_secret = device_secret
        self._server: Any = None
        self._clients: dict[Any, dict[str, Any]] = {}
        self._lock = asyncio.Lock()
        self._used_nonces: dict[str, float] = {}

    @property
    def actual_port(self) -> int:
        if self._server and getattr(self._server, "sockets", None):
            return int(self._server.sockets[0].getsockname()[1])
        return self.port

    @property
    def url(self) -> str:
        return f"ws://{self.host}:{self.actual_port}"

    async def start(self) -> None:
        self._server = await websockets.serve(self._handle_connection, self.host, self.port)

    async def stop(self) -> None:
        clients = list(self._clients.keys())
        for websocket in clients:
            try:
                await websocket.close()
            except Exception:
                logger.debug("Logos: error closing websocket client", exc_info=True)
        self._clients.clear()
        if self._server is not None:
            self._server.close()
            await self._server.wait_closed()
            self._server = None

    async def broadcast(self, frame: dict[str, Any], *, project_key: str | None = None) -> None:
        if not self._clients:
            return
        encoded = serialize_frame(frame)
        stale = []
        async with self._lock:
            clients = list(self._clients.items())
        for websocket, metadata in clients:
            client_project = metadata.get("project_key")
            if project_key and client_project and client_project != project_key:
                continue
            try:
                await websocket.send(encoded)
            except ConnectionClosed:
                stale.append(websocket)
            except Exception:
                stale.append(websocket)
                logger.debug("Logos: broadcast failed", exc_info=True)
        if stale:
            async with self._lock:
                for websocket in stale:
                    self._clients.pop(websocket, None)

    async def _handle_connection(self, websocket: Any) -> None:
        authenticated = False
        device_id: str | None = None
        project_key: str | None = None
        try:
            async for raw in websocket:
                try:
                    envelope = parse_frame(raw)
                    if not authenticated:
                        if envelope.type == "pair":
                            response = await self.adapter.handle_pairing_envelope(envelope)
                            if response.get("type") == "pairing_complete":
                                await websocket.send(json.dumps(response, ensure_ascii=False, separators=(",", ":")))
                            else:
                                await websocket.send(
                                    serialize_frame(
                                        error_frame(
                                            "pairing_failed",
                                            "Logos pairing failed. Generate a fresh QR code and try again.",
                                            request_id=envelope.request_id,
                                            device_id=envelope.device_id,
                                            project_key=envelope.project_key,
                                        )
                                    )
                                )
                            continue
                        if envelope.type != "hello":
                            await websocket.send(
                                serialize_frame(
                                    error_frame(
                                        "auth_required",
                                        "send hello with a valid signed authentication payload before other frames",
                                        request_id=envelope.request_id,
                                        device_id=envelope.device_id,
                                        project_key=envelope.project_key,
                                    )
                                )
                            )
                            continue
                        authenticated_result, auth_reason, auth_message, auth_details = self._authenticate(envelope)
                        if not authenticated_result:
                            auth_error = error_frame(
                                "auth_failed",
                                auth_message,
                                request_id=envelope.request_id,
                                device_id=envelope.device_id,
                                project_key=envelope.project_key,
                                raw=envelope.to_dict(),
                            )
                            auth_error["payload"]["reason"] = auth_reason
                            auth_error["payload"].update(auth_details)
                            await websocket.send(
                                serialize_frame(auth_error)
                            )
                            await websocket.close(code=1008, reason="auth_failed")
                            return
                        device_id = str(envelope.device_id or "").strip()
                        if not self.adapter.is_device_allowed(device_id):
                            await websocket.send(
                                serialize_frame(
                                    error_frame(
                                        "device_not_allowed",
                                        "Logos device is not enrolled or allowed",
                                        request_id=envelope.request_id,
                                        device_id=device_id,
                                        project_key=envelope.project_key,
                                    )
                                )
                            )
                            await websocket.close(code=1008, reason="device_not_allowed")
                            return
                        authenticated = True
                        project_key = envelope.project_key or envelope.payload.get("project_key")
                        async with self._lock:
                            self._clients[websocket] = {
                                "device_id": device_id,
                                "project_key": project_key,
                            }
                        await websocket.send(
                            serialize_frame(
                                {
                                    "type": "hello",
                                    "request_id": envelope.request_id,
                                    "device_id": device_id,
                                    "project_key": project_key,
                                    "payload": {
                                        "authenticated": True,
                                        "server": "logos",
                                        "auth": "hmac-sha256",
                                        "credential_scope": auth_details.get("credential_scope", "shared_master"),
                                        "protocol_stage": "review-hardening",
                                    },
                                }
                            )
                        )
                        replay = await self.adapter.reconnect_messages_batch(envelope)
                        if replay:
                            await websocket.send(serialize_frame(replay))
                        continue

                    claimed_device_id = str(envelope.device_id or "").strip()
                    if claimed_device_id and claimed_device_id != device_id:
                        await websocket.send(
                            serialize_frame(
                                error_frame(
                                    "device_mismatch",
                                    "frame device_id does not match the authenticated Logos device",
                                    request_id=envelope.request_id,
                                    device_id=claimed_device_id,
                                    project_key=envelope.project_key,
                                )
                            )
                        )
                        continue
                    if not claimed_device_id and device_id:
                        envelope = replace(envelope, device_id=device_id)

                    new_project_key = envelope.project_key or envelope.payload.get("project_key")
                    if new_project_key:
                        project_key = str(new_project_key)
                        async with self._lock:
                            if websocket in self._clients:
                                self._clients[websocket]["project_key"] = project_key
                    response = await self.adapter.handle_ws_envelope(envelope)
                    if response:
                        await websocket.send(serialize_frame(response))
                except ProtocolError as exc:
                    await websocket.send(serialize_frame(error_frame("protocol_error", str(exc))))
                except Exception as exc:
                    logger.exception("Logos: unhandled websocket frame error")
                    await websocket.send(serialize_frame(error_frame("internal_error", str(exc))))
        finally:
            async with self._lock:
                self._clients.pop(websocket, None)

    def _authenticate(self, envelope: Envelope) -> tuple[bool, str, str, dict[str, Any]]:
        payload = envelope.payload
        raw_device_id = envelope.device_id
        device_id = str(raw_device_id or "").strip()
        payload_device_id = str(payload.get("device_id") or "").strip()
        if raw_device_id is not None and raw_device_id != device_id:
            return False, "invalid_device_id", "invalid Logos signed hello: device_id must not include surrounding whitespace", {}
        if not device_id:
            return False, "missing_device_id", "invalid Logos signed hello: device_id is required", {}
        if payload_device_id and payload_device_id != device_id:
            return False, "device_mismatch", "invalid Logos signed hello: payload device_id does not match frame device_id", {}
        if "secret" in payload:
            return False, "legacy_plaintext_secret", "invalid Logos signed hello: plaintext secrets are not accepted", {}
        signature_raw = payload.get("signature")
        nonce_raw = payload.get("nonce")
        timestamp_ms_raw = payload.get("timestamp_ms")
        if not isinstance(signature_raw, str) or not signature_raw:
            return False, "missing_signature", "invalid Logos signed hello: missing signature", {}
        if not isinstance(nonce_raw, str) or not nonce_raw:
            return False, "missing_nonce", "invalid Logos signed hello: missing nonce", {}
        signature = signature_raw
        nonce = nonce_raw
        if len(nonce) < 12 or len(nonce) > 128:
            return False, "invalid_nonce", "invalid Logos signed hello: nonce length is outside the allowed range", {}
        try:
            timestamp_ms = int(timestamp_ms_raw)
        except (TypeError, ValueError):
            return False, "invalid_timestamp", "invalid Logos signed hello: timestamp_ms must be an integer", {}
        now_ms = int(time.time() * 1000)
        if abs(now_ms - timestamp_ms) > MAX_HELLO_SKEW_SECONDS * 1000:
            return False, "timestamp_skew", "invalid Logos signed hello: timestamp is outside the allowed clock skew", {
                "server_time_ms": now_ms,
                "max_skew_seconds": MAX_HELLO_SKEW_SECONDS,
            }
        self._purge_nonces(now=time.time())
        if nonce in self._used_nonces:
            return False, "replayed_nonce", "invalid Logos signed hello: nonce was already used", {}
        credential_scope = "shared_master"
        matched = False
        for candidate_secret, candidate_scope in self.adapter.auth_secrets_for_device(device_id):
            expected = sign_hello(
                candidate_secret,
                device_id=device_id,
                request_id=envelope.request_id,
                project_key=envelope.project_key,
                timestamp_ms=timestamp_ms,
                nonce=nonce,
            )
            if hmac.compare_digest(signature, expected):
                credential_scope = candidate_scope
                matched = True
                break
        if not matched:
            return False, "invalid_signature", "invalid Logos signed hello: signature mismatch", {}
        self._used_nonces[nonce] = time.time()
        return True, "ok", "authenticated", {"credential_scope": credential_scope}

    def _purge_nonces(self, *, now: float) -> None:
        stale = [nonce for nonce, seen_at in self._used_nonces.items() if now - seen_at > NONCE_TTL_SECONDS]
        for nonce in stale:
            self._used_nonces.pop(nonce, None)
