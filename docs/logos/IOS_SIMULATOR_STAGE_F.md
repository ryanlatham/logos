# Logos iOS Simulator — Stage F

Stage F creates the first SwiftUI phone surface for Logos and validates it against the real Logos WebSocket protocol using a deterministic local mock adapter.

## Location

```text
/Users/ryan/Development/logos/clients/ios/Logos
```

Generated project:

```text
/Users/ryan/Development/logos/clients/ios/Logos/Logos.xcodeproj
```

The project is generated from `project.yml` with XcodeGen. `Logos.xcodeproj/` is generated output and is ignored by the local `.gitignore`.

## App capabilities implemented

- SwiftUI app shell.
- Native `URLSessionWebSocketTask` client.
- HMAC-style shared-secret `hello` authentication frame compatible with the Logos WebSocket server.
- Environment-driven simulator config using `SIMCTL_CHILD_*` launch variables:
  - `LOGOS_WS_URL`
  - `LOGOS_DEVICE_SECRET`
  - `LOGOS_DEVICE_ID`
  - `LOGOS_AUTOCONNECT`
- Adapter configuration card with URL, shared secret, connection state, connect/reconnect/disconnect controls.
- Project picker backed by `list_projects` / `projects_list`.
- `new_project` command UI.
- Text composer sending `text_input` frames.
- Local SQLite message store at `Documents/LogosMessages.sqlite3`.
- Message rendering from `messages_batch` and live `state_update` frames.
- Run status indicator and stop button mapped to `run_cancel`.
- Approval card rendering and approve/deny response buttons.
- Clarification card rendering with choice buttons and free-text answer.
- Basic error banner for `error` frames and connection failures.

## Simulator fixture

`/Users/ryan/Development/logos/scripts/run_stage_f_mock_adapter.py` runs a mock Hermes adapter that uses the real Logos WebSocket, schema, adapter, and SQLite store, but replaces Hermes gateway execution with deterministic fixture behavior:

- normal text -> assistant echo: `Mock Hermes received: <text>`
- `/mock_approval` -> real `approval_request` frame
- `/mock_clarify` -> real `clarify_request` frame

This validates the app against the same wire protocol used by the plugin without requiring a live Hermes agent run for every UI test.

## Commands

Start the mock adapter:

```bash
cd /Users/ryan/Development/logos
PYTHONPATH=/Users/ryan/Development/logos/plugins:/Users/ryan/.hermes/hermes-agent \
  /Users/ryan/.hermes/hermes-agent/venv/bin/python \
  scripts/run_stage_f_mock_adapter.py \
  --host 127.0.0.1 \
  --port 8765 \
  --secret stage-f-secret \
  --store /tmp/logos-stage-f-simulator.db
```

Generate the project:

```bash
cd /Users/ryan/Development/logos/clients/ios/Logos
xcodegen generate --spec project.yml
```

Build:

```bash
xcodebuild \
  -project Logos.xcodeproj \
  -scheme Logos \
  -destination 'platform=iOS Simulator,id=FD91D719-6C01-4917-A654-B81D3465595A' \
  build
```

Test:

```bash
xcodebuild \
  -project Logos.xcodeproj \
  -scheme Logos \
  -destination 'platform=iOS Simulator,id=FD91D719-6C01-4917-A654-B81D3465595A' \
  test
```

Launch manually with auto-connect:

```bash
SIMCTL_CHILD_LOGOS_WS_URL=ws://127.0.0.1:8765 \
SIMCTL_CHILD_LOGOS_DEVICE_SECRET=stage-f-secret \
SIMCTL_CHILD_LOGOS_DEVICE_ID=ios-simulator \
SIMCTL_CHILD_LOGOS_AUTOCONNECT=1 \
xcrun simctl launch --terminate-running-process \
  FD91D719-6C01-4917-A654-B81D3465595A \
  com.ryan.logos
```

## Verification

Passed on iPhone 17 Pro Simulator `FD91D719-6C01-4917-A654-B81D3465595A`:

```bash
PYTHONPATH=/Users/ryan/Development/logos/plugins:/Users/ryan/.hermes/hermes-agent \
  /Users/ryan/.hermes/hermes-agent/venv/bin/pytest -q tests
# 28 passed

xcodebuild -project Logos.xcodeproj -scheme Logos \
  -destination 'platform=iOS Simulator,id=FD91D719-6C01-4917-A654-B81D3465595A' build
# succeeded

xcodebuild -project Logos.xcodeproj -scheme Logos \
  -destination 'platform=iOS Simulator,id=FD91D719-6C01-4917-A654-B81D3465595A' test
# succeeded: 3 unit tests + 2 UI tests
```

UI tests verified:

- Simulator app auto-connects to mock adapter.
- Text input round trip renders the assistant response.
- Approval fixture renders a card and sends an approve response.
- Clarification fixture renders a card and sends a choice response.

Screenshot artifact:

```text
docs/logos/stage-f-final-simulator.png
```

## Known limitations / next seams

- The project picker currently lists Logos-owned projects from the adapter; historical Hermes desktop sessions are not imported into the phone picker yet.
- UI tests use a deterministic mock Hermes adapter. Live Hermes gateway integration remains covered on the Python side and should be expanded in Stage K.
- Secrets are launch-time dev secrets only; do not commit or log real device credentials.
- Simulator validation does not cover physical-device network behavior, Tailscale reachability, microphone/ASR quality, or APNS delivery.
