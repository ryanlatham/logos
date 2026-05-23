# Logos Real Spectrum Analyzer Implementation Plan

> **For Hermes:** Planning only. Do not implement until Ryan explicitly approves. If approved, use TDD and keep the first implementation narrowly scoped to the iOS playback overlay.

**Goal:** Replace the current fake/static audio bars with a real, continuously updating spectrum analyzer driven by decoded playback PCM and Accelerate/vDSP FFT analysis.

**Architecture:** Keep the existing `AVAudioPlayer` playback path for now to avoid disturbing the recently hardened playback/cancel lifecycle. Decode completed playback audio into mono PCM samples once, store those samples by `audioID`, and compute FFT bins against `AVAudioPlayer.currentTime` on a bounded UI tick while audio is playing. Use `Accelerate`/`vDSP` for windowing, FFT magnitude, dB normalization, and 12 log-spaced visual bands.

**Tech Stack:** Swift, SwiftUI, AVFoundation/AVFAudio, Accelerate/vDSP, XCTest, existing Logos mock WebSocket UI test harness.

---

## Research notes

### What a real spectrum analyzer needs

A real spectrum analyzer must operate on time-domain PCM samples, not encoded bytes and not one broadband power meter. The usual path is:

1. obtain a small window of PCM samples from the playing audio,
2. apply a window function such as Hann to reduce spectral leakage,
3. run a forward FFT,
4. convert complex FFT output to magnitudes,
5. map FFT frequency bins into visual frequency bands,
6. smooth and normalize those bands for display,
7. update the UI periodically during playback.

### Source notes

- Apple `AVAudioPlayer.updateMeters()` only refreshes average/peak power values for channels. `averagePower(forChannel:)` returns one dBFS value per channel after `updateMeters()`, ranging from `-160` dBFS to `0` dBFS. That is volume metering, not frequency analysis.
- Apple `AVAudioNode.installTap(onBus:bufferSize:format:block:)` can observe output buffers from an audio node. This is the more invasive route if we later replace `AVAudioPlayer` with `AVAudioEngine`/`AVAudioPlayerNode`.
- Apple `AVAudioPCMBuffer` exposes decoded PCM via `floatChannelData`, `int16ChannelData`, etc.
- Apple `AVAudioFile` reads audio files into `AVAudioPCMBuffer` regardless of underlying file format; its processing format is suitable for sample processing.
- Apple `vDSP.WindowSequence.hanningDenormalized` / Hann windows reduce spectral leakage before DFT/FFT.
- Accelerate/vDSP FFT examples convert real audio samples into split-complex data, run a forward FFT, scale output, and compute magnitudes. Existing iOS examples use chunk sizes around 512+ frames and update UI periodically.

---

## Current diagnosis from the Logos code

Current files inspected:

- `clients/ios/Logos/Logos/AudioPlaybackController.swift`
- `clients/ios/Logos/Logos/LogosClient.swift`
- `clients/ios/Logos/Logos/ContentView.swift`
- `clients/ios/Logos/Logos/LogosModels.swift`
- `clients/ios/Logos/LogosTests/LogosModelTests.swift`

### Root problem

The current analyzer is not a spectrum analyzer. It is a static/fake visualization with no continuous data source.

Evidence:

1. `AudioPlaybackController.spectrumBins(audioID:count:)` uses `AVAudioPlayer.averagePower(forChannel:)`, which is a single broadband amplitude value, then multiplies it by a sine wave across bar indexes:
   - `player.updateMeters()`
   - `let power = player.averagePower(forChannel: 0)`
   - `let wave = 0.65 + 0.35 * sin(Double(index) * 0.9 + player.currentTime)`
2. `LogosClient.spectrumBins(fromBase64:)` uses raw bytes from the incoming base64 audio chunk. Those bytes are encoded audio payload bytes, not PCM samples. That can produce an initial-looking spike, but it is not acoustically meaningful.
3. `ContentView.SpectrumAnalyzerView` only receives `overlay.spectrumBins`; it does not query live audio. Its `pulse` state only adds a tiny fake animation offset.
4. `LogosClient.updateAudioOverlay(...)` only updates bins when audio frames/state events arrive: request, chunk, end, pause, resume, lifecycle events. After playback starts, there is no periodic refresh loop, so the bars can show an initial state and then stop.
5. Existing tests only assert bin count/range, not frequency correctness or continuous playback updates.

