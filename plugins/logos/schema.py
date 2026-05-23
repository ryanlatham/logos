from __future__ import annotations

import json
from dataclasses import dataclass, field
from typing import Any, Mapping, MutableMapping


class ProtocolError(ValueError):
    """Raised when a Logos WebSocket frame violates the Stage B envelope."""


CLIENT_FRAME_TYPES: set[str] = {
    "hello",
    "register_device",
    "app_focus_change",
    "speech",
    "text_input",
    "text_message",
    "switch_project",
    "list_projects",
    "new_project",
    "rename_project",
    "messages_get",
    "playback_audio",
    "approval_response",
    "clarify_response",
    "run_cancel",
    "heartbeat",
    "pair",
}

SERVER_FRAME_TYPES: set[str] = {
    "hello",
    "registered",
    "pairing_complete",
    "projects_list",
    "messages_batch",
    "state_update",
    "run_status",
    "playback_audio",
    "audio_chunk",
    "audio_end",
    "approval_request",
    "clarify_request",
    "tool_progress",
    "error",
    "heartbeat_ack",
}


def protocol_json_schema() -> dict[str, Any]:
    """Return the Swift-compatible common envelope JSON Schema."""
    return {
        "$schema": "https://json-schema.org/draft/2020-12/schema",
        "$id": "https://logos.local/protocol/envelope.schema.json",
        "title": "LogosEnvelope",
        "type": "object",
        "additionalProperties": False,
        "required": ["type", "payload"],
        "properties": {
            "type": {"type": "string", "enum": sorted(CLIENT_FRAME_TYPES | SERVER_FRAME_TYPES)},
            "request_id": {"type": ["string", "null"]},
            "device_id": {"type": ["string", "null"]},
            "project_key": {"type": ["string", "null"]},
            "session_id": {"type": ["string", "null"]},
            "server_seq": {"type": ["integer", "null"], "minimum": 0},
            "payload": {"type": "object", "additionalProperties": True},
        },
    }


@dataclass(frozen=True)
class Envelope:
    type: str
    request_id: str | None = None
    device_id: str | None = None
    project_key: str | None = None
    session_id: str | None = None
    server_seq: int | None = None
    payload: dict[str, Any] = field(default_factory=dict)

    @classmethod
    def from_dict(cls, data: Mapping[str, Any]) -> "Envelope":
        msg_type = data.get("type")
        if not isinstance(msg_type, str) or not msg_type.strip():
            raise ProtocolError("frame type is required")

        payload = data.get("payload", {})
        if payload is None:
            payload = {}
        if not isinstance(payload, dict):
            raise ProtocolError("payload must be an object")

        server_seq = data.get("server_seq")
        if server_seq is not None and not isinstance(server_seq, int):
            raise ProtocolError("server_seq must be an integer when present")

        return cls(
            type=msg_type.strip(),
            request_id=_optional_str(data.get("request_id"), "request_id"),
            device_id=_optional_str(data.get("device_id"), "device_id"),
            project_key=_optional_str(data.get("project_key"), "project_key"),
            session_id=_optional_str(data.get("session_id"), "session_id"),
            server_seq=server_seq,
            payload=dict(payload),
        )

    def to_dict(self) -> dict[str, Any]:
        result: dict[str, Any] = {"type": self.type, "payload": self.payload}
        if self.request_id is not None:
            result["request_id"] = self.request_id
        if self.device_id is not None:
            result["device_id"] = self.device_id
        if self.project_key is not None:
            result["project_key"] = self.project_key
        if self.session_id is not None:
            result["session_id"] = self.session_id
        if self.server_seq is not None:
            result["server_seq"] = self.server_seq
        return result


def _optional_str(value: Any, field_name: str) -> str | None:
    if value is None:
        return None
    if not isinstance(value, str):
        raise ProtocolError(f"{field_name} must be a string when present")
    return value


def parse_frame(raw: str | bytes | bytearray | Mapping[str, Any]) -> Envelope:
    if isinstance(raw, Mapping):
        data = raw
    else:
        try:
            data = json.loads(raw)
        except json.JSONDecodeError as exc:
            raise ProtocolError(f"invalid JSON: {exc.msg}") from exc
    if not isinstance(data, dict):
        raise ProtocolError("frame must be a JSON object")
    return Envelope.from_dict(data)


def serialize_frame(frame: Envelope | Mapping[str, Any]) -> str:
    if isinstance(frame, Envelope):
        data = frame.to_dict()
    else:
        data = dict(frame)
    return json.dumps(redact_secrets(data), ensure_ascii=False, separators=(",", ":"))


def error_frame(
    code: str,
    message: str,
    *,
    request_id: str | None = None,
    device_id: str | None = None,
    project_key: str | None = None,
    raw: Any = None,
) -> dict[str, Any]:
    redacted_raw = redact_secrets(raw)
    redacted_message = _redact_message_with_raw_values(message, raw)
    payload: dict[str, Any] = {"code": code, "message": redacted_message}
    if redacted_raw is not None:
        payload["raw"] = redacted_raw
    frame: dict[str, Any] = {"type": "error", "payload": payload}
    if request_id:
        frame["request_id"] = request_id
    if device_id:
        frame["device_id"] = device_id
    if project_key:
        frame["project_key"] = project_key
    return frame


def redact_secrets(value: Any) -> Any:
    if isinstance(value, Mapping):
        result: MutableMapping[str, Any] = {}
        for key, item in value.items():
            key_s = str(key)
            if _is_secret_key(key_s):
                result[key_s] = "[REDACTED]"
            else:
                result[key_s] = redact_secrets(item)
        return dict(result)
    if isinstance(value, list):
        return [redact_secrets(item) for item in value]
    if isinstance(value, tuple):
        return tuple(redact_secrets(item) for item in value)
    return value


def _is_secret_key(key: str) -> bool:
    lowered = key.lower()
    return any(marker in lowered for marker in ("secret", "token", "password", "auth_key", "api_key"))


def _secret_values(value: Any) -> list[str]:
    found: list[str] = []
    if isinstance(value, Mapping):
        for key, item in value.items():
            if _is_secret_key(str(key)) and isinstance(item, str) and item:
                found.append(item)
            else:
                found.extend(_secret_values(item))
    elif isinstance(value, (list, tuple)):
        for item in value:
            found.extend(_secret_values(item))
    return found


def _redact_message_with_raw_values(message: str, raw: Any) -> str:
    redacted = message
    for secret in _secret_values(raw):
        redacted = redacted.replace(secret, "[REDACTED]")
    return redacted
