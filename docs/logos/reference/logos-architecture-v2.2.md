# Logos — Revised Architecture (v2.2 final verification pass)

## Executive summary

**Logos** is a personal iPhone voice-and-tap surface for Hermes Agent. It lets the user continue project work away from the desktop, with low perceived latency from a local fast model and high-quality work from the normal Hermes agent path.

This revision keeps the original architecture but tightens the core path around Hermes's verified extension surfaces and the current gateway/session behavior:

- Logos is a **Hermes platform plugin**, not a patched built-in platform.
- Final user input is routed through Hermes as a normal `MessageEvent` via the adapter's `handle_message(...)` path, rather than by constructing `AIAgent` directly in the Logos code.
- Gateway-native slash commands are supported where verified. `/resume`, `/title`, `/queue`, `/stop`, `/approve`, `/deny`, and other supported commands stay on the normal gateway path. `/sessions` is **not** a hard dependency for v1: Logos provides its own mobile picker, and only passes `/sessions` through when the installed Hermes build actually handles it.
- Approval, denial, stop, queued-message, and clarification behavior is supported in the voice client, but it reuses Hermes gateway semantics wherever possible.
- Phone-side replication is made sequence-aware with `message_id` and `server_seq` instead of timestamp-only pagination.
- Active project pointers are lineage-aware so compression-triggered child sessions do not strand the phone on an old session id.
- APNS defaults to a private payload: the notification says Hermes finished, needs input, or needs approval, but response summaries and command details are fetched over the tailnet after reconnect.
- Background iOS behavior is treated as reconnect-driven. The foreground WebSocket is fast; APNS and delta sync are the reliable background path.
- Hindsight remains useful but is isolated from the voice critical path. Its daemon may use a local model endpoint, but Logos should not require the in-process fast model to be alive for memory extraction.

The scope stays deliberately narrow: one user, one Mac Studio, one Hermes profile, one iPhone app, no public server, no durable run recovery, no phone-free Watch client, no separate Kanban UI, and no persistent approval-policy system.

## Goals

Logos needs to support:

- Speech-to-text-to-agent interaction with sub-second perceived acknowledgment latency.
- Tap-to-talk and hold-to-talk input on iPhone, with energy-based silence detection for tap-to-talk.
- Project continuity between desktop CLI and phone without manual state transfer.
- Explicit resume of existing Hermes sessions from Logos using gateway-native `/resume`; browsing uses the Logos mobile picker, with `/sessions` passed through only if the installed gateway handler is available.
- Project switching by app picker or by voice, for example: "switch to allox".
- Frontier-model quality for actual work through Hermes's normal agent stack.
- Fast local-model responses only for acknowledgment, safe micro-responses, summarization metadata, and narrow intent extraction.
- Interactive Hermes surfaces: clarification prompts, one-shot tool approvals, denial, stop/cancel, and visible tool/run progress.
- Asynchronous completion notifications when the phone is backgrounded or disconnected.
- Lazy/manual and active-app automatic audio playback use full assistant message text, with summaries retained for notification metadata and future compact surfaces.

## Non-goals for core v1

These are intentionally not part of the core build:

- Phone-free Apple Watch operation.
- Apple Watch relay before the iPhone path is solid.
- Multi-user support.
- Federation across profiles or machines.
- Public-internet exposure.
- Durable recovery of in-flight agent runs after adapter restart.
- A separate manual Kanban UI in the phone app.
- Persisted Hermes call-history analytics in the phone app.
- Long-running background WebSocket assumptions on iOS.
- Persistent "always approve this" policy management.
- Fine-tuning the fast model before real failure data exists.

Apple Watch remains a later polish step: useful, but not part of the reliability-critical path.

## Design principles

### Hermes remains the agent authority

Logos should not reimplement Hermes's agent lifecycle. The custom adapter translates iPhone events into Hermes platform events, then lets the gateway runner handle session routing, slash commands, running-agent guards, approval commands, queue behavior, callbacks, persistence, compression, tool execution, memory flushes, and fallback behavior.

The adapter is allowed to add user-experience machinery around the agent path: WebSocket framing, device registration, fast acknowledgments, TTS playback, project pointers, message mirroring, summaries, and notifications. It should not become a second agent runner.

### Latency layering lives outside the agent loop

The fast acknowledgment must arrive before Hermes has done meaningful work. Therefore the fast model remains outside the Hermes agent loop. It emits short acknowledgments and narrow routing decisions. Its outputs are not persisted to `state.db` and are not treated as conversation turns.

### Sessions carry conversation; memory carries continuity

Hermes sessions remain bounded conversation threads. Cross-session and cross-modal continuity comes from profile-wide memory, Hindsight, and Kanban, not from forcing desktop and phone to share one live conversation row.

The phone can resume or switch to a project by title or session id through gateway-native `/resume`, or by choosing from the Logos mobile picker. The core v1 assumption is still explicit session selection, not implicit desktop/phone session sharing at all times.

### Foreground is live; background is replay

When the iPhone app is foregrounded, the WebSocket gives low-latency live updates. When backgrounded, the app should expect the socket to die or be suspended. APNS is the signal; reconnect and delta-sync are the source of truth.

