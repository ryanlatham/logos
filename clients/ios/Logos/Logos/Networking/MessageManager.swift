import Combine
import Foundation

/// Client-side dependencies the message-DATA/LIST subsystem needs from its owner (WS1 P5, mirroring
/// `AudioCoordinatorHost` + `ProgressActivityManagerHost` + `InteractionControllerHost` +
/// `NotificationRouterHost`). The `MessageManager` reaches back through this narrow seam instead of
/// holding the whole `LogosClient`, so the message-list domain stays decoupled from the connection
/// socket and the notification-route anchors. The host is held `weak`; every member is a no-op-safe
/// call the manager routes its non-list work through.
@MainActor
protocol MessageManagerHost: AnyObject {
    /// The active project key the visible thread + outbound `messages_get` frames are scoped to
    /// (mirrors `LogosClient.activeProjectKey`).
    var messageActiveProjectKey: String { get }
    /// The device id stamped onto outbound `messages_get` frames (mirrors `LogosClient.settings.deviceID`).
    var messageDeviceID: String { get }
    /// Send a message-subsystem frame over the socket (mirrors `LogosClient.sendFrame`'s default-auth path).
    @discardableResult func sendMessageFrame(_ frame: [String: Any], onCompletion: ((Result<Void, Error>) -> Void)?) -> Bool
    /// The notification-route anchors merged into the visible thread when re-deriving `messages`
    /// (mirrors the former inline `notificationRouter.anchoredMessages(forProjectKey:)` read).
    func messageAnchoredMessages(forProjectKey projectKey: String) -> [LogosMessage]
}

/// Owns the message-DATA/LIST layer lifted out of `LogosClient` (WS1 P5): the published, de-duped
/// visible thread (`messages`), the injected `SQLiteMessageStore` persistence, the
/// `PendingMessageBuffer` (optimistic user sends awaiting persistence), and the local stale-silence
/// notice list. `LogosClient` keeps a reference, re-exposes `messages` via computed forwarding, and
/// keeps owning the `messages_batch`/`state_update` frame routers (the coordination hub): those parse
/// each frame, orchestrate the progress/interaction/notification managers + run-status, and then call
/// the high-level "apply" ops here (`persist`/`applyPersistedMessage`/`reconcilePending`/…) for the
/// list mutation + store write — preserving the exact ordering/semantics. All client-side dependencies
/// are routed through `host` (held `weak`).
@MainActor
final class MessageManager: ObservableObject {
    @Published private(set) var messages: [LogosMessage] = []

    weak var host: MessageManagerHost?

    /// The persistence injected through `LogosClient.init(store:)` (the test seam stays via the
    /// client's initializer, which threads its `store:` parameter straight into this manager).
    let store: SQLiteMessageStore

    private var pendingMessages = PendingMessageBuffer()
    private var localNoticeMessages: [LogosMessage] = []
    private var localNoticeSequence = 0

    private var activeProjectKey: String { host?.messageActiveProjectKey ?? "default" }

    init(store: SQLiteMessageStore) {
        self.store = store
    }

    /// Seed the visible thread from the store for the given project (mirrors the client's former
    /// `messages = visibleMessages(from: store.loadMessages(...))` in `LogosClient.init`). Called once
    /// the host is wired so `activeProjectKey` resolves.
    func loadInitialMessages(projectKey: String) {
        messages = visibleMessages(from: store.loadMessages(projectKey: projectKey))
    }

    // MARK: - Message backfill request

    /// Request a message backfill window over the socket (mirrors the former
    /// `LogosClient.requestMessages(afterServerSeq:)`).
    func requestMessages(afterServerSeq: Int) {
        host?.sendMessageFrame([
            "type": "messages_get",
            "request_id": UUID().uuidString,
            "device_id": host?.messageDeviceID ?? "",
            "project_key": activeProjectKey,
            "payload": [
                "after_server_seq": afterServerSeq,
                "limit": 100
            ]
        ], onCompletion: nil)
    }

    // MARK: - High-level apply operations (called by the client's frame routers)

    /// Persist a decoded message without re-deriving the visible thread (mirrors a bare `store.upsert`
    /// inside the `messages_batch` loop, where `refreshMessages` is batched to the end).
    func persist(_ message: LogosMessage) {
        store.upsert(message)
    }

    /// Persist a decoded message and immediately re-derive the visible thread (mirrors the
    /// `store.upsert` + `refreshMessages` pair the progress-routed `state_update` branch uses, and the
    /// `ProgressActivityManagerHost.persistProgressMessage` delegation).
    func persistAndRefresh(_ message: LogosMessage) {
        store.upsert(message)
        refreshMessages()
    }

    /// Persist a decoded message, reconcile it against the pending buffer, then re-derive the visible
    /// thread (mirrors the `store.upsert` + `pendingMessages.reconcile(with:)` + `refreshMessages`
    /// sequence the normal `state_update` message branch uses).
    func applyPersistedMessage(_ message: LogosMessage) {
        store.upsert(message)
        pendingMessages.reconcile(with: message)
        refreshMessages()
    }

