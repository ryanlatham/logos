import Foundation

enum LogosConnectionState: String {
    case disconnected
    case connecting
    case connected
    case error
}

enum LogosRunStatus: String {
    case idle
    case running
    case queued
    case awaitingApproval = "awaiting_approval"
    case awaitingClarification = "awaiting_clarification"
    case cancelling
    case error
}

struct LogosConnectionLifecycle: Equatable {
    private(set) var activeConnectionID = UUID()

    mutating func startConnection() -> UUID {
        activeConnectionID = UUID()
        return activeConnectionID
    }

    mutating func invalidate() {
        activeConnectionID = UUID()
    }

    func accepts(_ connectionID: UUID) -> Bool {
        connectionID == activeConnectionID
    }
}
enum LogosAutoConnectPolicy {
    static func shouldAttempt(
        autoConnect: Bool,
        hasCompletedFirstConnection _: Bool,
        connectionState: LogosConnectionState
    ) -> Bool {
        guard autoConnect else { return false }
        switch connectionState {
        case .disconnected, .error:
            return true
        case .connecting, .connected:
            return false
        }
    }
}

enum LogosReconnectBackoff {
    private static let delays: [TimeInterval] = [1, 2, 4, 8, 15, 30, 60]

    static func delay(afterFailedAttempt attempt: Int) -> TimeInterval {
        let index = min(max(attempt, 1) - 1, delays.count - 1)
        return delays[index]
    }
}

enum ThreadFocusReason: String {
    case finishedNotification = "finished_notification"
}

struct ThreadFocusRequest: Equatable, Identifiable {
    let id: String
    let projectKey: String
    let targetMessageID: String
    let reason: ThreadFocusReason
    let createdAt: TimeInterval
}
