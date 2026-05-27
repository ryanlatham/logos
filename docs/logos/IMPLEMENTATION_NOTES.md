# Logos Implementation Notes

Last updated: 2026-05-18T06:42:03-07:00

## Architecture-completion correction

The previous Kanban/project closure overstated completion. Current implementation includes a source Logos platform plugin scaffold and the adapter does construct `MessageEvent` and call `self.handle_message(...)`, but the end-to-end validation that was repeatedly run used `scripts/run_stage_f_mock_adapter.py`, not the live Hermes gateway/plugin deployment. Several architecture-critical components are still stubs or unproven in live operation:

- `plugins/logos/fast_llm.py` uses `DeterministicFastModel`, a regex/deterministic fallback rather than a real local fast LLM runtime/client.
- `plugins/logos/tts.py` uses `DeterministicStubTTS`, explicitly non-speech WAV beeps rather than real TTS.
- UI tests exercise mock adapter fixtures such as `/mock_approval` and `/mock_clarify`, not necessarily live Hermes-origin approval/clarification callbacks.
- Physical/manual validation was performed against the mock/client flow, not the full live Logos architecture.

The `logos-agent-voice-app` Kanban board has been reopened with corrective tasks:

- `t_770be11f` — Correction parent: reopen Logos v1 real-architecture completion.
- `t_76133bd4` — Implement live Logos gateway plugin end-to-end path.
- `t_e7efd02c` — Replace deterministic fast-model stub with real configurable local fast LLM.
- `t_21b1d429` — Replace deterministic beep WAV TTS with real TTS runtime/client.
- `t_7d9c8fed` — Wire real Hermes approval, clarification, run progress, and tool progress to Logos.
- `t_7629f3e0` — Run physical/manual validation against real plugin, not mock adapter.

## Closure verification follow-up — playback status accessibility

During the final Logos Kanban closure rerun, the adapter correctly received the UI-test playback request and streamed `audio_chunk` / `audio_end` frames, but the UI test could miss the playback status because the custom SwiftUI `ToolStrip` did not expose a stable playback-status accessibility node. The app now marks the playback strip with `playbackStatusLabel` and an accessibility label equal to the current status (`Receiving audio`, `Playing audio`, or `Audio finished`), and the UI test waits on that explicit element instead of brittle exact `StaticText` discovery.

Verification after this fix:

- Focused UI regression: `LogosUITests/testTextMessageRoundTripThroughMockAdapter` passed.
- Full Xcode target: `LogosModelTests` 50/50 and `LogosUITests` 5/5 passed on Simulator `<simulator-udid>`.
- Python tests: `49 passed`.
- Python compile check: passed.
- `git diff --check`: passed.
- Diff secret scan: `secret_scan_findings=0`.
- Mock adapter cleanup: no tracked Hermes background process and no listener on `127.0.0.1:8766` after tests.

## Stage A — environment and contract verification

Status: complete for implementation planning. No Hermes core implementation files were modified during this stage. The only repo-local changes are Logos documentation/reference files under `/path/to/logos/docs/logos/`.

### Workspace and references

- Development workspace: `/path/to/logos`
- Hermes source inspected: `/path/to/hermes-agent`
- Hermes profile/home: `$HERMES_HOME`
- Stable reference directory: `/path/to/logos-agent-reference`
- Repo-local reference copy: `/path/to/logos/docs/logos/reference`
- Reference hashes copied into repo-local docs:
  - `logos-agent-autonomous-handoff-prompt-v2.md`: `27e7866b927e0fa0d8b9495754ddebaf182feb403cc9848b35e9e93fa9a3f42c`
  - `logos-architecture-v2.2.md`: `6b83ccbb308f23211a1e1b34a33c045e472e0fbd73440a39b91c3dbed5cb63d0`

### Baseline repository state

Hermes repo:

- Root: `/path/to/hermes-agent`
- `git status --short`: clean
- Hermes CLI: `/path/to/hermes-agent/venv/bin/hermes`
- Hermes version: `Hermes Agent v0.13.0 (2026.5.7)`
- Hermes runtime Python reported by CLI: `3.11.15`
- System `python3`: `Python 3.9.6` at `/usr/bin/python3`; use Hermes venv Python for Hermes-side scripts/tests.

Logos workspace:

- Root: `/path/to/logos`
- Git repo initialized.
- Baseline before Stage A notes: `?? docs/` only.

### Xcode and Simulator facts

- `xcode-select -p`: `/Applications/Xcode.app/Contents/Developer`
- `xcodebuild -version`: `Xcode 26.4.1`, build `17E202`
- Swift: `Apple Swift version 6.3.1`
- Available iOS runtime: `iOS 26.4 (26.4.1 - 23E254a)`
- Available watchOS runtime: `watchOS 26.4 (26.4 - 23T240b)`
- Chosen initial simulator destination: `platform=iOS Simulator,name=iPhone 17 Pro,OS=26.4`
  - UDID: `<simulator-udid>`
- Other available iOS simulators: iPhone 17 Pro Max, iPhone 17e, iPhone Air, iPhone 17, and current iPad devices.

### Test profile strategy

- Automated Hermes integration tests should avoid mutating the real profile at `$HERMES_HOME`.
- Use a temporary `HERMES_HOME` under `/path/to/logos/.hermes-test/<name>` for adapter/gateway integration tests whenever possible.
- Do not run migrations or table changes against the real `state.db` without a timestamped backup.
- SQLite source of truth for the real profile currently exists at `$HERMES_HOME/state.db`.
- Kanban is intentionally shared under Hermes root and should remain on the real `logos-agent-voice-app` board for this implementation ledger.

## Hermes platform plugin facts

### Discovery and loading

Installed Hermes uses the general plugin manager in `hermes_cli/plugins.py`.

Discovery paths:

1. Bundled plugins: `<repo>/plugins/<name>/plugin.yaml`
2. Bundled platform plugins: `<repo>/plugins/platforms/<name>/plugin.yaml`
3. User plugins: `<HERMES_HOME>/plugins/<name>/plugin.yaml`
4. Project plugins: `<cwd>/.hermes/plugins/<name>/plugin.yaml` when project plugin discovery is enabled
5. Entry-point plugins

Important operational details:

- The manifest filename is lowercase `plugin.yaml` or `plugin.yml`. The architecture document says `PLUGIN.yaml`; that is stale for this build.
- Directory plugins must contain `__init__.py` exposing `register(ctx)`.
- Platform plugins should use `kind: platform` in `plugin.yaml`.
- Bundled platform plugins auto-load. User-installed platform plugins under `~/.hermes/plugins/` are still opt-in through `plugins.enabled` or `hermes plugins enable <name>`.
- Plugin debug logging can be enabled with `HERMES_PLUGINS_DEBUG=1`.

Recommended Logos source/runtime strategy:

- Source of truth: `/path/to/logos/plugins/logos/` or equivalent repo path.
- Runtime install: symlink or copy to `$HERMES_HOME/plugins/logos/`.
- Manifest: `$HERMES_HOME/plugins/logos/plugin.yaml`.
- Enable plugin: `hermes plugins enable logos` or equivalent config edit.
- Enable platform config: `platforms.logos.enabled: true` in Hermes config once plugin exists.

### Platform registration contract

Plugins register platform adapters through `PluginContext.register_platform(...)`, which wraps `gateway.platform_registry.PlatformEntry`.

This build requires this signature shape:

```python
ctx.register_platform(
    name="logos",
    label="Logos",
    adapter_factory=lambda cfg: LogosAdapter(cfg),
    check_fn=lambda: True,
    validate_config=validate_config,          # optional
    required_env=["LOGOS_DEVICE_SECRET"],
    allowed_users_env="LOGOS_ALLOWED_USERS", # recommended
    allow_all_env="LOGOS_ALLOW_ALL_USERS",   # dev-only escape hatch
    pii_safe=True,
    emoji="📱",
)
```

Architecture mismatch: the v2.2 example omits `check_fn`, but installed `register_platform()` requires it.

`Platform("logos")` is accepted only after runtime registration, because `gateway.config.Platform._missing_()` allows dynamic plugin platform pseudo-members for bundled platform plugins or registry-registered plugin platforms.

### Adapter interface

Logos should subclass `gateway.platforms.base.BasePlatformAdapter`.

