import Foundation

struct ProgressActivityEvent: Identifiable, Hashable {
    let id: String
    let kind: String
    let text: String
    let timestamp: TimeInterval
    let count: Int
}

enum ProgressActivityFinalStatus: String, Hashable {
    case complete
    case failed
    case stopped
    case interrupted
}

enum ProgressRetryRequest: Hashable {
    case text(String)
    case speech(text: String)
}

struct ProgressActivityState: Identifiable, Hashable {
    var id: String { requestID }
    let requestID: String
    let projectKey: String
    let sessionID: String?
    var events: [ProgressActivityEvent]
    var isExpanded: Bool
    var timedOut: Bool
    var isComplete: Bool
    var completedFinalMessageID: String?
    var updateCount: Int
    var lastUpdateAt: TimeInterval
    var startedAt: TimeInterval = Date().timeIntervalSince1970
    var completedAt: TimeInterval? = nil
    var finalStatus: ProgressActivityFinalStatus? = nil
    var failureMessage: String? = nil
    var retryRequest: ProgressRetryRequest? = nil
    var adapterUpdateCount: Int = 0
}

struct ConnectionRetryEvent: Identifiable, Hashable {
    let id: String
    let text: String
    let timestamp: TimeInterval
}

struct ConnectionRetryState: Identifiable, Hashable {
    var id: String { "connection-retry" }
    var attemptCount: Int
    var latestError: String
    var nextRetryAt: TimeInterval?
    var events: [ConnectionRetryEvent]
}