### The phone mirrors state; it does not author Hermes state directly

The phone has a local store so the UI is instant and resilient to brief network loss, but the phone does not write `state.db`. User messages, assistant messages, tool results, approvals, and clarifications become real only when they travel through the adapter and Hermes path and are echoed back as persisted or accepted state.

### Scope control beats cleverness

For v1, the right default is the smallest deterministic behavior that works every time. Do not add rich project automation, complex approval policies, auto-generated Kanban operations, continuous ambient listening, or cross-device global focus until the core voice-to-Hermes loop is boringly reliable.

## Architecture

### Topology

```text
iPhone app ── WebSocket over Tailscale ──► Logos Hermes platform plugin
                                                │
                                                ├─ WebSocket device server
                                                ├─ Local fast LLM for ack/intent/summary
                                                ├─ Local TTS for short audio playback
                                                ├─ Project/session pointer mirror
                                                ├─ Phone message replication
                                                └─ MessageEvent bridge
                                                       │
                                                       ▼
                                                Hermes gateway runner
                                                ├─ session routing
                                                ├─ slash commands
                                                ├─ run guard / queue / stop
                                                ├─ approval / denial commands
                                                ├─ callbacks
                                                └─ AIAgent
                                                       │
                                                       ▼
                                                Hermes profile
                                                ├─ state.db
                                                ├─ MEMORY.md / USER.md
                                                ├─ kanban.db
                                                └─ Hindsight memory provider
                                                       ▲
                                                       │
                                                Desktop CLI
                                                same profile, separate sessions
```

The iPhone talks only to the Mac over Tailscale, except for APNS registration and push delivery through Apple. The desktop CLI and Logos share the same Hermes profile, but each has its own active focus and session routing.

### Runtime environment

The Hermes gateway, Logos plugin, Hermes profile, desktop CLI, local fast model, TTS engine, and optional Hindsight daemon all run on the Mac Studio. This removes cross-machine inference latency and avoids a second orchestration server.

The fast model and TTS engine can be loaded in the Logos plugin process if startup and memory behavior are acceptable. If that makes gateway startup too slow or model lifecycle too coupled, the fallback is a local loopback service on the same Mac. That fallback is still local-only and does not change the iPhone protocol.

Hindsight is deliberately not in the voice critical path. If Hindsight needs LLM extraction or reflection calls, configure it against a local OpenAI-compatible endpoint or a separate local runtime rather than the Logos plugin's in-process fast model. A Hindsight outage should degrade long-memory recall, not speech submission, approval handling, message replication, or notifications.

The preferred v1 deployment is:

```text
Hermes gateway process
  └─ Logos platform plugin
       ├─ WebSocket server
       ├─ fast LLM runtime or local client
       ├─ TTS runtime or local client
       └─ adapter metadata store

Local daemons/services
  ├─ PostgreSQL for Hindsight
  └─ optional local model/TTS service if in-process loading proves awkward
```

No component needs public inbound networking.

## Hermes integration

### Plugin path

Logos should live as a user plugin:

```text
~/.hermes/plugins/logos/
  PLUGIN.yaml
  adapter.py
  ws_server.py
  fast_llm.py
  tts.py
  schema.py
  store.py
```

The plugin registers a platform adapter named `logos`. It should not be added under `gateway/platforms/logos.py` unless Logos is later upstreamed as an official built-in platform.

Minimal registration shape:

```python
# adapter.py
from gateway.platforms.base import BasePlatformAdapter, MessageEvent, SendResult
from gateway.config import Platform, PlatformConfig

class LogosAdapter(BasePlatformAdapter):
    def __init__(self, config: PlatformConfig):
        super().__init__(config, Platform("logos"))
        # initialize ws server, device registry, fast LLM, TTS, etc.

    async def connect(self) -> bool:
        # start WebSocket server
        self._mark_connected()
        return True

    async def disconnect(self) -> None:
        # stop WebSocket server and close device sockets
        self._mark_disconnected()

    async def send(self, chat_id, content, reply_to=None, metadata=None):
        # gateway -> Logos delivery; push to connected devices and local mirror
        return SendResult(success=True, message_id=None)


def register(ctx):
    ctx.register_platform(
        name="logos",
        label="Logos",
        adapter_factory=lambda cfg: LogosAdapter(cfg),
        required_env=["LOGOS_DEVICE_SECRET"],
    )
```

### Message bridge

For a final user utterance, Logos should construct a Hermes `MessageEvent` and call the adapter's normal inbound path:

```text
speech final / text input
  → resolve device active project
  → choose Logos chat_id for that project
  → run fast LLM ack/routing side path
  → call self.handle_message(MessageEvent(...))
  → gateway runner handles the agent run
```

The adapter should not directly instantiate `AIAgent` for normal messages. Direct `AIAgent` construction is reserved only for a future escape hatch if a specific Logos-only operation cannot be expressed through the gateway path.

Text beginning with `/` must be forwarded unmodified through this same path. Logos should not parse or reimplement Hermes slash commands except for optional voice-intent sugar that deliberately maps a spoken phrase such as "resume archwright" to `/resume archwright`.

