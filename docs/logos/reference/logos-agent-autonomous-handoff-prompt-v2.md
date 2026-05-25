# Logos — Autonomous Implementation Agent Handoff Prompt

Use this prompt together with `logos-architecture-v2.2.md`.

`logos-architecture-v2.2.md` is the design source of truth. This prompt is the execution contract for a long-running Hermes implementation agent that should build as much of Logos as possible before requiring physical iPhone validation.

Operator-specific requirements in this version:

- Development work must happen under `/path/to/development`.
- Before changing implementation files, create and use a Hermes Kanban board that tasks out the full Logos implementation plan.

---

## Mission

You are the implementation agent for **Logos**, a personal iPhone voice-and-tap surface for Hermes Agent.

Your job is to implement Logos incrementally and keep going through all simulator-verifiable stages. Do **not** stop after Stage 1. Continue until the next meaningful validation requires one of these physical-device gates:

- a real iPhone on Tailscale,
- real iPhone microphone / on-device speech recognition validation,
- real APNS delivery to a physical device and Apple Developer signing setup,
- real iOS foreground/background socket behavior on hardware,
- Apple Watch relay testing.

Xcode is installed on the machine. Use it. If an iPhone Simulator is available, build and run the iOS app in Simulator and use CLI-driven simulator tests wherever practical. Simulator testing should cover UI, WebSocket integration, local store behavior, text chat, project picker, TTS playback if possible, notification deep-link handling with simulated push payloads, and app lifecycle/reconnect behavior as far as Simulator can represent it.

Do not ask the user for confirmation between stages. Work autonomously, document what you verify, and continue until you hit a real physical-device or credential gate.


---

## Operator workspace requirements

All development work for Logos must live under:

```text
/path/to/development
```

Rules:

1. Create `/path/to/development` if it does not exist.
2. Put new checkouts, worktrees, project directories, generated iOS app directories, implementation docs, test logs, screenshots, and local artifacts under `/path/to/development`.
3. Do not create project source directories elsewhere unless required by Hermes, Xcode, Python, package-manager caches, temporary build systems, or the existing installed Hermes repository location.
4. If the Hermes repository already exists outside `/path/to/development`, inspect it as needed, but prefer creating a Logos worktree, clone, or implementation workspace under `/path/to/development` when doing new development.
5. If a plugin must be installed in a Hermes-required runtime location such as `~/.hermes/plugins/`, keep the source of truth under `/path/to/development` and install, copy, or symlink into the Hermes runtime location as appropriate. Document the chosen strategy.
6. Do not move, delete, or reorganize existing user projects to satisfy this path rule.

Suggested workspace layout, adjustable after inspecting the installed repo:

```text
/path/to/development/
  logos-agent-reference/
    README.md
    logos-architecture-v2.2.md
    logos-agent-autonomous-handoff-prompt-v2.md
  logos/                  # repo, worktree, or standalone implementation workspace
    docs/logos/
    clients/ios/Logos/
    ...
```

Persist the handoff materials before development:

1. Copy `logos-architecture-v2.2.md` and this handoff prompt into `/path/to/logos-agent-reference/` without modifying their contents.
2. Record hashes for both files in `/path/to/logos-agent-reference/README.md`.
3. Once the implementation repo/workspace is identified, also copy both files into a repo-local traceability directory such as `docs/logos/reference/`.
4. Treat the copied architecture document as the stable design reference for this run. Do not rely on transient chat attachments after the run begins.

---

## Reference documents

Read `logos-architecture-v2.2.md` completely before changing code.

Treat it as product/design intent, but **do not assume implementation details are true** until you verify them against the installed Hermes repository and the current local environment.

Important:

- Use `logos-architecture-v2.2.md`, not older `logos-architecture.md`, `logos-architecture-v2.md`, or `logos-architecture-v2.1.md` if they are present.
- If the architecture document and installed Hermes code disagree, installed code is operational truth. Preserve the architecture intent with the smallest adjustment and document the mismatch.
- If the architecture document is outside the repo, copy it into a repo-local docs/reference location for traceability, without changing its content.


