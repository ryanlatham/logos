# Logos Test Report

Last updated: 2026-05-15T05:47:05-07:00

Workspace: `/Users/ryan/Development/logos`

Simulator: `FD91D719-6C01-4917-A654-B81D3465595A` / iPhone 15 Pro

Bundle id: `com.ryan.logos`

Server secret used in Simulator tests: `[REDACTED]`

## Summary

Stage K validation passed for the simulator-verifiable Logos path.

What is verified:

- Logos Python adapter/protocol/store tests pass.
- Logos plugin Python sources compile.
- WebSocket CLI-style round trip works against the deterministic mock adapter.
- iOS app builds for iPhone Simulator.
- iOS unit tests pass.
- iOS UI tests pass against the mock adapter.
- Simulator launch connects to the local adapter.
- Typed text from Simulator reaches the adapter and renders a response.
- Project picker/default project UI is present and usable in the Simulator.
- Approval and clarification cards render from mock adapter fixtures.
- Audio playback plumbing is exercised by UI test and reaches `Playing audio` status.
- ASR UI/state-machine code compiles and unit tests cover the local-only recognition policy and tap-to-talk silence behavior.
- Private APNS payload construction is tested and `xcrun simctl push` accepts the private payload fixture.
- Notification/deep-link route parsing is unit-tested; `logos://` Simulator open triggers the iOS first-open confirmation.

What remains gated:

- Real iPhone microphone quality and on-device ASR behavior.
- Physical-device speech permission prompts and denial behavior.
- Tailscale/private-network reachability from real iPhone.
- Real APNS device-token registration and delivery.
- Apple Developer signing/provisioning.
- Real notification tap/background reconnect behavior on iPhone.
- Apple Watch relay. Do not start that yet; the iPhone path is the gate.

## Commands and results

### Python tests

```bash
cd /Users/ryan/Development/logos
PYTHONPATH=/Users/ryan/Development/logos/plugins:/Users/ryan/.hermes/hermes-agent \
  /Users/ryan/.hermes/hermes-agent/venv/bin/pytest -q tests
```

Result:

```text
45 passed in 0.22s
```

### Python compile check

```bash
cd /Users/ryan/Development/logos
PYTHONPATH=/Users/ryan/Development/logos/plugins:/Users/ryan/.hermes/hermes-agent \
  /Users/ryan/.hermes/hermes-agent/venv/bin/python -m compileall -q plugins/logos scripts tests
```

Result: passed with no output.

### Stage K mock adapter

```bash
cd /Users/ryan/Development/logos
PYTHONPATH=/Users/ryan/Development/logos/plugins:/Users/ryan/.hermes/hermes-agent \
  /Users/ryan/.hermes/hermes-agent/venv/bin/python scripts/run_stage_f_mock_adapter.py \
  --host 127.0.0.1 \
  --port 8765 \
  --secret [REDACTED] \
  --store /tmp/logos-stage-k-simulator.db
```

Result: adapter accepted WebSocket connections on `ws://127.0.0.1:8765`.

### WebSocket CLI-style round trip

A direct WebSocket test client sent `hello`, then `text_input` with `stage k cli round trip`.

Observed frames:

```json
{
  "frames_seen": [
    "state_update:fast_ack",
    "run_status:",
    "state_update:message_appended"
  ],
  "assistant_response": "Mock Hermes received: stage k cli round trip"
}
```

Result: passed.

### Xcode generate/build/test

```bash
cd /Users/ryan/Development/logos/clients/ios/Logos
xcodegen generate --spec project.yml
xcodebuild -project Logos.xcodeproj -scheme Logos \
  -destination 'platform=iOS Simulator,id=FD91D719-6C01-4917-A654-B81D3465595A' test
```

Result:

```text
LogosModelTests: 19 tests, 0 failures
LogosUITests: 2 tests, 0 failures
** TEST SUCCEEDED **
```

Xcode result bundle:

```text
/Users/ryan/Library/Developer/Xcode/DerivedData/Logos-dlclbxwcbdpywgftxzecnnzrzohg/Logs/Test/Test-Logos-2026.05.15_05-45-05--0700.xcresult
```

### Simulator launch

```bash
cd /Users/ryan/Development/logos/clients/ios/Logos
SIMCTL_CHILD_LOGOS_WS_URL=ws://127.0.0.1:8765 \
SIMCTL_CHILD_LOGOS_DEVICE_SECRET=[REDACTED] \
SIMCTL_CHILD_LOGOS_DEVICE_ID=ios-simulator \
SIMCTL_CHILD_LOGOS_AUTOCONNECT=1 \
xcrun simctl launch --terminate-running-process \
  FD91D719-6C01-4917-A654-B81D3465595A com.ryan.logos
```