This keeps slash commands, session guards, queueing, cancellation, approvals, callback dispatch, compression, persistence, and gateway authorization on the normal Hermes path.

### Project chat ids and sessions

A Logos project maps to a stable platform routing key. The project key, not the iOS device id, should be the `chat_id` basis so the same project can be opened from the same phone after reinstall and can survive pointer changes.

Example:

```text
platform: logos
chat_type: project
chat_id: project:<project_key>
session key: agent:main:logos:project:project:<project_key>
```

Do not manually construct Hermes session keys in Logos code. Use Hermes's session-key helper if available. Logos can store `project_key` and `current_session_id` in adapter metadata, but the gateway's platform/session machinery should remain authoritative.

Desktop CLI sessions and Logos project sessions normally remain separate because each surface has its own current focus. Exact cross-modal continuity is still supported explicitly: a user can type or speak `/resume <title-or-session-id>` in Logos, or choose an entry from the Logos mobile picker, to bind the current Logos project/thread to an existing Hermes session. `/sessions` may be passed through when the installed Hermes build handles it, but the mobile picker should not depend on that command. The non-goal is implicit automatic sharing of whichever session happens to be active on the desktop.

## iPhone client

### Input modes

The iPhone supports two input modes:

- **Hold-to-talk**: start recognition on press, stream partial transcripts while held, send the final transcript on release.
- **Tap-to-talk**: start recognition on tap, stop after energy-based silence detection, send the final transcript.

Use `SFSpeechRecognizer` with `requiresOnDeviceRecognition = true`, but check `supportsOnDeviceRecognition` before enabling voice input. If the recognizer does not support on-device recognition for the selected locale/device, v1 should disable voice input or require an explicit user opt-in to network speech. It should not silently fall back to network recognition.

Text input can be present from day one and should use the same transport as final speech. This gives a debug path for every voice feature.

### Partial transcripts

Partial transcripts are useful for speculative fast-LLM warmup but should not produce Hermes user messages. The adapter may cache the most recent partial per input id and precompute an acknowledgment, but only `is_final=true` can enter the Hermes path.

Each speech request should carry:

```json
{
  "type": "speech",
  "client_msg_id": "uuid",
  "device_id": "iphone-15-pro",
  "project_key": "archwright-phase-6",
  "text": "...",
  "is_final": true,
  "partial_seq": 7,
  "started_at_ms": 1778760000000
}
```

`client_msg_id` lets the adapter and phone deduplicate retries.

### Foreground/background lifecycle

Foreground behavior:

- Maintain the WebSocket.
- Send periodic heartbeats.
- Receive live `state_update`, `run_status`, `audio_chunk`, `approval_request`, and `clarify_request` frames.
- Render local optimistic UI only for pending/queued state, not as persisted Hermes messages.

Background behavior:

- Assume the WebSocket may be suspended or closed.
- Treat `app_focus_change` as a hint, not as truth.
- Let heartbeat timeout and socket close drive adapter state.
- Use APNS only as a wake/attention signal.
- On notification tap or foreground, reconnect and send the last seen sequence for delta sync.

## Phone-local message store

The phone keeps a local SQLite or Core Data store that mirrors Logos-visible session history. This makes the chat view instant and allows the user to read recently fetched history even when Tailscale is briefly unreachable.

The local store should contain:

```text
projects
  project_key
  title
  current_session_id
  lineage_root_session_id
  last_seen_message_id
  last_seen_server_seq
  last_preview
  updated_at

messages
  session_id
  message_id
  server_seq
  role
  content
  timestamp
  status        -- persisted | pending | queued | failed
  metadata_json

runs
  session_id
  run_id
  status        -- idle | running | queued | awaiting_approval | awaiting_clarification | cancelling
  updated_at
```

Only adapter-confirmed rows should be stored with `status = persisted`. The client may show pending local rows while a speech/text message is being submitted, but those rows are replaced or removed when the adapter echoes the real persisted message.

### Sequence-aware replication

Do not paginate only by timestamp. Use Hermes `message_id` plus an adapter `server_seq`.

Initial or reconnect fetch:

```json
{
  "type": "messages_get",
  "project_key": "archwright-phase-6",
  "session_id": "optional-known-session-id",
  "after_server_seq": 981,
  "limit": 100
}
```

Older history fetch:

```json
{
  "type": "messages_get",
  "session_id": "...",
  "before_message_id": 12345,
  "limit": 50
}
```

Live append:

```json
{
  "type": "state_update",
  "server_seq": 982,
  "project_key": "archwright-phase-6",
  "session_id": "...",
  "op": "message_appended",
  "message": {
    "message_id": 12346,
    "role": "assistant",
    "content": "...",
    "timestamp": 1778760000.12
  }
}
```

The phone deduplicates on `(session_id, message_id)` and tracks `last_seen_server_seq` per project. This makes reconnect behavior deterministic.

## WebSocket protocol

The WebSocket is a single bidirectional control plane. Every frame uses a common envelope:

```json
{
  "type": "...",
  "request_id": "uuid-or-null",
  "device_id": "iphone-15-pro",
  "project_key": "optional-project-key",
  "session_id": "optional-session-id",
  "server_seq": "adapter-to-client only",
  "payload": {}
}
```