---

## Kanban-first execution requirement

Before changing any implementation files, create and populate a Hermes Kanban board for this project. Use Hermes's built-in Kanban features as the durable project execution ledger.

Board requirements:

- Board slug: `logos-agent-voice-app`, unless an existing equivalent board is found.
- Board display name: `Logos Agent Voice App`.
- Board description: `Implementation of the Logos iPhone voice-and-tap interface for Hermes Agent.`
- Workspace: all development artifacts under `/path/to/development`.

Use the installed Hermes Kanban surface that is actually available in this environment. Prefer model-visible `kanban_*` tools when running as a Kanban worker or orchestrator; otherwise use `/kanban ...` slash commands or `hermes kanban ...` CLI commands. Verify the available surface before relying on it.

Minimum board setup:

1. Create or select the `logos-agent-voice-app` board.
2. Create a parent/project task for the overall Logos implementation.
3. Create tasks for every major development stage in this prompt:
   - Stage 0 — workspace, references, and Kanban setup.
   - Stage A — environment and contract verification.
   - Stage B — platform plugin and WebSocket text bridge.
   - Stage C — protocol, sequencing, and message replication.
   - Stage D — sessions, project routing, and `/resume`.
   - Stage E — run state, queue, stop/cancel, approval, and clarification.
   - Stage F — iOS app skeleton in Xcode Simulator.
   - Stage G — TTS playback.
   - Stage H — fast local model for acknowledgment, intent, and summaries.
   - Stage I — ASR UI and speech state machine.
   - Stage J — notifications and private APNS path.
   - Stage K — end-to-end simulator validation.
   - Stage L — physical-device gate and final report.
4. Add child tasks or comments for material feature areas from `logos-architecture-v2.2.md`, including plugin loading, gateway message routing, slash-command pass-through, reconnect replay, local iOS message store, project picker, approval cards, clarification cards, private notification payloads, summary playback, and device validation checklist.
5. Use stable idempotency keys if the CLI supports them, so repeated setup does not duplicate the whole plan.
6. Do **not** create implementation tasks for explicitly deferred scope, except as a separate “Deferred / not v1” note or backlog task. Deferred items must not be worked unless this prompt's normal stop conditions allow it.

Execution rules while using the board:

1. At the start of each stage, read or claim the relevant Kanban task and confirm acceptance criteria.
2. During long work, add comments or heartbeats with meaningful progress and blocker information.
3. When a stage is complete, mark its task complete with a handoff summary that includes changed files, commands run, tests passed/failed, and remaining risks.
4. If a stage is blocked on a physical iPhone, APNS credentials, Tailscale hardware behavior, Apple Watch, or user action, mark or comment it as blocked rather than pretending it is complete.
5. Keep `docs/logos/IMPLEMENTATION_NOTES.md` and the Kanban board consistent. The notes are the detailed engineering journal; Kanban is the task ledger.
6. Do not build a separate Logos Kanban UI. The board is for implementation coordination only, not a product feature.

If Kanban is unavailable in the installed Hermes build after two reasonable verification attempts, create `docs/logos/TASK_LEDGER.md` as a temporary fallback, document the blocker, and continue. This fallback is only for a missing or broken local Kanban surface; otherwise Kanban usage is mandatory.

---

## Non-negotiable architecture rules

