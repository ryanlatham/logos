import Foundation

/// Single-shot watchdog that fires if an audio stream never starts playing within a window
/// (WS1 P5 — a focused collaborator lifted out of LogosClient, sibling to SpectrumAnimator). It
/// owns only the timer/task lifecycle and the active audio id; the owner supplies the `onTimeout`
/// action (which inspects playback state and fails the stream), so this type has no back-reference
/// to the client and no audio-domain state. The interval is injectable for deterministic tests.
@MainActor
final class PlaybackStreamTimeout {
    private var task: Task<Void, Never>?
    private(set) var audioID: String?
    private let interval: TimeInterval

    init(interval: TimeInterval = 60) {
        self.interval = max(0.001, interval)
    }

    var isScheduled: Bool { task != nil }

    /// Schedule (replacing any pending watchdog) `onTimeout(audioID)` to run after `interval`,
    /// unless cancelled or superseded first.
    func schedule(audioID: String, onTimeout: @escaping @MainActor (String) -> Void) {
        task?.cancel()
        self.audioID = audioID
        let interval = self.interval
        task = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            } catch {
                return
            }
            // Only fire if this is still the active watchdog (not cancelled / superseded).
            guard let self, self.audioID == audioID else { return }
            onTimeout(audioID)
        }
    }

    /// Cancel the watchdog. With `audioID`, only cancels if it matches the active one.
    func cancel(audioID: String? = nil) {
        guard audioID == nil || self.audioID == audioID else { return }
        task?.cancel()
        task = nil
        self.audioID = nil
    }
}