### Client → adapter

| Type | Purpose |
|---|---|
| `register_device` | Register APNS token, device metadata, and app capabilities. |
| `app_focus_change` | Hint that the app foregrounded/backgrounded. Not authoritative. |
| `speech` | Transcribed speech partial or final. Only final reaches Hermes. |
| `text_message` | Typed message. Same Hermes path as final speech. |
| `switch_project` | Change this device's active project pointer. |
| `list_projects` | Request project picker data. |
| `new_project` | Create a new Logos project/session. |
| `rename_project` | Rename a Logos project/session title. |
| `messages_get` | Fetch recent, delta, or older messages. |
| `playback_audio` | Request summary TTS for a message. |
| `run_cancel` | Cancel/stop the active run for the project. Maps to Hermes `/stop`. |
| `approval_response` | One-shot allow/deny response to an approval request. |
| `clarify_response` | User answer to a Hermes clarification request. |
| `heartbeat` | Keepalive and round-trip health check. |

### Adapter → client

| Type | Purpose |
|---|---|
| `registered` | Device registration success plus negotiated capabilities. |
| `projects_list` | Response to `list_projects`. |
| `messages_batch` | Response to `messages_get`. |
| `state_update` | Message appended, summary ready, project renamed, or pointer updated. |
| `run_status` | Idle/running/queued/awaiting-approval/awaiting-clarification/cancelling. |
| `approval_request` | Display an approve/deny card to unblock a tool call. |
| `clarify_request` | Display a clarification prompt and collect user text. |
| `tool_progress` | Short progress updates from Hermes callbacks. |
| `audio_chunk` | Streaming TTS audio frame. |
| `audio_end` | End of TTS stream. |
| `error` | Protocol or adapter-level error. |
| `heartbeat_ack` | Keepalive response. |

This is more than the original schema, but still core: these frames cover the Hermes interaction surfaces that would otherwise break voice use. They are not feature creep because they do not add new product surfaces; they preserve existing Hermes behavior in the iPhone client.

## Approval and clarification support

### Principles

Approval and clarification are part of the core path because Hermes can block on them during normal work. Logos must surface them in the app, but it should not invent a separate policy engine.

V1 behavior:

- One pending approval or clarification card per project/run.
- User can approve, deny, answer, or cancel.
- No persistent "always allow" rules.
- No custom risk scoring beyond what Hermes already provides.
- No hidden auto-approval.
- If the phone is disconnected, send a private APNS notification saying Hermes needs input.

### Approval flow

1. Hermes detects an operation that requires approval.
2. The gateway/agent approval callback is surfaced through the Logos adapter.
3. The adapter emits `approval_request` to the active device if connected.
4. The app renders a compact approval card:
   - action title
   - command/tool summary
   - risk text supplied by Hermes, if present
   - approve button
   - deny button
   - cancel/stop option
5. User taps approve or deny.
6. App sends `approval_response`.
7. Adapter maps response to Hermes's normal approval path, preferably by forwarding the equivalent `/approve` or `/deny` command through `MessageEvent` so the gateway's bypass semantics apply.

Example request:

```json
{
  "type": "approval_request",
  "request_id": "appr_123",
  "project_key": "archwright-phase-6",
  "session_id": "...",
  "payload": {
    "title": "Approve shell command?",
    "summary": "Run migration script in the project directory",
    "command_preview": "python manage.py migrate",
    "risk": "This may modify local database files.",
    "expires_at": 1778760300000
  }
}
```

Example response:

```json
{
  "type": "approval_response",
  "request_id": "appr_123",
  "project_key": "archwright-phase-6",
  "payload": {
    "decision": "approve",
    "note": "Proceed"
  }
}
```

If the approval request arrives while the app is backgrounded, the APNS payload should not include the command text. It should only say that Hermes needs approval and carry ids needed to fetch the request after reconnect.

### Clarification flow

1. Hermes calls the `clarify` tool or equivalent clarification callback.
2. The adapter emits `clarify_request` with the question and optional choices.
3. The app shows a prompt card with a text field and optional choice buttons.
4. User answers by voice or text.
5. App sends `clarify_response`.
6. Adapter routes the response to Hermes through the native clarify callback if available; otherwise it forwards the answer as the next high-priority user message on the same project while preserving gateway guard behavior.

Example request:

```json
{
  "type": "clarify_request",
  "request_id": "clar_456",
  "project_key": "archwright-phase-6",
  "payload": {
    "question": "Which branch should I apply the change to?",
    "choices": ["main", "feature/auth", "create a new branch"],
    "allow_free_text": true
  }
}
```

Example response:

```json
{
  "type": "clarify_response",
  "request_id": "clar_456",
  "project_key": "archwright-phase-6",
  "payload": {
    "text": "Use feature/auth."
  }
}
```

### Cancel/stop flow

`run_cancel` maps to Hermes `/stop`. If the user speaks "stop", "cancel", or "never mind" while a run is active, the fast intent classifier can emit `cancel_intent = true`; the adapter then sends the stop command through the Hermes gateway path rather than adding the utterance to the conversation.

V1 should keep cancellation simple: stop current run, mark UI idle/cancelled, and let the user re-ask. Do not attempt partial run rollback.

