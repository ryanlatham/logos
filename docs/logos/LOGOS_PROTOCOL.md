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
- `commands_get`
- `commands_complete`
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
- `commands_list`
- `commands_complete_result`
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

## Slash command discovery

Slash commands remain plain text execution inputs: the iOS app sends `/...` through `text_input` and Hermes decides what the command does. Logos only exposes read-only discovery and completion frames.

`commands_get` requests a bounded catalog:

```json
{
  "type": "commands_get",
  "request_id": "uuid",
  "payload": { "include_unavailable": true }
}
```

`commands_list.payload` contains:

- `schema_version`
- `catalog_version`
- `generated_at`
- `fallback_used`
- `warnings`
- `commands`

Each command has `id`, `trigger`, `canonical`, `aliases`, `description`, `category`, `args_hint`, `subcommands`, `source`, `available`, `unavailable_reason`, `requires_args`, `adds_trailing_space`, and `deprecated`.

`commands_complete` is read-only and accepts a leading-slash draft fragment:

```json
{
  "type": "commands_complete",
  "request_id": "uuid",
  "payload": {
    "catalog_version": "fingerprint",
    "text": "/model o"
  }
}
```

`commands_complete_result.payload.items` use absolute replacement offsets: `canonical`, `replacement_text`, `replacement_start`, `replacement_end`, `display`, `detail`, `kind`, and `adds_trailing_space`.

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

## Private notification routing

`register_device` may include `apns_token`, `apns_environment`, and `capabilities`. iOS sends `apns_environment: "sandbox"` for Debug/device builds and `"production"` for Release/TestFlight builds. The adapter stores that environment per device and uses it to choose the APNS host, so mixed development and TestFlight devices can share the same Logos store.

Server APNS delivery uses Apple's token-based HTTP/2 provider API with the configured `.p8` auth key. Logos does not use APNS SSL certificates.

Completion, approval, and clarification APNS payloads are private signals. They carry routing ids only:

- `kind`
- `project_key`
- `session_id`
- `message_id`
- `request_id`
- `server_seq`

On a `kind: "finished"` notification tap, the app switches to `project_key`, reconnects/authenticates if needed, fetches `messages_get` from `max(server_seq - 1, 0)`, and plays one matched finalized assistant response using `final_auto`. Approval and clarification notifications only route and sync state; they do not trigger playback.

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

Final Hermes assistant responses must include explicit terminal metadata:

```json
{
  "metadata": {
    "finalized": true,
    "source": "hermes"
  }
}
```

Clients should treat active-request assistant messages without explicit final metadata as progress/status updates unless they arrive through another scoped terminal path such as a whole-request cancellation.

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

Routine gateway activity such as "Still working...", retry notices, provider-call abort/timeout notices, preflight compression, and context-compaction notices continue to use `kind: "gateway_status"` and `transient: true`; clients should treat them as activity/progress signals, not durable conversation history or final assistant responses.

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
      "run_status": null,
      "has_more": false,
      "after_server_seq": 981,
      "before_message_id": null
    }
  }
```

Clients should compute `after_server_seq` from durable messages they have stored. Transient frames such as `run_status` keepalives and gateway-status `tool_progress` frames may carry event sequence values for ordering live activity, but they are not replayed as messages. The adapter replays the latest project run state separately in `messages_batch.payload.run_status`; clients should use that value to reconcile optimistic local run state after reconnect.

When present, `run_status` has the latest project-level run state:

```json
{
  "project_key": "default",
  "session_id": "project:default",
  "status": "idle",
  "request_id": "text-request-id",
  "device_id": "iphone-17-pro",
  "server_seq": 1001,
  "updated_at": 1780016878.824,
  "payload": {
    "interrupted": true,
    "final_status": "interrupted",
    "reason": "gateway_restarting"
  }
}
```

`interrupted: true` means an in-flight run ended without a final assistant response, usually because Hermes restarted or shut down. Clients should clear active working status, keep a visible interrupted progress card when it matches the active request, and allow retry when the original request can be replayed.

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
