import Foundation

/// Client-side dependencies the progress-activity subsystem needs from its owner (WS1 P5,
/// mirroring `AudioCoordinatorHost`). The `ProgressActivityManager` reaches back through this
/// narrow seam instead of holding the whole `LogosClient`, so the progress/run-lifecycle domain
/// stays decoupled from the connection socket, message store, and run-status bookkeeping. The host
/// is held `weak`; every member is a no-op-safe call the manager routes non-progress work through.
@MainActor
protocol ProgressActivityManagerHost: AnyObject {
    // MARK: Run-scope context the progress predicates read
    /// The active project key progress frames are scoped to (mirrors `LogosClient.activeProjectKey`).
    var progressActiveProjectKey: String { get }
    /// The coarse run lifecycle the progress methods drive (mirrors `LogosClient.runStatus`).
    var progressRunStatus: LogosRunStatus { get set }
    /// The single in-flight outbound request awaiting a live response, if any.
    var progressPendingOutboundResponseRequestID: String? { get set }
    /// Every outbound request still awaiting reconciliation.
    var progressOutstandingOutboundResponseRequestIDs: Set<String> { get }

    // MARK: Connection state the retry/retry-send paths read
    /// Whether the socket is live enough to retry a failed run (mirrors `connectionState == .connected`).
    var progressIsConnected: Bool { get }
    /// Whether the underlying task + open socket exist (for `retryProgressActivity` gating).
    var progressHasOpenSocket: Bool { get }
    /// Whether auto-reconnect is permitted (mirrors `LogosClient.canAutoRetryConnection`).
    var progressCanAutoRetryConnection: Bool { get }

    // MARK: Outbound-request bookkeeping owned by the client
    /// Drop a request from the outstanding set, clearing `pendingOutboundResponseRequestID` to match.
    func clearProgressOutstandingOutboundRequestID(_ requestID: String?)
    /// Drop every outstanding outbound request (mirrors `outstandingOutboundResponseRequestIDs.removeAll()`).
    func clearAllProgressOutstandingOutboundRequestIDs()

    // MARK: Stale-timeout scheduler owned by the client
    /// Arm the stale-silence watchdog for a live run.
    func scheduleProgressStaleTimeout(requestID: String, projectKey: String)
    /// Cancel the stale-silence watchdog.
    func suspendProgressStaleTimeout()

    // MARK: Message-store / classification helpers owned by the client
    /// Persist a (non-transient) progress message and refresh the visible thread.
    func persistProgressMessage(_ message: LogosMessage)
    /// Classify a message as an explicit terminal assistant message (`hasFinalizedMetadata && isFinal`).
    func isProgressTerminalAssistantMessage(_ message: LogosMessage) -> Bool

    // MARK: Transient/interaction/audio state cleared on run completion
    /// Clear the transient fast-ack banner.
    func clearAckForProgress()
    /// Clear approval/clarify interaction cards when a run ends via cancel/interrupt.
    func clearInteractionStateForProgress()
    /// Tear down any in-flight audio when a run finishes (mirrors the client's project-switch reset).
    func clearAudioPlaybackForProgress()
    /// Mark that only request-scoped live responses should be accepted after a cancel/interrupt.
    func setRequiresScopedLiveResponse(_ value: Bool)
    /// Forget the pending cancel request id (a finished run supersedes it).
    func clearPendingCancelRequestID()

    // MARK: Outbound send paths used to retry a failed run
    /// Resend a text run (mirrors `LogosClient.sendText`).
    @discardableResult func sendProgressText(_ text: String) -> Bool
    /// Resend a final speech run (mirrors `LogosClient.sendSpeech` for the retry case).
    @discardableResult func sendProgressSpeech(text: String) -> Bool

    // MARK: Connection-retry side effects owned by the client
    /// Kick a fresh automatic reconnect attempt (mirrors `connect(isAutomaticRetry: true)`).
    func reconnectForRetry()

