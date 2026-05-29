from __future__ import annotations

import asyncio
import base64
import hashlib
import hmac
import json
import logging
import secrets
import time
from dataclasses import replace
from typing import Any

import websockets
from websockets.exceptions import ConnectionClosed

from .crypto import (
    CryptoError,
    LogosSessionCrypto,
    ROLE_SERVER,
    SUPPORTED_AEADS,
    is_encrypted_payload,
)
from .schema import Envelope, ProtocolError, error_frame, parse_frame, serialize_frame

logger = logging.getLogger(__name__)

AUTH_VERSION = "logos-v1"
AUTH_VERSION_V2 = "logos-v2"
MAX_HELLO_SKEW_SECONDS = 300
NONCE_TTL_SECONDS = MAX_HELLO_SKEW_SECONDS * 2

# Encryption negotiation modes (see plugins/logos/crypto.py for the AEAD scheme).
ENC_MODE_NEGOTIATE = "negotiate"  # encrypt if the client supports it, else allow cleartext
ENC_MODE_REQUIRED = "required"  # reject clients that cannot negotiate encryption
ENC_MODE_OFF = "off"  # never offer encryption
ENC_NONCE_BYTES = 32


def canonical_hello_message(
    *,
    device_id: str | None,
    request_id: str | None,
    project_key: str | None,
    timestamp_ms: int,
    nonce: str,
    enc_client_nonce: str | None = None,
) -> str:
    """Return the stable string signed by Logos hello frames.

    The v1 form (``enc_client_nonce is None``) is unchanged so already-paired devices keep
    authenticating. The v2 form appends the client's base64 encryption nonce so that it is
    covered by the HMAC and cannot be tampered with during encryption negotiation.
    """

    fields = [
        AUTH_VERSION if enc_client_nonce is None else AUTH_VERSION_V2,
        device_id or "",
        request_id or "",
        project_key or "",
        str(int(timestamp_ms)),
        nonce,
    ]
    if enc_client_nonce is not None:
        fields.append(enc_client_nonce)
    return "\n".join(fields)


def sign_hello(
    secret: str,
    *,
    device_id: str | None,
    request_id: str | None,
    project_key: str | None,
    timestamp_ms: int,
    nonce: str,
    enc_client_nonce: str | None = None,
) -> str:
    message = canonical_hello_message(
        device_id=device_id,
        request_id=request_id,
        project_key=project_key,
        timestamp_ms=timestamp_ms,
        nonce=nonce,
        enc_client_nonce=enc_client_nonce,
    )
    return hmac.new(secret.strip().encode("utf-8"), message.encode("utf-8"), hashlib.sha256).hexdigest()


