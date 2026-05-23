# Non-Spoken Progress Updates + Active Gateway State Implementation Plan

> **For Hermes:** Implement directly with TDD; keep Hermes core untouched. The Logos plugin and iOS client own the platform-specific behavior.

**Goal:** Progress/status updates such as “⏳ Still working...” and gateway lifecycle warnings render as transient progress/activity UI, never as assistant messages with Play/autoplay, and the iOS run status remains `running` while Hermes is still working.

**Architecture:** Treat operational updates as progress events at the Logos adapter boundary. The backend should broadcast `tool_progress`/progress frames instead of persisting normal assistant messages or emitting terminal `idle`. The iOS client should defensively classify legacy status-shaped assistant messages as progress so stale/replayed frames cannot trigger TTS or show a Play affordance.

**Tech Stack:** Python Logos plugin (`plugins/logos/adapter.py`), pytest; Swift/SwiftUI iOS client (`clients/ios/Logos`), XCTest.

---

## Root Cause

1. Hermes gateway sends periodic long-running updates through the normal platform `send()` path:
   - `⏳ Still working... (3 min elapsed — iteration 1/1000, API call #1 completed)`
2. Logos only treated tool-line updates like `🔧 terminal: ...` as progress.
3. The still-working update therefore became a persisted assistant message.
4. Persisted assistant messages trigger `final_auto` playback and render a manual Play button.
5. `adapter.send()` also broadcasts `run_status: idle` after normal assistant messages, so the header shows `IDLE · LIVE` even while the Hermes run continues.

## Acceptance Criteria

- Still-working gateway updates broadcast as transient progress frames.
- Gateway restart/shutdown status warnings also broadcast as transient status/progress frames.
- These frames are not stored in the Logos message database.
- They do not generate summaries, APNS finished notifications, or `run_status: idle`.
- iOS aggregates them into `ProgressActivityCard` and keeps `runStatus == .running`.
- iOS never sends `playback_audio` for these updates, even if received as legacy `state_update` assistant messages.
- Normal final assistant responses still persist, summarize, notify, and autoplay according to the existing final/summary rules.

---

## Task 1: Backend regression tests for gateway status updates

**Files:**
- Modify: `tests/test_stage_b_adapter_ws.py`

**Steps:**
1. Add a pytest that calls `adapter.send()` with a still-working message.
2. Assert the result is successful and returns a `progress-*` message id.
3. Assert no Logos messages were stored.
4. Assert the broadcast frame type is `tool_progress`, kind/progress_kind is gateway status, and no `idle` run status is sent.
5. Add the same guard for `⚠️ Gateway restarting — ...`.
6. Run the new tests and verify they fail before implementation.

## Task 2: Backend progress classification implementation

**Files:**
- Modify: `plugins/logos/adapter.py`

**Steps:**
1. Add narrowly-scoped regexes for gateway status/progress text:
   - `⏳ Still working... (...)`
   - `⚠️ Gateway restarting — ...`
   - `⚠️ Gateway shutting down — ...`
2. Add a classifier returning progress kind/source for either tool progress or gateway status.
3. Update `send()` and `edit_message()` to route those updates through `_broadcast_progress_text()`.
4. Extend `_broadcast_progress_text()` to accept `kind`/`progress_kind` and annotate the frame payload.
5. Run the backend regression tests and verify they pass.

## Task 3: iOS defensive regression tests

**Files:**
- Modify: `clients/ios/Logos/LogosTests/LogosModelTests.swift`

**Steps:**
1. Add an XCTest that sends a legacy `state_update/message_appended` frame containing the still-working text but no metadata.
2. Assert `client.messages` remains empty.
3. Assert `client.progressActivity` contains the text.
4. Assert no `playback_audio` frame was sent.
5. Assert a later `run_status: idle` is ignored while the progress activity is active.
6. Run the targeted iOS test and verify it fails before implementation.

## Task 4: iOS defensive implementation

**Files:**
- Modify: `clients/ios/Logos/Logos/LogosModels.swift`

**Steps:**
1. Add `looksLikeGatewayProgressText(_:)` helper to `LogosMessage`.
2. Extend `isProgressUpdate` to return true for assistant/non-user still-working and gateway lifecycle warning text.
3. Keep normal assistant messages untouched.
4. Run the targeted iOS test and verify it passes.

## Task 5: Verification

**Commands:**
- `python -m pytest tests/test_stage_b_adapter_ws.py -q`
- iOS targeted unit test for the new regression.
- Broader iOS unit target if targeted verification is clean.
- `python -m pytest tests -q` if time permits and no live gateway interruption risk.

**Manual check after restart:**
1. Restart Hermes gateway so the plugin change loads.
2. Send a long-running Logos request.
3. Confirm updates appear only in the progress card.
4. Confirm no Play button on updates.
5. Confirm header shows running/active while progress is live.