    // MARK: Frame-parsing helpers shared with the client
    /// Extract a non-empty `project_key` from an inbound frame root.
    func progressFrameProjectKey(_ root: [String: Any]) -> String?
    /// Whether an inbound frame targets the active project (nil project_key counts as active).
    func progressIsActiveProjectFrame(_ root: [String: Any]) -> Bool
    /// Coerce a wire value to `Bool` (mirrors `LogosClient.boolValue`).
    func progressBoolValue(_ value: Any?) -> Bool?
    /// Coerce a wire value to `Int` (mirrors `LogosClient.integerValue`).
    func progressIntegerValue(_ value: Any?) -> Int?
}

/// Owns the progress-activity + connection-retry subsystems lifted out of `LogosClient` (WS1 P5):
/// the published progress overlay and reconnect banner, the suppressed/active run-id bookkeeping,
/// and the run-lifecycle decisions (route/clear/complete/finish) that operate on progress state.
/// `LogosClient` keeps a reference, re-exposes `progressActivity`/`connectionRetryState` via computed
/// forwarding, and routes inbound frames through the manager so views/tests are unchanged. All
/// client-side dependencies are routed through `host` (held `weak`).
@MainActor
final class ProgressActivityManager: ObservableObject {
    @Published private(set) var progressActivity: ProgressActivityState?
    @Published private(set) var connectionRetryState: ConnectionRetryState?

    weak var host: ProgressActivityManagerHost?

    private var suppressedRunRequestIDs = Set<String>()
    private var connectionRetryAttemptCount = 0
    private var connectionRetryEventSequence = 0
    private var reconnectTask: Task<Void, Never>?

    static let staleSilenceNoticeText = "Logos has not heard from Hermes in a while. The run may still be working; waiting for the next adapter update."
    private static let maxConnectionRetryEvents = 8

    // MARK: - Run-error reset

    func resetRunErrorIfNoActiveProgress() {
        guard host?.progressRunStatus == .error else { return }
        guard progressActivity?.isComplete == false else {
            host?.progressRunStatus = .idle
            return
        }
    }

    // MARK: - Connection retry

    func clearConnectionRetryState() {
        reconnectTask?.cancel()
        reconnectTask = nil
        connectionRetryAttemptCount = 0
        connectionRetryState = nil
    }

    var canAutoRetryConnection: Bool {
        host?.progressCanAutoRetryConnection ?? false
    }

    func noteConnectionRetryFailure(_ message: String) {
        guard canAutoRetryConnection else { return }
        connectionRetryAttemptCount += 1
        connectionRetryEventSequence += 1
        let attempt = connectionRetryAttemptCount
        let now = Date().timeIntervalSince1970
        let delay = LogosReconnectBackoff.delay(afterFailedAttempt: attempt)
        let nextRetryAt = now + delay
        let event = ConnectionRetryEvent(
            id: "connection-retry-\(connectionRetryEventSequence)",
            text: "Connection attempt \(attempt) failed: \(message)",
            timestamp: now
        )
        var events = (connectionRetryState?.events ?? []) + [event]
        if events.count > Self.maxConnectionRetryEvents {
            events.removeFirst(events.count - Self.maxConnectionRetryEvents)
        }
        connectionRetryState = ConnectionRetryState(
            attemptCount: attempt,
            latestError: message,
            nextRetryAt: nextRetryAt,
            events: events
        )
        scheduleConnectionRetry(after: delay)
    }

