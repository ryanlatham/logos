from __future__ import annotations

import asyncio
import hashlib
import json
import socket
import time

import pytest
import websockets

from gateway.config import PlatformConfig
from logos.adapter import LogosAdapter
from logos.pairing import derive_device_secret
from logos.schema import Envelope
from logos.ws_server import sign_hello


@pytest.mark.asyncio
async def test_websocket_rejects_legacy_plaintext_secret_hello(tmp_path):
    adapter = LogosAdapter(
        PlatformConfig(enabled=True, extra={"host": "127.0.0.1", "port": 0, "store_path": str(tmp_path / "logos.db")})
    )
    assert await adapter.connect() is True
    try:
        async with websockets.connect(adapter.ws_url) as ws:
            await ws.send(json.dumps({"type": "hello", "request_id": "legacy", "device_id": "iphone", "payload": {"secret": "dev-secret"}}))
            response = json.loads(await asyncio.wait_for(ws.recv(), timeout=2))
            assert response["type"] == "error"
            assert response["payload"]["code"] == "auth_failed"
            assert response["payload"]["raw"]["payload"]["secret"] == "[REDACTED]"
    finally:
        await adapter.disconnect()


@pytest.mark.asyncio
async def test_websocket_signed_hello_reports_signature_mismatch_reason(tmp_path):
    adapter = LogosAdapter(
        PlatformConfig(enabled=True, extra={"host": "127.0.0.1", "port": 0, "store_path": str(tmp_path / "logos.db")})
    )
    assert await adapter.connect() is True
    timestamp_ms = int(time.time() * 1000)
    nonce = "nonce-invalid-signature-123"
    try:
        async with websockets.connect(adapter.ws_url) as ws:
            await ws.send(
                json.dumps(
                    {
                        "type": "hello",
                        "request_id": "hello-bad-sig",
                        "device_id": "iphone",
                        "project_key": "default",
                        "payload": {
                            "timestamp_ms": timestamp_ms,
                            "nonce": nonce,
                            "signature": sign_hello(
                                "wrong-secret",
                                device_id="iphone",
                                request_id="hello-bad-sig",
                                project_key="default",
                                timestamp_ms=timestamp_ms,
                                nonce=nonce,
                            ),
                        },
                    }
                )
            )
            response = json.loads(await asyncio.wait_for(ws.recv(), timeout=2))
            assert response["type"] == "error"
            assert response["payload"]["code"] == "auth_failed"
            assert response["payload"]["reason"] == "invalid_signature"
            assert "signature mismatch" in response["payload"]["message"]
    finally:
        await adapter.disconnect()


@pytest.mark.asyncio
async def test_websocket_rejects_signed_hello_without_frame_device_id_for_enrolled_device(tmp_path):
    master_secret = "dev-secret"
    device_id = "iphone-paired"
    adapter = LogosAdapter(
        PlatformConfig(
            enabled=True,
            extra={"device_secret": master_secret, "host": "127.0.0.1", "port": 0, "store_path": str(tmp_path / "logos.db")},
        )
    )
    device_secret = derive_device_secret(master_secret, device_id)
    adapter.store.upsert_device(
        device_id=device_id,
        display_name="Paired iPhone",
        shared_secret_hash=hashlib.sha256(device_secret.encode("utf-8")).hexdigest(),
        capabilities=["text", "speech"],
    )
    assert await adapter.connect() is True
    timestamp_ms = int(time.time() * 1000)
    nonce = "nonce-missing-device-123"
    try:
        async with websockets.connect(adapter.ws_url) as ws:
            await ws.send(
                json.dumps(
                    {
                        "type": "hello",
                        "request_id": "hello-missing-device",
                        "project_key": "default",
                        "payload": {
                            "device_id": device_id,
                            "timestamp_ms": timestamp_ms,
                            "nonce": nonce,
                            "signature": sign_hello(
                                master_secret,
                                device_id=None,
                                request_id="hello-missing-device",
                                project_key="default",
                                timestamp_ms=timestamp_ms,
                                nonce=nonce,
                            ),
                        },
                    }
                )
            )
            response = json.loads(await asyncio.wait_for(ws.recv(), timeout=2))
            assert response["type"] == "error"
            assert response["payload"]["code"] == "auth_failed"
            assert response["payload"]["reason"] == "missing_device_id"
    finally:
        await adapter.disconnect()


