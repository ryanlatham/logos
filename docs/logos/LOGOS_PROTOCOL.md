# Logos Protocol Contract — Stage C

This document is the Swift-compatible Stage C protocol contract for the Logos WebSocket bridge.

## Common envelope

Every frame is a JSON object:

```json
{
  "type": "messages_get",
  "request_id": "uuid-or-null",
  "device_id": "iphone-17-pro",
  "project_key": "default",
  "session_id": "optional-session-id",
  "server_seq": 42,
  "payload": {}
}
```

Swift shape:

```swift
struct LogosEnvelope<Payload: Codable>: Codable, Identifiable {
    var id: String { requestId ?? UUID().uuidString }
    let type: String
    let requestId: String?
    let deviceId: String?
    let projectKey: String?
    let sessionId: String?
    let serverSeq: Int?
    let payload: Payload

    enum CodingKeys: String, CodingKey {
        case type
        case requestId = "request_id"
        case deviceId = "device_id"
        case projectKey = "project_key"
        case sessionId = "session_id"
        case serverSeq = "server_seq"
        case payload
    }
}
```

Python source of truth:

- `plugins/logos/schema.py::Envelope`
- `plugins/logos/schema.py::protocol_json_schema()`
- `plugins/logos/schema.py::CLIENT_FRAME_TYPES`
- `plugins/logos/schema.py::SERVER_FRAME_TYPES`

## Stage C client frame types

- `hello`
- `register_device`
- `app_focus_change`
- `speech`
- `text_input`
- `text_message`
- `switch_project`
- `list_projects`
- `new_project`
- `rename_project`
- `messages_get`
- `playback_audio`
- `approval_response`
- `clarify_response`
- `run_cancel`
- `heartbeat`

## Stage C server frame types

- `hello`
- `registered`
- `projects_list`
- `messages_batch`
- `state_update`
- `run_status`
- `playback_audio`
- `audio_chunk`
- `audio_end`
- `approval_request`
- `clarify_request`
- `tool_progress`
- `error`
- `heartbeat_ack`

## Handshake client config

Authenticated `hello` responses and `registered` responses include app-facing configuration:

```json
{
  "type": "hello",
  "payload": {
    "authenticated": true,
    "server": "logos",
    "client_config": {
      "stale_timeout_seconds": 900
    }
  }
}
```

`client_config.stale_timeout_seconds` is the app's silence threshold for adding a local "haven't heard from Hermes" notice. It defaults to `900`, can be configured with `platforms.logos.extra.timeout_seconds`, and is overridden by `LOGOS_TIMEOUT_SECONDS`. It does not change Hermes' own agent inactivity timeout.

## Message model

Swift shape:

```swift
struct LogosMessage: Codable, Identifiable, Hashable {
    var id: String { "\(sessionId):\(messageId)" }
    let projectKey: String
    let sessionId: String
    let messageId: String
    let serverSeq: Int
    let role: String
    let content: String
    let timestamp: TimeInterval
    let metadata: [String: JSONValue]

    enum CodingKeys: String, CodingKey {
        case projectKey = "project_key"
        case sessionId = "session_id"
        case messageId = "message_id"
        case serverSeq = "server_seq"
        case role
        case content
        case timestamp
        case metadata
    }
}
```

Deduplication key:

```text
(session_id, message_id)
```

`server_seq` is a monotonic adapter event sequence. It is used for replay and delta sync, not as a replacement for Hermes message ids.

## Durable progress

Non-`gateway_status` `tool_progress` frames are mirrored as normal Logos messages so the app can keep a visible history of tool activity after the final assistant response arrives:

```json
{
  "type": "tool_progress",
  "request_id": "req-1",
  "project_key": "default",
  "session_id": "project:default",
  "server_seq": 44,
  "payload": {
    "kind": "tool_progress",
    "progress_kind": "tool_progress",
    "message_id": "progress-abc",
    "text": "🔧 terminal: \"pytest\"",
    "transient": false,
    "finalized": false,
    "message": {
      "project_key": "default",
      "session_id": "project:default",
      "message_id": "progress-abc",
      "server_seq": 44,
      "role": "assistant",
      "content": "🔧 terminal: \"pytest\"",
      "timestamp": 1710000000.0,
      "metadata": {
        "source": "tool_progress",
        "progress_kind": "tool_progress",
        "finalized": false,
        "request_id": "req-1",
        "transient": false
      }
    }
  }
}
```

Routine gateway keepalives such as "Still working..." continue to use `kind: "gateway_status"` and `transient: true`; clients should treat them as activity signals, not durable conversation history.

## Reconnect / replay

On reconnect the client should send either:

```json
{
  "type": "hello",
  "request_id": "hello-1",
  "device_id": "iphone-17-pro",
  "project_key": "default",
  "payload": {
    "secret": "...",
    "after_server_seq": 981
  }
}
```

or an explicit request:

```json
{
  "type": "messages_get",
  "request_id": "get-1",
  "device_id": "iphone-17-pro",
  "project_key": "default",
  "payload": {
    "after_server_seq": 981,
    "limit": 100
  }
}
```

The adapter responds:

```json
{
  "type": "messages_batch",
  "request_id": "get-1",
  "project_key": "default",
  "payload": {
    "messages": [],
    "has_more": false,
    "after_server_seq": 981,
    "before_message_id": null
  }
}
```

Clients should compute `after_server_seq` from durable messages they have stored. Transient frames such as `run_status` keepalives and gateway-status `tool_progress` frames may carry event sequence values for ordering live activity, but they are not replayed as messages.

## Older history pagination

Request:

```json
{
  "type": "messages_get",
  "request_id": "older-1",
  "device_id": "iphone-17-pro",
  "project_key": "default",
  "session_id": "sess-1",
  "payload": {
    "before_message_id": "12345",
    "limit": 50
  }
}
```

The adapter resolves `before_message_id` through the Logos mirror and returns messages ordered by ascending `server_seq`, with at most `limit` rows.

## Stage C storage

Stage C adds a Logos-owned SQLite mirror in `plugins/logos/store.py`.

Tables:

```sql
logos_event_seq(id INTEGER PRIMARY KEY CHECK (id = 1), last_server_seq INTEGER NOT NULL)
logos_messages(
  project_key TEXT NOT NULL,
  session_id TEXT NOT NULL,
  message_id TEXT NOT NULL,
  server_seq INTEGER NOT NULL UNIQUE,
  role TEXT NOT NULL,
  content TEXT NOT NULL,
  timestamp REAL NOT NULL,
  metadata_json TEXT NOT NULL DEFAULT '{}',
  PRIMARY KEY (session_id, message_id)
)
```

Default runtime path is `~/.hermes/logos/logos.db`. Tests pass `platforms.logos.extra.store_path` and do not write the real profile.