Constructor:

```python
BasePlatformAdapter.__init__(config: PlatformConfig, platform: Platform)
```

Minimum methods Logos must implement:

- `async connect() -> bool`
- `async disconnect() -> None`
- `async send(chat_id: str, content: str, reply_to: str | None = None, metadata: dict | None = None) -> SendResult`

Useful optional methods/surfaces:

- `send_clarify(...)` — base implementation exists but Logos should override to emit `clarify_request` WebSocket frames.
- `send_exec_approval(...)` — not on the base class, but gateway detects whether the adapter class defines it. Logos should implement this to emit `approval_request` WebSocket frames and then resolve through Hermes approval semantics.
- `send_typing`, `stop_typing`, `pause_typing_for_chat`, `resume_typing_for_chat` support running-state UX but are not sufficient by themselves for the Logos `run_status` protocol.

`SendResult` fields:

- `success: bool`
- `message_id: Optional[str]`
- `error: Optional[str]`
- `raw_response: Any`
- `retryable: bool`
- `continuation_message_ids: tuple`

### Inbound message bridge

The correct gateway path is:

```python
await self.handle_message(MessageEvent(...))
```

That calls the adapter-owned active-session guard and eventually the gateway runner’s message handler. Logos must not instantiate `AIAgent` directly for normal text/speech input.

Required `MessageEvent` fields for Logos text/speech final input:

```python
MessageEvent(
    text=final_text,
    message_type=MessageType.TEXT,
    source=SessionSource(
        platform=Platform("logos"),
        chat_id=f"project:{project_key}",
        chat_name=project_title,
        chat_type="dm",
        user_id=device_or_user_id,
        user_name=device_display_name,
        message_id=client_msg_id,
    ),
    message_id=client_msg_id,
    raw_message=original_frame,
)
```

Why `chat_type="dm"`: Hermes session-key construction treats non-DM chat types as group/channel-like and may append `user_id` when `group_sessions_per_user` is enabled. For v1, a Logos project should be keyed by project, not by device/user suffix. Using DM semantics with `chat_id="project:<project_key>"` yields stable keys like:

```text
agent:main:logos:dm:project:<project_key>
```

This is a small adjustment from the architecture example (`chat_type: project`) to match installed session-key behavior while preserving the product intent.

Authorization note:

- `_handle_message()` ignores unauthenticated non-internal messages.
- `SessionSource.user_id` must be populated.
- Plugin platforms can provide `allowed_users_env` / `allow_all_env`; Logos should use `LOGOS_ALLOWED_USERS` and `LOGOS_ALLOW_ALL_USERS` so gateway authorization works normally.
- WebSocket shared-secret authentication is still required before constructing a `MessageEvent`; gateway auth is a second layer, not a substitute.

### Outbound delivery path

For non-streaming final replies, `GatewayRunner._handle_message()` returns text to `BasePlatformAdapter._process_message_background()`, which calls the adapter’s `send(...)` method. Logos `send(...)` should:

1. Store/mirror the outbound assistant/system text in Logos metadata or replication store.
2. Generate/attach adapter `server_seq`.
3. Emit a `state_update` / message append frame to connected WebSocket clients.
4. Return `SendResult(success=True, message_id=<logos-visible-id>)`.

Streaming/draft paths use adapter methods such as `send`, `edit_message`, and platform stream consumers where supported. Gateway activity text that is not a true Hermes final response, including still-working, retry, individual provider-call abort/timeout notices, preflight compression, and context-compaction notices, should be forwarded as transient `gateway_status` progress so clients keep the run active until a real final response or terminal run-status arrives. Real final assistant responses emitted by the Logos adapter carry `metadata.finalized = true` and default `metadata.source = "hermes"`; active-request assistant text without that terminal metadata is a progress/status signal for iOS.

## Slash command and run-state facts

### Command detection relative to agent creation

Slash commands are detected before a normal agent run is started:

- Adapter layer: `BasePlatformAdapter.handle_message()` detects commands for active-session bypass. Resolvable commands bypass the adapter active-session guard so `/stop`, `/approve`, `/deny`, etc. do not deadlock behind a running agent.
- Gateway layer: `GatewayRunner._handle_message()` resolves command definitions early, before session claim and before `AIAgent` creation.
- The gateway only sets the `_AGENT_PENDING_SENTINEL` and begins agent creation after command/quick-command/plugin-command/skill-command checks.

Consequence for Logos:

- Text beginning with `/` must be forwarded unchanged through `handle_message()`.
- Logos must not parse/reimplement gateway slash commands except for narrow voice-intent sugar that intentionally translates speech to a slash command.

### Relevant commands in this build

Command registry includes:

- `/resume [name]`
- `/title [name]`
- `/sessions`
- `/queue <prompt>` / `/q <prompt>`
- `/steer <prompt>`
- `/stop`
- `/approve [all] [session|always]`
- `/deny [all]`
- `/status`
- `/kanban ...`

Verified gateway handlers:

- `/resume`: implemented in `GatewayRunner._handle_resume_command()`.
  - With no args: lists recent titled sessions for the same source/platform.
  - With args: resolves by title via `SessionDB.resolve_session_by_title(...)`, then follows `resolve_resume_session_id(...)` to avoid compression child issues, then calls `session_store.switch_session(...)`.
- `/title`: implemented. Sets or shows current session title.
- `/queue`: implemented. In an active run it queues one full future turn per invocation, FIFO, without merging. Without a running agent, `/queue` is not a normal user prompt path; use only where the gateway expects it.
- `/stop`: implemented. Interrupts/clears running or pending agent state and returns an ephemeral stop notice.
- `/approve` and `/deny`: implemented. They unblock `tools.approval` gateway approvals; bare text like `yes` does not approve anything.
- `/status`: implemented and reports session/run status.
- `/kanban`: implemented in the gateway and bypasses the running-agent guard.

`/sessions` finding:

- The command registry advertises `/sessions` as “Browse and resume previous sessions”.
- I found no dedicated `canonical == "sessions"` gateway handler in `gateway/run.py`.
- Because `/sessions` is a known command but lacks a handler in this build, it is not reliable as a Logos dependency. Treat it as optional/pass-through only. Logos should implement its picker through read-only session queries and use `/resume` for explicit continuation.

### Running-agent and queue behavior

Adapter-level active-session behavior:

- Resolvable slash commands bypass the active-session guard.
- `/stop`, `/new`, `/reset` use a dedicated handoff path that cancels the in-flight adapter task and preserves ordering.
- Other bypass commands such as `/approve`, `/deny`, `/status`, `/background`, `/restart` dispatch directly to the gateway handler.
- If a clarify prompt is waiting for free-form text, the next non-command message bypasses the normal interrupt path and reaches the clarify resolver.
- Photo bursts queue without interrupt.
- Default non-photo follow-up while running stores a pending event and signals interrupt.

Gateway-level behavior:

- Recognized slash commands during active runs are generally rejected mid-turn unless they have special handling: `⏳ Agent is running — /<cmd> can't run mid-turn...`.
- `/queue` is explicitly safe for future-turn FIFO queuing.
- `/steer` is an in-run injection after next tool call when supported; otherwise falls back to queue-like behavior.
- Pending exec approvals are only resolved by `/approve` or `/deny`, not natural language.

Logos implications:

- `run_cancel` should send `/stop` as a `MessageEvent` through `handle_message()`.
- Approval buttons can either send `/approve` / `/deny` through `handle_message()` or call the same underlying `tools.approval.resolve_gateway_approval()` from a rich adapter callback. Prefer the gateway command path for Stage E unless direct button resolution is needed.
- Clarification text answers should route as normal text on the same project/session when the gateway is awaiting text. Button choices can call `tools.clarify_gateway.resolve_gateway_clarify(clarify_id, response)`.

## Sessions, message IDs, lineage, and state storage

SQLite schema (`hermes_state.py`) includes:

