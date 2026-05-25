# Audio Background Resume Implementation Plan

> **For Hermes:** Use subagent-driven-development skill to implement this plan task-by-task.

**Goal:** If the app is locked/backgrounded/minimized during audio playback and later resumes, audio should continue from the saved position instead of replaying from the beginning.

**Architecture:** Capture/resume playback state locally inside `AudioPlaybackController` and `LogosClient`; do not re-request `playback_audio` for the same message as a resume mechanism. Use scene lifecycle hooks and AVAudioSession interruption hooks. Add background audio capability only if product behavior requires continuous playback while locked.

**Tech Stack:** Swift, AVFoundation, SwiftUI scenePhase, XCTest.

---

## Task 1: Add resumable playback controller state

**Objective:** Track active player, current time, and resumability without treating pause as finish.

**Files:**
- Modify: `clients/ios/Logos/Logos/AudioPlaybackController.swift`
- Test: `clients/ios/Logos/LogosTests/LogosModelTests.swift`

**Steps:**
1. RED: Add tests proving lifecycle pause captures nonzero `currentTime` and does not call `onPlaybackFinished`.
2. GREEN: Extend `AudioPlaying` with `currentTime`, `duration`, `isPlaying`, `pause()`, `stop()`.
3. GREEN: Add `pauseForLifecycle(reason:)` and `resumeAfterLifecycle()` using saved `currentTime`.
4. GREEN: Retain assembled audio data or player until natural finish so resume can seek.

## Task 2: Wire scene lifecycle without sending duplicate playback_audio

**Objective:** Foreground resume must be local, not a new server playback request.

**Files:**
- Modify: `clients/ios/Logos/Logos/LogosClient.swift`
- Modify: `clients/ios/Logos/Logos/ContentView.swift`
- Test: `clients/ios/Logos/LogosTests/LogosModelTests.swift`

**Steps:**
1. RED: Add test that background/active lifecycle calls pause/resume and sends no extra `playback_audio` frame.
2. GREEN: Add `pauseAudioForSceneBackground()` and `resumeAudioForSceneActive()` to `LogosClient`.
3. GREEN: In `ContentView.onChange(of: scenePhase)`, call pause on `.background` and local resume on `.active` before/alongside reconnect.
4. GREEN: Suppress autoplay duplicate while the same message is active or resumable.

## Task 3: Handle AVAudioSession interruptions

**Objective:** Lock screen, route change, or interruption should save position and resume only when safe.

**Files:**
- Modify: `clients/ios/Logos/Logos/AudioPlaybackController.swift`
- Test: `clients/ios/Logos/LogosTests/LogosModelTests.swift`

**Steps:**
1. RED: Add tests for interruption began/end with `shouldResume` and route-change old-device-unavailable.
2. GREEN: Observe `AVAudioSession.interruptionNotification`, `routeChangeNotification`, and `mediaServicesWereResetNotification` in controller or a small helper.
3. GREEN: On interruption began, pause and save offset. On end with shouldResume, resume from offset; without shouldResume, stay paused.

## Task 4: Background mode decision

**Objective:** Align plist capability with product behavior.

**Files:**
- Modify if needed: `clients/ios/Logos/Logos/Info.plist`
- Modify if needed: `clients/ios/Logos/project.yml`
- Test: `clients/ios/Logos/LogosTests/LogosModelTests.swift`

**Steps:**
1. If desired behavior is continuous playback while locked/minimized, add `audio` to `UIBackgroundModes` and test plist configuration.
2. If desired behavior is pause/resume on foreground, do not add background audio yet; prove explicit pause/resume works.
3. In either case, document physical-device caveat: Simulator does not prove lock-screen audio behavior.

## Verification

Run:

```bash
xcodebuild -project clients/ios/Logos/Logos.xcodeproj -scheme Logos -destination 'platform=iOS Simulator,id=<simulator-udid>' -only-testing:LogosTests/LogosModelTests test
```

## Risks

- If the app is killed, in-memory resume state is gone; that is a later persisted-checkpoint feature.
- Backgrounding during chunk receipt is different from backgrounding after audio starts; cover both if possible.
- Background audio entitlement changes must be validated on a physical iPhone.