Result: app launched and connected.

Screenshot:

```text
docs/logos/stage-k-simulator-app.png
```

Visible state in the screenshot:

- Adapter connected to `ws://127.0.0.1:8765`.
- Active project is `default`.
- Run status is `Idle`.
- Notifications panel is visible with explicit `Enable` control and no permission prompt forced at launch.
- Voice panel is visible and says on-device speech recognition is available in Simulator.
- Hold-to-talk and tap-to-talk controls are visible.

### Simulator private push fixture

```bash
xcrun simctl push FD91D719-6C01-4917-A654-B81D3465595A \
  com.ryan.logos docs/logos/stage-j-private-push.apns
```

Result:

```text
Notification sent to 'com.ryan.logos'
```

Fixture path:

```text
docs/logos/stage-j-private-push.apns
```

The payload contains only routing ids and a private alert body. It does not contain response summaries, command previews, file paths, or secrets.

### Simulator deep-link route

```bash
xcrun simctl openurl FD91D719-6C01-4917-A654-B81D3465595A \
  'logos://notification?kind=approval&project_key=default&request_id=appr-sim&server_seq=1'
```

Result: Simulator displayed the first-open confirmation (`Open in “Logos”?`). I did not click the system confirmation. The route parsing and reconnect/delta-sync call are unit-covered; full notification tap behavior remains a hardware/manual validation gate.

Screenshot:

```text
docs/logos/stage-j-notification-route-simulator.png
```

## Feature validation matrix

| Area | Status | Evidence |
|---|---:|---|
| Plugin/protocol Python tests | Pass | `pytest -q tests` → `45 passed` |
| Python syntax/bytecode | Pass | `compileall` succeeded |
| WebSocket auth/hello | Pass | CLI-style round trip returned authenticated hello |
| Text input bridge | Pass | CLI and UI tests received deterministic mock Hermes response |
| Slash command pass-through | Pass | Existing Stage B/D/E tests cover slash command routing and `/resume` intent path |
| Sequencing/reconnect/message replication | Pass | Stage C tests + Stage K round trip observed ordered `server_seq` frames |
| Project picker | Pass | UI present in Simulator; unit/project decoding tests pass |
| Approval card | Pass | UI fixture test passes |
| Clarification card | Pass | UI fixture test passes |
| Run status | Pass | UI tests observe `Idle`; adapter tests cover run statuses |
| Stop/cancel path | Pass at protocol level | Stage E tests cover `/stop` mapping; physical long-running cancel remains manual |
| TTS playback plumbing | Pass | UI test taps play and observes `Playing audio`; Stage G tests cover chunk/end frames |
| Fast ack/intent/summary stub | Pass | Stage H tests cover conservative intents and summary metadata |
| ASR UI/state machine | Simulator-pass | Unit tests cover state machine/policy; UI visible; real mic is hardware-gated |
| Private APNS payloads | Pass | Stage J tests reject sensitive content in payloads |
| APNS live send | Skipped/gated | Missing Apple credentials/physical device; APNS client skips deterministically |
| Simulator push | Pass | `xcrun simctl push` accepted fixture |
| Notification tap/deep-link | Partial | Parser/unit path passes; Simulator first-open confirmation blocks fully automated tap route |

## Known limitations

- The iOS app is simulator-signed locally. Physical APNS requires Apple Developer provisioning.
- TTS is deterministic stub WAV audio, not Kokoro. Kokoro was not installed in the Hermes venv.
- Fast model is deterministic stub logic, not MLX/Qwen. Local MLX/Qwen packages were unavailable in this workspace.
- ASR code compiles and policy/state-machine tests pass, but Simulator cannot prove real mic quality or privacy behavior on hardware.
- The Stage F mock adapter intentionally replaces Hermes agent execution with deterministic echo responses for Simulator UI tests. The real plugin path and gateway interfaces are tested separately at adapter/protocol level.
- The first `logos://` open in Simulator shows a system confirmation. That is expected; route parsing is unit-covered and physical notification taps are still gate work.

## Artifacts

- `docs/logos/stage-k-simulator-app.png`
- `docs/logos/stage-j-notification-route-simulator.png`
- `docs/logos/stage-j-private-push.apns`
- `/tmp/logos-stage-k-full-test.log`
- `/tmp/logos-stage-k-xcodegen.log`

## Verdict

Stage K passes for everything this machine and iPhone Simulator can honestly verify. The remaining meaningful work is physical-device validation and credential provisioning, not another round of local code scaffolding.