## Run state and concurrency

Hermes already has a running-agent guard and queue semantics. Logos should mirror those states for UI purposes rather than implement a competing queue.

Recommended UI states:

```text
idle
running
queued
awaiting_approval
awaiting_clarification
cancelling
error
```

Same-project input while running:

- Normal message: forward through `handle_message(...)`; Hermes guard queues or interrupts according to normal gateway behavior.
- Stop/cancel intent: map to `/stop`.
- Approval/clarification response: bypass as the appropriate Hermes command/callback.

Different-project input while another project is running:

- Allow separate runs if Hermes/gateway allows it.
- Add a conservative adapter-level global cap, for example two simultaneous Logos-initiated runs, to avoid accidental resource pileups.
- If cap is reached, mark the request `queued` locally and submit when a slot opens.

The phone should not append queued user messages as persisted history. It should render them as transient local UI until Hermes accepts and echoes a real message row.

## Gateway slash commands and session resume

Logos should expose Hermes gateway slash commands as first-class input, not as custom app features. This costs almost nothing once the adapter routes inbound text through `handle_message(...)`, and it avoids scope creep because the command semantics live in Hermes, not in Logos.

Core v1 command support:

- `/resume <title-or-session-id>`: resume a previously named or identified session into the current Logos project/thread.
- `/sessions`: optional pass-through only. Do not make it a v1 dependency unless the installed Hermes build has a working handler. The app's project/session picker should list recent sessions through adapter-side read-only session queries and then resume via `/resume` or an equivalent gateway-supported helper.
- `/title <name>`: rename the active session/project.
- `/queue <prompt>` and `/steer <prompt>`: use Hermes's existing running-agent behavior rather than a Logos-specific queue.
- `/stop`: cancel the current run.
- `/approve` and `/deny`: unblock dangerous-command approvals.
- `/status`, `/usage`, and other gateway-supported informational commands.

Voice can add a thin natural-language layer over those commands:

```text
"resume archwright phase six" → /resume archwright phase six
"show sessions"              → open Logos project/session picker; pass /sessions only if supported
"rename this to allox cli"    → /title allox cli
"stop"                       → /stop
```

The fast LLM may classify these narrow control intents, but the resulting action should still be a Hermes slash command or normal gateway event. Do not build an independent Logos *resume* subsystem. A read-only mobile picker is acceptable because the app already needs a project picker, and it avoids coupling v1 to `/sessions` command behavior. Resume still flows through Hermes `/resume` or another gateway-supported helper.

Scope boundary: `/handoff logos` from the desktop CLI is not required for core v1. It would be convenient later, but native in-Logos `/resume` already covers the important case: picking up a previous desktop session from the phone on demand.

## Project and session model

### Project identity

A Logos project is a topic-scoped wrapper around a Hermes gateway session lineage.

Suggested metadata:

```json
{
  "project_key": "archwright-phase-6",
  "title": "archwright-phase-6",
  "current_session_id": "session_child_or_root",
  "lineage_root_session_id": "session_root",
  "source": "logos",
  "chat_id": "project:archwright-phase-6",
  "last_seen_message_id": 12346,
  "last_seen_server_seq": 982,
  "updated_at": 1778760000.12
}
```

`project_key` is stable and device-independent. `current_session_id` can change after compression. `lineage_root_session_id` lets Logos discover the latest child session if the current session is split.

After any explicit `/resume`, Logos should verify that the active session is the latest known continuation in its lineage before storing the pointer. If the gateway resolves a title to an older compression parent, Logos should follow Hermes session lineage where safe, or at minimum warn the user that the selected session may not be the most recent continuation.

### Active pointer

The active pointer is device-local:

```text
voice_active_project_<device_id> = {
  project_key,
  title,
  current_session_id,
  lineage_root_session_id,
  updated_at
}
```

The iPhone stores the same pointer locally. The adapter mirror exists so reinstall/reconnect can recover focus.

Desktop CLI focus does not mutate the phone pointer. Phone focus does not mutate CLI focus.

### Compression and lineage reconciliation

Hermes compression can create a child session. After each completed agent run, the adapter should reconcile the project's `current_session_id`:

1. Inspect the latest session id associated with the project's Hermes routing key or lineage root.
2. If compression created a child, update the project metadata.
3. Emit `state_update` with `op = "project_session_changed"` so the phone updates its local pointer.
4. Continue message replication against the current child session.

This prevents a subtle failure where the phone keeps asking against a pre-compression session while Hermes has moved forward.

### Project list

The project picker queries recent Logos projects/sessions by title, recency, and preview. Keep this simple:

- active/open projects first
- then recently touched projects, for example last 30 days
- title, preview, status, last active time
- no global search UI in v1 unless the list becomes unwieldy

Voice project switching uses fuzzy title matching against this same list. If ambiguous, ask a clarification instead of guessing.

## Cross-modal continuity

Continuity between desktop and Logos is composed of four layers:

1. **Built-in profile memory**: `MEMORY.md` and `USER.md` are shared by all sessions and modalities.
2. **Hindsight memory provider**: captures structured facts and relationships from past work and supports recall across old sessions.
3. **Kanban DB**: stores task/project state that any Hermes session can inspect or update through normal tools.
4. **Explicit session/project selection**: the user can switch to a titled Logos project, start a new one, use gateway-native `/resume`, or choose from the Logos mobile picker to pick up an existing Hermes session.

Do not make implicit single-session sharing the core continuity mechanism. It causes live-input races and makes phone/desktop focus surprising. Explicit `/resume` is the correct escape hatch when exact thread continuity matters.

## Fast LLM

The fast model has four deliberately narrow jobs:

1. Generate a very short, contextual acknowledgment for Hermes-bound work.
2. Detect narrow control intents: switch project, create project, resume, cancel/stop, and explicit approval/denial replies.
3. Produce safe direct micro-responses for trivial non-tool asks such as greetings, thanks, static app help, or tiny generic text.
4. Summarize completed agent responses for notification metadata and compact future surfaces.

It does not answer substantive user requests, query current facts, calculate, inspect files, read project state, or call tools. Direct micro-responses are Logos-local assistant messages marked with `metadata.source = "fast_response"`; they are not persisted into Hermes conversation history. Anything ambiguous, current, stateful, tool-requiring, or action-oriented goes through the normal Hermes gateway path.

Suggested schema:

```json
{
  "ack": true,
  "ack_text": "I'll check.",
  "direct_response_text": null,
  "direct_response_kind": null,
  "switch_intent": null,
  "create_intent": null,
  "resume_intent": null,
  "cancel_intent": false,
  "approval_decision": null,
  "confidence": 0.91
}
```

For a fast direct response:

```json
{
  "ack": false,
  "ack_text": null,
  "direct_response_text": "I'm here.",
  "direct_response_kind": "social",
  "switch_intent": null,
  "create_intent": null,
  "resume_intent": null,
  "cancel_intent": false,
  "approval_decision": null,
  "confidence": 0.93
}
```

Acknowledgments are transient state updates, not chat messages. The adapter includes `transient: true` and `ttl_ms` in `fast_ack` frames; the iOS client clears them on assistant messages, terminal run status, project/interaction changes, or TTL expiry.

V1 behavior on uncertainty:

- If switch intent is ambiguous, do not switch; ask a clarification or leave the active project unchanged.
- If direct-response safety is uncertain, set `direct_response_text` to null and route the request to Hermes.
- If JSON validation fails, fall back to deterministic safe ack/intent behavior and no model-originated direct response.
- If the model is unavailable, the app still submits the message to Hermes; only the low-latency nicety is lost.

Use a constrained decoder or structured-output wrapper. Treat `>95%` intent accuracy as an evaluation target, not an architectural assumption. Collect a small local eval set from real commands before trusting voice-driven switching.

## TTS

TTS is request-scoped and adapter-owned:

- optional fast acknowledgment audio at request time
- active-app automatic playback of completed assistant messages using full message text
- manual playback using `mode: "full"`
- optional clarification/approval prompt readout if the UI asks for it

`playback_audio` request:

```json
{
  "type": "playback_audio",
  "project_key": "archwright-phase-6",
  "session_id": "...",
  "payload": {
    "message_id": "12346",
    "mode": "full"
  }
}
```

When a `message_id` is present, the adapter treats its stored message content as authoritative instead of trusting client-provided text. Summaries are still stored for notification metadata and compact surfaces, but full-response playback is the user-facing audio path.

Start with Kokoro or the simplest high-speed local TTS that works reliably on the Mac. Treat Chatterbox, Qwen3-TTS, and other naturalness upgrades as future internal swaps, not v1 product decisions.

## Summaries and notifications

### Summary storage

Summaries are adapter metadata keyed by Hermes `message_id`:

```text
logos_summaries
  message_id
  session_id
  project_key
  summary_text
  source_hash
  created_at
```

If avoiding a new table at first, `state_meta` keys are acceptable:

```text
logos_summary:<session_id>:<message_id>
```

A separate table is cleaner once the implementation stabilizes.

### APNS private mode

Core v1 uses private APNS payloads. Do not put response text, summaries, command previews, file paths, secrets, or approval details in push payloads.

Example completion push:

```json
{
  "aps": {
    "alert": {
      "title": "Hermes finished",
      "body": "Open Logos to view the result."
    },
    "sound": "default"
  },
  "project_key": "archwright-phase-6",
  "session_id": "...",
  "message_id": 12346,
  "server_seq": 982
}
```

Example approval-needed push:

```json
{
  "aps": {
    "alert": {
      "title": "Hermes needs approval",
      "body": "Open Logos to continue."
    },
    "sound": "default"
  },
  "project_key": "archwright-phase-6",
  "request_id": "appr_123",
  "kind": "approval"
}
```

After the user taps the notification:

1. App opens to the relevant project.
2. WebSocket reconnects.
3. App sends `messages_get` with `after_server_seq`, usually `server_seq - 1` from the private payload.
4. Adapter returns the missed message, summary-ready metadata, or pending approval/clarification request.
5. For `kind: "finished"`, the app matches the finalized assistant message by `message_id` first, falls back to the latest finalized message in the routed project/session at or after `server_seq`, and starts `final_auto` playback once. Approval and clarification routes reveal their cards without autoplay.