1. Logos is a **Hermes platform plugin**, not a broad fork or patch of Hermes core.
2. Normal final user input must route through Hermes as a platform message/event using the adapter/gateway path. Do **not** construct `AIAgent` directly unless you prove the gateway path cannot support a required behavior and write an ADR first.
3. Gateway-native slash commands must pass through unchanged when entered as text or produced by voice intent translation. Test at least `/resume` if practical, plus a benign command available in the installed build. `/sessions` is optional/pass-through only; the Logos mobile picker is the reliable browser.
4. Hermes remains source of truth for persisted conversation state. The phone mirrors state; it must not write directly to Hermes `state.db`.
5. Do not persist fake “thinking” messages. Run/working state is transient adapter/client state, emitted as status events.
6. Approval, denial, stop/cancel, queued input, and clarification must be supported as interaction surfaces, but do not invent a complex Logos-only policy engine. Reuse Hermes semantics wherever available.
7. APNS payloads must be private by default: notification text may say “Hermes finished”, “Hermes needs approval”, or “Hermes needs clarification”, but response summaries, command details, and sensitive text are fetched over the tailnet after reconnect.
8. Keep the build single-user, one Mac, one Hermes profile, private-network/Tailscale only. No public server.
9. Avoid scope creep: no multi-user auth, no phone-free Watch client, no durable run recovery, no custom Kanban UI, no fast-model fine-tuning, no global cross-device focus sync, no persistent “always approve this command” policy system.

---

## Safety and repository hygiene

Before implementation:

1. Ensure `/path/to/development` exists.
2. Persist this prompt and `logos-architecture-v2.2.md` under `/path/to/logos-agent-reference/` with hashes.
3. Create or reuse the `logos-agent-voice-app` Hermes Kanban board and task out the whole plan before code changes.
4. Run `git status --short` in any repo you will modify and record the baseline.
5. Identify the Hermes repo root, profile path, Python environment, and existing test commands.
6. Avoid destructive changes to user data. Use a test Hermes profile for automated tests where possible.
7. If any migration or state-table change touches the real Hermes profile, first create a timestamped backup of affected SQLite files.
8. Never log secrets, APNS keys, device tokens, Tailscale identifiers, or model-provider credentials.
9. Do not push remote branches or make irreversible system changes.
10. If dependency installation is needed, prefer the project’s existing environment manager. Record every package added and why.
11. If the repo is dirty with unrelated user changes, do not overwrite them. Work around them or document that they block a specific file.

Use small commits or clear checkpoint notes if the environment allows. If committing is inappropriate, maintain an implementation journal in `docs/logos/IMPLEMENTATION_NOTES.md`.

---

## Required verification before code

Inspect the installed Hermes code and report the answers in `docs/logos/IMPLEMENTATION_NOTES.md` before changing implementation files:

- How platform plugins are discovered and loaded.
- The correct plugin path and manifest/config shape.
- The base adapter class/interface Logos should implement.
- The method used to forward inbound platform messages to the gateway runner.
- How outbound messages are delivered back to a platform adapter.
- Where slash commands are detected relative to agent creation.
- How `/resume`, `/title`, `/queue`, `/stop`, `/approve`, and `/deny` behave in this build.
- Whether `/sessions` has a working gateway handler in this build.
- How sessions, message ids, parent session ids, compression lineage, and state metadata are represented in `state.db`.
- Where clarification and approval callbacks are exposed.
- How Hermes Kanban boards are created, selected, listed, and updated in this build.
- Whether the agent-facing `kanban_*` tools are available in this run; if not, which CLI or slash-command Kanban surface is reliable.
- Where the `logos-agent-voice-app` board is stored, and how task state will be maintained during execution.
- Any mismatch between v2.2 architecture and installed Hermes code.

Do not block forever on documentation. Prefer code inspection and empirical tests.

---

## Autonomous execution loop

For each stage:

1. Select or create the corresponding Kanban task on `logos-agent-voice-app` and mark or claim it according to the installed workflow.
2. Define the smallest acceptance criteria for that stage.
3. Implement the stage.
4. Add tests where practical.
5. Run the relevant tests/build commands.
6. Add Kanban comments for material discoveries, blockers, commands run, and verification results.
7. Update `docs/logos/IMPLEMENTATION_NOTES.md` with what changed, what was verified, and what remains unverified.
8. Complete, block, or leave in-progress the Kanban task according to actual status.
9. Continue to the next stage automatically unless a stop condition applies.

