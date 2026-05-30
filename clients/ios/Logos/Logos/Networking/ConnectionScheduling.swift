import Foundation

/// Schedules a single-shot fire after a delay, replacing any pending fire. Serves
/// both the stale-progress notice (surfaced when Hermes goes quiet) and the
/// fast-ack clear (run once a transient ack's TTL elapses). Production sleeps in
/// real wall-clock time; tests inject a manual scheduler so the fire can be
/// triggered synchronously instead of racing a real timer (flaky on a loaded CI
/// runner).
@MainActor
protocol DelayedFireScheduling: AnyObject {
    /// Schedule `fire` to run after `interval` seconds, replacing any pending fire.
    func schedule(after interval: TimeInterval, fire: @escaping @MainActor () -> Void)
    /// Cancel any pending fire.
    func cancel()
}

@MainActor
final class TaskDelayedFireScheduler: DelayedFireScheduling {
    private var task: Task<Void, Never>?

    func schedule(after interval: TimeInterval, fire: @escaping @MainActor () -> Void) {
        task?.cancel()
        task = Task { @MainActor in
            do {
                try await Task.sleep(for: .seconds(max(0.001, interval)))
            } catch {
                return
            }
            fire()
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
    }
}
