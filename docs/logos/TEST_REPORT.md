# Logos Test Report

Last updated: 2026-05-22T20:42:43-07:00

Workspace: `/path/to/logos`

Kanban board: `logos-agent-voice-app`

Simulator: `<simulator-udid>` / iPhone 17 Pro

Bundle id: `dev.logos.app`

Secrets and tokens are intentionally omitted or shown as `[REDACTED]`.

## Summary

The automated and live-integration gates for the Logos v1 architecture now pass.

Verified paths:

- Live Hermes gateway is loaded through launchd and running with the Logos platform plugin.
- Live Logos WebSocket auth/enrollment accepts the smoke client through the configured real plugin path.
- Text input reaches the live Hermes gateway/agent path and returns a real Hermes response.
- Fast ack path uses the configured local Ollama model: `ollama/gemma3:12b`.
- TTS uses the configured `macos_say` provider and returns intelligible WAV audio chunks.
- Live Hermes clarification callbacks reach Logos and `clarify_response` resumes the agent.
- Live Hermes approval callbacks reach Logos and `approval_response` maps to Hermes deny/approve semantics.
- iOS client unit/UI tests pass against the mock adapter for deterministic Simulator UI coverage.
- Python tests pass for plugin/protocol/store/LLM/TTS/APNS/callback behavior.

Remaining gate: the maintainer still needs to run the physical iPhone/manual validation using `docs/logos/LOGOS_PHYSICAL_DEVICE_TEST_GUIDE.html`. Simulator and live CLI smoke tests cannot prove physical microphone, physical speaker audibility, APNS delivery on hardware, or real-device network conditions. Annoying, but physics remains stubborn.

## Runtime configuration observed

```text
logos_enabled: True
fast_model_provider: ollama
fast_model_model: gemma3:12b
tts_provider: macos_say
allow_all_users: True
device_secret_present: True
```

Gateway status:

```text
Launchd plist: ~/Library/LaunchAgents/ai.hermes.gateway.plist
Service definition matches current Hermes install
Gateway service is loaded
PID: 96285
LastExitStatus: 0
```

## Commands and results

### Python tests

```bash
cd /path/to/logos
python -m pytest tests -q
```

Result:

```text
75 passed, 1 warning in 0.57s
```

### Python compile check

```bash
cd /path/to/logos
python -m compileall -q plugins/logos scripts tests
```

Result: passed with no output.

### Live Logos smoke test against real Hermes gateway/plugin

```bash
cd /path/to/logos
python scripts/logos_live_smoke.py --scenario all --timeout 360
```

Result summary:

```json
{
  "url": "ws://your-mac:8765",
  "device_id": "logos-live-smoke-cli",
  "fast_model_provider": "ollama",
  "fast_model_model": "gemma3:12b",
  "tts_provider": "macos_say",
  "secret": "[REDACTED]",
  "results": [
    {
      "scenario": "text",
      "ok": true,
      "project_key": "live-smoke-text-6f9cf4",
      "sentinel": "LOGOS_TEXT_OK_cc76eead",
      "ack_text": "Got it.",
      "fast_model_confidence": 1.0
    },
    {
      "scenario": "tts",
      "ok": true,
      "project_key": "live-smoke-tts-35df8d",
      "source": "macos_say_tts",
      "mime_type": "audio/wav",
      "chunk_count": 29,
      "riff_prefix": true
    },
    {
      "scenario": "clarify",
      "ok": true,
      "project_key": "live-smoke-clarify-b1f17b",
      "question": "For Logos smoke, choose alpha or beta.",
      "choices": ["alpha", "beta"]
    },
    {
      "scenario": "approval",
      "ok": true,
      "project_key": "live-smoke-approval-498f93",
      "decision_sent": "deny",
      "command_preview_matches": true
    }
  ]
}
```

This smoke test does **not** use `scripts/run_stage_f_mock_adapter.py`; it connects to the configured live Logos endpoint and exercises the real Hermes platform plugin path.

### Direct TTS runtime probe

```bash
cd /path/to/logos
PYTHONPATH=plugins python - <<'PY'
from logos.tts import MacOSSayTTS
audio = MacOSSayTTS(timeout_seconds=8).synthesize('Logos speech smoke test.')
print('bytes:', len(audio))
print('prefix:', audio[:4].decode('ascii', errors='replace'))
PY
```

