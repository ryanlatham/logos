# iOS Autoplay Full Response Audio Implementation Plan

> **For Hermes:** Use subagent-driven-development skill to implement this plan task-by-task.

**Goal:** When the Logos iOS app is open on the active session/project, newly received assistant responses should immediately request/play audio, and the Play button should speak the complete response rather than a generated summary.

**Architecture:** Keep the fix entirely inside the Logos project. The iOS client will own auto-play policy for live inbound assistant `state_update` frames and request full-message TTS. The Logos adapter already supports `mode: "full"` by falling back to stored `message.content`; backend changes should be limited to regression tests unless evidence shows the server violates full-mode semantics.

**Tech Stack:** Swift/SwiftUI, XCTest, Logos WebSocket protocol, existing Python adapter TTS tests.

---

## Root Cause Summary

1. **No autoplay:** `LogosClient.handleStateUpdate` stores/refreshes new assistant messages but never calls `playback(message:)` or sends a `playback_audio` frame. The only call site is the manual Play button in `ContentView.swift`.
2. **Partial playback:** `LogosClient.playback(message:)` sends `payload.mode = "summary"`. The adapter intentionally speaks `LogosSummary.summary_text` for summary mode, which is often first sentence / capped text. The Play button therefore speaks a summary, not the full response.

## Constraints

- Do not change Hermes core agent code.
- Do not autoplay historical `messages_batch` replay on reconnect.
- Do not autoplay user messages, pending messages, or inactive-project messages.
- Avoid duplicate autoplay for the same message ID across `message_appended` / `message_updated` / reconnect noise.
- Keep manual Play available and make it full-response playback.

---

### Task 1: Add failing test for manual Play requesting full response

**Objective:** Prove tapping Play sends `playback_audio` with `mode: "full"` and message content.

**Files:**
- Modify: `clients/ios/Logos/LogosTests/LogosModelTests.swift`
- Production target later: `clients/ios/Logos/Logos/LogosClient.swift`

**Step 1: Write failing test**

Add a `@MainActor` XCTest that:

1. Creates a socket-backed `LogosClient` with `makeSocketBackedClient`.
2. Builds a persisted assistant `LogosMessage` with long multi-sentence content.
3. Calls `client.playback(message:)`.
4. Reads the last sent WebSocket frame.
5. Asserts `type == "playback_audio"`, `payload["mode"] == "full"`, and `payload["text"] == message.content`.

**Step 2: Run RED**

Run from `clients/ios/Logos`:

```bash
xcodebuild -project Logos.xcodeproj -scheme Logos -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:LogosTests/LogosModelTests/testManualPlaybackRequestsFullMessageAudio test
```

Expected: FAIL because current mode is `summary`.

---

### Task 2: Add failing test for live assistant response autoplay

**Objective:** Prove live `state_update.message_appended` for an active-project assistant message sends exactly one full `playback_audio` request automatically.

**Files:**
- Modify: `clients/ios/Logos/LogosTests/LogosModelTests.swift`
- Production target later: `clients/ios/Logos/Logos/LogosClient.swift`

**Step 1: Write failing test**

Add a `@MainActor` XCTest that:

1. Creates socket-backed `LogosClient`.
2. Records current sent-frame count after hello/register/project-list noise.
3. Calls `client.handleFrameString` with a live `state_update` payload:
   - `op: "message_appended"`
   - active `project_key`
   - assistant role
   - persisted message content
4. Asserts exactly one new `playback_audio` frame was sent.
5. Asserts the audio frame uses `mode: "full"`, the same `message_id`, `session_id`, active `project_key`, and full content.
6. Sends the same state update again and asserts no second autoplay frame is sent.

**Step 2: Run RED**

Run the new single test. Expected: FAIL because current code only stores/refreshes the message.

---

### Task 3: Implement full-mode playback request

**Objective:** Make manual Play speak the full message.

**Files:**
- Modify: `clients/ios/Logos/Logos/LogosClient.swift`

**Implementation:**

Change `playback(message:)` payload:

```swift
"mode": "full",
"text": message.content
```

Keep `message_id` so the adapter can audit/source the request.

**Verification:** Run Task 1 test. Expected: PASS.

---

### Task 4: Implement live assistant autoplay policy

**Objective:** Automatically request full audio once for newly received active assistant responses.

**Files:**
- Modify: `clients/ios/Logos/Logos/LogosClient.swift`

**Implementation shape:**

1. Add private state:

```swift
private var autoPlayedMessageKeys = Set<String>()
```

2. Extract helper:

```swift
private func maybeAutoPlayLiveAssistantMessage(_ message: LogosMessage, op: String?) {
    guard connectionState == .connected, task != nil else { return }
    guard message.projectKey == activeProjectKey else { return }
    guard message.status == "persisted", message.role != "user" else { return }
    guard op == "message_appended" || op == "message_updated" else { return }
    let key = message.id
    guard autoPlayedMessageKeys.insert(key).inserted else { return }
    playback(message: message)
}
```

3. In `handleStateUpdate`, after `store.upsert(message)`, `pendingMessages.reconcile`, and `refreshMessages()`, call the helper using the payload op.
4. Do **not** call it from `handleMessagesBatch`, so reconnect/history replay remains silent.
5. On `activeProjectKey` switch, optionally keep the set rather than clearing it; duplicate protection should span the app session.

**Verification:** Run Task 2 test. Expected: PASS.

---

### Task 5: Backend full-mode regression

**Objective:** Protect against future server changes that accidentally summarize full-mode playback.

**Files:**
- Modify: `tests/test_stage_g_tts.py`

**Test:** Add a Python test with a recording TTS object. Store a multi-sentence assistant message, call `_handle_playback_audio` with `mode: "full"` and only `message_id`, then assert the TTS received exact `message.content`, not the first sentence/summary.

**Run:**

```bash
python -m pytest tests/test_stage_g_tts.py -q
```

Expected after implementation: PASS.

---

### Task 6: Verification

Run:

```bash
cd /Users/ryan/Development/logos
python -m pytest tests/test_stage_g_tts.py tests/test_stage_e_interactions.py tests/test_logos_pairing.py -q
cd clients/ios/Logos
xcodebuild -project Logos.xcodeproj -scheme Logos -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:LogosTests/LogosModelTests test
```

If Simulator naming differs, list destinations and choose an available iPhone simulator.

Manual physical-device check after deploy:

1. Open Logos app and active project/session.
2. Send `Hello`.
3. Confirm fast ack may appear visually, but final assistant response starts audio automatically.
4. Tap Play on the same assistant response and confirm it speaks the entire visible text.
5. Confirm reconnecting into history does not autoplay old messages.