So the user-visible symptom — initial spike then silence/frozen analyzer — is exactly what this architecture would produce. The part that gets us killed is pretending this is a rendering bug. It is a data-source bug.

---

## Recommended approach

### Recommendation

Implement a real decoded-PCM analyzer while keeping `AVAudioPlayer` for playback.

This is the right first move because it gives us real frequency-domain data without replacing the playback engine, audio session behavior, pause/resume/stop lifecycle, or the recently hardened playback request flow.

### Why not jump straight to `AVAudioEngine`?

`AVAudioEngine` + `AVAudioPlayerNode` + tap is the cleanest “live output buffer” design in a greenfield app. It is also a broader migration:

- replace `AVAudioPlayer` creation,
- schedule decoded buffers or files,
- rework delegate-style completion,
- revalidate pause/resume/currentTime/lifecycle behavior,
- retest output route/session behavior.

That is more blast radius than this bug needs. Bold. Possibly stupid. Let’s make it less stupid: first build a true analyzer on top of the current playback path; only move to engine taps if currentTime-synced PCM analysis proves visibly out of sync.

---

## Target behavior

1. While audio is **requesting**:
   - show a quiet placeholder/pulse, not a fake spectrum.
2. While audio is **receiving encoded chunks**:
   - show “Receiving audio” with minimal loading motion.
   - Do not pretend chunk bytes are spectrum data.
3. When audio is **playing**:
   - update 12 bars at ~20-30 Hz from decoded PCM near `AVAudioPlayer.currentTime`.
   - low frequencies affect low bars; high frequencies affect high bars.
   - silence/near-silence settles near the floor.
4. When audio is **paused**:
   - freeze the last real bars or dim them; do not keep ticking.
5. When audio is **resumed**:
   - restart ticking from the resumed playback time.
6. When audio is **stopped, failed, finished, project-switched, disconnected, or superseded by another playback request**:
   - stop the ticker and do not allow stale audio IDs to update the overlay.

---

## Frequency band design

Use 12 log-spaced visual bands. A practical default for voice/TTS playback:

```text
80, 117, 172, 253, 371, 545, 800, 1174, 1724, 2530, 3713, 5450, 8000 Hz
```

These are band edges for 12 bands from 80 Hz to 8 kHz. Voice has useful energy here, and the UI only has 92px width, so more bins would be aesthetic noise.

FFT sizing:

- Start with `fftSize = 1024`.
- For sample rates:
  - 24 kHz: ~23.44 Hz/bin, ~42.7 ms window
  - 44.1 kHz: ~43.07 Hz/bin, ~23.2 ms window
  - 48 kHz: ~46.88 Hz/bin, ~21.3 ms window
- If the bars look too jittery, use 2048 samples or stronger smoothing before considering an engine rewrite.

---

## Implementation plan

### Task 1: Add RED tests for real spectrum correctness

**Objective:** Prove the current implementation cannot distinguish different frequencies.

**Files:**

- Modify: `clients/ios/Logos/LogosTests/LogosModelTests.swift`

**Test cases to add:**

1. `testSpectrumAnalyzerMapsLowToneToLowerBands`
   - Generate a synthetic mono sine wave around a low voice-band frequency, e.g. 160 Hz.
   - Analyze 12 bands.
   - Assert one of the low bands is materially stronger than upper bands.

2. `testSpectrumAnalyzerMapsHighToneToHigherBands`
   - Generate a synthetic mono sine wave around a higher frequency, e.g. 3000 Hz.
   - Analyze 12 bands.
   - Assert high bands are materially stronger than low bands.

3. `testSpectrumAnalyzerSilenceReturnsFloorBins`
   - Analyze all-zero samples.
   - Assert all bins are finite, in `0...1`, and near the floor.

**Expected before implementation:** fail because no `AudioSpectrumAnalyzer` exists and current `spectrumBins` cannot perform frequency-specific mapping.

---