If a dependency or toolchain issue blocks one feature after two reasonable attempts, preserve the interface, add a deterministic stub/mock, document the blocker, and continue to the next stage. Do not let non-core model packaging block the Hermes/iOS end-to-end path.

---


## Stage 0 — Workspace, references, and Kanban setup

Goal: establish the durable workspace and project-management substrate before code changes.

Deliverables:

- `/path/to/development` confirmed or created.
- Handoff prompt and `logos-architecture-v2.2.md` copied to `/path/to/logos-agent-reference/`.
- Hashes recorded in `/path/to/logos-agent-reference/README.md`.
- `logos-agent-voice-app` Hermes Kanban board created or reused.
- Full project task plan created on the board, covering all stages and major features.
- Kanban command/tool surface verified or fallback file created only if Kanban is unavailable.

Acceptance criteria:

- Development will happen under `/path/to/development`.
- The architecture and prompt are persisted outside ephemeral chat/upload context.
- The board contains a complete, inspectable task breakdown before implementation begins.
- The first implementation task is clearly selected or claimed.

---

## Stage A — Environment and contract verification

Goal: establish ground truth and prevent architecture drift.

Deliverables:

- `docs/logos/IMPLEMENTATION_NOTES.md` created.
- Reference docs copied into repo-local `docs/logos/reference/` if appropriate.
- Local Hermes plugin/gateway/session facts recorded.
- Local Hermes Kanban board/tool facts recorded.
- Local Xcode facts recorded:
  - `xcode-select -p`
  - `xcodebuild -version`
  - `xcrun simctl list devices available`
  - chosen simulator destination
- Test profile strategy documented.
- Final stage plan adjusted to the installed repo if needed.

Acceptance criteria:

- You know how to load a plugin.
- You know how to send inbound messages through the gateway path.
- You know how to observe outbound adapter messages.
- You know how to run or create an iOS Simulator target.

---

## Stage B — Logos platform plugin and WebSocket text bridge

Goal: prove Mac-side Hermes integration before any iOS UI.

Deliverables:

- Logos platform plugin scaffold using the installed Hermes plugin mechanism.
- Local WebSocket server owned by the adapter.
- Typed JSON envelope parser/serializer.
- Development shared-secret authentication.
- Minimal local CLI test client, for example `scripts/logos_ws_client.py`.
- Gateway event bridge for final text input.
- Outbound Hermes response forwarding to WebSocket clients.
- Slash-command pass-through tests.

Minimum protocol types:

- `hello`
- `text_input` or `speech` with `is_final=true`
- `state_update`
- `error`

Acceptance criteria:

- Plugin loads without modifying Hermes core files.
- A local WebSocket client sends text to Logos.
- Text reaches Hermes through adapter/gateway path, not direct `AIAgent` construction.
- Hermes response returns over WebSocket.
- Slash-command text is not swallowed by Logos.

---

## Stage C — Protocol contract, sequencing, and message replication

Goal: make the bridge reconnect-safe and ready for a phone client.

Deliverables:

- Formal protocol models in Python and Swift-compatible JSON schema or documented structs.
- `server_seq` generated by adapter for outbound events.
- Message replication keyed by `(session_id, message_id)` where Hermes message ids are available.
- `messages_get` and `messages_batch` with `before_message_id` or equivalent stable pagination; avoid timestamp-only pagination.
- Client reconnect handshake using last seen `server_seq` and/or last seen `message_id`.
- Unit tests for duplicate handling, out-of-order delivery if applicable, reconnect replay, and pagination.

Core protocol types now include:

- `speech`
- `text_input`
- `switch_project`
- `list_projects`
- `new_project`
- `rename_project`
- `messages_get`
- `messages_batch`
- `state_update`
- `run_status`
- `playback_audio`
- `audio_chunk`
- `approval_request`
- `approval_response`
- `clarify_request`
- `clarify_response`
- `run_cancel`
- `error`

