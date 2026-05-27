from __future__ import annotations

import asyncio
import json
import time

import pytest

from gateway.config import PlatformConfig
from logos.adapter import LogosAdapter
from logos.apns import (
    APNSClient,
    APNSConfig,
    APNSSendResult,
    PrivateNotificationKind,
    apns_host_for_environment,
    build_private_apns_payload,
)
from logos.schema import Envelope


def adapter_for(tmp_path):
    return LogosAdapter(
        PlatformConfig(
            enabled=True,
            extra={"device_secret": "test-secret", "store_path": str(tmp_path / "logos.db")},
        )
    )


def walk_strings(value):
    if isinstance(value, dict):
        for item in value.values():
            yield from walk_strings(item)
    elif isinstance(value, list):
        for item in value:
            yield from walk_strings(item)
    elif isinstance(value, str):
        yield value


class RecordingAPNSClient:
    def __init__(self):
        self.config = APNSConfig(key_id="key", team_id="team", bundle_id="dev.logos.app", auth_key_path="/tmp/AuthKey.p8")
        self.sent = []

    async def send(self, device_token, payload, *, environment=None):
        self.sent.append({"device_token": device_token, "payload": payload, "environment": environment})
        return APNSSendResult(
            success=True,
            status=200,
            apns_id=f"apns-{len(self.sent)}",
            environment=environment,
            host=apns_host_for_environment(environment),
            http_version="HTTP/2",
        )


class RecordingHTTP2Client:
    def __init__(self, response=None, exc=None):
        self.response = response
        self.exc = exc
        self.requests = []
        self.closed = False

    async def post(self, path, *, content=None, headers=None):
        self.requests.append({"path": path, "content": content, "headers": dict(headers or {})})
        if self.exc is not None:
            raise self.exc
        return self.response

    async def aclose(self):
        self.closed = True


class RecordingHTTP2ClientFactory:
    def __init__(self, *clients):
        self.clients = list(clients)
        self.calls = []

    def __call__(self, *, host, timeout, http2):
        self.calls.append({"host": host, "timeout": timeout, "http2": http2})
        assert self.clients
        return self.clients.pop(0)


class FakeHTTPResponse:
    def __init__(self, status_code, *, json_body=None, text="", headers=None, http_version="HTTP/2", reason_phrase=""):
        self.status_code = status_code
        self._json_body = json_body
        self.text = text
        self.headers = dict(headers or {})
        self.http_version = http_version
        self.reason_phrase = reason_phrase
        if json_body is not None:
            self.content = json.dumps(json_body).encode("utf-8")
        else:
            self.content = text.encode("utf-8")

    def json(self):
        if self._json_body is None:
            raise ValueError("not json")
        return self._json_body


class FakeConnectTimeout(Exception):
    pass


def test_private_completion_payload_contains_only_routing_ids():
    payload = build_private_apns_payload(
        PrivateNotificationKind.FINISHED,
        project_key="archwright-phase-6",
        session_id="session-1",
        message_id="msg-42",
        server_seq=982,
        sensitive_context={"summary": "SECRET answer /path/to/private.txt", "command": "rm -rf nope"},
    )

    assert payload["aps"]["alert"]["title"] == "Hermes finished"
    assert payload["aps"]["alert"]["body"] == "Open Logos to view the result."
    assert payload["project_key"] == "archwright-phase-6"
    assert payload["session_id"] == "session-1"
    assert payload["message_id"] == "msg-42"
    assert payload["server_seq"] == 982
    all_text = "\n".join(walk_strings(payload))
    assert "SECRET" not in all_text
    assert "private.txt" not in all_text
    assert "rm -rf" not in all_text


def test_private_approval_and_clarification_payloads_do_not_include_details():
    approval = build_private_apns_payload(
        PrivateNotificationKind.APPROVAL,
        project_key="default",
        request_id="appr-1",
        sensitive_context={"command_preview": "python dangerous.py --token abc"},
    )
    clarify = build_private_apns_payload(
        PrivateNotificationKind.CLARIFICATION,
        project_key="default",
        request_id="clar-1",
        sensitive_context={"question": "Which secret branch?"},
    )

    assert approval["aps"]["alert"]["title"] == "Hermes needs approval"
    assert approval["kind"] == "approval"
    assert approval["request_id"] == "appr-1"
    assert "dangerous.py" not in "\n".join(walk_strings(approval))
    assert clarify["aps"]["alert"]["title"] == "Hermes needs clarification"
    assert clarify["kind"] == "clarification"
    assert clarify["request_id"] == "clar-1"
    assert "secret branch" not in "\n".join(walk_strings(clarify))