@pytest.mark.asyncio
async def test_websocket_signed_hello_rejects_replayed_nonce(tmp_path):
    adapter = LogosAdapter(
        PlatformConfig(enabled=True, extra={"host": "127.0.0.1", "port": 0, "store_path": str(tmp_path / "logos.db")})
    )
    assert await adapter.connect() is True
    timestamp_ms = int(time.time() * 1000)
    nonce = "nonce-replay-test-123"
    payload = {
        "timestamp_ms": timestamp_ms,
        "nonce": nonce,
        "signature": sign_hello(
            "dev-secret",
            device_id="iphone",
            request_id="hello-1",
            project_key="default",
            timestamp_ms=timestamp_ms,
            nonce=nonce,
        ),
    }
    try:
        async with websockets.connect(adapter.ws_url) as ws:
            await ws.send(json.dumps({"type": "hello", "request_id": "hello-1", "device_id": "iphone", "project_key": "default", "payload": payload}))
            ok = json.loads(await asyncio.wait_for(ws.recv(), timeout=2))
            assert ok["type"] == "hello"
        async with websockets.connect(adapter.ws_url) as ws:
            await ws.send(json.dumps({"type": "hello", "request_id": "hello-1", "device_id": "iphone", "project_key": "default", "payload": payload}))
            replay = json.loads(await asyncio.wait_for(ws.recv(), timeout=2))
            assert replay["type"] == "error"
            assert replay["payload"]["code"] == "auth_failed"
    finally:
        await adapter.disconnect()


def test_connect_refuses_wildcard_bind_without_explicit_override(tmp_path, monkeypatch):
    monkeypatch.delenv("LOGOS_ALLOW_UNSAFE_BIND", raising=False)
    adapter = LogosAdapter(
        PlatformConfig(enabled=True, extra={"host": "0.0.0.0", "port": 0, "store_path": str(tmp_path / "logos.db")})
    )
    assert LogosAdapter._is_safe_bind_host("0.0.0.0") is False
    assert asyncio.run(adapter.connect()) is False


def test_safe_bind_allows_private_and_tailscale_hostnames(monkeypatch):
    def fake_getaddrinfo(host, port, proto=0):
        assert host == "ryans-mac-studio"
        return [
            (socket.AF_INET, socket.SOCK_STREAM, proto, "", ("100.116.9.88", 0)),
            (socket.AF_INET, socket.SOCK_STREAM, proto, "", ("192.168.1.39", 0)),
        ]

    monkeypatch.setattr("logos.adapter.socket.getaddrinfo", fake_getaddrinfo)
    assert LogosAdapter._is_safe_bind_host("ryans-mac-studio") is True


def test_safe_bind_rejects_public_hostname(monkeypatch):
    def fake_getaddrinfo(host, port, proto=0):
        return [(socket.AF_INET, socket.SOCK_STREAM, proto, "", ("8.8.8.8", 0))]

    monkeypatch.setattr("logos.adapter.socket.getaddrinfo", fake_getaddrinfo)
    assert LogosAdapter._is_safe_bind_host("example.com") is False


@pytest.mark.asyncio
async def test_messages_batch_replays_pending_approval_after_reconnect(tmp_path):
    adapter = LogosAdapter(PlatformConfig(enabled=True, extra={"store_path": str(tmp_path / "logos.db")}))
    await adapter.send_exec_approval(
        chat_id="project:alpha",
        command="python manage.py migrate",
        session_key="agent:main:logos:dm:project:alpha",
        description="May modify DB",
        metadata={"session_id": "project:alpha"},
    )

    response = adapter._handle_messages_get(
        Envelope(type="messages_get", request_id="get", device_id="iphone", project_key="alpha", payload={"after_server_seq": 0})
    )

    pending = response["payload"]["pending_interactions"]
    assert len(pending) == 1
    assert pending[0]["type"] == "approval_request"
    assert pending[0]["request_id"]
    assert pending[0]["payload"]["command_preview"] == "python manage.py migrate"


@pytest.mark.asyncio
async def test_final_user_text_is_mirrored_for_reconnect_delta(tmp_path):
    captured = []

    class Capturing(LogosAdapter):
        async def handle_message(self, event):  # type: ignore[override]
            captured.append(event)

    adapter = Capturing(PlatformConfig(enabled=True, extra={"store_path": str(tmp_path / "logos.db")}))
    await adapter.handle_ws_envelope(
        Envelope(
            type="text_input",
            request_id="r1",
            device_id="iphone",
            project_key="alpha",
            payload={"text": "please check the repo status", "client_msg_id": "client-hello", "is_final": True},
        )
    )

    batch = adapter._handle_messages_get(
        Envelope(type="messages_get", request_id="get", device_id="iphone", project_key="alpha", payload={"after_server_seq": 0})
    )
    assert captured[-1].text == "please check the repo status"
    assert [message["content"] for message in batch["payload"]["messages"]] == ["please check the repo status"]
    assert batch["payload"]["messages"][0]["message_id"] == "client-hello"