    /// Drop any pending optimistic sends now confirmed by a freshly persisted batch (mirrors the
    /// `messages_batch` `pendingMessages.reconcile(with: persistedMessages)`).
    func reconcilePending(with persisted: [LogosMessage]) {
        pendingMessages.reconcile(with: persisted)
    }

    /// Add an optimistic pending user message and re-derive the visible thread (mirrors the former
    /// `LogosClient.addPendingMessage`).
    func addPendingMessage(_ message: LogosMessage) {
        pendingMessages.add(message, persisted: store.loadMessages(projectKey: message.projectKey))
        refreshMessages()
    }

    /// Remove a pending optimistic send without re-deriving the visible thread (mirrors the bare
    /// `pendingMessages.remove(messageID:)` the client's send-failure / draft-restore paths use before
    /// their own — sometimes conditional, sometimes batched — `refreshMessages`).
    func removePendingMessage(messageID: String) {
        pendingMessages.remove(messageID: messageID)
    }

    /// Append a local stale-silence notice for an in-flight run and re-derive the visible thread
    /// (mirrors the former `LogosClient.handleStaleTimeout` tail: bump the sequence, build the notice,
    /// `store.upsert`, append to `localNoticeMessages`, `refreshMessages`).
    func appendLocalStaleNotice(projectKey: String, requestID: String, content: String, now: TimeInterval) {
        localNoticeSequence += 1
        let notice = LogosMessage.localNotice(
            projectKey: projectKey,
            requestID: requestID,
            sequence: localNoticeSequence,
            content: content,
            timestamp: now
        )
        store.upsert(notice)
        localNoticeMessages.append(notice)
        refreshMessages()
    }

    // MARK: - Store lookups (delegated from the notification router's host)

    /// The newest persisted `server_seq` for a project (mirrors `store.latestServerSeq(projectKey:)`,
    /// defaulting to the active project — the former `LogosClient.latestServerSeq`).
    func latestServerSeq(projectKey: String? = nil) -> Int {
        store.latestServerSeq(projectKey: projectKey ?? activeProjectKey)
    }

    /// Look up a specific stored message (mirrors `store.message(projectKey:sessionID:messageID:)`).
    func storedMessage(projectKey: String, sessionID: String?, messageID: String) -> LogosMessage? {
        store.message(projectKey: projectKey, sessionID: sessionID, messageID: messageID)
    }

    /// The latest final message at/after a `server_seq` (mirrors `store.latestFinalMessage(...)`).
    func latestFinalMessage(projectKey: String, sessionID: String, atOrAfterServerSeq serverSeq: Int) -> LogosMessage? {
        store.latestFinalMessage(projectKey: projectKey, sessionID: sessionID, atOrAfterServerSeq: serverSeq)
    }

    // MARK: - Pure message classifiers / ordering

    /// Whether a message is an explicit, finalized terminal assistant message (mirrors the former
    /// `LogosClient.isExplicitTerminalAssistantMessage`; backs `ProgressActivityManagerHost`'s
    /// `isProgressTerminalAssistantMessage`).
    func isExplicitTerminalAssistantMessage(_ message: LogosMessage) -> Bool {
        guard message.role != "user", message.isProgressUpdate == false else { return false }
        return message.hasFinalizedMetadata && message.isFinal
    }

    // MARK: - Visible-thread derivation

    /// Re-derive the published `messages` from the store, the notification-route anchors (through the
    /// host), the reconciled pending buffer, and the local notices — preserving the de-dup-by-id and
    /// `messageDisplayPrecedes` ordering (mirrors the former `LogosClient.refreshMessages`).
    func refreshMessages() {
        let activeProjectKey = self.activeProjectKey
        var visibleByID: [String: LogosMessage] = [:]
        for message in visibleMessages(from: store.loadMessages(projectKey: activeProjectKey)) {
            visibleByID[message.id] = message
        }
        for message in host?.messageAnchoredMessages(forProjectKey: activeProjectKey) ?? [] {
            visibleByID[message.id] = message
        }
        let persisted = visibleByID.values.sorted(by: messageDisplayPrecedes)
        pendingMessages.reconcile(with: persisted)
        let persistedIDs = Set(persisted.map(\.id))
        let localNotices = localNoticeMessages.filter { $0.projectKey == activeProjectKey }
            .filter { persistedIDs.contains($0.id) == false }
        messages = (pendingMessages.merged(with: persisted, projectKey: activeProjectKey) + localNotices).sorted(by: messageDisplayPrecedes)
    }

    private func visibleMessages(from persisted: [LogosMessage]) -> [LogosMessage] {
        persisted.filter { $0.isProgressUpdate == false }
    }

    private func messageDisplayPrecedes(_ lhs: LogosMessage, _ rhs: LogosMessage) -> Bool {
        if lhs.serverSeq > 0, rhs.serverSeq > 0, lhs.serverSeq != rhs.serverSeq {
            return lhs.serverSeq < rhs.serverSeq
        }
        if lhs.timestamp != rhs.timestamp {
            return lhs.timestamp < rhs.timestamp
        }
        return lhs.id < rhs.id
    }
}