### Task 2: Create a pure `AudioSpectrumAnalyzer`

**Objective:** Add testable FFT logic without touching playback lifecycle yet.

**Files:**

- Create: `clients/ios/Logos/Logos/AudioSpectrumAnalyzer.swift`
- Modify: `clients/ios/Logos/LogosTests/LogosModelTests.swift`

**Design:**

```swift
struct AudioSpectrumAnalyzer {
    struct Configuration: Equatable {
        var fftSize: Int = 1024
        var binCount: Int = 12
        var minimumFrequency: Float = 80
        var maximumFrequency: Float = 8000
        var floorDB: Float = -80
    }

    func analyze(
        samples: [Float],
        sampleRate: Double,
        playheadTime: TimeInterval,
        configuration: Configuration = .init(),
        previousBins: [Double]? = nil
    ) -> [Double]
}
```

**Implementation details:**

- Clamp `fftSize` to a power-of-two supported by vDSP.
- Convert `playheadTime` to a sample frame offset.
- Pull a sample window at/near the playhead; zero-pad at edges.
- Apply a Hann window before FFT.
- Run forward real FFT with Accelerate/vDSP.
- Convert FFT complex output to magnitudes.
- Convert magnitudes to dB and normalize into `0...1`.
- Map FFT bins into 12 log-spaced frequency bands.
- Apply lightweight visual smoothing only at the output layer, not inside raw DSP tests unless explicitly injected.

**Verification:**

Run targeted iOS unit tests for the new analyzer tests.

---

### Task 3: Add a test seam for decoding playback data into PCM

**Objective:** Make production decoding real while keeping unit tests deterministic and not dependent on AVAudioFile quirks.

**Files:**

- Modify: `clients/ios/Logos/Logos/AudioPlaybackController.swift`
- Modify: `clients/ios/Logos/LogosTests/LogosModelTests.swift`

**Design:**

```swift
struct DecodedAudioSamples: Equatable {
    let samples: [Float]
    let sampleRate: Double
}

protocol AudioSampleDecoding {
    func decodeSamples(from data: Data) throws -> DecodedAudioSamples
}
```

Production implementation:

- `AVAudioFileSampleDecoder`
- Writes the assembled playback `Data` to a temporary file if needed.
- Opens it with `AVAudioFile(forReading:)`.
- Reads into `AVAudioPCMBuffer` using the processing format.
- Mixes channels to mono Float samples.
- Cleans up temporary files.

Test implementation:

- `RecordingAudioSampleDecoder` or `SyntheticAudioSampleDecoder`
- Returns known generated samples and sample rate.

**Verification:**

Add tests proving:

- `AudioPlaybackController.finish(...)` stores decoded samples by `audioID` on playback start.
- Decode failure does not prevent playback from starting; it degrades to floor/placeholder spectrum and records no user-facing fatal playback error.
- Stored sample data is removed on finish/stop/decode-error cleanup so we do not leak memory per audio.

---

### Task 4: Replace fake `spectrumBins(audioID:)` with decoded PCM analysis

**Objective:** Make `AudioPlaybackController.spectrumBins` return frequency-domain bins for active playback.

**Files:**

- Modify: `clients/ios/Logos/Logos/AudioPlaybackController.swift`
- Modify: `clients/ios/Logos/LogosTests/LogosModelTests.swift`

**Implementation details:**

- Add `spectrumTracksByAudioID: [String: DecodedAudioSamples]`.
- During `finish(audioID:expectedChunkCount:)`, after assembling `Data`, decode/stash samples.
- In `spectrumBins(audioID:count:)`:
  - if a player and decoded samples exist: analyze using `player.currentTime`;
  - if paused and player still exists: return last bins or analyze at frozen `currentTime`;
  - if no samples exist: return floor bins, not encoded byte bars;
  - never synthesize sine-wave bars from `averagePower`.
- Keep `AVAudioPlayer` metering out of spectrum logic. It can be deleted from the protocol if no other code needs it, or left unused temporarily to minimize churn.

**Verification:**

Add tests proving:

- Different `RecordingAudioPlayer.currentTime` values can produce different bins for synthetic changing audio.
- Low and high synthetic tones map to different bar regions through the controller, not just through the pure analyzer.
- `stop(audioID:)`, delegate finish, and decode error clean analyzer state.

