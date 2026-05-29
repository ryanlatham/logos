import Foundation

/// One recorded client-side error, tagged with where it originated (WS1 P7). Backs the error
/// history that replaces the single, silently-overwritten `lastError`.
struct LoggedError: Identifiable, Equatable {
    enum Source: String, Equatable, CaseIterable {
        case connection
        case adapter
        case audio
        case decode
        case action
        case unknown

        /// Short human label for a diagnostics list.
        var label: String {
            switch self {
            case .connection: return "Connection"
            case .adapter: return "Adapter"
            case .audio: return "Audio"
            case .decode: return "Decode"
            case .action: return "Action"
            case .unknown: return "Error"
            }
        }
    }

    let id: UUID
    let date: Date
    let message: String
    let source: Source

    init(id: UUID = UUID(), date: Date = Date(), message: String, source: Source) {
        self.id = id
        self.date = date
        self.message = message
        self.source = source
    }
}

/// A bounded, most-recent-first history of client errors with consecutive-duplicate
/// collapsing. A pure value type so the retention policy is unit-testable away from the UI;
/// `LogosClient` owns one as `@Published` state and exposes `lastError` as a shim over it.
struct ErrorLogBuffer: Equatable {
    private(set) var entries: [LoggedError] = []
    let capacity: Int

    init(capacity: Int = 50) {
        self.capacity = max(1, capacity)
    }

    var latest: LoggedError? { entries.first }
    var isEmpty: Bool { entries.isEmpty }

    /// Record an error at the front. A consecutive identical (message + source) error refreshes
    /// the existing head entry's timestamp instead of spamming duplicates into the history.
    @discardableResult
    mutating func record(
        _ message: String,
        source: LoggedError.Source,
        id: UUID = UUID(),
        date: Date = Date()
    ) -> Bool {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return false }
        if let head = entries.first, head.message == trimmed, head.source == source {
            entries[0] = LoggedError(id: head.id, date: date, message: trimmed, source: source)
            return false
        }
        entries.insert(LoggedError(id: id, date: date, message: trimmed, source: source), at: 0)
        if entries.count > capacity {
            entries.removeLast(entries.count - capacity)
        }
        return true
    }

    @discardableResult
    mutating func dismiss(id: UUID) -> Bool {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return false }
        entries.remove(at: index)
        return true
    }

    mutating func clear() {
        entries.removeAll()
    }
}