def test_register_device_persists_token_without_echoing_secret_token(tmp_path):
    adapter = adapter_for(tmp_path)
    frame = asyncio.run(
        adapter.handle_ws_envelope(
            Envelope(
                type="register_device",
                request_id="reg-1",
                device_id="iphone-test",
                payload={
                    "display_name": "Test iPhone",
                    "apns_token": "abcdef123456",
                    "apns_environment": "sandbox",
                    "capabilities": ["text", "speech", "notifications"],
                },
            )
        )
    )

    assert frame["type"] == "registered"
    assert frame["request_id"] == "reg-1"
    assert frame["payload"]["device"]["device_id"] == "iphone-test"
    assert frame["payload"]["device"]["apns_registered"] is True
    assert "abcdef123456" not in str(frame)

    stored = adapter.store.get_device("iphone-test")
    assert stored is not None
    assert stored.apns_token == "abcdef123456"
    assert stored.capabilities == ["text", "speech", "notifications"]


@pytest.mark.asyncio
async def test_apns_client_skips_live_send_when_credentials_absent():
    client = APNSClient(APNSConfig())
    result = await client.send("token", {"aps": {"alert": {"title": "Hermes finished"}}})
    assert result.skipped is True
    assert result.success is False
    assert result.reason == "missing_credentials"


def test_apns_host_resolves_per_environment():
    assert apns_host_for_environment("sandbox") == "api.sandbox.push.apple.com"
    assert apns_host_for_environment(None) == "api.sandbox.push.apple.com"
    assert apns_host_for_environment("production") == "api.push.apple.com"


@pytest.mark.asyncio
async def test_apns_client_uses_http2_and_returns_success_metadata():
    response = FakeHTTPResponse(
        200,
        headers={"apns-id": "apns-success"},
    )
    http_client = RecordingHTTP2Client(response=response)
    factory = RecordingHTTP2ClientFactory(http_client)
    client = APNSClient(
        APNSConfig(
            key_id="key",
            team_id="team",
            bundle_id="dev.logos.app",
            auth_key_path="/tmp/AuthKey.p8",
            timeout_seconds=7.0,
        ),
        http_client_factory=factory,
    )
    client._jwt = "signed-provider-token"
    client._jwt_created_at = time.time()

    result = await client.send("device-token", {"aps": {"alert": {"title": "Hermes finished"}}}, environment="production")

    assert factory.calls == [{"host": "api.push.apple.com", "timeout": 7.0, "http2": True}]
    assert http_client.requests[0]["path"] == "/3/device/device-token"
    assert json.loads(http_client.requests[0]["content"]) == {"aps": {"alert": {"title": "Hermes finished"}}}
    headers = http_client.requests[0]["headers"]
    assert headers["authorization"] == "bearer signed-provider-token"
    assert headers["apns-topic"] == "dev.logos.app"
    assert headers["apns-push-type"] == "alert"
    assert headers["apns-priority"] == "10"
    assert result.success is True
    assert result.status == 200
    assert result.apns_id == "apns-success"
    assert result.environment == "production"
    assert result.host == "api.push.apple.com"
    assert result.http_version == "HTTP/2"


@pytest.mark.asyncio
async def test_apns_client_preserves_error_reason_and_temporary_status():
    bad_token_response = FakeHTTPResponse(
        400,
        json_body={"reason": "BadDeviceToken"},
        headers={"apns-id": "apns-bad-token"},
    )
    throttled_response = FakeHTTPResponse(
        429,
        json_body={"reason": "TooManyRequests"},
        headers={"apns-id": "apns-throttled"},
    )
    factory = RecordingHTTP2ClientFactory(
        RecordingHTTP2Client(response=bad_token_response),
        RecordingHTTP2Client(response=throttled_response),
    )
    client = APNSClient(
        APNSConfig(key_id="key", team_id="team", bundle_id="dev.logos.app", auth_key_path="/tmp/AuthKey.p8"),
        http_client_factory=factory,
    )
    client._jwt = "signed-provider-token"
    client._jwt_created_at = time.time()

    bad_token = await client.send("bad-token", {"aps": {"alert": {"title": "Hermes finished"}}}, environment="sandbox")
    throttled = await client.send("ok-token", {"aps": {"alert": {"title": "Hermes finished"}}}, environment="production")

    assert bad_token.success is False
    assert bad_token.status == 400
    assert bad_token.reason == "BadDeviceToken"
    assert bad_token.temporary_failure is False
    assert throttled.success is False
    assert throttled.status == 429
    assert throttled.reason == "TooManyRequests"
    assert throttled.temporary_failure is True


