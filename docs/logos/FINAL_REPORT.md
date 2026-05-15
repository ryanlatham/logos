# Logos Final Report — Simulator Complete / Physical Device Gate

Last updated: 2026-05-15T06:28:32-07:00

Workspace: `/Users/ryan/Development/logos`

Reference archive: `/Users/ryan/Development/logos-agent-reference`

Kanban board: `logos-agent-voice-app`

Simulator: `FD91D719-6C01-4917-A654-B81D3465595A` / iPhone 15 Pro

Bundle id: `com.ryan.logos`

Secrets and tokens are intentionally omitted or shown as `[REDACTED]`.

## 1. What was implemented

### Mac / Hermes side

- Logos Hermes platform plugin scaffold under `plugins/logos/`.
- Plugin manifest `plugins/logos/plugin.yaml` using installed Hermes lowercase `plugin.yaml` convention.
- WebSocket server with shared-secret authentication.
- Typed JSON envelope parsing and serialization.
- Inbound `text_input`, `text_message`, and final `speech` forwarding through adapter/gateway `handle_message(...)` path, not direct `AIAgent` construction.
- Slash-command pass-through for text beginning with `/`.
- Protocol sequencing with adapter-generated `server_seq`.
- SQLite-backed adapter store for:
  - projects,
  - device active project pointers,
  - mirrored messages,
  - summaries,
  - registered devices/APNS tokens,
  - adapter event sequence state.
- Reconnect-safe message fetch using `messages_get` / `messages_batch` with `after_server_seq` and `before_message_id` behavior.
- Project/session operations:
  - `list_projects`,
  - `switch_project`,
  - `new_project`,
  - `rename_project`,
  - `/resume` pass-through/intention path.
- Run-state mirroring:
  - `idle`,
  - `running`,
  - `queued`,
  - `awaiting_approval`,
  - `awaiting_clarification`,
  - `cancelling`,
  - `error`.
- Stop/cancel via `run_cancel` mapping to Hermes `/stop` semantics.
- Approval request and response surfaces, mapped through normal Hermes approval/deny command semantics.
- Clarification request and response surfaces, including Hermes clarify callback integration where available.
- Deterministic stub TTS backend producing chunked WAV audio frames for `playback_audio`.
- Fast-model interface/stub for:
  - immediate acknowledgment,
  - conservative intent extraction,
  - response summaries keyed by message id.
- Private APNS scaffolding:
  - device registration protocol,
  - APNS token storage,
  - token-auth APNS client when credentials exist,
  - deterministic no-credential skip behavior,
  - private completion/approval/clarification payload builder.

### iOS side

- SwiftUI iOS app under `clients/ios/Logos` using XcodeGen.
- Native `URLSessionWebSocketTask` client.
- HMAC signing compatible with the Python WebSocket server.
- Local SQLite message store.
- Text chat UI.
- Project picker and new-project field.
- Run status display and stop button.
- Approval card UI.
- Clarification card UI.
- Playback button and AVFoundation audio chunk assembly/playback.
- Ack/playback status surfaces.
- Voice panel with:
  - `SFSpeechRecognizer` capability check,
  - on-device-only recognition policy,
  - hold-to-talk,
  - tap-to-talk,
  - partial transcript display,
  - tap-to-talk energy/silence state machine.
- Notification panel with explicit `Enable` action.
- iOS APNS registration delegate.
- Notification route parsing from APNS `userInfo`.
- `logos://` deep-link route parsing for Simulator/development validation.
- Reconnect + delta-sync path on notification route.
- Accessibility identifiers for UI tests.

### Documentation/artifacts

- `docs/logos/IMPLEMENTATION_NOTES.md`
- `docs/logos/TEST_REPORT.md`
- `docs/logos/DEVICE_TEST_CHECKLIST.md`
- `docs/logos/LOGOS_PHYSICAL_DEVICE_TEST_GUIDE.html`
- `docs/logos/IOS_SIMULATOR_STAGE_F.md`
- Simulator screenshots:
  - `docs/logos/stage-g-playback-simulator.png`
  - `docs/logos/stage-i-voice-ui-simulator.png`
  - `docs/logos/stage-j-notification-route-simulator.png`
  - `docs/logos/stage-k-simulator-app.png`
- Private push fixture:
  - `docs/logos/stage-j-private-push.apns`

## 2. What was verified by tests

### Python

Command:

```bash
cd /Users/ryan/Development/logos
PYTHONPATH=/Users/ryan/Development/logos/plugins:/Users/ryan/.hermes/hermes-agent \
  /Users/ryan/.hermes/hermes-agent/venv/bin/pytest -q tests
```

Result:

```text
45 passed
```

Coverage includes:

- protocol envelope validation,
- WebSocket authentication and bridge behavior,
- slash-command pass-through,
- sequencing/reconnect/message pagination,
- project/session routing,
- `/resume` intent path,
- run status/cancel/queue behavior,
- approval and clarification frames/responses,
- TTS `playback_audio` → `audio_chunk` / `audio_end`,
- deterministic fast-model ack/intent/summary behavior,
- APNS private payloads and no-credential skip,
- device registration storage without echoing raw tokens.

Compile check:

```bash
PYTHONPATH=/Users/ryan/Development/logos/plugins:/Users/ryan/.hermes/hermes-agent \
  /Users/ryan/.hermes/hermes-agent/venv/bin/python -m compileall -q plugins/logos scripts tests
```

Result: passed.

### iOS unit/UI tests

Command:

```bash
cd /Users/ryan/Development/logos/clients/ios/Logos
xcodegen generate --spec project.yml
xcodebuild -project Logos.xcodeproj -scheme Logos \
  -destination 'platform=iOS Simulator,id=FD91D719-6C01-4917-A654-B81D3465595A' test
```

Result:

```text
LogosModelTests: 12 tests, 0 failures
LogosUITests: 2 tests, 0 failures
** TEST SUCCEEDED **
```

The UI tests validate:

- app launch with Simulator env vars,
- adapter connection,
- notification panel presence,
- voice panel/control presence,
- typed message round trip through the mock adapter,
- assistant response rendering,
- playback button/status path,
- approval fixture card rendering,
- clarification fixture card rendering and response submission.

## 3. What was verified in iPhone Simulator

- App builds for iOS Simulator.
- App launches on iPhone 15 Pro Simulator.
- Simulator app connects to local WebSocket adapter at `ws://127.0.0.1:8765`.
- Typed text reaches the adapter and response renders in chat.
- Project picker/default project UI is visible.
- Approval/clarification cards render from fixtures.
- Audio playback plumbing reaches `Playing audio` status.
- Voice UI appears; Simulator reports on-device speech recognition availability in the captured run.
- `xcrun simctl push` accepts the private notification payload fixture.
- `logos://` open URL reaches the iOS route mechanism far enough for Simulator to display first-open confirmation; parser/route behavior is unit-tested.

Primary report: `docs/logos/TEST_REPORT.md`.

## 4. What could not be verified without physical device / credentials

- Real iPhone microphone quality, latency, and interruption behavior.
- Real `SFSpeechRecognizer` on-device recognition quality and locale support on hardware.
- Real permission-prompt flows for microphone, speech recognition, and notifications.
- iPhone-to-Mac connectivity over Tailscale/private network.
- Real iOS foreground/background WebSocket suspension and reconnect behavior.
- Real APNS device-token registration.
- Real APNS delivery from Apple servers.
- Notification tap routing after app background/suspend.
- Apple Developer signing/provisioning setup.
- Apple Watch relay. This remains intentionally out of scope until physical iPhone validation passes.

## 5. Exact commands to run the adapter

### Development/simulator mock adapter

This is the command used for Simulator UI validation. It uses the real Logos protocol/server/store code and replaces only the Hermes agent run with deterministic echo fixtures.

```bash
cd /Users/ryan/Development/logos
export LOGOS_DEVICE_SECRET='[REDACTED]'
PYTHONPATH=/Users/ryan/Development/logos/plugins:/Users/ryan/.hermes/hermes-agent \
  /Users/ryan/.hermes/hermes-agent/venv/bin/python scripts/run_stage_f_mock_adapter.py \
  --host 127.0.0.1 \
  --port 8765 \
  --secret "$LOGOS_DEVICE_SECRET" \
  --store /tmp/logos-stage-k-simulator.db
```

### Real Hermes plugin install/run path

Source of truth stays under `/Users/ryan/Development/logos/plugins/logos`.

Install as a user plugin:

```bash
mkdir -p /Users/ryan/.hermes/plugins
ln -sfn /Users/ryan/Development/logos/plugins/logos /Users/ryan/.hermes/plugins/logos
/Users/ryan/.hermes/hermes-agent/venv/bin/hermes plugins enable logos
```

Configure environment:

```bash
export LOGOS_DEVICE_SECRET='[REDACTED]'
export LOGOS_HOST='127.0.0.1'        # use a Tailscale/private-network bind address for physical iPhone testing
export LOGOS_PORT='8765'
export LOGOS_STORE_PATH='/Users/ryan/Development/logos/logos-store.db'
```

Optional APNS credentials:

```bash
export LOGOS_APNS_KEY_ID='[REDACTED]'
export LOGOS_APNS_TEAM_ID='[REDACTED]'
export LOGOS_APNS_BUNDLE_ID='com.ryan.logos'
export LOGOS_APNS_AUTH_KEY_PATH='/path/to/AuthKey_[REDACTED].p8'
export LOGOS_APNS_ENV='sandbox'
```

Enable platform config if needed:

```bash
/Users/ryan/.hermes/hermes-agent/venv/bin/hermes config set platforms.logos.enabled true
```

Then run Hermes normally from the installed environment. Exact gateway invocation depends on the active Hermes deployment mode; the plugin itself is now ready for the installed plugin manager. I did not enable it on the live profile during this run to avoid surprising the active chat/gateway process without a physical phone ready. Boring caution. Correct caution.

## 6. Exact commands to build/run the iOS app

Generate project and build/test:

```bash
cd /Users/ryan/Development/logos/clients/ios/Logos
xcodegen generate --spec project.yml
xcodebuild -project Logos.xcodeproj -scheme Logos \
  -destination 'platform=iOS Simulator,id=FD91D719-6C01-4917-A654-B81D3465595A' build
xcodebuild -project Logos.xcodeproj -scheme Logos \
  -destination 'platform=iOS Simulator,id=FD91D719-6C01-4917-A654-B81D3465595A' test
```

Install/launch on Simulator with environment variables:

```bash
cd /Users/ryan/Development/logos/clients/ios/Logos
APP_PATH=$(xcodebuild -project Logos.xcodeproj -scheme Logos \
  -destination 'platform=iOS Simulator,id=FD91D719-6C01-4917-A654-B81D3465595A' \
  -showBuildSettings 2>/dev/null | \
  awk -F' = ' '/ TARGET_BUILD_DIR = /{dir=$2} / WRAPPER_NAME = /{wrap=$2} END{print dir "/" wrap}')

xcrun simctl install FD91D719-6C01-4917-A654-B81D3465595A "$APP_PATH"

SIMCTL_CHILD_LOGOS_WS_URL='ws://127.0.0.1:8765' \
SIMCTL_CHILD_LOGOS_DEVICE_SECRET='[REDACTED]' \
SIMCTL_CHILD_LOGOS_DEVICE_ID='ios-simulator' \
SIMCTL_CHILD_LOGOS_AUTOCONNECT='1' \
xcrun simctl launch --terminate-running-process \
  FD91D719-6C01-4917-A654-B81D3465595A com.ryan.logos
```

Simulator private push fixture:

```bash
xcrun simctl push FD91D719-6C01-4917-A654-B81D3465595A \
  com.ryan.logos /Users/ryan/Development/logos/docs/logos/stage-j-private-push.apns
```

Simulator route fixture:

```bash
xcrun simctl openurl FD91D719-6C01-4917-A654-B81D3465595A \
  'logos://notification?kind=approval&project_key=default&request_id=appr-sim&server_seq=1'
```

## 7. Required environment variables / config values

### Required

- `LOGOS_DEVICE_SECRET` — shared secret used by WebSocket clients.

### Adapter/server optional

- `LOGOS_HOST` — host/interface to bind; default `127.0.0.1`.
- `LOGOS_PORT` — WebSocket port; default `8765`.
- `LOGOS_STORE_PATH` — SQLite adapter metadata path.
- `LOGOS_ALLOWED_USERS` — comma-separated allowed device/user ids.
- `LOGOS_ALLOW_ALL_USERS` — dev-only allow-all switch.

### iOS Simulator launch env

- `LOGOS_WS_URL`
- `LOGOS_DEVICE_SECRET`
- `LOGOS_DEVICE_ID`
- `LOGOS_AUTOCONNECT=1`

### APNS optional

- `LOGOS_APNS_KEY_ID`
- `LOGOS_APNS_TEAM_ID`
- `LOGOS_APNS_BUNDLE_ID`
- `LOGOS_APNS_AUTH_KEY_PATH`
- `LOGOS_APNS_ENV` — `sandbox` or `production`.

## 8. Physical iPhone validation checklist

Detailed checklist: `docs/logos/DEVICE_TEST_CHECKLIST.md`.

