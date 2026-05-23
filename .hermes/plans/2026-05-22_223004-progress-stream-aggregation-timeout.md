# Progress Stream Aggregation and Timeout Implementation Plan

> **For Hermes:** Use subagent-driven-development skill to implement this plan task-by-task.

**Goal:** Treat Hermes streamed tool/progress updates as request progress, not final assistant responses: aggregate/collapse them visually, never autoplay them, keep the run non-idle until final output or a timeout, and play one standard timeout response if the gateway goes silent.

**Architecture:** Classify non-final assistant `message_updated` frames and explicit `tool_progress` frames as progress events. Store them separately from final chat messages in iOS UI state. Only final assistant messages clear the in-progress state and become autoplay candidates. Implement timeout in `LogosClient` so the app can recover from gateway silence even if no final frame arrives.

**Tech Stack:** Swift, SwiftUI, Python adapter protocol tests, XCTest.

---

## Task 1: Parse final/progress metadata on messages

**Objective:** Let iOS distinguish final assistant content from streaming progress.

**Files:**
- Modify: `clients/ios/Logos/Logos/LogosModels.swift`
- Modify: `plugins/logos/adapter.py` if protocol metadata needs normalization
- Test: `clients/ios/Logos/LogosTests/LogosModelTests.swift`, `tests/test_stage_b_adapter_ws.py`

**Steps:**
1. RED: Add tests showing `LogosMessage.from` parses `metadata.finalized`, `metadata.source`, and a progress flag/type without storing raw `[String: Any]`.
2. GREEN: Add scalar fields such as `isFinal`, `metadataSource`, `progressKind`.
3. GREEN: Ensure adapter `send()` marks final appended assistant messages final; `edit_message(finalize=True)` already carries `finalized: true`.

## Task 2: Add aggregated progress UI state

**Objective:** Surface progress as one collapsed/expandable unit instead of many chat bubbles.

**Files:**
- Modify: `clients/ios/Logos/Logos/LogosModels.swift`
- Modify: `clients/ios/Logos/Logos/LogosClient.swift`
- Create: `clients/ios/Logos/Logos/ProgressActivityView.swift`
- Modify: `clients/ios/Logos/Logos/ContentView.swift`
- Test: `clients/ios/Logos/LogosTests/LogosModelTests.swift`

**Steps:**
1. RED: Feed multiple non-final `message_updated`/`tool_progress` frames and assert one aggregate progress group with multiple events.
2. GREEN: Add `ProgressActivityState` with `requestID`, `projectKey`, `events`, `isExpanded`, `lastUpdateAt`, and `timedOut`.
3. GREEN: Render it as one card/strip with collapsed summary and an expand/collapse button. Accessibility ID: `progressActivityCard`.
4. GREEN: Exclude progress events from `messages` chat bubbles.

## Task 3: Prevent progress autoplay and idle misclassification

**Objective:** Only final messages should satisfy a request or trigger speech.

**Files:**
- Modify: `clients/ios/Logos/Logos/LogosClient.swift`
- Test: `clients/ios/Logos/LogosTests/LogosModelTests.swift`

**Steps:**
1. RED: Add tests proving non-final updates do not call `playback_audio`, do not insert into `autoPlayedMessageKeys`, and do not set terminal/idle UI.
2. GREEN: Gate `maybeAutoPlayLiveAssistantMessage` on `message.isFinal` for `message_updated`; treat appended assistant messages from `send()` as final unless metadata says otherwise.
3. GREEN: Keep `runStatus` `.running` while progress activity is open even if stale gateway status says idle before final.

## Task 4: Add gateway-silence timeout audio

**Objective:** If no final response arrives after progress stops, play one standard timeout response.

**Files:**
- Modify: `clients/ios/Logos/Logos/LogosClient.swift`
- Optionally modify: `plugins/logos/adapter.py` if adding a local `playback_audio` source mode is cleaner
- Test: `clients/ios/Logos/LogosTests/LogosModelTests.swift`, `tests/test_stage_g_tts.py` if backend mode added

**Steps:**
1. RED: Test that progress events arm a timeout and any subsequent progress resets it.
2. RED: Test that final assistant message cancels timeout.
3. GREEN: Add `progressTimeoutTask` with a conservative default, e.g. 45s, shorter injectable/test value.
4. GREEN: On timeout, mark progress card timed out and request TTS for a standard message such as: `The gateway stopped sending updates before a final response arrived.`
5. GREEN: Ensure timeout audio plays only once per request.

## Verification

Run targeted Python/iOS tests, then:

```bash
python -m pytest tests -q
xcodebuild -project clients/ios/Logos/Logos.xcodeproj -scheme Logos -destination 'platform=iOS Simulator,id=FD91D719-6C01-4917-A654-B81D3465595A' -only-testing:LogosTests/LogosModelTests test
```

## Risks

- Gateway metadata may be inconsistent; prefer defensive classification and tests with current frame shapes.
- Timeout must not fire during approval/clarification waits.
- Do not treat historical `messages_batch` replay as live progress.