```sql
sessions(
  id TEXT PRIMARY KEY,
  source TEXT NOT NULL,
  user_id TEXT,
  model TEXT,
  model_config TEXT,
  system_prompt TEXT,
  parent_session_id TEXT,
  started_at REAL NOT NULL,
  ended_at REAL,
  end_reason TEXT,
  message_count INTEGER DEFAULT 0,
  ...,
  title TEXT,
  handoff_state TEXT,
  handoff_platform TEXT,
  handoff_error TEXT
)

messages(
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  session_id TEXT NOT NULL REFERENCES sessions(id),
  role TEXT NOT NULL,
  content TEXT,
  tool_call_id TEXT,
  tool_calls TEXT,
  tool_name TEXT,
  timestamp REAL NOT NULL,
  token_count INTEGER,
  finish_reason TEXT,
  reasoning TEXT,
  reasoning_content TEXT,
  reasoning_details TEXT,
  codex_reasoning_items TEXT,
  codex_message_items TEXT
)

state_meta(key TEXT PRIMARY KEY, value TEXT)
```

Important session APIs:

- `build_session_key(source, group_sessions_per_user=True, thread_sessions_per_user=False)` is the source of truth for platform session keys.
- `SessionStore.get_or_create_session(source)` maps session key to current session id and persists a session record.
- `SessionStore.switch_session(session_key, target_session_id)` is used by `/resume`; it ends the current mapping with `session_switch`, reopens the target session, and stores the target session id under the existing platform session key.
- `SessionStore.load_transcript(session_id)` reads from SQLite first, with JSONL fallback if legacy JSONL has more messages.
- `SessionDB.get_compression_tip(session_id)` walks compression-child chains where parent `end_reason = 'compression'` and child started after parent ended.
- `SessionDB.resolve_resume_session_id(session_id)` redirects empty parent sessions to descendants that hold messages.
- `SessionDB.list_sessions_rich(...)` can project compression roots forward to their latest live tip.

Logos implications:

- Hermes `messages.id` is a stable integer message id suitable for phone dedupe/pagination when available.
- Hermes remains the conversation source of truth. Logos can read session/message rows for replication but must not write Hermes `messages` or `sessions` rows directly for phone-originated turns.
- A Logos-owned metadata DB/table can store `project_key`, `current_session_id`, `lineage_root_session_id`, `last_seen_message_id`, and `last_seen_server_seq`. If adding tables inside the real profile, back up SQLite first; for early Stage B/C use a Logos-owned SQLite file under the workspace/test profile.

## Approval and clarification callbacks

### Approval

- Dangerous command approval state lives in `tools.approval` and is keyed by gateway `session_key`.
- Gateway registers a per-session approval notify callback before agent execution.
- If the adapter class implements `send_exec_approval(...)`, gateway prefers it for rich approval UI; otherwise it falls back to `send(...)` with textual `/approve` instructions.
- `/approve` and `/deny` call `tools.approval.resolve_gateway_approval(session_key, choice, resolve_all=...)`.
- Approval choices include `once`, `session`, `always`, and `deny`; Logos v1 should expose one-shot approve/deny only and avoid persistent approval policies unless the user explicitly chooses the built-in Hermes variants.

### Clarification

- Clarify state lives in `tools.clarify_gateway`.
- Gateway calls adapter `send_clarify(chat_id, question, choices, clarify_id, session_key, metadata)` and then blocks the agent thread with a timeout.
- Base `send_clarify()` sends a numbered text fallback and marks the clarify entry as awaiting text.
- Rich adapters should resolve button choices through `tools.clarify_gateway.resolve_gateway_clarify(clarify_id, response)`.
- Open-ended clarification responses are captured by the gateway text-intercept when the next non-command message arrives in the same session.

Logos implications:

- Stage E should implement `send_clarify()` to emit `clarify_request` frames including `clarify_id` and `session_key`.
- `clarify_response` frames can call `resolve_gateway_clarify(...)` directly for choices or send normal text through the same project session for open-ended answers.

## Kanban facts

- Board slug: `logos-agent-voice-app`
- Board name: `Logos Agent Voice App`
- Board description: `Implementation of the Logos iPhone voice-and-tap interface for Hermes Agent.`
- Current active board: `logos-agent-voice-app`
- Board DB: `$HERMES_HOME/kanban/boards/logos-agent-voice-app/kanban.db`
- Board metadata: `$HERMES_HOME/kanban/boards/logos-agent-voice-app/board.json`
- Kanban home/root: `$HERMES_HOME`

Available Kanban surface in this agent run:

- No model-visible `kanban_*` tools are available in the active toolset.
- Reliable surface is the Hermes CLI: `hermes kanban ...`.
- Commands already verified by use: `boards list`, `boards create`, `claim`, `comment`, `complete`, and `list` with `--board logos-agent-voice-app`.
- Use `--board logos-agent-voice-app` explicitly during this implementation to avoid accidental writes to the wrong board.

## Architecture/code mismatches and decisions

1. **Manifest filename**
   - Architecture says `PLUGIN.yaml`.
   - Installed code scans `plugin.yaml` / `plugin.yml` only.
   - Decision: use lowercase `plugin.yaml`.

2. **`register_platform` example missing `check_fn`**
   - Architecture example omits `check_fn`.
   - Installed `PluginContext.register_platform()` requires `check_fn`.
   - Decision: include `check_fn=lambda: True` initially, with real dependency checks as features are added.

3. **User plugin loading is opt-in**
   - Architecture implies putting files under `~/.hermes/plugins/logos/` is enough.
   - Installed user plugins are gated by `plugins.enabled`.
   - Decision: Stage B should install/symlink the plugin and enable it explicitly.

4. **Project chat type**
   - Architecture suggests a `project` chat type and session key shape like `agent:main:logos:project:project:<key>`.
   - Installed `build_session_key()` treats non-DM types as group/channel-like and may append `user_id`.
   - Decision: use `chat_type="dm"` with `chat_id="project:<project_key>"` for stable project-scoped sessions unless tests reveal a cleaner registered platform path.

5. **`/sessions`**
   - Architecture correctly says not to hard-depend on `/sessions`.
   - Installed registry advertises it, but no dedicated gateway handler was found.
   - Decision: build Logos project/session picker from read-only session queries and use `/resume` for continuity.

6. **Approval rich UI method**
   - `send_exec_approval()` is a duck-typed adapter method, not a base abstract method.
   - Decision: implement it on Logos adapter class explicitly when Stage E starts.

## Stage plan adjustments before coding

- Stage B should start with a user plugin scaffold under the Logos workspace, then symlink/copy to `$HERMES_HOME/plugins/logos` only after the source files exist.
- Use a test profile and a minimal gateway runner test before touching real profile config.
- For first bridge tests, use `chat_type="dm"`, `chat_id="project:default"`, and a deterministic test `user_id` that is admitted by Logos auth config.
- Implement a Logos-owned sequence/message mirror. Do not depend on Hermes timestamps for pagination.
- Keep `/resume`, `/title`, `/stop`, `/queue`, `/approve`, `/deny`, and `/kanban` on the gateway path by sending exact slash text through `handle_message()`.
- Treat `/sessions` as unsupported/research-only until a handler is added upstream.

## Stage A acceptance check

- Plugin discovery/loading path known: yes.
- Correct plugin manifest/config shape known: yes, with v2.2 corrections.
- Base adapter interface known: yes.
- Inbound gateway bridge known: yes, `await self.handle_message(MessageEvent(...))`.
- Outbound adapter delivery known: yes, gateway/base calls adapter `send(...)` and optional rich methods.
- Slash command position relative to agent creation known: yes, detected before normal agent run and before sentinel claim.
- `/resume`, `/title`, `/queue`, `/stop`, `/approve`, `/deny` behavior inspected: yes.
- `/sessions` status inspected: advertised but no dedicated gateway handler found; not reliable.
- Session/message/state schema inspected: yes.
- Approval/clarification callback surfaces inspected: yes.
- Kanban board/tool facts recorded: yes.
- Xcode/Simulator facts recorded: yes.

## Stage B — Logos platform plugin and WebSocket text bridge

Status: implemented and simulator-independent tests passing.

### Files added

- `plugins/logos/plugin.yaml` — user platform plugin manifest, using the installed lowercase manifest filename.
- `plugins/logos/__init__.py` — exposes `register(ctx)` for Hermes plugin loading.
- `plugins/logos/adapter.py` — `LogosAdapter` implementation with WebSocket-backed platform bridge.
- `plugins/logos/schema.py` — typed Stage B JSON envelope parser/serializer and redacted error frames.
- `plugins/logos/ws_server.py` — authenticated local WebSocket server.
- `scripts/logos_ws_client.py` — minimal CLI test client.
- `tests/test_stage_b_schema.py` — envelope/secret-redaction tests.
- `tests/test_stage_b_plugin_registration.py` — plugin registration contract test.
- `tests/test_stage_b_adapter_ws.py` — adapter and WebSocket round-trip tests.
- `tests/test_stage_b_cli.py` — CLI help import-safety regression test.