@pytest.mark.asyncio
async def test_apns_client_closes_clients_and_clears_jwt_after_provider_token_error():
    response = FakeHTTPResponse(
        403,
        json_body={"reason": "ExpiredProviderToken"},
    )
    http_client = RecordingHTTP2Client(response=response)
    client = APNSClient(
        APNSConfig(key_id="key", team_id="team", bundle_id="dev.logos.app", auth_key_path="/tmp/AuthKey.p8"),
        http_client_factory=RecordingHTTP2ClientFactory(http_client),
    )
    client._jwt = "expired-provider-token"
    client._jwt_created_at = time.time()

    result = await client.send("device-token", {"aps": {"alert": {"title": "Hermes finished"}}})

    assert result.status == 403
    assert result.reason == "ExpiredProviderToken"
    assert client._jwt is None
    assert http_client.closed is True


@pytest.mark.asyncio
async def test_apns_client_marks_transport_errors_temporary():
    http_client = RecordingHTTP2Client(exc=FakeConnectTimeout("timed out"))
    client = APNSClient(
        APNSConfig(key_id="key", team_id="team", bundle_id="dev.logos.app", auth_key_path="/tmp/AuthKey.p8"),
        http_client_factory=RecordingHTTP2ClientFactory(http_client),
    )
    client._jwt = "signed-provider-token"
    client._jwt_created_at = time.time()

    result = await client.send("device-token", {"aps": {"alert": {"title": "Hermes finished"}}})

    assert result.success is False
    assert result.reason == "FakeConnectTimeout"
    assert result.temporary_failure is True


@pytest.mark.asyncio
async def test_final_send_pushes_private_completion_to_notification_capable_devices(tmp_path):
    adapter = adapter_for(tmp_path)
    recorder = RecordingAPNSClient()
    adapter.apns = recorder
    adapter.store.upsert_device(
        device_id="iphone-sandbox",
        apns_token="sandbox-token",
        apns_environment="sandbox",
        capabilities=["text", "notifications"],
    )
    adapter.store.upsert_device(
        device_id="iphone-production",
        apns_token="production-token",
        apns_environment="production",
        capabilities=["notifications"],
    )
    adapter.store.upsert_device(
        device_id="iphone-no-notifications",
        apns_token="no-notifications-token",
        apns_environment="sandbox",
        capabilities=["text"],
    )
    adapter.store.upsert_device(
        device_id="iphone-no-token",
        apns_environment="sandbox",
        capabilities=["notifications"],
    )

    result = await adapter.send(
        "project:default",
        "Sensitive final response with /private/path.txt",
        metadata={"session_id": "session-push", "request_id": "req-push"},
    )

    assert result.success is True
    assert [(item["device_token"], item["environment"]) for item in recorder.sent] == [
        ("production-token", "production"),
        ("sandbox-token", "sandbox"),
    ]
    for item in recorder.sent:
        payload = item["payload"]
        assert payload["kind"] == "finished"
        assert payload["project_key"] == "default"
        assert payload["session_id"] == "session-push"
        assert payload["message_id"] == result.message_id
        assert payload["request_id"] == "req-push"
        assert isinstance(payload["server_seq"], int)
        all_text = "\n".join(walk_strings(payload))
        assert "Sensitive final response" not in all_text
        assert "private/path" not in all_text


@pytest.mark.asyncio
async def test_finalized_edit_pushes_private_completion(tmp_path):
    adapter = adapter_for(tmp_path)
    recorder = RecordingAPNSClient()
    adapter.apns = recorder
    adapter.store.upsert_device(
        device_id="iphone-sandbox",
        apns_token="sandbox-token",
        apns_environment="sandbox",
        capabilities=["notifications"],
    )
    sent = await adapter.send("project:default", "Draft response.", metadata={"session_id": "session-edit-push", "request_id": "req-edit-push"})
    recorder.sent.clear()

    edited = await adapter.edit_message(
        "project:default",
        sent.message_id,
        "Sensitive finalized edit response.",
        finalize=True,
    )

    assert edited.success is True
    assert len(recorder.sent) == 1
    payload = recorder.sent[0]["payload"]
    assert payload["kind"] == "finished"
    assert payload["message_id"] == sent.message_id
    assert payload["session_id"] == "session-edit-push"
    assert payload["request_id"] == "req-edit-push"
    assert "Sensitive finalized edit" not in "\n".join(walk_strings(payload))