The app records the APNS environment during `register_device`: Debug/device builds use `sandbox`; Release/TestFlight builds use `production`. The adapter must send through the stored device environment rather than a single global host, because development and TestFlight devices can be registered at the same time.

A convenience mode that includes the summary in APNS can be added later as an explicit privacy tradeoff, but it is not core v1.

## Security and authentication

The network boundary is Tailscale plus device-level registration.

Minimum v1 controls:

- Bind the WebSocket server to the tailnet interface or localhost plus Tailscale routing.
- Require a per-device shared secret or signed registration token.
- Store device ids, APNS tokens, last_seen, and capability metadata.
- Reject unknown devices by default.
- Use Hermes gateway authorization where applicable.
- Keep APNS payloads private.
- Avoid logging full transcripts, approval command bodies, or summaries unless debug logging is explicitly enabled.

Device registration record:

```text
logos_devices
  device_id
  display_name
  shared_secret_hash
  apns_token
  apns_environment
  capabilities_json
  last_seen_at
  revoked_at
```

A simple shared secret is enough for personal v1 because Tailscale is already the network gate. More elaborate mutual TLS or hardware-bound attestation is not necessary now.

`/resume` is intentionally powerful in this app because the sole user wants to resume desktop work from the phone. Treat that as a single-user privilege, not as a multi-user-safe default. If Logos is ever exposed to more users, shared devices, guests, or an untrusted chat surface, require source/user-scoped resume semantics before enabling title-based resume.

## Adapter metadata

Use adapter-owned tables if Hermes plugin migrations make that reasonable. Otherwise, use namespaced `state_meta` keys until the schema stabilizes.

Recommended tables after v0:

```sql
CREATE TABLE IF NOT EXISTS logos_projects (
  project_key TEXT PRIMARY KEY,
  title TEXT NOT NULL,
  chat_id TEXT NOT NULL,
  current_session_id TEXT,
  lineage_root_session_id TEXT,
  last_seen_message_id INTEGER,
  last_seen_server_seq INTEGER,
  created_at REAL NOT NULL,
  updated_at REAL NOT NULL
);

CREATE TABLE IF NOT EXISTS logos_devices (
  device_id TEXT PRIMARY KEY,
  display_name TEXT,
  shared_secret_hash TEXT,
  apns_token TEXT,
  apns_environment TEXT,
  capabilities_json TEXT,
  last_seen_at REAL,
  revoked_at REAL
);

CREATE TABLE IF NOT EXISTS logos_summaries (
  message_id INTEGER PRIMARY KEY,
  session_id TEXT NOT NULL,
  project_key TEXT NOT NULL,
  summary_text TEXT NOT NULL,
  source_hash TEXT,
  created_at REAL NOT NULL
);

CREATE TABLE IF NOT EXISTS logos_event_seq (
  id INTEGER PRIMARY KEY CHECK (id = 1),
  last_server_seq INTEGER NOT NULL
);
```

`server_seq` can be generated by the adapter as a monotonic integer for phone replication. It does not need to replace Hermes message ids.

## Implementation order

A good build path that keeps scope under control:

1. **Plugin skeleton and text-only bridge**
   - Create `~/.hermes/plugins/logos`.
   - Register the Logos platform.
   - Bring up the WebSocket server.
   - Accept typed text from a test client.
   - Convert it to `MessageEvent` and call `handle_message(...)`.
   - Confirm Hermes responses come back through adapter `send(...)`.

2. **Protocol envelope and sequence replication**
   - Add `request_id`, `client_msg_id`, `server_seq`, and `messages_get`.
   - Implement adapter-to-client message batches.
   - Dedupe on the phone by `(session_id, message_id)`.

3. **Project routing, slash resume, and lineage-aware pointer**
   - Add `project_key` and device-local active pointer.
   - Implement list/switch/new/rename.
   - Verify `/resume <title-or-session-id>` and `/title` work through the gateway path.
   - Feature-detect `/sessions`; if unavailable or unsuitable, keep using the Logos picker.
   - Test title resume on compressed sessions and reconcile `current_session_id` to the latest lineage continuation after resume and after each completed run.

4. **Run state, queue, and stop**
   - Mirror Hermes running state in `run_status`.
   - Map `run_cancel` to `/stop`.
   - Show queued/pending states locally without persisting fake messages.

5. **Approval and clarification cards**
   - Add `approval_request` / `approval_response`.
   - Add `clarify_request` / `clarify_response`.
   - Verify approval/deny/stop bypass running-agent guard correctly.
   - Keep this text-only first.

6. **iPhone text client**
   - Local message store.
   - Project picker.
   - Reconnect and delta sync.
   - Working indicator.

7. **TTS playback**
   - Implement `playback_audio` and streaming `audio_chunk`.
   - Render full short messages first; add summary lookup later.

8. **On-device ASR**
   - Add hold-to-talk.
   - Check on-device support.
   - Add tap-to-talk and silence detection.
   - Stream partials, but only final enters Hermes.

9. **Fast LLM ack and intent extraction**
   - Add ack generation.
   - Add switch/create/cancel intent.
   - Validate with a small command eval set.
   - Failure mode: submit to Hermes with no ack/control action.