### Runtime install strategy

- Source of truth remains under `/path/to/logos/plugins/logos`.
- Runtime plugin path installed as a symlink:

```text
$HERMES_HOME/plugins/logos -> /path/to/logos/plugins/logos
```

- Enabled plugin with `hermes plugins enable logos`.
- Did not enable `platforms.logos.enabled` in the real profile yet; adapter startup still requires `LOGOS_DEVICE_SECRET` or `platforms.logos.extra.device_secret`.

### Implemented Stage B behavior

- Hermes plugin registration uses:
  - `name="logos"`
  - `label="Logos"`
  - `kind: platform`
  - `required_env=["LOGOS_DEVICE_SECRET"]`
  - `allowed_users_env="LOGOS_ALLOWED_USERS"`
  - `allow_all_env="LOGOS_ALLOW_ALL_USERS"`
- `LogosAdapter` subclasses `BasePlatformAdapter` and implements:
  - `connect()` / `disconnect()`
  - `send(...)`
  - `get_chat_info(...)`
- Local WebSocket server starts on `LOGOS_HOST`/`LOGOS_PORT` or `platforms.logos.extra.host/port`, defaulting to `127.0.0.1:8765`.
- WebSocket authentication requires a signed `hello` frame using HMAC-SHA256 over device id, request id, project key, timestamp, and nonce. Plaintext `payload.secret` hello frames are rejected; failed auth returns an `error` frame and closes with code `1008`.
- Final `text_input`, `text_message`, and final `speech` frames create a Hermes `MessageEvent` and call `await self.handle_message(event)`.
- Non-final `speech` frames do not enter the Hermes gateway path; they return a transient `state_update` with `op="speech_partial_received"`.
- Slash command text is not rewritten or swallowed; `/resume archwright` is forwarded unchanged through the same `handle_message(...)` path.
- Gateway responses delivered through adapter `send(...)` are broadcast to authenticated WebSocket clients as `state_update` frames with `op="message_appended"`.
- Adapter-created Stage B outbound messages include monotonic in-memory `server_seq` values. Durable replay/message replication is deliberately left for Stage C.

### Verification commands run

```bash
PYTHONPATH=/path/to/logos/plugins:/path/to/hermes-agent \
  $HERMES_PYTHON -m pytest -q \
  tests/test_stage_b_cli.py \
  tests/test_stage_b_schema.py \
  tests/test_stage_b_plugin_registration.py \
  tests/test_stage_b_adapter_ws.py
# 10 passed

PYTHONPATH=/path/to/logos/plugins:/path/to/hermes-agent \
  $HERMES_PYTHON -m compileall -q \
  plugins/logos scripts/logos_ws_client.py tests

/usr/bin/python3 scripts/logos_ws_client.py --help

PYTHONPATH=/path/to/hermes-agent \
  $HERMES_PYTHON - <<'PY'
from hermes_cli.plugins import discover_plugins, get_plugin_manager
from gateway.config import PlatformConfig
from gateway.platform_registry import platform_registry

discover_plugins(force=True)
entry = platform_registry.get('logos')
plugins = {p['key']: p for p in get_plugin_manager().list_plugins()}
print('logos_entry=', bool(entry))
print('logos_plugin=', plugins.get('logos'))
adapter = platform_registry.create_adapter(
    'logos',
    PlatformConfig(enabled=True, extra={'device_secret': 'test-secret', 'host': '127.0.0.1', 'port': 0}),
)
print(type(adapter).__name__, adapter.platform.value)
PY
```

Observed:

- Stage B pytest suite: `10 passed`.
- Plugin manager discovers user plugin `logos` as enabled, kind `platform`, error `None`.
- Platform registry creates `LogosAdapter` for platform value `logos`.
- No Hermes core files were modified.

### Stage B remaining risks / next-stage seams

- `server_seq` is currently in-memory only. Stage C must persist or otherwise replay server sequence/message mirror state.
- `send(...)` currently broadcasts to all authenticated clients. Stage C/D should add project/session-aware filtering and reconnect replay.
- Outbound `message_id` is adapter-generated (`logos-<server_seq>`) at Stage B. Stage C should key replication to Hermes `messages.id` where available.
- Real Hermes gateway run with a configured `platforms.logos.enabled` remains to be exercised once Stage C/D storage and test-profile setup are in place.

## Stage C — protocol sequencing and message replication

Status: implemented and tests passing.

### Files added/changed

- `plugins/logos/store.py` — SQLite-backed Logos mirror for `server_seq` and replicated messages.
- `plugins/logos/schema.py` — added `CLIENT_FRAME_TYPES`, `SERVER_FRAME_TYPES`, and `protocol_json_schema()`.
- `plugins/logos/adapter.py` — added persistent store integration, `messages_get`, `messages_batch`, replay helper, store-backed outbound message ids/sequences.
- `plugins/logos/ws_server.py` — `hello` now supports reconnect replay via `after_server_seq` / `last_seen_server_seq`.
- `docs/logos/LOGOS_PROTOCOL.md` — Swift-compatible envelope/message contract and pagination rules.
- `tests/test_stage_c_store.py` — store sequence, dedupe, persistence, and pagination tests.
- `tests/test_stage_c_protocol.py` — protocol type/schema tests.
- `tests/test_stage_c_adapter_replay.py` — `messages_get` and reconnect replay tests.

### Storage contract

Stage C added a Logos-owned SQLite mirror, not direct writes to Hermes `state.db`:

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

Default runtime path: `~/.hermes/logos/logos.db`.

Tests pass `platforms.logos.extra.store_path` and do not write the real profile. One default-path test artifact was created during development and removed immediately; runtime platform config is still not enabled.

### Implemented Stage C behavior

- Outbound gateway responses are persisted in the Logos mirror before broadcast.
- `server_seq` is now generated by `LogosStore` and persists across adapter/store restarts.
- Messages deduplicate by `(session_id, message_id)`.
- If Hermes metadata supplies `message_id` / `hermes_message_id`, the mirror uses it. Otherwise Stage C uses adapter ids like `logos-<server_seq>`.
- `messages_get` supports:
  - `after_server_seq` / `last_seen_server_seq` delta replay by `project_key`.
  - `before_message_id` older-history pagination by `session_id`.
  - bounded `limit` clamped to `1...500`.
- `messages_batch` returns protocol messages ordered by ascending `server_seq`.
- WebSocket `hello` accepts `payload.after_server_seq` or `payload.last_seen_server_seq`; after auth ack, the server immediately sends a `messages_batch` with missed messages.
- Protocol frame type sets now include Stage C/D/E-forward types needed by the iOS client without changing the envelope shape later.

### Verification commands run

```bash
PYTHONPATH=/path/to/logos/plugins:/path/to/hermes-agent \
  $HERMES_PYTHON -m pytest -q \
  tests/test_stage_b_cli.py \
  tests/test_stage_b_schema.py \
  tests/test_stage_b_plugin_registration.py \
  tests/test_stage_b_adapter_ws.py \
  tests/test_stage_c_store.py \
  tests/test_stage_c_protocol.py \
  tests/test_stage_c_adapter_replay.py
# 18 passed

PYTHONPATH=/path/to/logos/plugins:/path/to/hermes-agent \
  $HERMES_PYTHON -m compileall -q \
  plugins/logos scripts/logos_ws_client.py tests
```

Observed:

- Stage B+C pytest suite: `18 passed`.
- Plugin manager still discovers enabled `logos` plugin with error `None`.
- Platform registry creates `LogosAdapter` with explicit test `store_path`.
- No Hermes core files were modified.

### Stage C remaining risks / next-stage seams

- The mirror still records assistant outputs delivered through adapter `send(...)`; it does not yet backfill existing Hermes `messages` rows for arbitrary old sessions. Stage D project/session picker should read Hermes sessions and seed/resume pointers safely.
- Project/session ids are still simple Stage B values (`chat_id` fallback if no metadata session id). Stage D must reconcile to actual Hermes session ids and `/resume` behavior.
- Client filtering remains broadcast-all for authenticated clients. Stage D should bind active project/device state.

