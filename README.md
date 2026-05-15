# Logos

Logos is a private iPhone voice-and-tap surface for Hermes Agent.

This repository contains:

- `plugins/logos/` — Hermes platform plugin and WebSocket adapter.
- `clients/ios/Logos/` — SwiftUI iOS client, generated with XcodeGen from `project.yml`.
- `scripts/` — local development and simulator helper scripts.
- `tests/` — Python adapter/protocol tests.
- `docs/logos/` — architecture references, implementation notes, test reports, manual device walkthrough, and code-review report.

## Current status

Simulator-verifiable implementation is complete and reviewer-approved. Real iPhone validation remains gated on physical device, Tailscale/private networking, Apple signing/APNS credentials, and microphone behavior.

See:

- `docs/logos/FINAL_REPORT.md`
- `docs/logos/CODE_REVIEW_REPORT.md`
- `docs/logos/DEVICE_TEST_CHECKLIST.md`
- `docs/logos/LOGOS_PHYSICAL_DEVICE_TEST_GUIDE.html`

## Validate Python side

```bash
PYTHONPATH=/Users/ryan/Development/logos/plugins:/Users/ryan/.hermes/hermes-agent \
  /Users/ryan/.hermes/hermes-agent/venv/bin/pytest -q tests
```

## Validate iOS side

```bash
cd clients/ios/Logos
xcodegen generate --spec project.yml
xcodebuild -project Logos.xcodeproj \
  -scheme Logos \
  -destination 'platform=iOS Simulator,id=FD91D719-6C01-4917-A654-B81D3465595A' \
  test
```

The UI tests expect the mock adapter to be running on `127.0.0.1:8765` with the test-only secret used in `LogosUITests`.