@pytest.mark.asyncio
async def test_invalid_apns_token_is_cleared_without_revoking_device(tmp_path):
    class BadTokenAPNSClient:
        config = APNSConfig(key_id="key", team_id="team", bundle_id="dev.logos.app", auth_key_path="/tmp/AuthKey.p8")

        async def send(self, device_token, payload, *, environment=None):
            return APNSSendResult(
                success=False,
                status=400,
                reason="BadDeviceToken",
                environment=environment,
                host=apns_host_for_environment(environment),
                http_version="HTTP/2",
            )

    adapter = adapter_for(tmp_path)
    adapter.apns = BadTokenAPNSClient()
    adapter.store.upsert_device(
        device_id="iphone-sandbox",
        apns_token="bad-token",
        apns_environment="sandbox",
        capabilities=["notifications"],
    )

    result = await adapter.send("project:default", "Final response.", metadata={"session_id": "session-bad-token"})

    assert result.success is True
    stored = adapter.store.get_device("iphone-sandbox")
    assert stored is not None
    assert stored.apns_token is None
    assert stored.apns_environment is None
    assert stored.revoked_at is None


@pytest.mark.asyncio
async def test_temporary_apns_failure_does_not_fail_final_send_or_clear_token(tmp_path):
    class TemporaryFailureAPNSClient:
        config = APNSConfig(key_id="key", team_id="team", bundle_id="dev.logos.app", auth_key_path="/tmp/AuthKey.p8")

        async def send(self, device_token, payload, *, environment=None):
            return APNSSendResult(
                success=False,
                status=500,
                reason="InternalServerError",
                temporary_failure=True,
                environment=environment,
                host=apns_host_for_environment(environment),
                http_version="HTTP/2",
            )

    adapter = adapter_for(tmp_path)
    adapter.apns = TemporaryFailureAPNSClient()
    adapter.store.upsert_device(
        device_id="iphone-sandbox",
        apns_token="still-valid-token",
        apns_environment="sandbox",
        capabilities=["notifications"],
    )

    result = await adapter.send("project:default", "Final response.", metadata={"session_id": "session-temp-failure"})

    assert result.success is True
    stored = adapter.store.get_device("iphone-sandbox")
    assert stored is not None
    assert stored.apns_token == "still-valid-token"
    assert stored.revoked_at is None


@pytest.mark.asyncio
async def test_apns_client_exception_does_not_fail_final_send_or_clear_token(tmp_path):
    class RaisingAPNSClient:
        config = APNSConfig(key_id="key", team_id="team", bundle_id="dev.logos.app", auth_key_path="/tmp/AuthKey.p8")

        async def send(self, device_token, payload, *, environment=None):
            raise RuntimeError("transport exploded")

    adapter = adapter_for(tmp_path)
    adapter.apns = RaisingAPNSClient()
    adapter.store.upsert_device(
        device_id="iphone-sandbox",
        apns_token="still-valid-token",
        apns_environment="sandbox",
        capabilities=["notifications"],
    )

    result = await adapter.send("project:default", "Final response.", metadata={"session_id": "session-apns-raise"})

    assert result.success is True
    stored = adapter.store.get_device("iphone-sandbox")
    assert stored is not None
    assert stored.apns_token == "still-valid-token"
    assert stored.revoked_at is None


@pytest.mark.asyncio
async def test_approval_and_clarification_publish_private_notifications(tmp_path):
    adapter = adapter_for(tmp_path)
    recorder = RecordingAPNSClient()
    adapter.apns = recorder
    adapter.store.upsert_device(
        device_id="iphone-sandbox",
        apns_token="sandbox-token",
        apns_environment="sandbox",
        capabilities=["notifications"],
    )

    await adapter.send_clarify(
        "project:default",
        question="Which secret branch should I use?",
        choices=["private-a", "private-b"],
        clarify_id="clarify-1",
        session_key="secret-session-key",
        metadata={"session_id": "session-interaction-push"},
    )
    await adapter.send_exec_approval(
        "project:default",
        command="python dangerous.py --token abc",
        session_key="secret-session-key",
        description="Dangerous command",
        metadata={"approval_id": "approval-1", "session_id": "session-interaction-push"},
    )

    assert [item["payload"]["kind"] for item in recorder.sent] == ["clarification", "approval"]
    assert recorder.sent[0]["payload"]["request_id"] == "clarify-1"
    assert isinstance(recorder.sent[0]["payload"]["server_seq"], int)
    assert recorder.sent[1]["payload"]["request_id"] == "approval-1"
    assert isinstance(recorder.sent[1]["payload"]["server_seq"], int)
    all_text = "\n".join(walk_strings([item["payload"] for item in recorder.sent]))
    assert "secret branch" not in all_text
    assert "private-a" not in all_text
    assert "dangerous.py" not in all_text
    assert "secret-session-key" not in all_text