## Stage D — sessions, project routing, and `/resume`

Status: implemented for Logos-owned project routing and gateway pass-through. Existing Hermes session import/lineage backfill remains a deeper integration seam for later stages.

### Files added/changed

- `plugins/logos/store.py` — added `logos_projects`, `logos_device_pointers`, project slugging, project CRUD, active device pointer APIs.
- `plugins/logos/adapter.py` — added handlers for `list_projects`, `new_project`, `switch_project`, and `rename_project`; final text now resolves active project pointer when no project key is supplied.
- `docs/logos/PROJECT_ROUTING.md` — Stage D routing/storage contract.
- `tests/test_stage_d_projects.py` — project store/pointer/slug tests.
- `tests/test_stage_d_adapter_projects.py` — adapter project lifecycle, active pointer routing, `/resume` pass-through, and picker session pointer tests.

### Implemented Stage D behavior

- Device-local active project pointer is stored in `logos_device_pointers` keyed by `device_id`.
- Project metadata is stored in `logos_projects`:
  - `project_key`
  - `title`
  - `chat_id`
  - `current_session_id`
  - `lineage_root_session_id`
  - `last_seen_message_id`
  - `last_seen_server_seq`
  - `last_preview`
  - timestamps
- `new_project` creates a slug key from title and avoids collisions (`archwright-phase-6`, `archwright-phase-6-2`).
- `switch_project` sets the active pointer for the device and creates a placeholder project if needed.
- `rename_project` updates Logos metadata.
- `list_projects` returns `projects_list` with `active_project_key`.
- Final `text_input`/`speech` without `project_key` uses the device active project.
- Final text still enters Hermes through `await self.handle_message(MessageEvent(...))`.
- `/resume Alpha` is preserved exactly as slash-command text and routed through the gateway path.
- Adapter `send(...)` updates project session pointers and last preview when gateway responses include `metadata.session_id`.

### Verification commands run

```bash
PYTHONPATH=/path/to/logos/plugins:/path/to/hermes-agent \
  $HERMES_PYTHON -m pytest -q tests
# 23 passed
```

Observed:

- Stage B+C+D pytest suite: `23 passed`.
- No Hermes core files were modified.
- No runtime platform config was enabled; tests continue to use explicit temporary `store_path` values.

### Stage D remaining risks / next-stage seams

- The picker lists Logos-owned projects. It does not yet import every historical Hermes desktop session into the mobile picker.
- `lineage_root_session_id` is stored but not yet actively reconciled against compression child sessions.
- Renaming is currently Logos metadata only. Users can still issue `/title <name>` through text/voice for Hermes-native title changes.
- Client filtering remains broadcast-all for authenticated clients; now that active pointers exist, Stage E/F can apply project-aware filtering when multiple devices/clients are connected.

## Stage E — run state, queue, stop/cancel, approval, and clarification

Status: implemented with deterministic adapter fixtures and gateway-compatible command/callback routing.

### Files added/changed

- `plugins/logos/adapter.py`
  - Emits `run_status` frames for `running`, `idle`, `cancelling`, `awaiting_approval`, and `awaiting_clarification`.
  - Maps `run_cancel` to literal `/stop` on the normal Hermes gateway path.
  - Maps `approval_response` to `/approve` or `/deny` on the normal gateway path.
  - Adds `send_exec_approval(...)` for Hermes dangerous-command approval cards.
  - Overrides `send_clarify(...)` for rich `clarify_request` cards and native clarify resolution support.
  - Attempts `resolve_gateway_clarify(clarify_id, text)` before falling back to forwarding clarify text as a user message.
- `docs/logos/RUN_INTERACTIONS.md` — Stage E protocol/semantics contract.
- `tests/test_stage_e_interactions.py` — stop, approval, clarification, rich cards, and run-status tests.
- `tests/test_stage_b_adapter_ws.py` — updated text round-trip test to account for the new `run_status: running` frame before the response update.

### Implemented Stage E behavior

- Final text/speech broadcasts `run_status: running` before entering Hermes via `handle_message(...)`.
- `send(...)` broadcasts the assistant `state_update` and then `run_status: idle` when a WebSocket server is active.
- Run status is transient adapter/client state, not fake persisted Hermes history.
- `run_cancel` emits/returns `run_status: cancelling` and forwards `/stop` unchanged.
- `approval_response` only supports one-shot approve/deny mapping; no persistent policy system was added.
- `send_exec_approval(...)` emits private WebSocket approval card data. Real APNS privacy handling remains Stage J.
- `send_clarify(...)` emits rich clarification cards and marks the clarify id awaiting text when Hermes native clarify state is available.
- `clarify_response` first tries native `resolve_gateway_clarify`; if unresolved, it routes the answer through normal `MessageEvent` so simulator fixtures still work.
- Same-session queue semantics remain delegated to Hermes gateway. Logos deliberately does not implement a competing queue engine.

### Verification commands run

```bash
PYTHONPATH=/path/to/logos/plugins:/path/to/hermes-agent \
  $HERMES_PYTHON -m pytest -q tests
# 28 passed

PYTHONPATH=/path/to/logos/plugins:/path/to/hermes-agent \
  $HERMES_PYTHON -m compileall -q \
  plugins/logos scripts/logos_ws_client.py tests
```

Observed:

- Stage B+C+D+E pytest suite: `28 passed`.
- No Hermes core files were modified.
- No runtime platform config was enabled; tests use temporary store paths.

### Stage E remaining risks / next-stage seams

- Native approval callback resolution in Hermes is still command-mediated (`/approve`/`/deny`) rather than a direct function call because the installed dangerous-command approval flow is session-command based.
- Run status is currently emitted by adapter edge events. A deeper future integration could mirror more granular gateway tool progress if Hermes exposes it through callbacks for this adapter.
- Broadcast filtering is still coarse; Stage F app state and later device registration should narrow presentation by active project/device.

## Stage F — iOS app skeleton in Xcode Simulator

Status: implemented and validated in iPhone Simulator against a deterministic Logos WebSocket fixture.

### Files added/changed

- `clients/ios/Logos/project.yml` — XcodeGen spec for the SwiftUI app, unit tests, and UI tests.
- `clients/ios/Logos/Logos/` — SwiftUI app source:
  - `LogosApp.swift`
  - `ContentView.swift`
  - `LogosClient.swift`
  - `LogosModels.swift`
  - `SQLiteMessageStore.swift`
  - `Info.plist`
- `clients/ios/Logos/LogosTests/LogosModelTests.swift` — model/environment unit tests.
- `clients/ios/Logos/LogosUITests/LogosUITests.swift` — simulator text, approval, and clarification UI tests.
- `scripts/run_stage_f_mock_adapter.py` — deterministic simulator fixture that uses the real Logos adapter/WebSocket/schema/store path while replacing Hermes execution with predictable responses.
- `docs/logos/IOS_SIMULATOR_STAGE_F.md` — app, commands, and simulator verification notes.
- `docs/logos/stage-f-final-simulator.png` — launch screenshot captured from the iPhone 17 Pro Simulator.

### Implemented Stage F behavior

- SwiftUI app builds for iOS Simulator using Xcode 26.4.1.
- App connects via native `URLSessionWebSocketTask` and authenticates with the Logos `hello` frame.
- Launch configuration can be injected by `SIMCTL_CHILD_LOGOS_WS_URL`, `SIMCTL_CHILD_LOGOS_DEVICE_SECRET`, `SIMCTL_CHILD_LOGOS_DEVICE_ID`, and `SIMCTL_CHILD_LOGOS_AUTOCONNECT`.
- Text chat UI sends `text_input` frames and renders `state_update` assistant messages.
- Local SQLite store persists rendered messages in the app container.
- Project picker uses `list_projects`; new project UI sends `new_project`.
- Run status UI renders `idle` / running-style states and sends `run_cancel` for stop.
- Approval and clarification cards render from Stage E protocol frames and send `approval_response` / `clarify_response`.
- Error frames and WebSocket failures surface as visible UI error text.

### Verification commands run