class LogosWebSocketServer:
    """Authenticated WebSocket control plane for Logos."""

    def __init__(
        self,
        adapter: Any,
        *,
        host: str,
        port: int,
        device_secret: str,
        enc_mode: str = ENC_MODE_NEGOTIATE,
        ssl_context: "ssl.SSLContext | None" = None,
    ) -> None:
        self.adapter = adapter
        self.host = host
        self.port = int(port)
        self.device_secret = device_secret
        self.enc_mode = enc_mode if enc_mode in (ENC_MODE_NEGOTIATE, ENC_MODE_REQUIRED, ENC_MODE_OFF) else ENC_MODE_NEGOTIATE
        # WS3 S4: when present, serve WSS directly (direct-WSS transport) instead of relying on a
        # TLS-terminating front like Tailscale Serve. App-layer AEAD applies either way.
        self._ssl_context = ssl_context
        self._server: Any = None
        self._clients: dict[Any, dict[str, Any]] = {}
        self._lock = asyncio.Lock()
        self._used_nonces: dict[str, float] = {}

    @staticmethod
    def _negotiate_aead(client_supported: Any) -> str | None:
        """Pick the server's preferred AEAD that the client also supports, or None."""
        if not isinstance(client_supported, (list, tuple)):
            return None
        offered = {str(name) for name in client_supported}
        for candidate in SUPPORTED_AEADS:  # server preference order
            if candidate in offered:
                return candidate
        return None

    @staticmethod
    def _seal_outgoing(frame: dict[str, Any], crypto: "LogosSessionCrypto | None") -> dict[str, Any]:
        """Return ``frame`` with its payload sealed, if the session negotiated encryption.

        Routing fields stay cleartext (the server/clients route on them); only ``payload`` is
        encrypted, and it is bound to those routing fields via the AEAD AAD.
        """
        if crypto is None:
            return frame
        header = {key: value for key, value in frame.items() if key != "payload"}
        sealed = dict(frame)
        sealed["payload"] = crypto.seal_payload(header, frame.get("payload") or {})
        return sealed

    def _encode(self, frame: dict[str, Any], crypto: "LogosSessionCrypto | None") -> str:
        return serialize_frame(self._seal_outgoing(frame, crypto))

    async def _send_locked(self, websocket: Any, meta: dict[str, Any] | None, frame: dict[str, Any]) -> None:
        """Seal (if negotiated) and send a frame, holding the per-connection send lock.

        The AEAD counter is assigned inside seal, so seal+send must be atomic per connection —
        otherwise a background broadcast racing the handler could deliver frames out of counter
        order and the receiver would reject them as replays.
        """
        if meta is None:
            await websocket.send(serialize_frame(frame))
            return
        lock = meta.get("send_lock")
        crypto = meta.get("crypto")
        if lock is None:
            await websocket.send(self._encode(frame, crypto))
            return
        async with lock:
            await websocket.send(self._encode(frame, crypto))

    @property
    def actual_port(self) -> int:
        if self._server and getattr(self._server, "sockets", None):
            return int(self._server.sockets[0].getsockname()[1])
        return self.port

    @property
    def url(self) -> str:
        scheme = "wss" if self._ssl_context is not None else "ws"
        return f"{scheme}://{self.host}:{self.actual_port}"

    async def start(self) -> None:
        self._server = await websockets.serve(
            self._handle_connection, self.host, self.port, ssl=self._ssl_context
        )

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
        stale = []
        async with self._lock:
            clients = list(self._clients.items())
        for websocket, metadata in clients:
            client_project = metadata.get("project_key")
            if project_key and client_project and client_project != project_key:
                continue
            try:
                # Seal per client — each session has its own s2c key (cleartext if not negotiated).
                await self._send_locked(websocket, metadata, frame)
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
        crypto: "LogosSessionCrypto | None" = None
        meta: dict[str, Any] | None = None
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
                        authenticated_result, auth_reason, auth_message, auth_details, enc_ctx = self._authenticate(envelope)
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
                        project_key = self.adapter._project_key_for_hello(envelope)
                        client_config = self.adapter.client_config_payload() if hasattr(self.adapter, "client_config_payload") else {}

                        # Encryption negotiation. The client's enc nonce was authenticated by the
                        # signed hello (it travels in enc_ctx); pick an AEAD and derive a
                        # per-connection session. The master device secret never leaves enc_ctx.
                        enc_response: dict[str, Any] | None = None
                        if enc_ctx and self.enc_mode != ENC_MODE_OFF and enc_ctx.get("enc_client_nonce_bytes"):
                            selected_aead = self._negotiate_aead(enc_ctx.get("enc_supported"))
                            if selected_aead is not None:
                                server_nonce = secrets.token_bytes(ENC_NONCE_BYTES)
                                crypto = LogosSessionCrypto.derive_session(
                                    device_secret=enc_ctx["matched_secret"],
                                    client_nonce=enc_ctx["enc_client_nonce_bytes"],
                                    server_nonce=server_nonce,
                                    role=ROLE_SERVER,
                                    aead=selected_aead,
                                )
                                enc_response = {
                                    "aead": selected_aead,
                                    "mode": "hkdf-v1",
                                    "enc_server_nonce": base64.b64encode(server_nonce).decode("ascii"),
                                }
                        if crypto is None and self.enc_mode == ENC_MODE_REQUIRED:
                            await websocket.send(
                                serialize_frame(
                                    error_frame(
                                        "encryption_required",
                                        "Logos adapter requires an encrypted session; update the app to negotiate encryption.",
                                        request_id=envelope.request_id,
                                        device_id=device_id,
                                        project_key=envelope.project_key,
                                    )
                                )
                            )
                            await websocket.close(code=1008, reason="encryption_required")
                            return

                        meta = {
                            "device_id": device_id,
                            "project_key": project_key,
                            "crypto": crypto,
                            "send_lock": asyncio.Lock(),
                        }
                        async with self._lock:
                            self._clients[websocket] = meta
                        hello_payload: dict[str, Any] = {
                            "authenticated": True,
                            "server": "logos",
                            "auth": "hmac-sha256",
                            "credential_scope": auth_details.get("credential_scope", "shared_master"),
                            "protocol_stage": "review-hardening",
                            "client_config": client_config,
                        }
                        if enc_response is not None:
                            hello_payload["enc"] = enc_response
                        # The hello response is cleartext on purpose: it carries the server nonce
                        # the client needs to derive its keys. Every later frame is sealed.
                        await websocket.send(
                            serialize_frame(
                                {
                                    "type": "hello",
                                    "request_id": envelope.request_id,
                                    "device_id": device_id,
                                    "project_key": project_key,
                                    "payload": hello_payload,
                                }
                            )
                        )
                        replay = await self.adapter.reconnect_messages_batch(envelope)
                        if replay:
                            await self._send_locked(websocket, meta, replay)
                        continue

                    # Decrypt before any header normalization, so the AAD matches what the client
                    # sealed against (its as-sent routing fields).
                    if crypto is not None and is_encrypted_payload(envelope.payload):
                        try:
                            envelope = replace(envelope, payload=crypto.open_payload(envelope.to_dict(), envelope.payload))
                        except CryptoError:
                            await self._send_locked(websocket, meta, error_frame("decrypt_failed", "Logos failed to open an encrypted frame."))
                            continue
                    elif crypto is not None and self.enc_mode == ENC_MODE_REQUIRED:
                        await self._send_locked(websocket, meta, error_frame("encryption_required", "Logos requires encrypted frames on this session."))
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
                        await self._send_locked(websocket, meta, response)
                except ProtocolError as exc:
                    await self._send_locked(websocket, meta, error_frame("protocol_error", str(exc)))
                except Exception as exc:
                    logger.exception("Logos: unhandled websocket frame error")
                    await self._send_locked(websocket, meta, error_frame("internal_error", "Logos adapter internal error."))
        finally:
            async with self._lock:
                self._clients.pop(websocket, None)

    def _authenticate(
        self, envelope: Envelope
    ) -> tuple[bool, str, str, dict[str, Any], dict[str, Any] | None]:
        # Returns (ok, reason, message, details, enc_ctx). `details` may be merged into a
        # client-visible error frame on failure, so it must never contain secrets. The matched
        # device secret + encryption nonce travel in `enc_ctx` (success only) for the connection
        # handler's crypto setup; `enc_ctx` is never serialized into any frame.
        payload = envelope.payload
        raw_device_id = envelope.device_id
        device_id = str(raw_device_id or "").strip()
        payload_device_id = str(payload.get("device_id") or "").strip()
        if raw_device_id is not None and raw_device_id != device_id:
            return False, "invalid_device_id", "invalid Logos signed hello: device_id must not include surrounding whitespace", {}, None
        if not device_id:
            return False, "missing_device_id", "invalid Logos signed hello: device_id is required", {}, None
        if payload_device_id and payload_device_id != device_id:
            return False, "device_mismatch", "invalid Logos signed hello: payload device_id does not match frame device_id", {}, None
        if "secret" in payload:
            return False, "legacy_plaintext_secret", "invalid Logos signed hello: plaintext secrets are not accepted", {}, None
        signature_raw = payload.get("signature")
        nonce_raw = payload.get("nonce")
        timestamp_ms_raw = payload.get("timestamp_ms")
        if not isinstance(signature_raw, str) or not signature_raw:
            return False, "missing_signature", "invalid Logos signed hello: missing signature", {}, None
        if not isinstance(nonce_raw, str) or not nonce_raw:
            return False, "missing_nonce", "invalid Logos signed hello: missing nonce", {}, None
        signature = signature_raw
        nonce = nonce_raw
        if len(nonce) < 12 or len(nonce) > 128:
            return False, "invalid_nonce", "invalid Logos signed hello: nonce length is outside the allowed range", {}, None
        try:
            timestamp_ms = int(timestamp_ms_raw)
        except (TypeError, ValueError):
            return False, "invalid_timestamp", "invalid Logos signed hello: timestamp_ms must be an integer", {}, None
        now_ms = int(time.time() * 1000)
        if abs(now_ms - timestamp_ms) > MAX_HELLO_SKEW_SECONDS * 1000:
            return False, "timestamp_skew", "invalid Logos signed hello: timestamp is outside the allowed clock skew", {
                "server_time_ms": now_ms,
                "max_skew_seconds": MAX_HELLO_SKEW_SECONDS,
            }, None
        # Optional encryption negotiation. The client's enc nonce is bound into the signed
        # canonical (v2) so it cannot be tampered with; validate it before checking the signature.
        enc_client_nonce_raw = payload.get("enc_client_nonce")
        enc_client_nonce: str | None = None
        enc_client_nonce_bytes: bytes | None = None
        if enc_client_nonce_raw is not None:
            if not isinstance(enc_client_nonce_raw, str) or not enc_client_nonce_raw:
                return False, "invalid_enc_nonce", "invalid Logos signed hello: enc_client_nonce must be a non-empty string", {}, None
            try:
                enc_client_nonce_bytes = base64.b64decode(enc_client_nonce_raw, validate=True)
            except Exception:
                return False, "invalid_enc_nonce", "invalid Logos signed hello: enc_client_nonce is not valid base64", {}, None
            if len(enc_client_nonce_bytes) != ENC_NONCE_BYTES:
                return False, "invalid_enc_nonce", "invalid Logos signed hello: enc_client_nonce has an unexpected length", {}, None
            enc_client_nonce = enc_client_nonce_raw
        self._purge_nonces(now=time.time())
        if nonce in self._used_nonces:
            return False, "replayed_nonce", "invalid Logos signed hello: nonce was already used", {}, None
        credential_scope = "shared_master"
        matched_secret: str | None = None
        for candidate_secret, candidate_scope in self.adapter.auth_secrets_for_device(device_id):
            expected = sign_hello(
                candidate_secret,
                device_id=device_id,
                request_id=envelope.request_id,
                project_key=envelope.project_key,
                timestamp_ms=timestamp_ms,
                nonce=nonce,
                enc_client_nonce=enc_client_nonce,
            )
            if hmac.compare_digest(signature, expected):
                credential_scope = candidate_scope
                matched_secret = candidate_secret
                break
        if matched_secret is None:
            return False, "invalid_signature", "invalid Logos signed hello: signature mismatch", {}, None
        self._used_nonces[nonce] = time.time()
        enc_ctx = {
            "matched_secret": matched_secret,
            "enc_client_nonce_bytes": enc_client_nonce_bytes,
            "enc_supported": payload.get("enc_supported"),
        }
        return True, "ok", "authenticated", {"credential_scope": credential_scope}, enc_ctx

    def _purge_nonces(self, *, now: float) -> None:
        stale = [nonce for nonce, seen_at in self._used_nonces.items() if now - seen_at > NONCE_TTL_SECONDS]
        for nonce in stale:
            self._used_nonces.pop(nonce, None)