Acceptance criteria:

- A reconnecting client can fetch missed messages without duplicates.
- Events have stable ids/sequences.
- No phone/client code is required to write Hermes `state.db` directly.

---

## Stage D — Sessions, project routing, and resume

Goal: support project selection and explicit session continuity.

Deliverables:

- Device-local active project pointer.
- Adapter-side pointer persistence/mirror, preferably in Hermes-supported metadata or a small Logos-owned table if safer.
- Project/session list API for the mobile picker.
- `switch_project`, `new_project`, and `rename_project` handling.
- Gateway-native `/resume` pass-through.
- Voice/text intent translation can be stubbed at this stage, but the command path must exist.
- Lineage-aware pointer reconciliation after compression/resume if the installed Hermes session model exposes parent/child lineage.

Acceptance criteria:

- Client can list projects/sessions.
- Client can switch active project.
- Client can create or rename a project if supported safely.
- `/resume <title-or-id>` is tested or documented as unavailable in the installed build.
- `/sessions` is treated as optional; mobile picker does not depend on it.

---

## Stage E — Run state, queue, stop/cancel, approval, and clarification

Goal: handle Hermes interactive/blocking states before adding voice.

Deliverables:

- Per-session run status surfaced to clients.
- Same-session double-input behavior defined and implemented using Hermes queue semantics if available; otherwise prevent unsafe concurrent turn insertion.
- `/stop` or current Hermes cancel mechanism wired as `run_cancel`.
- Approval request cards surfaced over WebSocket.
- Approval responses routed through Hermes-supported `/approve` and `/deny` semantics or the installed equivalent.
- Clarification request cards surfaced over WebSocket.
- Clarification responses routed back through the correct callback/message path.
- Tool/run progress events forwarded where available.
- Tests using real Hermes callbacks where practical; otherwise adapter-level fixtures that simulate approval and clarification events.

Acceptance criteria:

- User can stop/cancel a running task.
- User can approve or deny a one-shot request.
- User can respond to a clarification prompt.
- The UI/client receives visible running/idle/progress state.
- No persistent approval policy system is added.

---

## Stage F — iOS app skeleton in Xcode Simulator

Goal: create the phone client and prove simulator build/run.

Preferred implementation:

- SwiftUI app.
- `URLSessionWebSocketTask` or equivalent native WebSocket client.
- Async/await where suitable.
- Local store using SQLite, Core Data, or SwiftData; choose the simplest robust path for the Xcode/iOS deployment target.
- Thin MVVM or similar state model; avoid heavy architecture.

Deliverables:

- iOS app project or package under a clear path such as `clients/ios/Logos`.
- App config for adapter URL and development shared secret.
- WebSocket connect/disconnect/reconnect.
- Text input chat UI.
- Project picker UI.
- Local message store and message rendering.
- Run status indicator.
- Approval card UI.
- Clarification card UI.
- Basic error/toast surface.
- Simulator build command documented.
- Simulator launch command documented.

Use Xcode CLI when possible:

- discover available simulators with `xcrun simctl list devices available`,
- choose an available iPhone simulator automatically,
- build/test with `xcodebuild -destination 'platform=iOS Simulator,...'`,
- boot/install/launch with `xcrun simctl` if useful,
- capture screenshots with `xcrun simctl io booted screenshot` if useful.

Acceptance criteria:

- App builds for iOS Simulator.
- App launches in Simulator.
- App connects to the local adapter from Simulator.
- Sending typed text from Simulator reaches Hermes and renders the response.
- Project picker works against real or mocked adapter data.
- Approval/clarification cards render and send responses against real or fixture events.

---

## Stage G — TTS playback

Goal: make audio output work with typed input before ASR.

Deliverables:

- Server-side TTS interface: `text -> audio stream frames`.
- Kokoro implementation if the dependency can be installed and loaded cleanly.
- Deterministic stub implementation if Kokoro packaging blocks progress.
- `playback_audio` request from iOS.
- `audio_chunk` streaming to iOS.
- iOS audio playback pipeline.
- Optional small disk cache keyed by message/summary id.

Acceptance criteria:

- From Simulator, user can tap play on a message and hear audio if Simulator audio is available.
- If real TTS is blocked, stub audio path still proves protocol and playback plumbing.
- Full response text remains visible; audio path is prepared to use summary text later.

---

## Stage H — Fast local model for acknowledgment, intent, and summaries

Goal: add low-latency UX helpers without affecting Hermes conversation state.

Deliverables:

- Fast-model interface with strict JSON outputs.
- Attempt real local implementation using the available MLX/Qwen setup if practical.
- Deterministic fallback/stub for tests and when the model is unavailable.
- Ack/no-ack generation for final user input.
- Intent extraction for:
  - switch project,
  - create project,
  - resume project,
  - stop/cancel,
  - approve/deny where obvious.
- Summary generation at agent completion, using private APNS-compatible text rules.
- Tests for schema validation and common utterances.

Rules:

- Fast-model outputs are not persisted as Hermes turns.
- Fast model is not registered as a Hermes provider unless the installed architecture absolutely requires it.
- Do not fine-tune.
- Do not let model packaging block the core path indefinitely; stub and continue after two reasonable attempts.

Acceptance criteria:

- Typed or spoken-equivalent text can produce an immediate ack event/audio path.
- Intent extraction routes only narrow, safe intents.
- Ambiguous utterances fall back to normal Hermes input rather than over-routing.
- Summaries are generated or stubbed and stored as Logos metadata keyed by assistant message id.

---

## Stage I — ASR UI and speech state machine

Goal: implement voice input while acknowledging physical-device validation limits.

Deliverables:

- Hold-to-talk UI.
- Tap-to-talk UI.
- Speech permission handling.
- `SFSpeechRecognizer` integration.
- `supportsOnDeviceRecognition` check.
- `requiresOnDeviceRecognition = true` when supported.
- Explicit fallback behavior when on-device recognition is not supported: disable voice or show a user-controlled network-recognition opt-in; do not silently fall back to network recognition.
- Partial transcript streaming over WebSocket.
- Final transcript dispatch.
- Energy/silence detection state machine for tap-to-talk, tested at unit level if real audio is not reliable in Simulator.

Simulator note:

- Implement and compile all ASR code in Simulator.
- Test permission/UI/state-machine behavior as far as Simulator allows.
- Mark real microphone quality, on-device recognition availability, and privacy behavior as physical-device validation gates.

Acceptance criteria:

- ASR code builds.
- Hold/tap controls behave correctly in UI tests or manual Simulator run.
- The app does not silently use network speech recognition when local-only mode is required.
- Physical iPhone validation checklist is written for real mic/on-device ASR.

---

## Stage J — Notifications and private APNS path

Goal: implement notification semantics without leaking response content.

Deliverables:

- Device registration protocol (`register_device`) and storage.
- APNS module with token-based auth if credentials are present through environment/config.
- Private payload builder:
  - “Hermes finished”
  - “Hermes needs approval”
  - “Hermes needs clarification”
  - custom data only for ids/routing, not sensitive response text.
- iOS notification permission request.
- Deep-link handling to session/message/approval/clarification ids.
- Reconnect + delta sync after notification tap.
- Simulator notification/deep-link test using `xcrun simctl push` where possible.
- Live APNS skipped if credentials are absent.

Environment variables/config names may include:

- `LOGOS_APNS_KEY_ID`
- `LOGOS_APNS_TEAM_ID`
- `LOGOS_APNS_BUNDLE_ID`
- `LOGOS_APNS_AUTH_KEY_PATH`
- `LOGOS_APNS_ENV` (`sandbox` or `production`)