```bash
PYTHONPATH=/path/to/logos/plugins:/path/to/hermes-agent \
  $HERMES_PYTHON -m pytest -q tests
# 28 passed

PYTHONPATH=/path/to/logos/plugins:/path/to/hermes-agent \
  $HERMES_PYTHON -m compileall -q \
  plugins/logos scripts tests

cd /path/to/logos/clients/ios/Logos
xcodegen generate --spec project.yml
xcodebuild -project Logos.xcodeproj -scheme Logos \
  -destination 'platform=iOS Simulator,id=<simulator-udid>' build
# succeeded

xcodebuild -project Logos.xcodeproj -scheme Logos \
  -destination 'platform=iOS Simulator,id=<simulator-udid>' test
# succeeded: 3 unit tests + 2 UI tests
```

Observed:

- Python Logos suite: `28 passed`.
- iOS build: succeeded.
- iOS tests: succeeded.
- UI tests verified simulator auto-connect, text round trip, approval card, and clarification card against `scripts/run_stage_f_mock_adapter.py`.
- A port handling bug was fixed in `LogosAdapter.__init__`: explicit `port: 0` now remains port zero for ephemeral test sockets instead of falling back to `8765`. Tiny detail. Large blast radius if left alone.

### Stage F remaining risks / next-stage seams

- The simulator fixture replaces live Hermes execution. Full live gateway + simulator integration remains Stage K work.
- The local iOS store is intentionally simple SQLite and should be extended carefully as TTS/ASR/notifications add metadata.
- Physical-device networking, Tailscale behavior, microphone permissions/quality, on-device ASR, and APNS are still unverified gates.

## Stage G — TTS playback

Status: implemented with deterministic server-side WAV stub and iOS `AVAudioPlayer` playback plumbing. Kokoro was checked and is not installed in the Hermes venv, so the deterministic stub is the active Stage G engine; this keeps the protocol and client path testable without letting packaging drama hijack the mission.

### Files added/changed

- `plugins/logos/tts.py` — TTS interface plus `DeterministicStubTTS`, generating base64 WAV chunks from text.
- `plugins/logos/adapter.py` — handles `playback_audio`, selects message text by `message_id` or explicit text, emits `audio_chunk` frames, and terminates with `audio_end`.
- `plugins/logos/store.py` — added `get_message(session_id, message_id)` lookup used by playback requests.
- `tests/test_stage_g_tts.py` — adapter-level tests for WAV chunk generation, `playback_audio`, `audio_end`, and missing-message error handling.
- `clients/ios/Logos/Logos/AudioPlaybackController.swift` — buffers streamed audio chunks, assembles WAV data, and plays it through `AVAudioPlayer`.
- `clients/ios/Logos/Logos/LogosClient.swift` — sends `playback_audio`, receives `audio_chunk` / `audio_end`, and surfaces playback status.
- `clients/ios/Logos/Logos/ContentView.swift` — adds Play buttons on persisted assistant messages and playback status UI.
- `clients/ios/Logos/LogosUITests/LogosUITests.swift` — extends the simulator text round-trip test to tap Play and verify playback status.
- `docs/logos/stage-g-playback-simulator.png` — simulator screenshot showing the Stage G app with connected status and Play controls.

### Implemented Stage G behavior

- Server-side `playback_audio` supports `message_id` lookup and explicit text fallback.
- Audio frames use protocol-native `audio_chunk` envelopes and a final `audio_end` envelope.
- Stub output is deterministic WAV (`audio/wav`) so tests and Simulator runs are stable.
- iOS receives chunks, buffers them by `audio_id`, assembles them on `audio_end`, and starts `AVAudioPlayer` playback.
- The UI exposes Play buttons only for persisted assistant messages.
- Playback status is transient UI state; no fake audio events are persisted into Hermes conversation history.

### Verification commands run

```bash
$HERMES_PYTHON - <<'PY'
try:
    import kokoro
    print('kokoro installed')
except Exception as exc:
    print('kokoro unavailable:', type(exc).__name__, str(exc)[:160])
PY
# kokoro unavailable: ModuleNotFoundError No module named 'kokoro'

PYTHONPATH=/path/to/logos/plugins:/path/to/hermes-agent \
  $HERMES_PYTHON -m pytest -q tests
# 31 passed

PYTHONPATH=/path/to/logos/plugins:/path/to/hermes-agent \
  $HERMES_PYTHON -m compileall -q plugins/logos scripts tests

cd /path/to/logos/clients/ios/Logos
xcodegen generate --spec project.yml
xcodebuild -project Logos.xcodeproj -scheme Logos \
  -destination 'platform=iOS Simulator,id=<simulator-udid>' build
# succeeded

xcodebuild -project Logos.xcodeproj -scheme Logos \
  -destination 'platform=iOS Simulator,id=<simulator-udid>' test
# succeeded: 3 unit tests + 2 UI tests
```

Observed:

- Python Logos suite: `31 passed`.
- iOS build: succeeded.
- iOS tests: succeeded.
- UI test verified simulator text round trip and tapped the assistant-message Play control; the app reported `Playing audio` after receiving and assembling the stub WAV stream.
- Screenshot `docs/logos/stage-g-playback-simulator.png` shows the app connected, idle, default project selected, assistant messages rendered, and Play buttons visible.

### Stage G remaining risks / next-stage seams

- Real Kokoro or another high-quality local TTS engine is not installed. The interface is in place; swapping implementation should be localized to `plugins/logos/tts.py`.
- Simulator audio audibility depends on host/simulator audio routing. The automated proof verifies the request/chunk/end/playback-control path, not human hearing quality.
- Summary-specific playback still uses message text/stub behavior; Stage H adds summary generation/storage hooks.
- Audio caching is not implemented yet. Fine for now; premature cache invalidation is how small apps become haunted houses.

## Stage H — fast local model for acknowledgment, intent, and summaries

Status: implemented with deterministic fallback model, strict output validation, narrow safe intent routing, transient ack events, and summary storage. MLX is installed, but no Qwen/MLX model cache was present; pulling a model during this run would be toolchain theater. The fallback keeps the interface stable and the core path moving.

### Environment check

```bash
$HERMES_PYTHON - <<'PY'
for mod in ('mlx_lm','mlx','ollama'):
    try:
        __import__(mod)
        print(f'{mod}: installed')
    except Exception as exc:
        print(f'{mod}: unavailable ({type(exc).__name__})')
PY
# mlx_lm: installed
# mlx: installed
# ollama: unavailable (ModuleNotFoundError)

ollama list
# gemma3:12b available through local Ollama CLI

# Qwen/MLX model cache check under ~/.cache/huggingface/hub: no Qwen models found.
```

### Files added/changed

- `plugins/logos/fast_llm.py` — deterministic fast-model interface, strict JSON parser, safe intent classifier, summary generator, and secret redaction.
- `plugins/logos/store.py` — added `logos_summaries` table plus `LogosSummary`, `upsert_summary`, and `get_summary`.
- `plugins/logos/adapter.py` — emits transient `fast_ack` updates, optional ack audio path for speech/`ack_audio`, routes narrow safe intents, and stores/broadcasts summary-ready metadata for assistant messages.
- `plugins/logos/tts.py` — reused by fast ack audio path.
- `clients/ios/Logos/Logos/LogosClient.swift` — handles `fast_ack` state updates.
- `clients/ios/Logos/Logos/ContentView.swift` — shows transient ack status in the status panel.
- `tests/test_stage_h_fast_model.py` — strict output, common utterance, summary redaction, ack, summary, and intent routing tests.
- `tests/test_stage_b_adapter_ws.py` — updated WebSocket ordering expectation for the new pre-run `fast_ack` frame.

### Implemented Stage H behavior

- Fast-model outputs are plain structured data and are not persisted as Hermes turns.
- Normal substantive requests still go through Hermes gateway after a transient `fast_ack` state update.
- Narrow intents route only when utterance shape is explicit:
  - `switch to <project>` switches only to an exact existing project title/key; unknown or ambiguous switches fall back to Hermes as normal text.
  - `create project <title>` creates/selects a Logos project.
  - `resume <target>` routes `/resume <target>` through Hermes gateway.
  - `stop`/`cancel` routes `/stop` through Hermes gateway.
  - `approve` / `deny` route `/approve` / `/deny` through Hermes gateway.
