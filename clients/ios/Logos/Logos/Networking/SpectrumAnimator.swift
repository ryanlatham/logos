import Foundation

/// Owns the periodic "tick" loop that refreshes the audio spectrum visualization while a track
/// plays (WS1 P5 — a focused collaborator lifted out of LogosClient). It deliberately holds only
/// the timer/task lifecycle and the active audio id; the actual per-tick refresh (which reads the
/// playback engine and updates the overlay) stays with the owner via the `tick` closure, so this
/// object has no back-reference to the client and no audio-domain state of its own.
@MainActor
final class SpectrumAnimator {
    /// Refresh cadence. 50ms ≈ 20fps — smooth enough for the bars without churning the main actor.
    static let interval: TimeInterval = 0.05

    private var task: Task<Void, Never>?
    private(set) var audioID: String?

    /// Whether a loop is currently scheduled (for tests/diagnostics).
    var isAnimating: Bool { task != nil }

    /// Start (replacing any current loop) ticking `tick(audioID)` every `interval` until stopped.
    func start(audioID: String, tick: @escaping @MainActor (String) -> Void) {
        stop()
        self.audioID = audioID
        task = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(SpectrumAnimator.interval))
                } catch {
                    return
                }
                guard self != nil else { return }
                tick(audioID)
            }
        }
    }

    /// Stop the loop. When `audioID` is given, only stops if it matches the active loop (so a
    /// stale stop for a superseded track is a no-op).
    func stop(audioID: String? = nil) {
        if let audioID, self.audioID != audioID { return }
        task?.cancel()
        task = nil
        self.audioID = nil
    }
}
