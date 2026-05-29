import Foundation

/// Schedules the single-shot fire that surfaces a stale-progress notice when
/// Hermes goes quiet. Production sleeps in real wall-clock time; tests inject a
/// manual scheduler so the timeout can be fired synchronously instead of racing
/// a real timer (which is flaky on a loaded CI runner).
@MainActor
protocol StaleTimeoutScheduling: AnyObject {
    /// Schedule `fire` to run after `interval` seconds, replacing any pending fire.
    func schedule(after interval: TimeInterval, fire: @escaping @MainActor () -> Void)
    /// Cancel any pending fire.
    func cancel()
}

@MainActor
final class TaskStaleTimeoutScheduler: StaleTimeoutScheduling {
    private var task: Task<Void, Never>?

    func schedule(after interval: TimeInterval, fire: @escaping @MainActor () -> Void) {
        task?.cancel()
        task = Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds: UInt64(max(0.001, interval) * 1_000_000_000))
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

/// Schedules the single-shot fire that clears a transient fast-ack once its TTL
/// elapses. Production sleeps in real wall-clock time; tests inject a manual
/// scheduler so the clear can be fired synchronously instead of racing a real
/// timer (which is flaky on a loaded CI runner).
@MainActor
protocol AckClearScheduling: AnyObject {
    /// Schedule `fire` to run after `interval` seconds, replacing any pending fire.
    func schedule(after interval: TimeInterval, fire: @escaping @MainActor () -> Void)
    /// Cancel any pending fire.
    func cancel()
}

@MainActor
final class TaskAckClearScheduler: AckClearScheduling {
    private var task: Task<Void, Never>?

    func schedule(after interval: TimeInterval, fire: @escaping @MainActor () -> Void) {
        task?.cancel()
        task = Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds: UInt64(max(0.001, interval) * 1_000_000_000))
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