- Assistant responses are summarized immediately after `send(...)`; summaries are stored in `logos_summaries` keyed by `(session_id, message_id)`.
- Summaries redact common secret-token shapes before storage.
- `playback_audio` in summary mode now prefers stored summary text and lazily creates one if absent.
- iOS displays transient ack text and keeps it out of local message persistence.

### Verification commands run

```bash
PYTHONPATH=/path/to/logos/plugins:/path/to/hermes-agent \
  $HERMES_PYTHON -m pytest -q tests/test_stage_h_fast_model.py
# 5 passed

PYTHONPATH=/path/to/logos/plugins:/path/to/hermes-agent \
  $HERMES_PYTHON -m pytest -q tests
# 36 passed

PYTHONPATH=/path/to/logos/plugins:/path/to/hermes-agent \
  $HERMES_PYTHON -m compileall -q plugins/logos scripts tests

cd /path/to/logos/clients/ios/Logos
xcodegen generate --spec project.yml
xcodebuild -project Logos.xcodeproj -scheme Logos \
  -destination 'platform=iOS Simulator,id=<simulator-udid>' test
# succeeded: 3 unit tests + 2 UI tests
```

Observed:

- Python Logos suite: `36 passed`.
- iOS tests: succeeded.
- Simulator UI tests still verify text round trip, approval card, clarification card, and playback after fast-ack protocol changes.
- No Hermes core files were modified.

### Stage H remaining risks / next-stage seams

- The real fast model is not wired yet. MLX libraries are installed, but no Qwen-family model was locally cached. The implementation deliberately avoids downloading model weights mid-run.
- Ollama has `gemma3:12b`, but that is not necessarily the low-latency ack/intent model we want in the iPhone critical path.
- Intent routing is intentionally conservative; richer fuzzy matching should wait for real utterance data and evals.
- Summary quality is deterministic and serviceable, not smart. It is adequate for metadata/audio plumbing and can be swapped behind `fast_llm.py` later.

## Stage I — ASR UI and speech state machine

Status: implemented and Simulator-verified as far as Simulator can represent.

### Files added/changed

- `clients/ios/Logos/Logos/VoiceInputStateMachine.swift` — tap-to-talk energy/silence detector, on-device-recognition policy, and speech frame builder.
- `clients/ios/Logos/Logos/VoiceInputController.swift` — `SFSpeechRecognizer` + `AVAudioEngine` controller, hold/tap recording modes, partial/final transcript callbacks.
- `clients/ios/Logos/Logos/LogosClient.swift` — sends `speech` frames for partial and final transcripts.
- `clients/ios/Logos/Logos/ContentView.swift` — Voice panel, partial transcript display, hold-to-talk and tap-to-talk controls, accessibility identifiers.
- `clients/ios/Logos/Logos/Info.plist` — microphone and speech-recognition usage descriptions.
- `clients/ios/Logos/LogosTests/LogosModelTests.swift` — unit tests for silence detection, no-network fallback policy, speech-frame metadata, and usage descriptions.
- `clients/ios/Logos/LogosUITests/LogosUITests.swift` — UI test asserts Voice panel/control presence while preserving adapter round-trip tests.
- `docs/logos/DEVICE_TEST_CHECKLIST.md` — physical-device ASR validation checklist.
- `docs/logos/stage-i-voice-ui-simulator.png` — Simulator screenshot of the Stage I Voice panel.

### Implemented Stage I behavior

- `SFSpeechRecognizer` capability check gates voice input.
- `SFSpeechAudioBufferRecognitionRequest.requiresOnDeviceRecognition = true` is set for actual recognition requests.
- If `supportsOnDeviceRecognition` is false, voice controls are disabled and the UI explicitly says Logos will not silently use network recognition.
- Hold-to-talk starts recognition on press and dispatches a final transcript on release.
- Tap-to-talk starts/stops on tap and auto-stops after either initial silence or trailing silence after speech.
- Partial transcripts stream as `speech` frames with `is_final=false` and metadata: `client_msg_id`, `partial_seq`, and `started_at_ms`.
- Final transcripts dispatch as `speech` frames with `is_final=true`; empty final text is not sent.
- The Stage I UI has accessibility identifiers for test automation.

### Verification commands run

```bash
PYTHONPATH=/path/to/logos/plugins:/path/to/hermes-agent \
  $HERMES_PYTHON -m pytest -q tests
# 36 passed

PYTHONPATH=/path/to/logos/plugins:/path/to/hermes-agent \
  $HERMES_PYTHON -m compileall -q plugins/logos scripts tests

cd /path/to/logos/clients/ios/Logos
xcodebuild -project Logos.xcodeproj -scheme Logos \
  -destination 'platform=iOS Simulator,id=<simulator-udid>' build
# succeeded

xcodebuild -project Logos.xcodeproj -scheme Logos \
  -destination 'platform=iOS Simulator,id=<simulator-udid>' test
# succeeded: 8 unit tests + 2 UI tests
```

Observed:

- Python Logos suite: `36 passed`.
- iOS full unit/UI suite: passed.
- Simulator screenshot `docs/logos/stage-i-voice-ui-simulator.png` shows adapter connected, idle run status, Voice panel, on-device recognition available, `Hold to Talk`, and `Tap to Talk`.
- Real microphone/recognizer quality is not provable in Simulator. That is a hardware gate, not a code excuse.

### Stage I physical-device gates / next-stage seams

- Real iPhone microphone capture quality and latency.
- Real iPhone on-device recognition availability and transcript accuracy.
- Real permission-prompt/denial behavior.
- Tap-to-talk energy thresholds under actual device audio conditions.
- Background/interruption behavior during live recording.

## Stage J — notifications and private APNS path

Status: implemented with private payloads, credential-gated live APNS, and Simulator push/deep-link validation.

### Files added/changed

- `plugins/logos/apns.py` — APNS config/env loading, ES256 provider-token signing path, HTTP/2 live-send transport, per-device sandbox/production host selection, private payload builder, and live-send skip behavior when credentials/device tokens are absent.
- `plugins/logos/store.py` — `logos_devices` table plus `LogosDevice` model and upsert/list/get helpers for APNS token and capability metadata, including APNS registration clearing for stale Apple tokens.
- `plugins/logos/adapter.py` — `register_device` handling, device persistence, server capability negotiation, private completion/approval/clarification notification sends, and app-focus update handling.
- `tests/test_stage_j_notifications.py` — private-payload regression tests, device registration persistence, device capability/environment routing, HTTP/2 APNS transport metadata, Apple error-reason preservation, stale-token cleanup, finalized completion push coverage, and missing-credential APNS skip test.
- `clients/ios/Logos/Logos/NotificationCoordinator.swift` — notification authorization, APNS device-token capture, notification route parsing, URL deep-link route parsing, and route callback.
- `clients/ios/Logos/Logos/LogosApp.swift` — iOS app delegate registration for APNS token callbacks.
- `clients/ios/Logos/Logos/LogosClient.swift` — `register_device` frame sender, build-derived APNS environment registration, notification-route reconnect/delta sync handling, and finished-notification final-response playback.
- `clients/ios/Logos/Logos/ContentView.swift` — Notifications panel with explicit Enable button and route status surface.
- `clients/ios/Logos/Logos/Info.plist` — `remote-notification` background mode and `logos://` URL scheme.
- `clients/ios/Logos/LogosTests/LogosModelTests.swift` — unit tests for private-push route parsing, `logos://` deep-link parsing, URL scheme, and background mode.
- `clients/ios/Logos/LogosUITests/LogosUITests.swift` — UI test asserts notification panel presence.
- `docs/logos/stage-j-private-push.apns` — private Simulator push payload fixture.
- `docs/logos/stage-j-notification-route-simulator.png` — Simulator screenshot captured during Stage J deep-link attempt.

### Implemented Stage J behavior

- Client sends `register_device` with device id, display name, capabilities, APNS token when available, and APNS environment. Debug/device builds register `sandbox`; Release/TestFlight builds register `production`.
- Adapter persists devices in `logos_devices` without echoing raw APNS tokens back over WebSocket.
- Adapter sends APNS through the stored device environment, so sandbox and production devices can coexist. Devices without APNS tokens or without the `notifications` capability are skipped.
- Live APNS uses Apple's HTTP/2 provider API with token-based `.p8` authentication. APNS SSL certificates are not required for Logos.
- Apple APNS errors preserve status, APNS id, and reason in sanitized logs. `BadDeviceToken`, `DeviceTokenNotForTopic`, and `Unregistered` clear the stored APNS token without revoking the Logos device pairing.
- APNS payloads are private by construction:
  - completion: `Hermes finished` / `Open Logos to view the result.`
  - approval: `Hermes needs approval` / `Open Logos to continue.`
  - clarification: `Hermes needs clarification` / `Open Logos to continue.`
