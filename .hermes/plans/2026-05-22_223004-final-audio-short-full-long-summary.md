# Final Audio Short-Full / Long-Summary Implementation Plan

> **For Hermes:** Use subagent-driven-development skill to implement this plan task-by-task.

**Goal:** Manual Play always plays the final Hermes message; live autoplay reads short final messages in full, but for long final messages plays exactly one fast-model summary and never the full long content.

**Architecture:** Keep final audio selection backend-owned with a new `playback_audio` mode `final_auto`. iOS asks for `final_auto` only for autoplay; manual Play remains `full`. The adapter decides full vs summary using configurable thresholds and reuses stored summaries by source hash.

**Tech Stack:** Python adapter/TTS tests, Swift client tests, existing fast model summary path.

---

## Task 1: Add backend final_auto playback mode

**Objective:** Centralize final audio selection in the adapter.

**Files:**
- Modify: `plugins/logos/adapter.py`
- Test: `tests/test_stage_g_tts.py`

**Steps:**
1. RED: Add `test_final_auto_playback_short_message_speaks_full_text`.
2. RED: Add `test_final_auto_playback_long_message_speaks_summary_once`.
3. GREEN: Add `DEFAULT_FINAL_AUDIO_FULL_MAX_CHARS` and `DEFAULT_FINAL_AUDIO_FULL_MAX_WORDS`, with config/env overrides.
4. GREEN: Implement `_is_short_final_audio_text()` and `_summary_for_message()` that validates existing summary `source_hash`.
5. GREEN: Extend `_handle_playback_audio` to support `mode == "final_auto"`, emitting metadata `requested_mode`, selected `mode`, and `selection_reason`.

## Task 2: Reuse summaries and avoid duplicate model calls

**Objective:** A long final message should result in one summary, not one per playback attempt.

**Files:**
- Modify: `plugins/logos/adapter.py`
- Test: `tests/test_stage_g_tts.py`

**Steps:**
1. RED: Call `send()` with long content, then `final_auto` playback; assert no second summarize call.
2. GREEN: Route send/finalize/playback summary generation through `_summary_for_message()`.
3. Verify stale summaries are regenerated only when `source_hash` differs.

## Task 3: Change iOS autoplay to request final_auto

**Objective:** Manual Play remains full; live final autoplay delegates selection to backend.

**Files:**
- Modify: `clients/ios/Logos/Logos/LogosClient.swift`
- Test: `clients/ios/Logos/LogosTests/LogosModelTests.swift`

**Steps:**
1. RED: Update/add test asserting manual Play sends `mode: "full"`.
2. RED: Add test asserting live final assistant autoplay sends `mode: "final_auto"`, not `full`.
3. GREEN: Refactor `playback(message:)` into `requestPlayback(message:mode:autoplay:)`; manual uses `full`, autoplay uses `final_auto`.

## Task 4: Only final messages autoplay

**Objective:** Avoid reading streaming updates or historical replay.

**Files:**
- Modify: `clients/ios/Logos/Logos/LogosModels.swift`
- Modify: `clients/ios/Logos/Logos/LogosClient.swift`
- Test: `clients/ios/Logos/LogosTests/LogosModelTests.swift`

**Steps:**
1. RED: Add tests for `message_updated` without `metadata.finalized` not autoplaying.
2. RED: Add tests for `message_updated` with `metadata.finalized: true` autoplaying once with `final_auto`.
3. GREEN: Parse final metadata and gate autoplay accordingly.

## Verification

Run:

```bash
python -m pytest tests/test_stage_g_tts.py tests/test_stage_h_fast_model.py -q
xcodebuild -project clients/ios/Logos/Logos.xcodeproj -scheme Logos -destination 'platform=iOS Simulator,id=<simulator-udid>' -only-testing:LogosTests/LogosModelTests test
```

## Risks

- Existing `ContentView.speakMode` is local and not wired; do not rely on it unless explicitly moved into settings.
- Summary prompt currently targets compact/notification surfaces; acceptable for v1, but spoken-summary prompt can improve later.
