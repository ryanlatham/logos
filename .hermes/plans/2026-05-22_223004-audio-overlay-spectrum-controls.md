# Audio Overlay, Controls, and Spectrum Analyzer Implementation Plan

> **For Hermes:** Use subagent-driven-development skill to implement this plan task-by-task.

**Goal:** While audio is playing or being requested, show a compact playback widget overlaid near the top of the text history with pause/resume, stop, and a spectrum-style visual indicator.

**Architecture:** Keep playback state in `LogosClient`, playback mechanics in `AudioPlaybackController`, and SwiftUI as a pure view over published state. Start with a metering/synthetic spectrum seam that is deterministic in tests; do not put timers or audio state in `ContentView`.

**Tech Stack:** Swift, SwiftUI, AVFoundation, XCTest via `xcodebuild`.

---

## Task 1: Add typed playback overlay state and controls

**Objective:** Introduce a typed UI model so playback is no longer represented only as a nullable string.

**Files:**
- Modify: `clients/ios/Logos/Logos/LogosModels.swift`
- Modify: `clients/ios/Logos/Logos/LogosClient.swift`
- Test: `clients/ios/Logos/LogosTests/LogosModelTests.swift`

**Steps:**
1. RED: Add tests proving `LogosClient` publishes an overlay state when playback is requested/receiving/playing.
2. GREEN: Add `AudioPlaybackPhase` and `AudioPlaybackOverlayState` with fields for `audioID`, `messageID`, `projectKey`, `phase`, `detail`, `spectrumBins`, `canPause`, `canStop`.
3. GREEN: Publish `@Published private(set) var audioPlaybackOverlay` and derive existing `playbackStatus` from the same transitions for compatibility.
4. Verify targeted iOS tests fail before implementation and pass after.

## Task 2: Extend playback controller with pause, resume, stop, and spectrum bins

**Objective:** Make the audio engine controllable and testable.

**Files:**
- Modify: `clients/ios/Logos/Logos/AudioPlaybackController.swift`
- Test: `clients/ios/Logos/LogosTests/LogosModelTests.swift`

**Steps:**
1. RED: Add tests for pause/resume/stop and normalized spectrum bins using the existing recording fake player.
2. GREEN: Extend `AudioPlaying` with `pause()`, `stop()`, `isPlaying`, `currentTime`, `duration`, metering hooks if available.
3. GREEN: Add `pause(audioID:)`, `resume(audioID:)`, `stop(audioID:)`, `stopAll()`, and a deterministic `spectrumBins(audioID:)` fallback.
4. REFACTOR: Keep all AVFoundation details inside `AudioPlaybackController`.

## Task 3: Render the overlay near the top of history

**Objective:** Move playback UI out of the chat stream and into an overlay at the top of the thread.

**Files:**
- Create: `clients/ios/Logos/Logos/AudioPlaybackOverlay.swift`
- Modify: `clients/ios/Logos/Logos/ContentView.swift`
- Test: `clients/ios/Logos/LogosTests/LogosModelTests.swift` and, if practical, `clients/ios/Logos/LogosUITests/LogosUITests.swift`

**Steps:**
1. RED: Add assertions for accessibility identifiers: `audioPlaybackOverlay`, `audioPauseButton`, `audioStopButton`, `audioSpectrumAnalyzer`.
2. GREEN: Wrap the thread scroll view in `ZStack(alignment: .top)` and render `AudioPlaybackOverlay` from `client.audioPlaybackOverlay`.
3. GREEN: Remove playback status from the `LazyVStack` and remove playback-driven scroll-to-bottom behavior.
4. Verify Dynamic Type, Reduce Motion, VoiceOver labels, and dark UI consistency.

## Task 4: Stop must suppress late audio frames

**Objective:** Prevent stopped audio from reappearing as chunks continue arriving.

**Files:**
- Modify: `clients/ios/Logos/Logos/LogosClient.swift`
- Test: `clients/ios/Logos/LogosTests/LogosModelTests.swift`

**Steps:**
1. RED: Test that after `stopPlayback()`, later matching `audio_chunk`/`audio_end` frames do not restart playback or show an error.
2. GREEN: Track ignored/stopped audio IDs until `audio_end` or a short expiry.
3. Verify no server protocol change is required for local pause/stop.

## Verification

Run:

```bash
xcodebuild -project clients/ios/Logos/Logos.xcodeproj -scheme Logos -destination 'platform=iOS Simulator,id=FD91D719-6C01-4917-A654-B81D3465595A' -only-testing:LogosTests/LogosModelTests test
```

## Risks

- A metering fallback is a spectrum-style visual, not a mathematically pure FFT. If strict FFT is required, add an Accelerate/vDSP follow-up.
- Voice recording and playback share `AVAudioSession`; pause/stop must not stomp active recording.
- Timers/display updates must cancel on stop/finish/deinit.