10. **Summaries and private APNS**
    - Summarize completed long responses.
    - Store summary metadata.
    - Send private completion and input-needed pushes.
    - On tap, reconnect and fetch the missed data.

11. **Apple Watch relay**
    - Add only after the iPhone path is stable.
    - Treat the Watch as a satellite to the iPhone, not a direct Hermes client.

Each stage should be demoable. Do not begin the next stage until the current one works under reconnect, duplicate frame, and same-session running-agent cases.

## Core-path review notes

### Changes accepted in this revision

- **Plugin instead of built-in platform**: avoids Hermes core patches and aligns with the extension model.
- **Gateway path instead of direct `AIAgent` construction**: preserves queueing, commands, callbacks, approvals, and persistence.
- **Approval/clarification support**: included because Hermes can naturally block on these during useful work.
- **Private APNS payloads**: preserves the local/tailnet privacy claim.
- **Sequence-based phone replication**: avoids timestamp pagination gaps and duplicates.
- **Lineage-aware active pointer**: handles compression child sessions.
- **Foreground-only WebSocket assumption**: avoids brittle iOS background behavior.
- **ASR capability check**: prevents silent network-recognition fallback.
- **Fast LLM uncertainty handling**: prevents accidental project switches.
- **No hard dependency on `/sessions`**: the app keeps its own picker and only passes `/sessions` through if the installed Hermes build supports it.
- **Resume guardrails**: explicit `/resume` stays in core v1, but title-based resume is treated as single-user-only and checked against compression lineage.

### Deliberately not added

- No background agent-run durability after adapter restart.
- No persistent approval policy store.
- No continuous background full-response TTS while the app is suspended.
- No continuous listening.
- No cross-device global focus sync.
- No manual Kanban editing UI.
- No public API server.
- No fine-tuned fast model before data exists.
- No Watch implementation before iPhone reliability.

### Remaining implementation risks

1. **Implicit focus sync vs explicit resume**

   Gateway-native `/resume` should be supported in Logos. The risk is not exact resume itself; the risk is implicit focus sharing, where the phone silently follows whatever session the desktop CLI last used. Keep explicit resume in core v1, but do not add automatic desktop/phone global focus sync. Do not hard-depend on `/sessions`; use the Logos picker unless the installed gateway handler is verified.

2. **Resume edge cases**

   Title-based `/resume` can be problematic if a Hermes build resolves across broader scope than intended or returns an older compression parent. This is acceptable for single-user personal v1 only if the app keeps authorization tight and tests resume against compressed sessions. Multi-user exposure requires scoped resume semantics.

3. **Callback plumbing details**

   Approval and clarify callbacks need to be validated against Hermes's current gateway callback implementation. The protocol above is stable, but the adapter implementation should use the highest-level Hermes callback/command surface available.

4. **Fast model lifecycle**

   In-process loading is elegant but may couple gateway startup and model failures. Keep a loopback local-service fallback in mind, but do not implement it unless in-process loading is actually painful.

5. **Hindsight lifecycle**

   Hindsight is valuable for project recall, but it should be async and non-blocking. Do not make Logos depend on the Hindsight daemon or on memory extraction completion before accepting another voice turn.

6. **Phone optimistic UI**

   The phone must clearly distinguish pending/queued local rows from persisted Hermes messages. Most duplicate-message bugs will come from this seam.

7. **APNS cannot be the source of truth**

   Pushes can be delayed or dropped. Every notification path must converge on reconnect + `messages_get` delta sync.

## Long-term roadmap

Only revisit these after the core path is stable:

- Apple Watch relay.
- Optional convenience-mode APNS summaries with explicit privacy warning.
- "Play full response" long-press mode.
- Multi-device project sharing.
- Durable run recovery after adapter restart.
- Fine-tuned or smaller fast model.
- Higher-naturalness TTS swap.
- Richer project search.

## Reference assumptions

- Hermes platform adapters can be added as plugins under `~/.hermes/plugins/`, and inbound messages should be forwarded through `self.handle_message(event)`.
- Hermes gateway handles running-agent guards, queue behavior, `/resume`, `/title`, `/stop`, `/approve`, `/deny`, `/queue`, and `/status` semantics. `/sessions` is feature-detected rather than assumed.
- Hermes session storage uses SQLite `state.db`, message ids, `state_meta`, and parent-session lineage for compression splits.
- Hermes agent callbacks include streaming, status/progress, clarification, and approval surfaces.
- Apple APNS payloads should not contain sensitive data and should be treated as signals, not source-of-truth data delivery.
- iOS background execution should not be assumed to preserve a live WebSocket for Logos.
- On-device speech recognition must check capability before relying on `requiresOnDeviceRecognition`.


## v2.2 verification correction

The v2.1 review correctly restored explicit desktop-session reuse through gateway-native `/resume`, but it over-assumed `/sessions` as a reliable gateway command. Core v1 should support `/resume` and provide a Logos mobile picker; `/sessions` is pass-through only when the installed Hermes build actually handles it. What remains out of scope is implicit automatic desktop/phone focus sharing and a dedicated `/handoff logos` flow.