---

### Task 5: Add a playback spectrum ticker in `LogosClient`

**Objective:** Continuously refresh `audioPlaybackOverlay.spectrumBins` while audio is playing.

**Files:**

- Modify: `clients/ios/Logos/Logos/LogosClient.swift`
- Modify: `clients/ios/Logos/LogosTests/LogosModelTests.swift`

**Design:**

Add a MainActor-owned ticker, scoped by `audioID`:

```swift
private var spectrumUpdateTask: Task<Void, Never>?

private func startSpectrumUpdates(audioID: String)
private func stopSpectrumUpdates(audioID: String? = nil)
private func refreshPlaybackSpectrum(audioID: String)
```

**Rules:**

- Start after `handleAudioEnd` successfully starts playback.
- Restart after `resumePlayback()` and `resumeAudioForSceneActive()`.
- Stop on pause, stop, finish, failure, project switch, disconnect, superseding playback request, and `prepareForNewPlaybackRequest`.
- Each tick must re-check:
  - `activeAudioID == audioID`,
  - overlay still matches `audioID`,
  - overlay phase is `.playing`,
  - audio has not been marked stopped.
- On each valid tick, update only `overlay.spectrumBins`; avoid rewriting detail/canPause/canStop unless necessary.

**Testing seam:**

Expose a narrow internal method like `refreshPlaybackSpectrumForTesting(audioID:)` or make `refreshPlaybackSpectrum(audioID:)` testable through existing `@testable import Logos`. Do not make unit tests sleep on real timers unless unavoidable.

**Verification tests:**

1. `testPlayingAudioSpectrumRefreshesOverlayBinsOnTick`
   - Start playback, set synthetic decoder/player state, call refresh method, assert overlay bins change.

2. `testPausedAudioStopsSpectrumRefresh`
   - Pause playback, attempt refresh, assert bins do not change and no new ticker remains active.

3. `testStoppedAudioRejectsStaleSpectrumTick`
   - Stop playback, call refresh for old audioID, assert overlay remains nil.

4. `testSupersededPlaybackRejectsOldSpectrumTick`
   - Start A, start B, tick A, assert B overlay is untouched.

---

### Task 6: Make the SwiftUI view render real bins cleanly

**Objective:** Remove fake motion from the analyzer bars and animate real bin changes instead.

**Files:**

- Modify: `clients/ios/Logos/Logos/ContentView.swift`

**Changes:**

- Keep `SpectrumAnalyzerView(bins:isActive:)` as a pure renderer.
- Remove or neutralize `pulse` as a height input during real playback. It can remain only as a subtle opacity/loading cue for requesting/receiving if desired.
- Add an animation tied to bin changes, for example `.animation(.linear(duration: 0.08), value: bins)`.
- Consider deriving bar opacity from `isActive`, but not bar height.

**Verification:**

- Unit tests cover state; UI test should only assert overlay remains present/control buttons still work.
- Manual visual check on Simulator/physical phone verifies bars move continuously during playback.

---

### Task 7: Remove encoded-byte pseudo-spectrum during receiving

**Objective:** Stop showing bogus “spectrum” data before PCM is available.

**Files:**

- Modify: `clients/ios/Logos/Logos/LogosClient.swift`
- Modify: `clients/ios/Logos/LogosTests/LogosModelTests.swift`

**Changes:**

- Replace `spectrumBins(fromBase64:)` use in `handleAudioChunk` with stable placeholder bins.
- Optionally rename/remove `spectrumBins(fromBase64:)` to make future regressions obvious.
- Keep `Receiving audio` state and overlay controls as-is.

**Verification:**

- Existing audio chunk tests updated to assert receiving overlay uses placeholder/floor bins rather than byte-derived bins.
- No user-facing playback regression.

---

### Task 8: Full verification

**Objective:** Prove no regression in iOS playback, request correlation, or mock UI flow.

**Commands:**

Python suite:

```bash
PYTHONPATH=/Users/ryan/Development/logos/plugins:/Users/ryan/.hermes/hermes-agent \
  /Users/ryan/.hermes/hermes-agent/venv/bin/pytest -q tests
```