Result:

```text
bytes: 56010
prefix: RIFF
```

### Ollama runtime probe

Ollama was reachable at `127.0.0.1:11434`; model list included `gemma3:12b`.

### Xcode build/test

Mock adapter setup used for deterministic Simulator UI tests:

```bash
cd /path/to/logos
PYTHONPATH=plugins python scripts/run_stage_f_mock_adapter.py \
  --host 127.0.0.1 \
  --port 8766 \
  --secret [REDACTED]
```

Test command:

```bash
cd /path/to/logos
xcodebuild test \
  -project clients/ios/Logos/Logos.xcodeproj \
  -scheme Logos \
  -destination 'platform=iOS Simulator,id=<simulator-udid>'
```

Result:

```text
LogosModelTests: 67 tests, 0 failures
** TEST SUCCEEDED **
```

Result bundle:

```text
~/Library/Developer/Xcode/DerivedData/Logos-dlclbxwcbdpywgftxzecnnzrzohg/Logs/Test/Test-Logos-2026.05.22_20-42-18--0700.xcresult
```

Focused UI smoke uses the mock adapter on port `8766`; the latest backend and model-test gates above did not require a persistent mock adapter.

### Independent review gate

Result: PASS after fixes.

```text
UX review: PASS
Architecture review: PASS
Security/privacy review: PASS
General code review: PASS
```

Review-driven hardening included editable device-key setup, local-network usage description, APNS entitlement attachment, streaming edit `server_seq`/summary/project-state refresh, and TTS failure log redaction.

## Feature validation matrix

| Area | Status | Evidence |
|---|---:|---|
| Live plugin WebSocket auth/enrollment | Pass | `logos_live_smoke.py --scenario all` authenticated as `logos-live-smoke-cli` |
| Live Hermes message routing | Pass | Live text smoke returned exact sentinel through Hermes path |
| Fast local LLM | Pass | Runtime config and smoke ack use `ollama/gemma3:12b` |
| Real TTS runtime | Pass | `macos_say` produced WAV chunks; direct probe returned `RIFF` bytes |
| Approval callbacks | Pass | Live approval smoke surfaced request and sent deny response |
| Clarification callbacks | Pass | Live clarify smoke surfaced choices and resumed with answer |
| Tool/run progress frames | Pass | Text smoke observed `state_update` and `run_status` frame sequence |
| iOS WebSocket/HMAC client | Pass | Swift tests cover canonical HMAC and UI mock-adapter connection |
| iOS local store/message update | Pass | Regression covers `message_updated` replacing existing progress content |
| iOS voice lifecycle | Pass | Unit tests cover tap, hold, silence, ASR-progress, duplicate finalization, disconnect/send failure |
| iOS playback lifecycle | Pass | Unit tests cover audio chunk assembly/session activation; UI test observes playback status |
| iOS approval/clarification UI | Pass | UI tests render and respond to fixture cards |
| APNS/private notification payload shape | Pass | Unit tests cover private payload/route parsing; live APNS delivery remains physical/manual |
| Physical iPhone microphone/speaker/APNS | Manual gate | Covered by `LOGOS_PHYSICAL_DEVICE_TEST_GUIDE.html`; a tester should run after handoff |

## Known limits and manual gate

- Physical iPhone testing is still required for real microphone capture, on-device speech behavior, physical speaker audibility, private-network reachability from device, signing, and APNS delivery.
- Apple Watch relay remains explicitly post-v1/deferred.
- `allow_all_users: true` is enabled in the local Hermes Logos config for this development validation run. Before treating this as a stricter production posture, narrow enrollment back to known device IDs or DB-enrolled devices.
- Existing gateway logs include unrelated Discord privileged-intents and Telegram chat-not-found warnings. They did not block the Logos live WebSocket smoke path.

## Artifacts

- Live smoke script: `scripts/logos_live_smoke.py`
- Manual/physical guide: `docs/logos/LOGOS_PHYSICAL_DEVICE_TEST_GUIDE.html`
- Device checklist: `docs/logos/DEVICE_TEST_CHECKLIST.md`
- Final status report: `docs/logos/FINAL_REPORT.md`