@pytest.mark.asyncio
async def test_pending_interaction_frames_do_not_expose_gateway_session_key(tmp_path):
    class CapturingServer:
        def __init__(self):
            self.frames = []

        async def broadcast(self, frame, *, project_key=None):
            self.frames.append({"frame": frame, "project_key": project_key})

    adapter = LogosAdapter(PlatformConfig(enabled=True, extra={"store_path": str(tmp_path / "logos.db")}))
    server = CapturingServer()
    adapter.ws_server = server  # type: ignore[assignment]

    approval = await adapter.send_exec_approval(
        chat_id="project:alpha",
        command="python manage.py migrate",
        session_key="agent:main:logos:dm:project:alpha:approval-secret",
        description="May modify DB",
        metadata={"session_id": "project:alpha", "approval_id": "approval-secret-test"},
    )
    clarification = await adapter.send_clarify(
        chat_id="project:alpha",
        question="Which target?",
        choices=["staging", "prod"],
        clarify_id="clarify-secret-test",
        session_key="agent:main:logos:dm:project:alpha:clarify-secret",
        metadata={"session_id": "project:alpha"},
    )

    assert "session_key" not in approval.raw_response["payload"]
    assert "session_key" not in clarification.raw_response["payload"]
    for item in server.frames:
        assert "session_key" not in item["frame"].get("payload", {})

    assert adapter.store.get_pending_interaction("approval-secret-test").payload["session_key"].endswith("approval-secret")
    assert adapter.store.get_pending_interaction("clarify-secret-test").payload["session_key"].endswith("clarify-secret")

    replay = adapter._handle_messages_get(
        Envelope(type="messages_get", request_id="get-pending", device_id="iphone", project_key="alpha", payload={"after_server_seq": 0})
    )
    for pending in replay["payload"]["pending_interactions"]:
        assert "session_key" not in pending["payload"]


@pytest.mark.asyncio
async def test_unscoped_signed_hello_does_not_receive_other_project_broadcasts(tmp_path):
    adapter = LogosAdapter(
        PlatformConfig(enabled=True, extra={"device_secret": "dev-secret", "host": "127.0.0.1", "port": 0, "store_path": str(tmp_path / "logos.db")})
    )
    adapter.store.set_active_project(device_id="iphone", project_key="alpha")
    adapter.store.append_message(
        project_key="alpha",
        session_id="project:alpha",
        message_id="alpha-private-replay",
        role="assistant",
        content="Alpha private replay must not be sent to unscoped hello.",
    )
    assert await adapter.connect() is True
    timestamp_ms = int(time.time() * 1000)
    nonce = "nonce-unscoped-project-123"
    try:
        async with websockets.connect(adapter.ws_url) as ws:
            await ws.send(
                json.dumps(
                    {
                        "type": "hello",
                        "request_id": "hello-unscoped",
                        "device_id": "iphone",
                        "payload": {
                            "timestamp_ms": timestamp_ms,
                            "nonce": nonce,
                            "after_server_seq": 0,
                            "signature": sign_hello(
                                "dev-secret",
                                device_id="iphone",
                                request_id="hello-unscoped",
                                project_key=None,
                                timestamp_ms=timestamp_ms,
                                nonce=nonce,
                            ),
                        },
                    }
                )
            )
            hello = json.loads(await asyncio.wait_for(ws.recv(), timeout=2))
            assert hello["type"] == "hello"
            assert hello["project_key"] == "default"

            try:
                replay = json.loads(await asyncio.wait_for(ws.recv(), timeout=0.2))
            except asyncio.TimeoutError:
                replay = None
            if replay is not None:
                assert replay["type"] == "messages_batch"
                assert replay["project_key"] == "default"
                assert "Alpha private replay" not in json.dumps(replay)

            await adapter.ws_server.broadcast(
                {"type": "run_status", "project_key": "alpha", "payload": {"status": "running"}},
                project_key="alpha",
            )
            with pytest.raises(asyncio.TimeoutError):
                await asyncio.wait_for(ws.recv(), timeout=0.2)
    finally:
        await adapter.disconnect()


