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

/// A coarse, user-legible phase of an in-flight run (WS1 P7 milestone progress). Derived
/// primarily from the adapter's structured `progress_kind`, falling back to text cues so it
/// still works for legacy frames that only carry free-text status.
enum ProgressMilestone: String, Hashable, CaseIterable {
    case queued
    case thinking
    case toolRunning
    case compacting
    case retrying
    case finalizing

    var label: String {
        switch self {
        case .queued: return "Queued"
        case .thinking: return "Thinking"
        case .toolRunning: return "Running tool"
        case .compacting: return "Compacting context"
        case .retrying: return "Retrying"
        case .finalizing: return "Finalizing"
        }
    }

    var systemImage: String {
        switch self {
        case .queued: return "clock"
        case .thinking: return "brain"
        case .toolRunning: return "wrench.and.screwdriver"
        case .compacting: return "arrow.down.right.and.arrow.up.left"
        case .retrying: return "arrow.clockwise"
        case .finalizing: return "checkmark.seal"
        }
    }

    /// Map a progress event to a milestone: structured `kind` first, then text heuristics.
    static func from(kind: String?, text: String) -> ProgressMilestone {
        switch (kind ?? "").trimmingCharacters(in: .whitespaces).lowercased() {
        case "queued": return .queued
        case "thinking", "reasoning": return .thinking
        case "tool", "tool_running", "tool_progress", "tool_use": return .toolRunning
        case "compacting", "compaction", "compression", "preflight_compression": return .compacting
        case "retrying", "retry": return .retrying
        case "finalizing", "final", "finalize": return .finalizing
        default: break
        }
        let lower = text.lowercased()
        if lower.contains("compact") || lower.contains("compress") { return .compacting }
        if lower.contains("retry") || lower.contains("retrying") { return .retrying }
        if lower.contains("finaliz") { return .finalizing }
        if lower.contains("queued") { return .queued }
        if lower.contains("tool") { return .toolRunning }
        return .thinking
    }
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

    /// The current run phase, derived from the most recent progress event.
    var currentMilestone: ProgressMilestone {
        ProgressMilestone.from(kind: events.last?.kind, text: events.last?.text ?? "")
    }
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