- Payloads carry routing ids (`project_key`, `session_id`, `message_id`, `server_seq`, `request_id`, `kind`) and deliberately ignore sensitive context such as response summaries, commands, questions, file paths, and secrets.
- Live APNS is skipped deterministically when required credentials are absent.
- Supported APNS env/config names:
  - `LOGOS_APNS_KEY_ID`
  - `LOGOS_APNS_TEAM_ID`
  - `LOGOS_APNS_BUNDLE_ID`
  - `LOGOS_APNS_AUTH_KEY_PATH`
  - `LOGOS_APNS_ENV` (`sandbox` or `production`)
- iOS notification permission is user-controlled via the Notifications panel `Enable` button; no surprise permission prompt on launch.
- Notification tap / route handling maps payload ids to app state and calls reconnect + `messages_get` delta sync from `server_seq - 1`.
- Finished notification routes are retained until the app is authenticated and the final assistant message is available. The app matches by `message_id` first, falls back to the latest finalized assistant message in the routed project/session at or after `server_seq`, and requests `final_auto` playback exactly once. Approval and clarification notifications sync state but do not auto-play.
- `logos://notification?...` deep links are supported for Simulator/development route validation.

### Verification commands run

```bash
PYTHONPATH=/path/to/logos/plugins:/path/to/hermes-agent \
  $HERMES_PYTHON -m pytest -q tests
# 45 passed

PYTHONPATH=/path/to/logos/plugins:/path/to/hermes-agent \
  $HERMES_PYTHON -m compileall -q plugins/logos scripts tests

cd /path/to/logos/clients/ios/Logos
xcodegen generate --spec project.yml
xcodebuild -project Logos.xcodeproj -scheme Logos \
  -destination 'platform=iOS Simulator,id=<simulator-udid>' build
# succeeded

xcodebuild -project Logos.xcodeproj -scheme Logos \
  -destination 'platform=iOS Simulator,id=<simulator-udid>' test
# succeeded: 19 unit tests + 2 UI tests

xcrun simctl push <simulator-udid> \
  dev.logos.app docs/logos/stage-j-private-push.apns
# Notification sent to 'dev.logos.app'

xcrun simctl openurl <simulator-udid> \
  'logos://notification?kind=approval&project_key=default&request_id=appr-sim&server_seq=1'
# Simulator displayed first-open confirmation for Logos URL route.
```

Observed:

- Python Logos suite: `45 passed`.
- iOS full unit/UI suite: passed.
- `xcrun simctl push` accepted the private payload fixture.
- `xcrun simctl openurl` hit the app URL route path but Simulator displayed the first-open confirmation (`Open in “Logos”?`). I did not click the system confirmation dialog. The route parser and reconnect/delta-sync call are covered in unit code; final notification-tap behavior remains part Simulator/manual Stage K and physical-device Stage L validation.
- Screenshot `docs/logos/stage-j-notification-route-simulator.png` shows the app connected with Notifications and Voice panels visible while the Simulator route confirmation is displayed.

### Stage J physical-device / credential gates

- Real APNS token registration requires Apple Developer signing/provisioning and a physical device.
- Live APNS delivery requires valid `LOGOS_APNS_*` credentials.
- Notification tap routing to a live app after background/suspend must be validated on hardware.
- Background reconnect behavior over Tailscale remains a physical iPhone gate.

## Stage K — end-to-end Simulator validation

Status: completed and documented in `docs/logos/TEST_REPORT.md`.

### Verification summary

- Python Logos suite: `45 passed`.
- Python compile check: passed.
- WebSocket CLI-style round trip: passed (`Mock Hermes received: stage k cli round trip`).
- iOS app generation/build/test: passed.
- iOS unit tests: 12 passed.
- iOS UI tests: 2 passed.
- Simulator launch: connected to local mock adapter.
- Simulator text message → adapter → response rendering: passed through UI tests.
- Project picker/default project surface: visible and usable.
- Approval/clarification fixture cards: rendered by UI tests.
- TTS playback plumbing: UI test tapped play and observed `Playing audio`.
- ASR UI/state-machine: unit/UI verified as far as Simulator can represent; real mic remains hardware-gated.
- Private APNS fixture: `xcrun simctl push` accepted `docs/logos/stage-j-private-push.apns`.
- Notification/deep-link: parser and reconnect/delta-sync path unit-covered; Simulator `openurl` shows first-open confirmation, not clicked.

### Stage K artifacts

- `docs/logos/TEST_REPORT.md`
- `docs/logos/DEVICE_TEST_CHECKLIST.md`
- `docs/logos/stage-k-simulator-app.png`
- `docs/logos/stage-j-notification-route-simulator.png`
- `docs/logos/stage-j-private-push.apns`
- `/tmp/logos-stage-k-full-test.log`

### Stage K conclusion

Everything local and Simulator-verifiable passes. Remaining work has crossed into physical iPhone, APNS credential, Tailscale hardware behavior, and eventually Apple Watch validation. Good. That is exactly where this should stop expanding and start proving itself on metal.

## Stage L — physical-device gate and final report

Status: completed.

Final report: `docs/logos/FINAL_REPORT.md`.

Stage L conclusion:

- Simulator-verifiable implementation is complete.
- Stage K test report is complete.
- Device checklist is complete enough for first hardware pass and should be filled in during real iPhone testing.
- No Apple Watch relay work was started.
- Physical/manual gate has now been accepted complete by the maintainer; no v1 implementation blocker remains.

## Post-physical/manual closure — 2026-05-18

Status: accepted complete by the maintainer after direct code fixes to the remaining field issues.

Post-manual code changes reviewed in this closure pass:

- `53d6a47` — hardens iOS speech delivery:
  - configures recording through the audio-session manager,
  - preserves/recovers undelivered final speech drafts on socket failure or disconnect,
  - adds pending-message reconciliation for final speech send confirmation.
- `36dc581` — adds iOS auto-connect and initial scroll hardening:
  - auto-connect resumes only after first successful connection unless launch environment explicitly forces it,
  - thread scrolls to the latest item on first layout and project switch.
- Follow-up verification fixes in this pass:
  - `tests/test_stage_f_mock_adapter.py` imports the mock adapter under the documented pytest command,
  - `LogosUITests.testTextMessageRoundTripThroughMockAdapter` now verifies playback status after tapping Play instead of requiring the Play button to remain visible.

Fresh verification from this pass:

```bash
PYTHONPATH=/path/to/logos/plugins:/path/to/hermes-agent \
  $HERMES_PYTHON -m pytest -q tests
# 49 passed

PYTHONPATH=/path/to/logos/plugins:/path/to/hermes-agent \
  $HERMES_PYTHON -m compileall -q plugins scripts tests
# passed

xcodebuild -project clients/ios/Logos/Logos.xcodeproj -scheme Logos \
  -destination 'id=<simulator-udid>' \
  -only-testing:LogosTests test
# LogosModelTests: 50 passed

LOGOS_UI_TEST_WS_URL=ws://127.0.0.1:8766 \
  xcodebuild -project clients/ios/Logos/Logos.xcodeproj -scheme Logos \
  -destination 'id=<simulator-udid>' test
# LogosUITests: 5 passed against Stage F mock adapter
```

Process hygiene after verification:

- Hermes background process registry empty.
- No listener on `127.0.0.1:8766`.

No v1 implementation blocker remains. Remaining ideas are post-v1 hardening/deferred scope: real TTS engine, real fast local model, Apple Watch relay, durable run recovery, and larger product-surface expansion.

Smoke verification after report generation:

```bash
PYTHONPATH=/path/to/logos/plugins:/path/to/hermes-agent \
  $HERMES_PYTHON -m pytest -q \
  tests/test_stage_j_notifications.py tests/test_stage_h_fast_model.py tests/test_stage_g_tts.py
# 12 passed
```

Stop condition reached.