@pytest.mark.asyncio
async def test_signed_hello_ignores_unsigned_payload_project_key(tmp_path):
    adapter = LogosAdapter(
        PlatformConfig(enabled=True, extra={"device_secret": "dev-secret", "host": "127.0.0.1", "port": 0, "store_path": str(tmp_path / "logos.db")})
    )
    adapter.store.append_message(
        project_key="alpha",
        session_id="project:alpha",
        message_id="alpha-private-payload-scope",
        role="assistant",
        content="Alpha private replay must not be selected by unsigned payload project_key.",
    )
    assert await adapter.connect() is True
    timestamp_ms = int(time.time() * 1000)
    nonce = "nonce-unsigned-payload-project-123"
    try:
        async with websockets.connect(adapter.ws_url) as ws:
            await ws.send(
                json.dumps(
                    {
                        "type": "hello",
                        "request_id": "hello-payload-project",
                        "device_id": "iphone",
                        "payload": {
                            "project_key": "alpha",
                            "timestamp_ms": timestamp_ms,
                            "nonce": nonce,
                            "after_server_seq": 0,
                            "signature": sign_hello(
                                "dev-secret",
                                device_id="iphone",
                                request_id="hello-payload-project",
                                project_key=None,
                                timestamp_ms=timestamp_ms,
                                nonce=nonce,
                            ),
                        },
                    }
                )
            )
            hello = json.loads(await asyncio.wait_for(ws.recv(), timeout=2))
            assert hello["type"] == "hello"
            assert hello["project_key"] == "default"

            try:
                replay = json.loads(await asyncio.wait_for(ws.recv(), timeout=0.2))
            except asyncio.TimeoutError:
                replay = None
            if replay is not None:
                assert replay["type"] == "messages_batch"
                assert replay["project_key"] == "default"
                assert "Alpha private replay" not in json.dumps(replay)
    finally:
        await adapter.disconnect()


@pytest.mark.asyncio
async def test_run_cancel_resolves_pending_interactions_for_project(tmp_path):
    class CapturingLogosAdapter(LogosAdapter):
        def __init__(self, config: PlatformConfig):
            super().__init__(config)
            self.captured_text: list[str] = []

        async def handle_message(self, event):  # type: ignore[override]
            self.captured_text.append(event.text)

    adapter = CapturingLogosAdapter(
        PlatformConfig(enabled=True, extra={"device_secret": "dev-secret", "store_path": str(tmp_path / "logos.db")})
    )
    adapter.store.upsert_pending_interaction(
        request_id="approval-cancelled",
        kind="approval",
        project_key="alpha",
        session_id="project:alpha",
        frame_type="approval_request",
        payload={"approval_id": "approval-cancelled"},
        server_seq=1,
    )
    adapter.store.upsert_pending_interaction(
        request_id="clarify-cancelled",
        kind="clarification",
        project_key="alpha",
        session_id="project:alpha",
        frame_type="clarify_request",
        payload={"clarify_id": "clarify-cancelled"},
        server_seq=2,
    )
    adapter.store.upsert_pending_interaction(
        request_id="approval-beta",
        kind="approval",
        project_key="beta",
        session_id="project:beta",
        frame_type="approval_request",
        payload={"approval_id": "approval-beta"},
        server_seq=3,
    )

    response = await adapter.handle_ws_envelope(
        Envelope(type="run_cancel", request_id="cancel-alpha", device_id="iphone", project_key="alpha", payload={})
    )

    assert response["type"] == "run_status"
    assert response["payload"]["status"] == "idle"
    assert response["payload"]["cancelled"] is True
    assert adapter.captured_text == ["/stop"]
    assert adapter.store.list_pending_interactions("alpha") == []
    assert [item.request_id for item in adapter.store.list_pending_interactions("beta")] == ["approval-beta"]