iOS unit suite:

```bash
cd /Users/ryan/Development/logos/clients/ios/Logos
xcodegen generate --spec project.yml
xcodebuild -project Logos.xcodeproj \
  -scheme Logos \
  -destination 'platform=iOS Simulator,id=FD91D719-6C01-4917-A654-B81D3465595A' \
  -only-testing:LogosTests \
  test
```

iOS UI mock suite:

```bash
cd /Users/ryan/Development/logos
PYTHONPATH=/Users/ryan/Development/logos/plugins:/Users/ryan/.hermes/hermes-agent \
  /Users/ryan/.hermes/hermes-agent/venv/bin/python scripts/run_stage_f_mock_adapter.py \
  --host 127.0.0.1 \
  --port 8766
```

Then in a separate command:

```bash
cd /Users/ryan/Development/logos/clients/ios/Logos
LOGOS_MESSAGE_STORE_FILENAME="LogosUITests-spectrum-$(uuidgen).sqlite3" \
xcodebuild -project Logos.xcodeproj \
  -scheme Logos \
  -destination 'platform=iOS Simulator,id=FD91D719-6C01-4917-A654-B81D3465595A' \
  -only-testing:LogosUITests \
  test
```

Cleanup checks after UI mock:

```bash
python3 - <<'PY'
import socket
s=socket.socket()
try:
    s.bind(('127.0.0.1', 8766))
    print('PORT_8766_FREE')
except OSError as e:
    print(f'PORT_8766_BUSY: {e}')
finally:
    s.close()
PY
```

Manual visual validation:

- Trigger playback of a normal assistant response.
- Confirm bars move throughout playback, not only at the first chunk/end event.
- Pause: bars freeze/dim.
- Resume: bars continue.
- Stop: overlay disappears and stale ticks do not resurrect it.
- Project switch during playback: overlay clears and no old analyzer updates appear.

---

## Files likely to change

- Create: `clients/ios/Logos/Logos/AudioSpectrumAnalyzer.swift`
- Modify: `clients/ios/Logos/Logos/AudioPlaybackController.swift`
- Modify: `clients/ios/Logos/Logos/LogosClient.swift`
- Modify: `clients/ios/Logos/Logos/ContentView.swift`
- Modify: `clients/ios/Logos/LogosTests/LogosModelTests.swift`

Probably no backend change.

Probably no `project.yml` change because the `Logos` target includes the whole `Logos/` source directory.

---

## Risks and mitigations

### Risk: AVAudioFile cannot decode some in-memory TTS data directly

Mitigation: production decoder writes assembled `Data` to a temporary file, reads via `AVAudioFile`, then deletes the temp file. If decoding fails, playback still runs and analyzer falls back to floor bins.

### Risk: Analyzer gets out of sync with playback

Mitigation: use `AVAudioPlayer.currentTime` every tick instead of maintaining a separate clock. Pause/resume already preserve player currentTime. If that is visibly wrong, then revisit the AVAudioEngine tap architecture.

### Risk: CPU/jank on MainActor

Mitigation: `fftSize=1024`, 12 bands, ~20-30 Hz update rate. If profiling shows jank, move FFT calculation to a small serial actor and publish bins back to MainActor.

### Risk: Stale ticks resurrect old overlays

Mitigation: scope every ticker and refresh call by `audioID`, and re-check active overlay/phase/stopped state on every tick. This mirrors the request/audio stale-frame hardening pattern we just merged.

### Risk: Tests become flaky due to real timers

Mitigation: unit-test the refresh method directly; keep timer sleeps out of tests. UI test only checks integration presence/control behavior.

### Risk: “Receiving” no longer has energetic bars

Decision: the analyzer should stay visually idle until playback starts. This avoids pretending encoded network chunks are real spectrum data. The overlay may still say `Receiving audio`, but bars should not animate as if sound is playing.

---

## Ryan decisions

1. During the **receiving** phase, the analyzer remains visually idle until playback starts.
2. Analyzer tuning is **voice/TTS-focused** using roughly `80-8000 Hz` bands.
3. Start with decoded-PCM/currentTime analysis on top of the current `AVAudioPlayer` lifecycle. Treat `AVAudioEngine` migration as a second phase only if physical-device validation shows visible sync/quality problems.