Acceptance criteria:

- Simulated push opens or routes the Simulator app if supported.
- Notification tap triggers reconnect/delta sync path.
- No summary or sensitive content is placed in payload by default.
- Real APNS delivery is marked as physical-device/credential validation if credentials or hardware are unavailable.

---

## Stage K — End-to-end simulator validation

Goal: prove everything possible without a real phone.

Run and document:

- Python/unit tests for adapter, protocol, sessions, approvals, clarification, TTS/fast-model stubs.
- Hermes integration tests with a test profile.
- WebSocket CLI test client round trip.
- iOS unit tests.
- iOS UI tests if practical.
- iOS Simulator build.
- iOS Simulator launch.
- Simulator text message → adapter → Hermes → response rendered in app.
- Simulator project picker.
- Simulator approval/clarification fixture flow.
- Simulator audio playback or documented limitation.
- Simulator simulated notification/deep-link if supported.
- Reconnect/delta-sync test.

Produce:

- `docs/logos/TEST_REPORT.md`
- `docs/logos/DEVICE_TEST_CHECKLIST.md`
- Kanban board summary with completed tasks, blocked tasks, physical-device-gated tasks, and follow-ups
- screenshots or logs where useful.

Acceptance criteria:

- The project is as close to end-to-end as Simulator and local credentials allow.
- Remaining work is reduced to physical iPhone/Watch validation and credential provisioning, not architecture or core implementation.

---

## Stage L — Physical-device gate and final report

Stop when the next meaningful work requires physical user/device action.

Final report must include:

1. What was implemented.
2. What was verified by tests.
3. What was verified in iPhone Simulator.
4. What could not be verified without a physical iPhone, APNS credentials, Tailscale app behavior, or Apple Watch.
5. Exact commands to run the adapter.
6. Exact commands to build/run the iOS app.
7. Required environment variables/config values.
8. A physical iPhone validation checklist:
   - install/run app on iPhone,
   - connect to adapter over Tailscale,
   - hold-to-talk ASR,
   - tap-to-talk ASR/silence detection,
   - summary playback,
   - foreground WebSocket live updates,
   - background/reconnect behavior,
   - real APNS registration and delivery,
   - approval request flow,
   - clarification flow,
   - `/resume` from phone,
   - stop/cancel during a run.
9. Known issues and suggested next fixes.
10. Kanban board summary: completed tasks, blocked tasks, physical-device-gated tasks, and remaining follow-ups.
11. A concise list of intentionally deferred scope.

Do not proceed into Apple Watch relay until the physical iPhone path is validated.

---

## Explicitly deferred unless everything above is complete

Do not implement these unless all core Mac + iOS Simulator stages are passing and no physical gate has been reached:

- Apple Watch relay.
- Persistent approval policies.
- Durable run recovery across adapter restarts.
- Separate Kanban UI.
- Multi-user device/account model.
- Public internet exposure.
- Fine-tuned fast model.
- “Play full response” secondary audio path.
- Global desktop/phone active-session synchronization.

If you finish everything simulator-verifiable with time remaining, improve tests, docs, and physical-device setup instructions rather than expanding feature scope.

---

## Practical implementation priorities

When forced to choose, prioritize in this order:

1. Workspace/reference persistence and Kanban task tracking.
2. Gateway-correct Hermes integration.
3. Deterministic protocol and reconnect behavior.
4. Session/project switching and `/resume`.
5. Run state, stop/cancel, approval, and clarification.
6. iOS text client in Simulator.
7. Local message store and project picker.
8. TTS playback.
9. Fast-model ack/intent/summary.
10. ASR implementation and state-machine tests.
11. Private APNS scaffolding and simulated push.
12. Polish.

Avoid building beautiful surfaces on top of unverified Hermes integration. The correct core path matters more than UI polish.