@pytest.mark.asyncio
async def test_run_cancel_broadcasts_terminal_idle_after_stop(tmp_path):
    class CaptureServer:
        def __init__(self):
            self.frames: list[dict] = []

        async def broadcast(self, frame, *, project_key=None):
            self.frames.append(frame)

    adapter = LogosAdapter(
        PlatformConfig(enabled=True, extra={"device_secret": "dev-secret", "store_path": str(tmp_path / "logos.db")})
    )
    capture = CaptureServer()
    adapter.ws_server = capture  # type: ignore[assignment]

    dispatched: list[str] = []

    async def fake_dispatch(envelope, text_override=None, **kwargs):
        dispatched.append(text_override or envelope.payload.get("text"))
        return envelope.project_key or "default"

    adapter._dispatch_gateway_text = fake_dispatch  # type: ignore[method-assign]

    response = await adapter.handle_ws_envelope(
        Envelope(type="run_cancel", request_id="cancel-terminal", device_id="iphone", project_key="alpha", payload={})
    )

    assert dispatched == ["/stop"]
    assert [frame["payload"]["status"] for frame in capture.frames if frame["type"] == "run_status"] == ["cancelling", "idle"]
    assert response["type"] == "run_status"
    assert response["payload"]["status"] == "idle"
    assert response["payload"]["cancelled"] is True


@pytest.mark.asyncio
async def test_run_cancel_returns_terminal_error_when_stop_dispatch_fails(tmp_path):
    class CaptureServer:
        def __init__(self):
            self.frames: list[dict] = []

        async def broadcast(self, frame, *, project_key=None):
            self.frames.append(frame)

    adapter = LogosAdapter(
        PlatformConfig(enabled=True, extra={"device_secret": "dev-secret", "store_path": str(tmp_path / "logos.db")})
    )
    adapter.store.upsert_pending_interaction(
        request_id="approval-alpha-preserve",
        kind="approval",
        project_key="alpha",
        session_id="project:alpha",
        frame_type="approval_request",
        payload={"approval_id": "approval-alpha-preserve"},
        server_seq=10,
    )
    capture = CaptureServer()
    adapter.ws_server = capture  # type: ignore[assignment]

    async def failing_dispatch(envelope, text_override=None, **kwargs):
        raise RuntimeError("gateway unavailable: /Users/ryan/.hermes/secret-token")

    adapter._dispatch_gateway_text = failing_dispatch  # type: ignore[method-assign]

    response = await adapter.handle_ws_envelope(
        Envelope(type="run_cancel", request_id="cancel-terminal-error", device_id="iphone", project_key="alpha", payload={})
    )

    statuses = [frame["payload"]["status"] for frame in capture.frames if frame["type"] == "run_status"]
    assert statuses == ["cancelling", "error"]
    assert response["type"] == "run_status"
    assert response["payload"]["status"] == "error"
    assert response["payload"]["cancelled"] is False
    assert [item.request_id for item in adapter.store.list_pending_interactions("alpha")] == ["approval-alpha-preserve"]
    assert "secret-token" not in json.dumps(response)


@pytest.mark.asyncio
async def test_text_input_cannot_rebroadcast_cross_project_message_collision(tmp_path):
    class CaptureServer:
        def __init__(self):
            self.frames: list[dict] = []

        async def broadcast(self, frame, *, project_key=None):
            self.frames.append(frame)

    adapter = LogosAdapter(
        PlatformConfig(enabled=True, extra={"device_secret": "dev-secret", "store_path": str(tmp_path / "logos.db")})
    )
    capture = CaptureServer()
    adapter.ws_server = capture  # type: ignore[assignment]
    adapter.store.append_message(
        project_key="beta",
        session_id="project:beta",
        message_id="shared-client-id",
        role="assistant",
        content="Beta private content must not leak",
    )

    dispatched: list[str] = []

    async def fake_handle_message(event):
        dispatched.append(event.text)

    adapter.handle_message = fake_handle_message  # type: ignore[method-assign]

    await adapter.handle_ws_envelope(
        Envelope(
            type="text_input",
            request_id="alpha-collision",
            device_id="iphone",
            project_key="alpha",
            session_id="project:beta",
            payload={"text": "check the alpha logs", "client_msg_id": "shared-client-id"},
        )
    )

    serialized_frames = json.dumps(capture.frames)
    user_frames = [
        frame
        for frame in capture.frames
        if frame["type"] == "state_update"
        and frame["payload"].get("op") == "message_appended"
        and frame["payload"]["message"]["role"] == "user"
    ]
    assert dispatched == ["check the alpha logs"]
    assert len(user_frames) == 1
    assert user_frames[0]["payload"]["message"]["project_key"] == "alpha"
    assert user_frames[0]["payload"]["message"]["session_id"] == "project:alpha"
    assert user_frames[0]["payload"]["message"]["content"] == "check the alpha logs"
    assert "Beta private content must not leak" not in serialized_frames