---

## AVAudioPlayer currentTime analysis vs AVAudioEngine tap

### Option A: Keep AVAudioPlayer and analyze decoded PCM by currentTime

**Pros:**

- Lowest blast radius. The existing playback path, audio session setup, pause/resume/stop behavior, delegate completion, overlay lifecycle, and stale-audio guards stay mostly intact.
- Easier to test. Pure FFT logic can be tested with synthetic PCM, and client refresh logic can be tested without real audio hardware.
- Good enough for TTS. Spoken audio does not require sample-perfect DJ-visualizer sync; it needs plausible, continuous, frequency-derived motion.
- Lower implementation risk. We avoid re-opening the playback lifecycle we just hardened.
- Performance is predictable. A 1024-sample FFT at ~20-30 Hz with 12 output bands is small work for Accelerate/vDSP on iPhone hardware.

**Cons:**

- It is playhead-synced, not output-buffer-synced. If `AVAudioPlayer.currentTime` drifts from actual speaker output latency, bars may be slightly early/late.
- Requires decoding/storing PCM samples in memory. For short TTS responses this is fine; for long audio it needs bounded memory cleanup and possibly downsampled analysis buffers.
- Playback and analysis are separate systems. If playback route/latency changes, analyzer does not observe the actual final output buffer.
- It analyzes source PCM, not post-processing output. System effects/output route changes are not reflected.

**Performance profile:**

- CPU: low. Accelerate/vDSP FFT is optimized; 1024-point FFT at 20-30 Hz is modest.
- Memory: moderate but bounded by decoded audio duration. Mono Float PCM is about `sampleRate * 4 bytes * seconds`; at 24 kHz, one minute is about 5.8 MB before dictionary overhead. Typical TTS responses are much shorter.
- UI load: low if ticks only publish 12 `Double` bins and stop when not playing.

### Option B: Move playback to AVAudioEngine + AVAudioPlayerNode + installTap

**Pros:**

- Most correct live analyzer architecture. The tap receives audio buffers as the engine renders them.
- Better sync with actual playback timing.
- No need to calculate spectrum from `currentTime`; incoming PCM buffers are the analysis source.
- Scales better for future advanced audio features: effects, mixing, streaming PCM, route-specific processing, waveform capture.

**Cons:**

- Higher blast radius. We would replace `AVAudioPlayer` with engine/player-node scheduling and reimplement completion, pause/resume, stop, lifecycle backgrounding, and cleanup semantics.
- More edge cases. `AVAudioEngine` graph state, taps, route changes, interruptions, and node scheduling failures are all new failure modes.
- Harder tests. Pure DSP remains testable, but engine scheduling/tap behavior is more integration-heavy and less deterministic in unit tests.
- More risk to recently-fixed playback controls and stale-frame suppression.

**Performance profile:**

- CPU: still fine for this use case, but somewhat more moving parts. The analyzer itself costs about the same FFT work; the engine graph/tap callback adds overhead and real-time-thread discipline.
- Memory: can be lower if analyzing streaming buffers directly instead of storing decoded PCM for the whole clip.
- Latency/sync: better than currentTime analysis because the data comes from render buffers.

### Recommendation

Use Option A first. It is materially simpler, fast enough, and fits Logos’ TTS use case. Option B is justified only if we observe unacceptable sync drift, need true streaming PCM visualization before the full clip is available, or decide to build richer audio features on top of an engine graph.

---

## Acceptance criteria

- Existing symptom is gone: no “initial spike then stops” during actual playback.
- Bars update continuously during `.playing` and stop/freeze appropriately during `.paused`, `.finished`, `.failed`, stopped, project switch, and disconnect.
- Spectrum bins are frequency-derived from decoded PCM, not encoded bytes, not `averagePower`, not fake sine modulation.
- Low-frequency and high-frequency synthetic test signals produce different dominant bar regions.
- No stale audio ID can update or resurrect the overlay.
- Full Python suite, iOS unit suite, and iOS UI mock suite pass.