    private func scheduleConnectionRetry(after delay: TimeInterval) {
        reconnectTask?.cancel()
        reconnectTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: UInt64(max(0, delay) * 1_000_000_000))
            } catch {
                return
            }
            guard let self else { return }
            guard self.connectionRetryState != nil, self.canAutoRetryConnection else { return }
            self.host?.reconnectForRetry()
        }
    }

    // MARK: - Progress lifecycle

    func startProgressActivity(requestID: String, projectKey: String, sessionID: String? = nil, retryRequest: ProgressRetryRequest? = nil) {
        let now = Date().timeIntervalSince1970
        progressActivity = ProgressActivityState(
            requestID: requestID,
            projectKey: projectKey,
            sessionID: sessionID,
            events: [],
            isExpanded: false,
            timedOut: false,
            isComplete: false,
            completedFinalMessageID: nil,
            updateCount: 0,
            lastUpdateAt: now,
            startedAt: now,
            completedAt: nil,
            finalStatus: nil,
            failureMessage: nil,
            retryRequest: retryRequest,
            adapterUpdateCount: 0
        )
    }

    @discardableResult
    func retryProgressActivity() -> Bool {
        guard host?.progressIsConnected == true, host?.progressHasOpenSocket == true else { return false }
        guard host?.progressRunStatus == .idle else { return false }
        guard let activity = progressActivity,
              activity.finalStatus == .failed || activity.finalStatus == .interrupted,
              let retryRequest = activity.retryRequest
        else { return false }
        switch retryRequest {
        case .text(let text):
            return host?.sendProgressText(text) ?? false
        case .speech(let text):
            return host?.sendProgressSpeech(text: text) ?? false
        }
    }

    func toggleProgressActivityExpanded() {
        guard var activity = progressActivity else { return }
        activity.isExpanded.toggle()
        progressActivity = activity
    }

    func appendProgressEvent(requestID: String, projectKey: String, sessionID: String?, kind: String, text: String, eventID: String? = nil) {
        guard projectKey == host?.progressActiveProjectKey else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return }
        guard isSuppressedRunRequestID(requestID) == false else { return }
        if host?.progressOutstandingOutboundResponseRequestIDs.contains(requestID) == true {
            host?.clearProgressOutstandingOutboundRequestID(requestID)
        } else if let pendingOutboundResponseRequestID = host?.progressPendingOutboundResponseRequestID {
            guard requestID == pendingOutboundResponseRequestID else { return }
            host?.clearProgressOutstandingOutboundRequestID(requestID)
        } else if let activity = progressActivity {
            guard activity.requestID == requestID else { return }
        }
        let now = Date().timeIntervalSince1970
        var activity = progressActivity ?? ProgressActivityState(
            requestID: requestID,
            projectKey: projectKey,
            sessionID: sessionID,
            events: [],
            isExpanded: false,
            timedOut: false,
            isComplete: false,
            completedFinalMessageID: nil,
            updateCount: 0,
            lastUpdateAt: now,
            startedAt: now,
            completedAt: nil,
            finalStatus: nil,
            failureMessage: nil,
            retryRequest: nil,
            adapterUpdateCount: 0
        )
        if activity.requestID != requestID || activity.projectKey != projectKey {
            activity = ProgressActivityState(
                requestID: requestID,
                projectKey: projectKey,
                sessionID: sessionID,
                events: [],
                isExpanded: false,
                timedOut: false,
                isComplete: false,
                completedFinalMessageID: nil,
                updateCount: 0,
                lastUpdateAt: now,
                startedAt: now,
                completedAt: nil,
                finalStatus: nil,
                failureMessage: nil,
                retryRequest: nil,
                adapterUpdateCount: 0
            )
        }
        activity.updateCount += 1
        activity.adapterUpdateCount += 1
        let stableEventID = eventID.flatMap { $0.isEmpty ? nil : $0 }
            ?? "\(requestID)-\(activity.events.count)-\(Int(now * 1000))"
        if let index = activity.events.firstIndex(where: { $0.id == stableEventID }) {
            let existing = activity.events[index]
            activity.events[index] = ProgressActivityEvent(
                id: existing.id,
                kind: kind,
                text: trimmed,
                timestamp: now,
                count: existing.kind == kind && existing.text == trimmed ? existing.count + 1 : existing.count
            )
        } else if let duplicateIndex = activity.events.lastIndex(where: { $0.kind == kind && $0.text == trimmed }) {
            let existing = activity.events[duplicateIndex]
            activity.events[duplicateIndex] = ProgressActivityEvent(
                id: existing.id,
                kind: existing.kind,
                text: existing.text,
                timestamp: now,
                count: existing.count + 1
            )
        } else {
            activity.events.append(ProgressActivityEvent(
                id: stableEventID,
                kind: kind,
                text: trimmed,
                timestamp: now,
                count: 1
            ))
        }
        activity.lastUpdateAt = now
        if activity.isComplete == false {
            activity.timedOut = false
        }
        progressActivity = activity
        guard activity.isComplete == false else { return }
        if host?.progressRunStatus != .cancelling {
            host?.progressRunStatus = .running
        }
        if host?.progressRunStatus == .cancelling {
            host?.suspendProgressStaleTimeout()
        } else {
            host?.scheduleProgressStaleTimeout(requestID: requestID, projectKey: projectKey)
        }
    }

    /// Append the stale-silence timeout event onto the active progress card, if it still matches.
    /// (The client owns scheduling + the local-notice message; this only mutates progress state.)
    func appendStaleTimeoutEvent(requestID: String, projectKey: String, now: TimeInterval) {
        guard var activity = progressActivity, activity.requestID == requestID, activity.projectKey == projectKey else { return }
        activity.timedOut = true
        activity.updateCount += 1
        activity.events.append(ProgressActivityEvent(
            id: "\(requestID)-timeout-\(Int(now * 1000))",
            kind: "timeout",
            text: Self.staleSilenceNoticeText,
            timestamp: now,
            count: 1
        ))
        progressActivity = activity
    }

    func clearProgressActivity(requestID: String? = nil) {
        if let requestID, progressActivity?.requestID != requestID { return }
        host?.suspendProgressStaleTimeout()
        progressActivity = nil
    }

    func completeProgressActivity(
        requestID: String? = nil,
        finalMessage: LogosMessage? = nil,
        finalStatus: ProgressActivityFinalStatus = .complete,
        failureMessage: String? = nil
    ) {
        if let requestID, progressActivity?.requestID != requestID { return }
        host?.suspendProgressStaleTimeout()
        guard var activity = progressActivity else { return }
        let now = Date().timeIntervalSince1970
        activity.isComplete = true
        activity.timedOut = false
        activity.finalStatus = finalStatus
        activity.failureMessage = failureMessage
        if activity.completedAt == nil {
            activity.completedAt = now
        }
        if let finalMessage {
            if activity.completedFinalMessageID == nil || activity.completedFinalMessageID == finalMessage.id {
                activity.completedFinalMessageID = finalMessage.id
            }
        }
        if finalStatus != .failed && finalStatus != .interrupted {
            activity.retryRequest = nil
        }
        progressActivity = activity
    }

    func finishProgressRun(
        requestID: String? = nil,
        finalStatus: ProgressActivityFinalStatus,
        failureMessage: String? = nil,
        suppressLateFrames: Bool = false
    ) {
        if suppressLateFrames {
            suppressCurrentRunRequestIDs()
            host?.setRequiresScopedLiveResponse(true)
        }
        completeProgressActivity(requestID: requestID, finalStatus: finalStatus, failureMessage: failureMessage)
        host?.progressRunStatus = .idle
        host?.clearPendingCancelRequestID()
        host?.progressPendingOutboundResponseRequestID = nil
        host?.clearAllProgressOutstandingOutboundRequestIDs()
        host?.clearInteractionStateForProgress()
        host?.clearAckForProgress()
        host?.clearAudioPlaybackForProgress()
    }

    // MARK: - Run-id predicates

    func isSuppressedRunRequestID(_ requestID: String?) -> Bool {
        guard let requestID, requestID.isEmpty == false else { return false }
        return suppressedRunRequestIDs.contains(requestID)
    }

    func isActiveRunRequestID(_ requestID: String?) -> Bool {
        guard let requestID, requestID.isEmpty == false else { return false }
        guard isSuppressedRunRequestID(requestID) == false else { return false }
        return (progressActivity?.requestID == requestID && progressActivity?.isComplete == false)
            || host?.progressPendingOutboundResponseRequestID == requestID
            || host?.progressOutstandingOutboundResponseRequestIDs.contains(requestID) == true
    }

    func shouldRouteMessageToProgress(_ message: LogosMessage, requestID: String?) -> Bool {
        if message.isProgressUpdate { return true }
        guard message.projectKey == host?.progressActiveProjectKey, message.role != "user" else { return false }
        guard let requestID, requestID.isEmpty == false, isActiveRunRequestID(requestID) else { return false }
        return host?.isProgressTerminalAssistantMessage(message) == false
    }

    func progressRoutingRequestID(for message: LogosMessage, frameRequestID: String?, allowGatewayStatusActiveFallback: Bool = false) -> String {
        if let requestID = message.metadataRequestID, requestID.isEmpty == false {
            return requestID
        }
        if message.isGatewayStatusUpdate,
           let activity = progressActivity,
           activity.isComplete == false,
           activity.projectKey == message.projectKey {
            if let requestID = frameRequestID, isActiveRunRequestID(requestID) {
                return requestID
            }
            if frameRequestID == nil || allowGatewayStatusActiveFallback {
                return activity.requestID
            }
        }
        if let requestID = frameRequestID, requestID.isEmpty == false {
            return requestID
        }
        return message.messageID
    }

    func progressEventKind(for message: LogosMessage) -> String {
        message.isProgressUpdate ? message.progressEventKind : "gateway_status"
    }

    func suppressRunRequestID(_ requestID: String?) {
        guard let requestID, requestID.isEmpty == false else { return }
        suppressedRunRequestIDs.insert(requestID)
    }

    func suppressCurrentRunRequestIDs() {
        suppressRunRequestID(progressActivity?.requestID)
        suppressRunRequestID(host?.progressPendingOutboundResponseRequestID)
        for requestID in host?.progressOutstandingOutboundResponseRequestIDs ?? [] {
            suppressRunRequestID(requestID)
        }
    }

    /// Drop a request id from the live run after a fresh send re-opens it (mirrors the
    /// `suppressedRunRequestIDs.remove` calls in the client's send paths).
    func unsuppressRunRequestID(_ requestID: String) {
        suppressedRunRequestIDs.remove(requestID)
    }

    /// Clear all run-scope bookkeeping the manager owns (called on project switch).
    func clearRunScopedState() {
        suppressedRunRequestIDs.removeAll()
    }

    func shouldClearProgressActivity(for message: LogosMessage, requestID: String?) -> Bool {
        guard let activity = progressActivity else { return false }
        guard host?.progressRunStatus != .cancelling else { return false }
        guard isSuppressedRunRequestID(requestID) == false else { return false }
        guard message.projectKey == host?.progressActiveProjectKey, host?.isProgressTerminalAssistantMessage(message) == true else { return false }
        if activity.isComplete, let completedFinalMessageID = activity.completedFinalMessageID {
            return message.id == completedFinalMessageID
        }
        if let requestID, requestID.isEmpty == false {
            return activity.requestID == requestID
        }
        // A request-scoped progress card must not be released by an unscoped final
        // message. After a cancel/re-ask in the same session, old adapter frames may
        // still arrive without a request_id; accepting a session-only match here can
        // clear the new run and trigger stale autoplay.
        guard activity.requestID.isEmpty else { return false }
        if let activitySessionID = activity.sessionID {
            return activitySessionID == message.sessionID
        }
        return true
    }

    func progressFinalStatus(for message: LogosMessage) -> ProgressActivityFinalStatus {
        if message.metadataIsError || message.metadataFinalStatus == ProgressActivityFinalStatus.failed.rawValue {
            return .failed
        }
        if message.metadataFinalStatus == ProgressActivityFinalStatus.stopped.rawValue {
            return .stopped
        }
        if message.metadataFinalStatus == ProgressActivityFinalStatus.interrupted.rawValue {
            return .interrupted
        }
        return .complete
    }

    func shouldPersistProgressMessage(_ message: LogosMessage) -> Bool {
        message.isProgressUpdate && message.isGatewayStatusUpdate == false
    }

    func shouldApplyBatchProgressToLiveRun(requestID: String, projectKey: String) -> Bool {
        projectKey == host?.progressActiveProjectKey && isActiveRunRequestID(requestID)
    }

    func idleRunStatusMatchesActiveProgress(requestID: String?, projectKey: String?) -> Bool {
        guard let activity = progressActivity, activity.isComplete == false else { return false }
        guard let requestID, requestID.isEmpty == false else { return false }
        if let projectKey, projectKey != activity.projectKey { return false }
        return activity.requestID == requestID || isActiveRunRequestID(requestID)
    }

    func activeRunErrorMatches(_ requestID: String?) -> Bool {
        guard let activity = progressActivity, activity.isComplete == false else { return false }
        guard let requestID, requestID.isEmpty == false else { return false }
        return activity.requestID == requestID
            || host?.progressPendingOutboundResponseRequestID == requestID
            || host?.progressOutstandingOutboundResponseRequestIDs.contains(requestID) == true
    }

    func activeRunInterruptionMatches(_ requestID: String?) -> Bool {
        guard progressActivity?.isComplete == false else {
            return host?.progressRunStatus == .running || host?.progressRunStatus == .queued
        }
        guard let requestID, requestID.isEmpty == false else { return true }
        return isActiveRunRequestID(requestID)
    }

    // MARK: - Inbound tool/progress frame

    private func syntheticProgressMessage(
        root: [String: Any],
        payload: [String: Any],
        projectKey: String,
        requestID: String,
        sessionID: String?,
        kind: String,
        text: String
    ) -> LogosMessage? {
        let transient = host?.progressBoolValue(payload["transient"]) ?? (kind == "gateway_status")
        guard transient == false || kind != "gateway_status" else { return nil }
        let messageID = payload["message_id"] as? String ?? requestID
        let serverSeq = host?.progressIntegerValue(root["server_seq"]) ?? host?.progressIntegerValue(payload["server_seq"]) ?? 0
        let metadata: [String: Any] = [
            "finalized": false,
            "source": "tool_progress",
            "progress_kind": payload["progress_kind"] as? String ?? kind,
            "request_id": requestID,
            "transient": false
        ]
        return LogosMessage.from(dictionary: [
            "project_key": projectKey,
            "session_id": sessionID ?? "project:\(projectKey)",
            "message_id": messageID,
            "server_seq": serverSeq,
            "role": "assistant",
            "content": text,
            "timestamp": Date().timeIntervalSince1970,
            "status": "persisted",
            "metadata": metadata
        ])
    }

    func handleToolProgress(_ root: [String: Any]) {
        guard host?.progressIsActiveProjectFrame(root) == true else { return }
        let payload = root["payload"] as? [String: Any] ?? [:]
        let projectKey = host?.progressFrameProjectKey(root) ?? host?.progressActiveProjectKey ?? "default"
        let requestID = root["request_id"] as? String ?? payload["request_id"] as? String ?? "progress-\(projectKey)"
        let sessionID = root["session_id"] as? String ?? payload["session_id"] as? String
        let kind = payload["progress_kind"] as? String ?? payload["kind"] as? String ?? root["type"] as? String ?? "progress"
        let text = payload["text"] as? String ?? payload["message"] as? String ?? payload["summary"] as? String ?? kind
        if let messageDict = payload["message"] as? [String: Any], let message = LogosMessage.from(dictionary: messageDict) {
            appendProgressEvent(requestID: requestID, projectKey: projectKey, sessionID: sessionID, kind: kind, text: text, eventID: message.messageID)
            if shouldPersistProgressMessage(message) {
                host?.persistProgressMessage(message)
            }
        } else if let message = syntheticProgressMessage(root: root, payload: payload, projectKey: projectKey, requestID: requestID, sessionID: sessionID, kind: kind, text: text),
                  shouldPersistProgressMessage(message) {
            appendProgressEvent(requestID: requestID, projectKey: projectKey, sessionID: sessionID, kind: kind, text: text, eventID: message.messageID)
            host?.persistProgressMessage(message)
        } else {
            appendProgressEvent(requestID: requestID, projectKey: projectKey, sessionID: sessionID, kind: kind, text: text, eventID: payload["message_id"] as? String)
        }
    }
}