Minimum physical gate checklist:

1. Install/run Logos on physical iPhone with real signing.
2. Configure adapter URL to Mac Tailscale/private-network address.
3. Confirm WebSocket foreground live updates.
4. Send typed text from iPhone → Logos adapter → Hermes → response rendered.
5. Verify project picker and `/resume` from phone.
6. Hold-to-talk ASR:
   - allow mic/speech permissions,
   - speak,
   - release,
   - verify final transcript dispatches once.
7. Tap-to-talk ASR/silence detection:
   - speak then stop,
   - verify auto-stop and single final transcript.
8. Hold/tap silence cases:
   - no empty final turn should be sent.
9. Summary playback / TTS audio path on device speaker/Bluetooth.
10. Background/reconnect behavior:
    - background app during/after a run,
    - reopen,
    - verify delta sync.
11. Real APNS registration and delivery:
    - enable notifications,
    - verify device token registration,
    - verify private completion notification.
12. Approval request flow while foregrounded and backgrounded.
13. Clarification request flow while foregrounded and backgrounded.
14. `/resume` from phone into a known desktop session.
15. Stop/cancel during a running task.
16. Inspect logs for secret/token/transcript leakage; none should appear in normal logs.

## 9. Known issues and suggested next fixes

- **Physical install not performed**: no iPhone/Apple signing validation yet. Next: provision bundle id and install from Xcode.
- **Live APNS not verified**: APNS client is scaffolded and private-payload tested, but no credentials/device token were available. Next: set `LOGOS_APNS_*`, enable notifications on iPhone, and run the Stage J checklist.
- **TTS is stubbed**: Kokoro was unavailable in the Hermes venv. Next: install/benchmark Kokoro or keep the stub until the real iPhone loop is stable. Do not let voice prettiness outrank transport correctness.
- **Fast model is stubbed**: MLX/Qwen packages were unavailable. Next: add a real local model behind `fast_llm.py` only after phone path is stable; preserve deterministic fallback.
- **Simulator URL route confirmation**: first `logos://` open prompts `Open in “Logos”?`. Unit parser/reconnect path is covered; hardware notification tap still needs validation.
- **Plugin not enabled in live Hermes profile**: implementation source exists and install commands are documented. Next: install/enable when ready to test with the phone. I avoided altering the active live gateway without hardware ready.
- **Mock adapter vs real gateway**: Simulator UI tests use deterministic mock Hermes responses. Python tests cover adapter/gateway semantics, but a real Hermes end-to-end task from phone should be the first physical-device smoke test.

## 10. Kanban board summary

Board: `logos-agent-voice-app`

Completed stages:

- Stage 0 — Workspace, references, and Kanban setup
- Stage A — Environment and contract verification
- Stage B — Platform plugin and WebSocket text bridge
- Stage C — Protocol, sequencing, and message replication
- Stage D — Sessions, project routing, and `/resume`
- Stage E — Run state, queue, stop/cancel, approval, and clarification
- Stage F — iOS app skeleton in Xcode Simulator
- Stage G — TTS playback
- Stage H — Fast local model for ack, intent, and summaries
- Stage I — ASR UI and speech state machine
- Stage J — Notifications and private APNS path
- Stage K — End-to-end Simulator validation
- Stage L — Physical-device gate and final report

Feature-note tasks on the board remain as ledger/backlog notes, not implementation blockers:

- plugin loading and gateway message routing
- slash command pass-through
- reconnect replay and local message store
- project picker and session routing
- approval and clarification cards
- private notification payloads
- summary playback and TTS
- physical device validation checklist
- deferred / not v1

Physical-device-gated items:

- real iPhone/Tailscale connection,
- real mic/on-device ASR,
- real APNS registration/delivery,
- real iOS foreground/background socket behavior,
- Apple Watch relay after iPhone path passes.

## 11. Intentionally deferred scope

- Apple Watch relay.
- Persistent approval policies.
- Durable run recovery across adapter restarts.
- Separate Logos Kanban UI.
- Multi-user device/account model.
- Public internet exposure.
- Fine-tuned fast model.
- Full-response automatic TTS.
- Global desktop/phone active-session synchronization.

## Final gate

The next meaningful validation requires physical user/device action: a signed physical iPhone build, Tailscale/private-network testing, APNS credentials/device token registration, and real microphone/on-device ASR validation.

Stop condition reached. The simulator path is as far as it can honestly go. Anything beyond this without hardware would be theater, and theater does not ship reliable software.