@pytest.mark.asyncio
async def test_fast_cancel_intent_mirrors_user_message_before_stop(tmp_path):
    class CaptureServer:
        def __init__(self):
            self.frames: list[dict] = []

        async def broadcast(self, frame, *, project_key=None):
            self.frames.append(frame)

    adapter = LogosAdapter(
        PlatformConfig(enabled=True, extra={"device_secret": "dev-secret", "store_path": str(tmp_path / "logos.db")})
    )
    capture = CaptureServer()
    adapter.ws_server = capture  # type: ignore[assignment]

    dispatched: list[str] = []

    async def fake_dispatch(envelope, text_override=None, **kwargs):
        dispatched.append(text_override or envelope.payload.get("text"))
        return envelope.project_key or "default"

    adapter._dispatch_gateway_text = fake_dispatch  # type: ignore[method-assign]

    await adapter.handle_ws_envelope(
        Envelope(
            type="text_input",
            request_id="req-fast-stop",
            device_id="iphone",
            project_key="alpha",
            payload={"text": "stop", "client_msg_id": "client-stop"},
        )
    )

    user_frames = [
        frame
        for frame in capture.frames
        if frame["type"] == "state_update"
        and frame["payload"].get("op") == "message_appended"
        and frame["payload"]["message"]["role"] == "user"
    ]
    assert dispatched == ["/stop"]
    assert len(user_frames) == 1
    assert user_frames[0]["payload"]["message"]["message_id"] == "client-stop"
    assert user_frames[0]["payload"]["message"]["content"] == "stop"
    assert [frame["payload"]["status"] for frame in capture.frames if frame["type"] == "run_status"] == ["cancelling", "idle"]


def test_messages_get_before_anchor_cannot_cross_project_sessions(tmp_path):
    adapter = LogosAdapter(PlatformConfig(enabled=True, extra={"store_path": str(tmp_path / "logos.db")}))
    adapter.store.append_message(
        project_key="beta",
        session_id="project:beta",
        message_id="beta-1",
        role="assistant",
        content="Beta private message one",
    )
    adapter.store.append_message(
        project_key="beta",
        session_id="project:beta",
        message_id="beta-2",
        role="assistant",
        content="Beta private message two",
    )

    response = adapter._handle_messages_get(
        Envelope(
            type="messages_get",
            request_id="get-cross-project-before",
            device_id="iphone",
            project_key="alpha",
            payload={"session_id": "project:beta", "before_message_id": "beta-2", "limit": 10},
        )
    )

    assert response["payload"]["messages"] == []


@pytest.mark.asyncio
async def test_websocket_internal_error_does_not_echo_exception_details(tmp_path):
    adapter = LogosAdapter(
        PlatformConfig(enabled=True, extra={"device_secret": "dev-secret", "host": "127.0.0.1", "port": 0, "store_path": str(tmp_path / "logos.db")})
    )

    async def boom(envelope):
        raise RuntimeError("leaked /Users/ryan/.hermes/secret-token")

    adapter.handle_ws_envelope = boom  # type: ignore[method-assign]
    assert await adapter.connect() is True
    timestamp_ms = int(time.time() * 1000)
    nonce = "nonce-internal-error-123"
    try:
        async with websockets.connect(adapter.ws_url) as ws:
            await ws.send(
                json.dumps(
                    {
                        "type": "hello",
                        "request_id": "hello-internal-error",
                        "device_id": "iphone",
                        "project_key": "default",
                        "payload": {
                            "timestamp_ms": timestamp_ms,
                            "nonce": nonce,
                            "signature": sign_hello(
                                "dev-secret",
                                device_id="iphone",
                                request_id="hello-internal-error",
                                project_key="default",
                                timestamp_ms=timestamp_ms,
                                nonce=nonce,
                            ),
                        },
                    }
                )
            )
            hello = json.loads(await asyncio.wait_for(ws.recv(), timeout=2))
            assert hello["type"] == "hello"
            await ws.send(json.dumps({"type": "text_input", "request_id": "boom", "device_id": "iphone", "project_key": "default", "payload": {"text": "boom"}}))
            response = json.loads(await asyncio.wait_for(ws.recv(), timeout=2))
            assert response["type"] == "error"
            assert response["payload"]["code"] == "internal_error"
            assert response["payload"]["message"] == "Logos adapter internal error."
            assert "secret-token" not in json.dumps(response)
            assert "/Users/ryan" not in json.dumps(response)
    finally:
        await adapter.disconnect()
