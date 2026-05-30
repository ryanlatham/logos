import Foundation
import Observation
import OSLog
import UIKit


struct FastAckState: Equatable {
    let id: String
    let projectKey: String
    let text: String
    let ttlMilliseconds: Int
    let expiresAt: Date

    static func next(id: String, projectKey: String, text: String?, ttlMilliseconds: Int?, now: Date = Date()) -> FastAckState? {
        guard let text else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return nil }
        let ttl = min(30_000, max(1, ttlMilliseconds ?? 5_000))
        return FastAckState(
            id: id,
            projectKey: projectKey,
            text: trimmed,
            ttlMilliseconds: ttl,
            expiresAt: now.addingTimeInterval(TimeInterval(ttl) / 1_000.0)
        )
    }

    func isExpired(now: Date = Date()) -> Bool {
        now >= expiresAt
    }
}

@MainActor
@Observable
final class LogosClient {
    var settings = LogosSettings() {
        didSet {
            settings.persist()
            if settings.urlString != oldValue.urlString
                || settings.secret != oldValue.secret
                || settings.autoConnect != oldValue.autoConnect
            {
                progressActivityManager.clearConnectionRetryState()
            }
        }
    }
    private(set) var projects: [LogosProject] = []
    var activeProjectKey: String = "default" {
        didSet {
            messageManager.refreshMessages()
            if oldValue != activeProjectKey {
                clearRunScopedStateForProjectChange()
            } else {
                clearCardsNotMatchingActiveProject()
            }
        }
    }
    private(set) var runStatus: LogosRunStatus = .idle
    var lastError: String?
    /// Bounded, source-tagged history of client errors (WS1 P7). `lastError` remains the
    /// transient single-error banner; `errorLog` is the persistent, dismissible record.
    private(set) var errorLog = ErrorLogBuffer()
    private(set) var ackText: String?
    private(set) var undeliveredSpeechDraft: UndeliveredSpeechDraft?
    var slashCommandCatalog: SlashCommandCatalog = .fallback
    var slashCommandCompletion: SlashCommandCompletionResult = .empty

    let logosConnection: LogosConnection
    let messageManager: MessageManager
    let audioCoordinator: AudioCoordinator
    let progressActivityManager: ProgressActivityManager
    let interactionController: InteractionController
    let notificationRouter: NotificationRouter
    private var staleTimeoutInterval: TimeInterval
    private let pairingExchanger: any PairingCredentialExchanging
    private var inFlightFinalSpeechDrafts: [String: UndeliveredSpeechDraft] = [:]
    private var ackState: FastAckState?
    private let staleTimeoutScheduler: any DelayedFireScheduling
    private let ackClearScheduler: any DelayedFireScheduling
    private var pendingCancelRequestID: String?
    var pendingCommandCatalogRequestID: String?
    var pendingCommandCompletionRequestID: String?
    private var pendingReconnectReplayRequestID: String?
    private var pendingOutboundResponseRequestID: String?
    private var outstandingOutboundResponseRequestIDs = Set<String>()
    private var requiresScopedLiveResponse = false
    private var pendingProjectSwitchRequestID: String?
    private var pendingProjectSwitchTarget: String?

    private static let staleSilenceNoticeText = "Logos has not heard from Hermes in a while. The run may still be working; waiting for the next adapter update."
    private static let maxStaleTimeoutInterval: TimeInterval = 86_400
    private static let maxInboundFrameBytes = 2_000_000

    init(
        store: SQLiteMessageStore = SQLiteMessageStore(),
        socketFactory: any WebSocketTaskMaking = URLSessionWebSocketTaskFactory(),
        pairingExchanger: any PairingCredentialExchanging = WebSocketPairingCredentialExchanger(),
        audioPlayback: AudioPlaybackController = AudioPlaybackController(),
        staleTimeoutInterval: TimeInterval = 900,
        staleTimeoutScheduler: (any DelayedFireScheduling)? = nil,
        ackClearScheduler: (any DelayedFireScheduling)? = nil
    ) {
        self.logosConnection = LogosConnection(socketFactory: socketFactory)
        self.pairingExchanger = pairingExchanger
        self.messageManager = MessageManager(store: store)
        self.audioCoordinator = AudioCoordinator(audioPlayback: audioPlayback)
        self.progressActivityManager = ProgressActivityManager()
        self.interactionController = InteractionController()
        self.notificationRouter = NotificationRouter()
        self.staleTimeoutInterval = min(max(0.001, staleTimeoutInterval), Self.maxStaleTimeoutInterval)
        self.staleTimeoutScheduler = staleTimeoutScheduler ?? TaskDelayedFireScheduler()
        self.ackClearScheduler = ackClearScheduler ?? TaskDelayedFireScheduler()
        logosConnection.host = self
        messageManager.host = self
        messageManager.loadInitialMessages(projectKey: activeProjectKey)
        audioCoordinator.host = self
        progressActivityManager.host = self
        interactionController.host = self
        notificationRouter.host = self
        // WS1 P5 wired six Combine `objectWillChange` sinks here so views observing `LogosClient`
        // refreshed when a collaborator's published state changed. The `@Observable` macro makes that
        // forwarding automatic: reading a computed forwarder (e.g. `client.messages`) inside a view's
        // `body` transitively registers the nested `@Observable` collaborator access, so the sinks are
        // redundant and were removed (Phase 2 modernization).
    }

    func connectIfRequestedByEnvironment() {
        logosConnection.connectIfRequestedByEnvironment()
    }

    func connectIfAutoConnectEnabled() {
        logosConnection.connectIfAutoConnectEnabled()
    }

    func connect() {
        logosConnection.connect()
    }

    func disconnect() {
        logosConnection.disconnect()
    }

    /// Re-exposes the connection's published state so existing views/tests reading
    /// `client.connectionState` keep working (get-only, matching the original `@Published private(set)`).
    var connectionState: LogosConnectionState { logosConnection.connectionState }

    fileprivate var canAutoRetryConnection: Bool {
        settings.autoConnect
            && URL(string: settings.urlString) != nil
            && LogosSettings.normalizedSecret(settings.secret).isEmpty == false
    }

    @discardableResult
    func sendText(_ text: String) async -> Bool {
        guard ensureConnectedForUserAction("send a message") else { return false }
        guard runStatus != .cancelling else { return false }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let projectKey = activeProjectKey
        let pending = LogosMessage.pending(projectKey: projectKey, content: trimmed)
        let requestID = UUID().uuidString
        let previousRunStatus = runStatus
        // Apply the optimistic UI state *before* awaiting the send: with async transport the
        // send (and its inline failure callback) now resolves within `await sendFrame`, so the
        // pending message / run state must already be in place for the failure handler to roll
        // it back. A pre-send validation failure (`sent == false`) undoes it below.
        progressActivityManager.clearProgressActivity()
        progressActivityManager.startProgressActivity(requestID: requestID, projectKey: projectKey, retryRequest: .text(trimmed))
        progressActivityManager.unsuppressRunRequestID(requestID)
        outstandingOutboundResponseRequestIDs.insert(requestID)
        pendingOutboundResponseRequestID = requestID
        messageManager.addPendingMessage(pending)
        runStatus = .running
        scheduleStaleTimeout(requestID: requestID, projectKey: projectKey)
        let sent = await sendFrame([
            "type": "text_input",
            "request_id": requestID,
            "device_id": settings.deviceID,
            "project_key": projectKey,
            "payload": [
                "text": trimmed,
                "client_msg_id": pending.messageID,
                "is_final": true
            ]
        ]) { [weak self] result in
            guard case .failure(let error) = result else { return }
            self?.handlePendingTextSendFailure(messageID: pending.messageID, projectKey: projectKey, requestID: requestID, error: error)
        }
        if sent {
            if Self.shouldRefreshCommandCatalog(afterSending: trimmed) {
                await requestCommandCatalog()
            }
        } else {
            handlePendingTextSendFailure(messageID: pending.messageID, projectKey: projectKey, requestID: requestID, error: LogosSocketSendError.staleConnection)
            // Roll back the optimistically-set run state too — a pre-send rejection (e.g. seal
            // failure) never routes through `failCurrentSocket`, so without this `runStatus` would
            // stay `.running` with no progress/timeout to ever clear it (stuck UI).
            runStatus = previousRunStatus
        }
        return sent
    }

    private static func shouldRefreshCommandCatalog(afterSending text: String) -> Bool {
        let firstToken = text.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
        return firstToken == "/reload-skills" || firstToken == "/reload-mcp"
    }

    @discardableResult
    func sendSpeech(text: String, isFinal: Bool, inputID: String, partialSeq: Int, startedAtMilliseconds: Int64) async -> Bool {
        guard ensureConnectedForUserAction(isFinal ? "send speech" : "stream speech") else { return false }
        guard runStatus != .cancelling else { return false }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let projectKey = activeProjectKey
        let pending = LogosMessage.pending(projectKey: projectKey, messageID: inputID, content: trimmed)
        let failedDraft = UndeliveredSpeechDraft(
            inputID: inputID,
            projectKey: projectKey,
            text: trimmed,
            reason: "The socket closed before Logos confirmed the final speech frame was sent."
        )
        let requestID = UUID().uuidString
        let previousRunStatus = runStatus
        // Apply the final-speech optimistic UI state *before* awaiting the send (see `sendText`):
        // the inline send/failure callback resolves within `await sendFrame`, so the pending
        // message / run state must already be in place for the failure handler to roll it back.
        if isFinal {
            inFlightFinalSpeechDrafts[inputID] = failedDraft
            progressActivityManager.clearProgressActivity()
            progressActivityManager.startProgressActivity(requestID: requestID, projectKey: projectKey, retryRequest: .speech(text: trimmed))
            progressActivityManager.unsuppressRunRequestID(requestID)
            outstandingOutboundResponseRequestIDs.insert(requestID)
            pendingOutboundResponseRequestID = requestID
            messageManager.addPendingMessage(pending)
            runStatus = .running
            scheduleStaleTimeout(requestID: requestID, projectKey: projectKey)
        }
        let sent = await sendFrame(LogosSpeechFrame.make(
            text: trimmed,
            isFinal: isFinal,
            inputID: inputID,
            partialSeq: partialSeq,
            startedAtMilliseconds: startedAtMilliseconds,
            deviceID: settings.deviceID,
            projectKey: projectKey,
            requestID: requestID
        )) { [weak self] result in
            guard isFinal else { return }
            switch result {
            case .success:
                self?.handleFinalSpeechSendSuccess(inputID: inputID)
            case .failure(let error):
                self?.handleFinalSpeechSendFailure(failedDraft, requestID: requestID, error: error)
            }
        }
        if sent == false, isFinal {
            // Pre-send validation failed (the inline failure callback never ran): roll back the
            // optimistic state without surfacing an undelivered-draft/error banner (mirrors the
            // former `sent == false, isFinal` branch that only dropped the in-flight draft).
            inFlightFinalSpeechDrafts.removeValue(forKey: inputID)
            clearOutstandingOutboundRequestID(requestID)
            progressActivityManager.clearProgressActivity(requestID: requestID)
            messageManager.removePendingMessage(messageID: inputID)
            messageManager.refreshMessages()
            suspendStaleTimeout()
            runStatus = previousRunStatus
        }
        return sent
    }

    @discardableResult
    func retryProgressActivity() async -> Bool {
        await progressActivityManager.retryProgressActivity()
    }

    func clearUndeliveredSpeechDraft(id: String) {
        guard undeliveredSpeechDraft?.id == id else { return }
        undeliveredSpeechDraft = nil
    }

    func requestProjects() async {
        LogosConnectionLog.logger.info("Requesting project list active_project=\(self.activeProjectKey, privacy: .public)")
        await sendFrame([
            "type": "list_projects",
            "request_id": UUID().uuidString,
            "device_id": settings.deviceID,
            "payload": ["limit": 50]
        ])
    }


    func registerDevice(apnsToken: String?) async {
        await notificationRouter.registerDevice(apnsToken: apnsToken)
    }

    func handleNotificationRoute(_ route: LogosNotificationRoute) async {
        await notificationRouter.handleNotificationRoute(route)
    }

    func updateSceneActivationForPlayback(isActive: Bool) async {
        await notificationRouter.updateSceneActivationForPlayback(isActive: isActive)
    }

    func applyPairingRoute(_ route: LogosPairingRoute) async {
        LogosConnectionLog.logger.info("Applying Logos pairing route host=\(route.adapterHostDescription, privacy: .public) device_id=\(route.deviceID, privacy: .public) autoconnect=\(route.autoConnect, privacy: .public)")
        let previousState = connectionState
        let hadUsableConnection = previousState == .connected && logosConnection.hasOpenSocket
        lastError = nil
        do {
            if route.isExpired {
                throw LogosPairingExchangeError.expired
            }
            let credential = try await pairingExchanger.exchange(route: route)
            logosConnection.cancelSocketForPairing()
            settings.urlString = credential.adapterURL
            settings.deviceID = credential.deviceID
            settings.secret = LogosSettings.normalizedSecret(credential.deviceSecret)
            // WS3 S4: adopt the direct-WSS leaf pin from the (signed) pairing link, if any.
            settings.certSPKISHA256 = (route.certSPKISHA256 ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            settings.autoConnect = route.autoConnect
            settings.hasCompletedFirstConnection = true
            lastError = nil
            if route.autoConnect {
                connect()
            } else {
                logosConnection.markDisconnectedForPairing()
            }
        } catch {
            LogosConnectionLog.logger.error("Pairing route failed error=\(error.localizedDescription, privacy: .public)")
            recordError("Logos pairing failed: \(error.localizedDescription)")
            logosConnection.restoreStateAfterFailedPairing(hadUsableConnection: hadUsableConnection)
        }
    }

    @discardableResult
    func createProject(title: String) async -> Bool {
        guard ensureConnectedForUserAction("create a project") else { return false }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return await sendFrame([
            "type": "new_project",
            "request_id": UUID().uuidString,
            "device_id": settings.deviceID,
            "payload": ["title": trimmed]
        ])
    }

    func switchProject(_ projectKey: String) async {
        let requestID = UUID().uuidString
        pendingProjectSwitchRequestID = requestID
        pendingProjectSwitchTarget = projectKey
        activeProjectKey = projectKey
        await sendFrame([
            "type": "switch_project",
            "request_id": requestID,
            "device_id": settings.deviceID,
            "payload": ["project_key": projectKey]
        ])
        await requestMessages(afterServerSeq: 0)
    }

    func requestMessages(afterServerSeq: Int) async {
        await messageManager.requestMessages(afterServerSeq: afterServerSeq)
    }

    func completeThreadFocusRequest(id: String) {
        notificationRouter.completeThreadFocusRequest(id: id)
    }

    func approveCurrentRequest() async {
        await interactionController.approveCurrentRequest()
    }

    func denyCurrentRequest() async {
        await interactionController.denyCurrentRequest()
    }

    @discardableResult
    func answerClarification(_ text: String) async -> Bool {
        await interactionController.answerClarification(text)
    }

    func cancelRun() async {
        guard ensureConnectedForUserAction("stop the run") else { return }
        guard runStatus != .cancelling else { return }
        let requestID = UUID().uuidString
        let previousRunStatus = runStatus
        // Apply the cancelling state *before* awaiting the send: the inline send/failure callback now
        // resolves within `await sendFrame`, and the failure handler is gated on
        // `runStatus == .cancelling && pendingCancelRequestID == requestID`, so that state must
        // already be in place. A pre-send validation failure (`sent == false`) rolls it back below.
        progressActivityManager.suppressCurrentRunRequestIDs()
        requiresScopedLiveResponse = true
        pendingCancelRequestID = requestID
        runStatus = .cancelling
        suspendStaleTimeout()
        interactionController.clearInteractionStateForCancel()
        clearAck()
        let sent = await sendFrame([
            "type": "run_cancel",
            "request_id": requestID,
            "device_id": settings.deviceID,
            "project_key": activeProjectKey,
            "payload": [:]
        ]) { [weak self, requestID] result in
            guard case .failure(let error) = result,
                  self?.runStatus == .cancelling,
                  self?.pendingCancelRequestID == requestID else { return }
            self?.pendingCancelRequestID = nil
            self?.recordError(error.localizedDescription)
            self?.runStatus = .error
        }
        if sent == false {
            // Pre-send validation failed (the inline failure callback never ran): undo the
            // cancelling state so the run is left as it was.
            if pendingCancelRequestID == requestID {
                pendingCancelRequestID = nil
            }
            if runStatus == .cancelling {
                runStatus = previousRunStatus
            }
        }
    }

    func playback(message: LogosMessage) async {
        await audioCoordinator.playback(message: message)
    }

    func pausePlayback() {
        audioCoordinator.pausePlayback()
    }

    func resumePlayback() {
        audioCoordinator.resumePlayback()
    }

    func stopPlayback() {
        audioCoordinator.stopPlayback()
    }

    func pauseAudioForSceneBackground() {
        audioCoordinator.pauseAudioForSceneBackground()
    }

    func resumeAudioForSceneActive() {
        audioCoordinator.resumeAudioForSceneActive()
    }

    func refreshPlaybackSpectrumForTesting(audioID: String) {
        audioCoordinator.refreshPlaybackSpectrumForTesting(audioID: audioID)
    }

    func toggleProgressActivityExpanded() {
        progressActivityManager.toggleProgressActivityExpanded()
    }

    /// Single funnel for surfacing a client error: records it in the persistent, source-tagged
    /// history and mirrors it to the transient `lastError` banner.
    func logError(_ message: String, source: LoggedError.Source) {
        errorLog.record(message, source: source)
        lastError = message
    }

    /// Dismiss one entry from the error history (UI affordance).
    func dismissError(id: UUID) {
        errorLog.dismiss(id: id)
    }

    /// Clear the entire error history.
    func clearErrorHistory() {
        errorLog.clear()
    }

    private func ensureConnectedForUserAction(_ action: String) -> Bool {
        guard logosConnection.hasTask, connectionState == .connected else {
            LogosConnectionLog.logger.warning("User action blocked because Logos is not connected action=\(action, privacy: .public) state=\(self.connectionState.rawValue, privacy: .public) open=\(self.logosConnection.hasOpenSocket, privacy: .public) has_task=\(self.logosConnection.hasTask, privacy: .public)")
            recordError("Cannot \(action): Logos is not connected.")
            return false
        }
        return true
    }

    private func clearCardsNotMatchingActiveProject() {
        interactionController.clearCardsNotMatchingActiveProject()
    }

    private func recordError(_ message: String) {
        clearAck()
        progressActivityManager.clearProgressActivity()
        logError(message, source: .action)
    }

    private func scheduleStaleTimeout(requestID: String, projectKey: String) {
        guard projectKey == activeProjectKey else { return }
        guard runStatus != .cancelling, runStatus != .awaitingApproval, runStatus != .awaitingClarification else { return }
        guard progressActivityManager.isActiveRunRequestID(requestID) else { return }
        staleTimeoutScheduler.schedule(after: staleTimeoutInterval) { [weak self] in
            self?.handleStaleTimeout(requestID: requestID, projectKey: projectKey)
        }
    }

    private func handleStaleTimeout(requestID: String, projectKey: String) {
        guard projectKey == activeProjectKey else { return }
        guard runStatus == .running || runStatus == .queued else { return }
        guard progressActivityManager.isActiveRunRequestID(requestID) else { return }
        let now = Date().timeIntervalSince1970
        progressActivityManager.appendStaleTimeoutEvent(requestID: requestID, projectKey: projectKey, now: now)
        messageManager.appendLocalStaleNotice(
            projectKey: projectKey,
            requestID: requestID,
            content: Self.staleSilenceNoticeText,
            now: now
        )
        scheduleStaleTimeout(requestID: requestID, projectKey: projectKey)
    }

    private func suspendStaleTimeout() {
        staleTimeoutScheduler.cancel()
    }

    /// Forward an outbound frame to the connection's transport (WS1 P5). Every internal send path
    /// (`sendText`/`sendSpeech`/`requestProjects`/`cancelRun`/…) and every manager-host `send*Frame`
    /// delegation routes through here so the seal/auth/counter behavior lives in one place. Matches
    /// the former `LogosClient.sendFrame` visibility/signature (internal) so the `+Commands` extension
    /// can keep calling it.
    @discardableResult
    func sendFrame(
        _ frame: [String: Any],
        requiresAuthentication: Bool = true,
        onCompletion: (@MainActor @Sendable (Result<Void, Error>) -> Void)? = nil
    ) async -> Bool {
        await logosConnection.sendFrame(frame, requiresAuthentication: requiresAuthentication, onCompletion: onCompletion)
    }

    func handleFrameString(_ string: String) async {
        guard string.utf8.count <= Self.maxInboundFrameBytes else {
            LogosConnectionLog.logger.error("Inbound frame rejected because it exceeded size limit bytes=\(string.utf8.count, privacy: .public)")
            return
        }
        guard
            let data = string.data(using: .utf8),
            let parsedRoot = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let type = parsedRoot["type"] as? String
        else {
            LogosConnectionLog.logger.error("Inbound frame parse failed bytes=\(string.utf8.count, privacy: .public)")
            return
        }
        var root = parsedRoot
        LogosConnectionLog.logger.info("Inbound frame parsed \(LogosConnectionLog.inboundFrameSummary(root), privacy: .public) bytes=\(string.utf8.count, privacy: .public)")
        if type != "error" {
            lastError = nil
        }
        if let payload = root["payload"] as? [String: Any],
           payload["enc"] as? Int == 1 {
            // Sealed frame: ask the connection to open it using the cleartext routing fields as the
            // AAD header (the connection owns the negotiated session crypto). A nil result means no
            // session was negotiated, so the (still-sealed) payload is left untouched.
            do {
                if let opened = try logosConnection.openInboundPayload(header: root, encPayload: payload) {
                    root["payload"] = opened
                }
            } catch {
                LogosConnectionLog.logger.error("Failed to open encrypted Logos frame type=\(type, privacy: .public)")
                return
            }
        }
        switch type {
        case "hello":
            await logosConnection.handleHelloFrame(root)
        case "registered":
            await logosConnection.handleRegisteredFrame(root)
        case "projects_list":
            handleProjectsList(root)
        case "commands_list":
            handleCommandsList(root)
        case "commands_complete_result":
            handleCommandsCompleteResult(root)
        case "messages_batch":
            await handleMessagesBatch(root)
        case "state_update":
            await handleStateUpdate(root)
        case "run_status":
            handleRunStatus(root)
        case "approval_request":
            interactionController.handleApprovalRequest(root)
        case "clarify_request":
            interactionController.handleClarifyRequest(root)
        case "tool_progress", "progress_update":
            progressActivityManager.handleToolProgress(root)
        case "audio_chunk":
            audioCoordinator.handleAudioChunk(root)
        case "audio_end":
            audioCoordinator.handleAudioEnd(root)
        case "error":
            let payload = root["payload"] as? [String: Any]
            let code = payload?["code"] as? String ?? "<none>"
            let message = adapterErrorMessage(payload: payload)
            LogosConnectionLog.logger.error("Inbound adapter error code=\(code, privacy: .public) reason=\(payload?["reason"] as? String ?? "<none>", privacy: .public) message=\(message, privacy: .public)")
            if code == "auth_failed" {
                logosConnection.failForAuthFailure(message: message)
            } else {
                handleAdapterError(root: root, code: code, message: message)
            }
        default:
            LogosConnectionLog.logger.warning("Unhandled inbound frame type=\(type, privacy: .public)")
            break
        }
    }

    private func applyClientConfig(from root: [String: Any]) {
        guard let payload = root["payload"] as? [String: Any],
              let config = payload["client_config"] as? [String: Any],
              let staleTimeout = timeIntervalValue(config["stale_timeout_seconds"]),
              staleTimeout > 0
        else { return }
        staleTimeoutInterval = min(staleTimeout, Self.maxStaleTimeoutInterval)
    }

    private func adapterErrorMessage(payload: [String: Any]?) -> String {
        let code = payload?["code"] as? String
        let reason = payload?["reason"] as? String
        let rawMessage = payload?["message"] as? String
        if code == "auth_failed" {
            switch reason {
            case "invalid_signature":
                return "Logos authentication failed: signature mismatch. Check that the iOS Device key matches LOGOS_DEVICE_SECRET on the Logos adapter."
            case "timestamp_skew":
                return "Logos authentication failed: device clock is outside the allowed skew. Check Date & Time on this iPhone and the Mac."
            case "replayed_nonce":
                return "Logos authentication failed: replayed nonce. Reconnect and try again."
            case "legacy_plaintext_secret":
                return "Logos authentication failed: this adapter requires signed hello authentication. Update the app before reconnecting."
            case "missing_signature", "missing_nonce", "invalid_nonce", "invalid_timestamp":
                return "Logos authentication failed: malformed signed hello. Update the app before reconnecting."
            default:
                return rawMessage ?? "Logos authentication failed."
            }
        }
        return rawMessage ?? "Logos adapter error"
    }

    private func handleProjectsList(_ root: [String: Any]) {
        guard let payload = root["payload"] as? [String: Any] else { return }
        let rawProjects = payload["projects"] as? [[String: Any]] ?? []
        let projectDecode = LogosWireDecoder.decodeList(rawProjects, LogosProject.from(dictionary:))
        if projectDecode.hasDrops {
            LogosConnectionLog.logger.warning("Dropped \(projectDecode.droppedCount, privacy: .public) malformed project entries in projects_list")
        }
        projects = projectDecode.decoded
        let hasCurrentProject = projects.contains(where: { $0.projectKey == activeProjectKey })
        if let active = payload["active_project_key"] as? String, !active.isEmpty {
            if active == activeProjectKey || hasCurrentProject == false {
                activeProjectKey = active
            }
        } else if hasCurrentProject == false, let first = projects.first {
            activeProjectKey = first.projectKey
        }
    }


    private func handleMessagesBatch(_ root: [String: Any]) async {
        guard let payload = root["payload"] as? [String: Any] else { return }
        let rawMessages = payload["messages"] as? [[String: Any]] ?? []
        let messageDecode = LogosWireDecoder.decodeList(rawMessages, LogosMessage.from(dictionary:))
        if messageDecode.hasDrops {
            LogosConnectionLog.logger.warning("Dropped \(messageDecode.droppedCount, privacy: .public) malformed message entries in messages_batch")
        }
        let decodedMessages = messageDecode.decoded
        var persistedMessages: [LogosMessage] = []
        let batchRequestID = root["request_id"] as? String
        let isReconnectReplay = batchRequestID != nil && batchRequestID == pendingReconnectReplayRequestID
        let replayedRunStatus = payload["run_status"] as? [String: Any]
        for message in decodedMessages {
            let progressRequestID = progressActivityManager.progressRoutingRequestID(for: message, frameRequestID: batchRequestID, allowGatewayStatusActiveFallback: true)
            if message.role != "user", progressActivityManager.isSuppressedRunRequestID(progressRequestID) {
                continue
            }
            if progressActivityManager.shouldRouteMessageToProgress(message, requestID: progressRequestID) {
                if progressActivityManager.shouldApplyBatchProgressToLiveRun(requestID: progressRequestID, projectKey: message.projectKey) {
                    progressActivityManager.appendProgressEvent(
                        requestID: progressRequestID,
                        projectKey: message.projectKey,
                        sessionID: message.sessionID,
                        kind: progressActivityManager.progressEventKind(for: message),
                        text: message.content,
                        eventID: message.messageID
                    )
                }
                if progressActivityManager.shouldPersistProgressMessage(message) {
                    messageManager.persist(message)
                    persistedMessages.append(message)
                }
            } else {
                messageManager.persist(message)
                persistedMessages.append(message)
            }
        }
        messageManager.reconcilePending(with: persistedMessages)
        let pending = payload["pending_interactions"] as? [[String: Any]] ?? []
        for interaction in pending {
            interactionController.handlePendingInteraction(interaction)
        }
        if payload.keys.contains("pending_interactions") {
            interactionController.reconcilePendingInteractionCards(pending, projectKey: root["project_key"] as? String ?? activeProjectKey)
        }
        if let replayedRunStatus {
            handleReplayedRunStatus(
                replayedRunStatus,
                fallbackProjectKey: frameProjectKey(root) ?? activeProjectKey,
                fallbackSessionID: root["session_id"] as? String
            )
        }
        let completingFinalMessage = persistedMessages.first { message in
            guard message.projectKey == activeProjectKey, messageManager.isExplicitTerminalAssistantMessage(message) else { return false }
            let finalRequestID = message.metadataRequestID ?? batchRequestID
            guard progressActivity != nil else { return progressActivityManager.isActiveRunRequestID(finalRequestID) }
            return progressActivityManager.shouldClearProgressActivity(for: message, requestID: finalRequestID)
        }
        if let completingFinalMessage, runStatus != .cancelling {
            progressActivityManager.completeProgressActivity(
                requestID: completingFinalMessage.metadataRequestID ?? batchRequestID,
                finalMessage: completingFinalMessage,
                finalStatus: progressActivityManager.progressFinalStatus(for: completingFinalMessage),
                failureMessage: completingFinalMessage.metadataIsError ? completingFinalMessage.content : nil
            )
            runStatus = .idle
        }
        if isReconnectReplay {
            pendingReconnectReplayRequestID = nil
            if replayedRunStatus == nil,
               completingFinalMessage == nil,
               pending.isEmpty,
               progressActivity?.isComplete == false {
                progressActivityManager.finishProgressRun(
                    finalStatus: .interrupted,
                    failureMessage: "Logos reconnected after Hermes restarted; this run may have been interrupted.",
                    suppressLateFrames: true
                )
            }
        }
        messageManager.refreshMessages()
        await notificationRouter.fulfillPendingFinishedNotificationRouteIfPossible()
    }

    private func handleReplayedRunStatus(
        _ runStatus: [String: Any],
        fallbackProjectKey: String,
        fallbackSessionID: String?
    ) {
        var payload = runStatus["payload"] as? [String: Any] ?? [:]
        payload["status"] = runStatus["status"] as? String
        if payload["updated_at"] == nil {
            payload["updated_at"] = runStatus["updated_at"]
        }
        var root: [String: Any] = [
            "type": "run_status",
            "project_key": runStatus["project_key"] as? String ?? fallbackProjectKey,
            "payload": payload
        ]
        if let requestID = runStatus["request_id"] as? String, requestID.isEmpty == false {
            root["request_id"] = requestID
        }
        if let sessionID = runStatus["session_id"] as? String ?? fallbackSessionID {
            root["session_id"] = sessionID
        }
        if let serverSeq = integerValue(runStatus["server_seq"]) {
            root["server_seq"] = serverSeq
        }
        handleRunStatus(root)
    }

    private func setTransientAck(_ text: String?, id: String? = nil, projectKey: String? = nil, ttlMilliseconds: Int? = nil) {
        let ackID = id?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? id! : UUID().uuidString
        let ackProjectKey = projectKey ?? activeProjectKey
        guard let state = FastAckState.next(id: ackID, projectKey: ackProjectKey, text: text, ttlMilliseconds: ttlMilliseconds) else {
            clearAck()
            return
        }
        ackState = state
        ackText = state.text
        let interval = TimeInterval(state.ttlMilliseconds) / 1_000.0
        ackClearScheduler.schedule(after: interval) { [weak self, ackID = state.id, ackProjectKey = state.projectKey] in
            self?.clearAck(matching: ackID, projectKey: ackProjectKey)
        }
    }

    private func clearAck(matching id: String? = nil, projectKey: String? = nil) {
        if let id, ackState?.id != id { return }
        if let projectKey, ackState?.projectKey != projectKey { return }
        ackClearScheduler.cancel()
        ackState = nil
        ackText = nil
    }

    private func clearRunScopedStateForProjectChange() {
        runStatus = .idle
        notificationRouter.clearThreadFocusRequestIfProjectChanged(activeProjectKey: activeProjectKey)
        pendingCancelRequestID = nil
        pendingReconnectReplayRequestID = nil
        pendingOutboundResponseRequestID = nil
        outstandingOutboundResponseRequestIDs.removeAll()
        progressActivityManager.clearRunScopedState()
        requiresScopedLiveResponse = false
        interactionController.clearInteractionStateForCancel()
        suspendStaleTimeout()
        clearAck()
        progressActivityManager.clearProgressActivity()
        audioCoordinator.clearAudioPlaybackForProjectSwitch()
    }

    private func clearRunScopedStateForSocketClosure(runStatus nextStatus: LogosRunStatus) {
        runStatus = nextStatus
        pendingCancelRequestID = nil
        pendingReconnectReplayRequestID = nil
        pendingOutboundResponseRequestID = nil
        outstandingOutboundResponseRequestIDs.removeAll()
        interactionController.clearInteractionStateForCancel()
        clearAck()
        progressActivityManager.clearProgressActivity()
        audioCoordinator.clearAudioPlaybackForProjectSwitch()
    }

    private func handleAdapterError(root: [String: Any], code: String, message: String) {
        let requestID = root["request_id"] as? String
        let projectKey = frameProjectKey(root) ?? activeProjectKey
        if let requestID, requestID == pendingCancelRequestID {
            pendingCancelRequestID = nil
            recordError(message)
            runStatus = .error
            return
        }
        if let requestID, requestID == pendingInteractionResponseID {
            interactionController.clearPendingInteractionResponse(requestID: requestID, projectKey: projectKey)
        }
        if progressActivityManager.activeRunErrorMatches(requestID) {
            progressActivityManager.finishProgressRun(requestID: requestID, finalStatus: .failed, failureMessage: message, suppressLateFrames: true)
            return
        }
        if code == "approval_not_pending" {
            interactionController.clearApprovalCardIfMatches(requestID: requestID)
            if runStatus == .awaitingApproval { runStatus = .idle }
        } else if code == "clarify_not_pending" {
            interactionController.clearClarifyCardIfMatches(requestID: requestID)
            if runStatus == .awaitingClarification { runStatus = .idle }
        }
        if progressActivity?.isComplete == false {
            clearAck()
            logError(message, source: .adapter)
            return
        }
        recordError(message)
    }

    private func ackTTLMilliseconds(from payload: [String: Any]) -> Int? {
        integerValue(payload["ttl_ms"])
    }

    private func integerValue(_ value: Any?) -> Int? {
        if let intValue = value as? Int { return intValue }
        if let doubleValue = value as? Double { return Int(doubleValue) }
        if let stringValue = value as? String { return Int(stringValue) }
        return nil
    }

    private func timeIntervalValue(_ value: Any?) -> TimeInterval? {
        if let doubleValue = value as? Double { return doubleValue }
        if let intValue = value as? Int { return TimeInterval(intValue) }
        if let stringValue = value as? String { return TimeInterval(stringValue) }
        return nil
    }

    private func boolValue(_ value: Any?) -> Bool? {
        if let boolValue = value as? Bool { return boolValue }
        if let intValue = value as? Int { return intValue != 0 }
        if let stringValue = value as? String {
            switch stringValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "1", "true", "yes", "on":
                return true
            case "0", "false", "no", "off":
                return false
            default:
                return nil
            }
        }
        return nil
    }

    private func isTerminalRunStatus(_ status: LogosRunStatus) -> Bool {
        status == .idle || status == .error
    }

    private func isCurrentCancelTerminalRunStatus(root: [String: Any], payload: [String: Any], status: LogosRunStatus) -> Bool {
        guard isTerminalRunStatus(status) else { return false }
        if payload["cancelled"] as? Bool == true { return true }
        guard let pendingCancelRequestID, let requestID = root["request_id"] as? String else { return false }
        return requestID == pendingCancelRequestID
    }

    private func frameProjectKey(_ root: [String: Any]) -> String? {
        guard let projectKey = root["project_key"] as? String, projectKey.isEmpty == false else { return nil }
        return projectKey
    }

    private func isActiveProjectFrame(_ root: [String: Any]) -> Bool {
        guard let projectKey = frameProjectKey(root) else { return true }
        return projectKey == activeProjectKey
    }

    private func clearOutstandingOutboundRequestID(_ requestID: String?) {
        guard let requestID, requestID.isEmpty == false else { return }
        outstandingOutboundResponseRequestIDs.remove(requestID)
        if pendingOutboundResponseRequestID == requestID {
            pendingOutboundResponseRequestID = nil
        }
    }

    private func handleStateUpdate(_ root: [String: Any]) async {
        guard let payload = root["payload"] as? [String: Any] else { return }
        let op = payload["op"] as? String
        if op == "fast_ack" {
            guard isActiveProjectFrame(root) else { return }
            let ackID = root["request_id"] as? String ?? payload["audio_id"] as? String ?? UUID().uuidString
            setTransientAck(payload["ack_text"] as? String, id: ackID, projectKey: frameProjectKey(root) ?? activeProjectKey, ttlMilliseconds: ackTTLMilliseconds(from: payload))
            if let audioID = payload["audio_id"] as? String, audioID.isEmpty == false {
                audioCoordinator.noteFastAckAudioID(audioID)
            }
        }
        if let projectDict = payload["project"] as? [String: Any], let project = LogosProject.from(dictionary: projectDict) {
            upsertProject(project)
            handleProjectStateUpdate(project: project, op: op, requestID: root["request_id"] as? String)
        }
        if let messageDict = payload["message"] as? [String: Any], let message = LogosMessage.from(dictionary: messageDict) {
            let frameRequestID = root["request_id"] as? String
            let messageRequestID = message.metadataRequestID ?? frameRequestID
            let progressRequestID = progressActivityManager.progressRoutingRequestID(for: message, frameRequestID: frameRequestID)
            if message.role != "user", progressActivityManager.isSuppressedRunRequestID(messageRequestID) || progressActivityManager.isSuppressedRunRequestID(progressRequestID) {
                return
            }
            if progressActivityManager.shouldRouteMessageToProgress(message, requestID: progressRequestID) {
                progressActivityManager.appendProgressEvent(
                    requestID: progressRequestID,
                    projectKey: message.projectKey,
                    sessionID: message.sessionID,
                    kind: progressActivityManager.progressEventKind(for: message),
                    text: message.content,
                    eventID: message.messageID
                )
                if progressActivityManager.shouldPersistProgressMessage(message) {
                    messageManager.persistAndRefresh(message)
                }
                return
            }
            let didClearProgressActivity = progressActivityManager.shouldClearProgressActivity(for: message, requestID: messageRequestID)
            if didClearProgressActivity {
                progressActivityManager.completeProgressActivity(requestID: messageRequestID, finalMessage: message, finalStatus: progressActivityManager.progressFinalStatus(for: message), failureMessage: message.metadataIsError ? message.content : nil)
                runStatus = .idle
            }
            messageManager.applyPersistedMessage(message)
            await notificationRouter.fulfillPendingFinishedNotificationRouteIfPossible()
            if message.projectKey == activeProjectKey && message.role != "user" && (op == "message_appended" || op == "message_updated") && progressActivityManager.isSuppressedRunRequestID(messageRequestID) == false {
                clearAck()
            }
            await maybeAutoPlayLiveAssistantMessage(message, op: op, requestID: messageRequestID, matchedCurrentRun: didClearProgressActivity)
        }
    }

    private func handleProjectStateUpdate(project: LogosProject, op: String?, requestID: String?) {
        switch op {
        case "project_created":
            pendingProjectSwitchRequestID = nil
            pendingProjectSwitchTarget = nil
            activeProjectKey = project.projectKey
        case "active_project_changed":
            let matchesPendingSwitch = requestID != nil
                && requestID == pendingProjectSwitchRequestID
                && project.projectKey == pendingProjectSwitchTarget
            guard matchesPendingSwitch || project.projectKey == activeProjectKey else { return }
            if matchesPendingSwitch {
                pendingProjectSwitchRequestID = nil
                pendingProjectSwitchTarget = nil
            }
            activeProjectKey = project.projectKey
        default:
            return
        }
    }

    private func handleRunStatus(_ root: [String: Any]) {
        guard isActiveProjectFrame(root) else { return }
        guard let payload = root["payload"] as? [String: Any], let statusRaw = payload["status"] as? String else { return }
        let previous = runStatus
        let next = LogosRunStatus(rawValue: statusRaw) ?? .error
        let requestID = root["request_id"] as? String
        if isInterruptedRunStatus(payload) {
            guard progressActivityManager.activeRunInterruptionMatches(requestID) else { return }
            progressActivityManager.finishProgressRun(
                requestID: requestID,
                finalStatus: .interrupted,
                failureMessage: interruptionFailureMessage(reason: payload["reason"] as? String),
                suppressLateFrames: true
            )
            return
        }
        if previous == .cancelling {
            if isCurrentCancelTerminalRunStatus(root: root, payload: payload, status: next) {
                progressActivityManager.finishProgressRun(finalStatus: .stopped, suppressLateFrames: true)
            }
            return
        }
        if payload["cancelled"] as? Bool == true, isTerminalRunStatus(next) {
            progressActivityManager.finishProgressRun(finalStatus: .stopped, suppressLateFrames: true)
            return
        }
        if next == .error, progressActivityManager.activeRunErrorMatches(requestID) {
            let message = payload["message"] as? String
                ?? payload["error"] as? String
                ?? "Hermes run failed."
            progressActivityManager.finishProgressRun(requestID: requestID, finalStatus: .failed, failureMessage: message, suppressLateFrames: true)
            return
        }
        if next == .idle, let activity = progressActivity, activity.timedOut == false, activity.isComplete == false {
            if progressActivityManager.idleRunStatusMatchesActiveProgress(requestID: requestID, projectKey: frameProjectKey(root)) {
                progressActivityManager.completeProgressActivity(requestID: requestID, finalStatus: .complete)
                clearOutstandingOutboundRequestID(requestID)
                runStatus = .idle
                clearAck()
            } else {
                runStatus = .running
            }
            return
        }
        runStatus = next
        if next == .cancelling {
            progressActivityManager.suppressCurrentRunRequestIDs()
            requiresScopedLiveResponse = true
        }
        if next == .cancelling || next == .awaitingApproval || next == .awaitingClarification {
            suspendStaleTimeout()
        }
        if next == .running || next == .queued {
            if let requestID, progressActivityManager.isActiveRunRequestID(requestID) {
                scheduleStaleTimeout(requestID: requestID, projectKey: frameProjectKey(root) ?? activeProjectKey)
            }
        }
        if isTerminalRunStatus(next) {
            suspendStaleTimeout()
            clearAck()
        }
        interactionController.applyRunStatusTransition(previous: previous, next: next)
    }

    private func isInterruptedRunStatus(_ payload: [String: Any]) -> Bool {
        if boolValue(payload["interrupted"]) == true { return true }
        return payload["final_status"] as? String == ProgressActivityFinalStatus.interrupted.rawValue
    }

    private func interruptionFailureMessage(reason: String?) -> String {
        switch reason {
        case "gateway_restarting":
            return "Hermes restarted before this run finished."
        case "gateway_shutting_down":
            return "Hermes shut down before this run finished."
        default:
            return "Logos reconnected after Hermes restarted; this run may have been interrupted."
        }
    }

    private func maybeAutoPlayLiveAssistantMessage(_ message: LogosMessage, op: String?, requestID: String?, matchedCurrentRun: Bool = false) async {
        guard connectionState == .connected, logosConnection.hasOpenSocket else { return }
        guard message.projectKey == activeProjectKey else { return }
        guard runStatus != .cancelling else { return }
        guard progressActivityManager.isSuppressedRunRequestID(requestID) == false else { return }
        var matchedActiveRun = matchedCurrentRun
        guard message.status == "persisted", message.role != "user", message.isFinal, message.isProgressUpdate == false else { return }
        guard op == "message_appended" || op == "message_updated" else { return }
        if let requestID, requestID.isEmpty == false, outstandingOutboundResponseRequestIDs.contains(requestID) {
            clearOutstandingOutboundRequestID(requestID)
            progressActivityManager.completeProgressActivity(requestID: requestID, finalMessage: message, finalStatus: progressActivityManager.progressFinalStatus(for: message), failureMessage: message.metadataIsError ? message.content : nil)
            runStatus = .idle
            matchedActiveRun = true
        } else if let progress = progressActivity {
            guard let requestID, requestID.isEmpty == false, requestID == progress.requestID else { return }
            if let progressSessionID = progress.sessionID, progressSessionID != message.sessionID {
                return
            }
            if progress.isComplete, let completedFinalMessageID = progress.completedFinalMessageID, completedFinalMessageID != message.id {
                return
            }
            matchedActiveRun = true
        } else if let pendingOutboundResponseRequestID {
            guard let requestID, requestID.isEmpty == false, requestID == pendingOutboundResponseRequestID else { return }
            clearOutstandingOutboundRequestID(requestID)
            progressActivityManager.completeProgressActivity(requestID: requestID, finalMessage: message, finalStatus: progressActivityManager.progressFinalStatus(for: message), failureMessage: message.metadataIsError ? message.content : nil)
            runStatus = .idle
            matchedActiveRun = true
        }
        if requiresScopedLiveResponse, matchedActiveRun == false { return }
        await notificationRouter.autoPlayLiveAssistantMessageIfNeeded(message)
    }

    private func upsertProject(_ project: LogosProject) {
        if let index = projects.firstIndex(where: { $0.projectKey == project.projectKey }) {
            projects[index] = project
        } else {
            projects.insert(project, at: 0)
        }
    }

    private func handlePendingTextSendFailure(messageID: String, projectKey: String, requestID: String, error _: Error) {
        clearOutstandingOutboundRequestID(requestID)
        progressActivityManager.clearProgressActivity(requestID: requestID)
        if outstandingOutboundResponseRequestIDs.isEmpty && pendingOutboundResponseRequestID == nil && progressActivity?.requestID != requestID {
            suspendStaleTimeout()
        }
        messageManager.removePendingMessage(messageID: messageID)
        if projectKey == activeProjectKey {
            messageManager.refreshMessages()
        }
    }

    private func handleFinalSpeechSendSuccess(inputID: String) {
        inFlightFinalSpeechDrafts.removeValue(forKey: inputID)
    }

    private func handleFinalSpeechSendFailure(_ draft: UndeliveredSpeechDraft, requestID: String, error: Error) {
        guard inFlightFinalSpeechDrafts.removeValue(forKey: draft.inputID) != nil else { return }
        clearOutstandingOutboundRequestID(requestID)
        progressActivityManager.clearProgressActivity(requestID: requestID)
        if outstandingOutboundResponseRequestIDs.isEmpty && pendingOutboundResponseRequestID == nil && progressActivity?.requestID != requestID {
            suspendStaleTimeout()
        }
        messageManager.removePendingMessage(messageID: draft.inputID)
        messageManager.refreshMessages()
        undeliveredSpeechDraft = UndeliveredSpeechDraft(
            inputID: draft.inputID,
            projectKey: draft.projectKey,
            text: draft.text,
            reason: error.localizedDescription
        )
        recordError("Speech was not sent: \(error.localizedDescription)")
    }

    private func restoreInFlightFinalSpeechDrafts(reason: String) {
        guard inFlightFinalSpeechDrafts.isEmpty == false else { return }
        let drafts = inFlightFinalSpeechDrafts.values.sorted { $0.inputID < $1.inputID }
        for draft in drafts {
            messageManager.removePendingMessage(messageID: draft.inputID)
        }
        inFlightFinalSpeechDrafts.removeAll()
        messageManager.refreshMessages()
        if let draft = drafts.last {
            undeliveredSpeechDraft = UndeliveredSpeechDraft(
                inputID: draft.inputID,
                projectKey: draft.projectKey,
                text: draft.text,
                reason: reason
            )
        }
    }
}

// MARK: - Message-list forwarding (WS1 P5)

extension LogosClient {
    /// Re-exposes the manager's visible thread so existing views/tests reading `client.messages`
    /// keep working (get-only, matching the original `@Published private(set)`).
    var messages: [LogosMessage] { messageManager.messages }
}

extension LogosClient: MessageManagerHost {
    var messageActiveProjectKey: String { activeProjectKey }

    var messageDeviceID: String { settings.deviceID }

    @discardableResult
    func sendMessageFrame(_ frame: [String: Any], onCompletion: (@MainActor @Sendable (Result<Void, Error>) -> Void)?) async -> Bool {
        await sendFrame(frame, onCompletion: onCompletion)
    }

    func messageAnchoredMessages(forProjectKey projectKey: String) -> [LogosMessage] {
        notificationRouter.anchoredMessages(forProjectKey: projectKey)
    }
}

// MARK: - Audio playback forwarding (WS1 P5)

extension LogosClient {
    /// Re-exposes the coordinator's overlay so existing views/tests reading `client.audioPlaybackOverlay`
    /// keep working (get-only, matching the original `@Published private(set)`).
    var audioPlaybackOverlay: AudioPlaybackOverlayState? { audioCoordinator.audioPlaybackOverlay }

    /// Re-exposes the coordinator's status (settable, matching the original `@Published var`).
    var playbackStatus: String? {
        get { audioCoordinator.playbackStatus }
        set { audioCoordinator.playbackStatus = newValue }
    }
}

extension LogosClient: AudioCoordinatorHost {
    var audioDeviceID: String { settings.deviceID }

    var audioActiveProjectKey: String { activeProjectKey }

    @discardableResult
    func ensureAudioConnected(_ action: String) -> Bool {
        ensureConnectedForUserAction(action)
    }

    @discardableResult
    func sendAudioFrame(_ frame: [String: Any], onCompletion: (@MainActor @Sendable (Result<Void, Error>) -> Void)?) async -> Bool {
        await sendFrame(frame, onCompletion: onCompletion)
    }

    func audioFrameProjectKey(_ root: [String: Any]) -> String? {
        frameProjectKey(root)
    }

    func recordAudioPlaybackError(_ message: String) {
        clearAck()
        logError(message, source: .audio)
    }

    func clearAutoPlayedMessageKey(_ key: String) {
        notificationRouter.clearAutoPlayedMessageKey(key)
    }

    func clearFulfilledNotificationRouteKey(_ key: String) {
        notificationRouter.clearFulfilledNotificationRouteKey(key)
    }
}

// MARK: - Progress-activity forwarding (WS1 P5)

extension LogosClient {
    /// Re-exposes the manager's progress overlay so existing views/tests reading
    /// `client.progressActivity` keep working (get-only, matching the original `@Published private(set)`).
    var progressActivity: ProgressActivityState? { progressActivityManager.progressActivity }

    /// Re-exposes the manager's reconnect banner (get-only, matching the original `@Published private(set)`).
    var connectionRetryState: ConnectionRetryState? { progressActivityManager.connectionRetryState }
}

extension LogosClient: ProgressActivityManagerHost {
    var progressActiveProjectKey: String { activeProjectKey }

    var progressRunStatus: LogosRunStatus {
        get { runStatus }
        set { runStatus = newValue }
    }

    var progressPendingOutboundResponseRequestID: String? {
        get { pendingOutboundResponseRequestID }
        set { pendingOutboundResponseRequestID = newValue }
    }

    var progressOutstandingOutboundResponseRequestIDs: Set<String> { outstandingOutboundResponseRequestIDs }

    var progressIsConnected: Bool { connectionState == .connected }

    var progressHasOpenSocket: Bool { logosConnection.hasOpenSocket }

    var progressCanAutoRetryConnection: Bool { canAutoRetryConnection }

    func clearProgressOutstandingOutboundRequestID(_ requestID: String?) {
        clearOutstandingOutboundRequestID(requestID)
    }

    func clearAllProgressOutstandingOutboundRequestIDs() {
        outstandingOutboundResponseRequestIDs.removeAll()
    }

    func scheduleProgressStaleTimeout(requestID: String, projectKey: String) {
        scheduleStaleTimeout(requestID: requestID, projectKey: projectKey)
    }

    func suspendProgressStaleTimeout() {
        suspendStaleTimeout()
    }

    func persistProgressMessage(_ message: LogosMessage) {
        messageManager.persistAndRefresh(message)
    }

    func isProgressTerminalAssistantMessage(_ message: LogosMessage) -> Bool {
        messageManager.isExplicitTerminalAssistantMessage(message)
    }

    func clearAckForProgress() {
        clearAck()
    }

    func clearInteractionStateForProgress() {
        interactionController.clearInteractionStateForProgress()
    }

    func clearAudioPlaybackForProgress() {
        audioCoordinator.clearAudioPlaybackForProjectSwitch()
    }

    func setRequiresScopedLiveResponse(_ value: Bool) {
        requiresScopedLiveResponse = value
    }

    func clearPendingCancelRequestID() {
        pendingCancelRequestID = nil
    }

    @discardableResult
    func sendProgressText(_ text: String) async -> Bool {
        await sendText(text)
    }

    @discardableResult
    func sendProgressSpeech(text: String) async -> Bool {
        let inputID = "voice-retry-\(UUID().uuidString)"
        let startedAtMilliseconds = Int64(Date().timeIntervalSince1970 * 1000)
        return await sendSpeech(text: text, isFinal: true, inputID: inputID, partialSeq: 0, startedAtMilliseconds: startedAtMilliseconds)
    }

    func reconnectForRetry() {
        logosConnection.reconnectForRetry()
    }

    func progressFrameProjectKey(_ root: [String: Any]) -> String? {
        frameProjectKey(root)
    }

    func progressIsActiveProjectFrame(_ root: [String: Any]) -> Bool {
        isActiveProjectFrame(root)
    }

    func progressBoolValue(_ value: Any?) -> Bool? {
        boolValue(value)
    }

    func progressIntegerValue(_ value: Any?) -> Int? {
        integerValue(value)
    }
}

// MARK: - Interaction forwarding (WS1 P5)

extension LogosClient {
    /// Re-exposes the controller's approval card so existing views/tests reading `client.approvalCard`
    /// keep working (get-only, matching the original `@Published private(set)`).
    var approvalCard: ApprovalCard? { interactionController.approvalCard }

    /// Re-exposes the controller's clarify card (get-only, matching the original `@Published private(set)`).
    var clarifyCard: ClarifyCard? { interactionController.clarifyCard }

    /// Re-exposes the controller's pending interaction-response id (get-only, matching the original
    /// `@Published private(set)`).
    var pendingInteractionResponseID: String? { interactionController.pendingInteractionResponseID }
}

extension LogosClient: InteractionControllerHost {
    var interactionActiveProjectKey: String { activeProjectKey }

    var interactionRunStatus: LogosRunStatus {
        get { runStatus }
        set { runStatus = newValue }
    }

    var interactionDeviceID: String { settings.deviceID }

    @discardableResult
    func ensureInteractionConnected(_ action: String) -> Bool {
        ensureConnectedForUserAction(action)
    }

    @discardableResult
    func sendInteractionFrame(_ frame: [String: Any], onCompletion: (@MainActor @Sendable (Result<Void, Error>) -> Void)?) async -> Bool {
        await sendFrame(frame, onCompletion: onCompletion)
    }

    func suspendInteractionStaleTimeout() {
        suspendStaleTimeout()
    }

    func setInteractionTransientAck(_ text: String?, id: String?, projectKey: String?) {
        setTransientAck(text, id: id, projectKey: projectKey)
    }

    func clearInteractionAck() {
        clearAck()
    }

    func clearInteractionAck(matchingID id: String, projectKey: String) {
        clearAck(matching: id, projectKey: projectKey)
    }
}

// MARK: - Notification-router forwarding (WS1 P5)

extension LogosClient {
    /// Re-exposes the router's thread-focus request so existing views/tests reading
    /// `client.threadFocusRequest` keep working (get-only, matching the original `@Published private(set)`).
    var threadFocusRequest: ThreadFocusRequest? { notificationRouter.threadFocusRequest }
}

extension LogosClient: NotificationRouterHost {
    var notificationActiveProjectKey: String {
        get { activeProjectKey }
        set { activeProjectKey = newValue }
    }

    var notificationDeviceID: String { settings.deviceID }

    var notificationIsConnected: Bool { connectionState == .connected }

    var notificationHasOpenSocket: Bool { logosConnection.hasOpenSocket }

    func notificationConnect() {
        connect()
    }

    @discardableResult
    func sendNotificationFrame(_ frame: [String: Any], onCompletion: (@MainActor @Sendable (Result<Void, Error>) -> Void)?) async -> Bool {
        await sendFrame(frame, onCompletion: onCompletion)
    }

    func notificationRequestMessages(afterServerSeq: Int) async {
        await requestMessages(afterServerSeq: afterServerSeq)
    }

    func notificationLatestServerSeq(projectKey: String) -> Int {
        messageManager.latestServerSeq(projectKey: projectKey)
    }

    func notificationStoredMessage(projectKey: String, sessionID: String?, messageID: String) -> LogosMessage? {
        messageManager.storedMessage(projectKey: projectKey, sessionID: sessionID, messageID: messageID)
    }

    func notificationLatestFinalMessage(projectKey: String, sessionID: String, atOrAfterServerSeq serverSeq: Int) -> LogosMessage? {
        messageManager.latestFinalMessage(projectKey: projectKey, sessionID: sessionID, atOrAfterServerSeq: serverSeq)
    }

    func notificationRefreshMessages() {
        messageManager.refreshMessages()
    }

    var notificationVisibleMessages: [LogosMessage] { messages }

    @discardableResult
    func requestAutoPlay(message: LogosMessage, autoPlayKey: String?, notificationRouteKey: String?) async -> Bool {
        await audioCoordinator.requestPlayback(message: message, mode: "final_auto", autoPlayKey: autoPlayKey, notificationRouteKey: notificationRouteKey)
    }
}

// MARK: - Connection forwarding (WS1 P5)

extension LogosClient: LogosConnectionHost {
    var connectionURLString: String { settings.urlString }

    var connectionDeviceSecret: String { settings.secret }

    var connectionDeviceID: String { settings.deviceID }

    var connectionActiveProjectKey: String { activeProjectKey }

    var connectionPinnedSPKISHA256: String? { settings.certSPKISHA256 }

    var connectionAutoConnect: Bool { settings.autoConnect }

    var connectionHasCompletedFirstConnection: Bool {
        get { settings.hasCompletedFirstConnection }
        set { settings.hasCompletedFirstConnection = newValue }
    }

    var connectionRunStatus: LogosRunStatus {
        get { runStatus }
        set { runStatus = newValue }
    }

    var connectionLastError: String? {
        get { lastError }
        set { lastError = newValue }
    }

    var connectionHasIncompleteProgressActivity: Bool { progressActivity?.isComplete == false }

    func handleInboundFrameString(_ string: String) async {
        await handleFrameString(string)
    }

    func noteReconnectReplayRequestID(_ requestID: String) {
        pendingReconnectReplayRequestID = requestID
    }

    func connectionLatestServerSeq() -> Int {
        messageManager.latestServerSeq()
    }

    func connectionDidCompleteHello() async {
        await notificationRouter.registerDeviceWithPendingToken()
        await requestProjects()
        await notificationRouter.processPendingNotificationRouteIfReady()
        await notificationRouter.processPendingFinalAutoPlayIfReady()
    }

    func connectionDidRegister() async {
        notificationRouter.clearPendingAPNSToken()
        await notificationRouter.processPendingNotificationRouteIfReady()
        await notificationRouter.processPendingFinalAutoPlayIfReady()
    }

    func connectionApplyClientConfig(from root: [String: Any]) {
        applyClientConfig(from: root)
    }

    func connectionClearConnectionRetryState() {
        progressActivityManager.clearConnectionRetryState()
    }

    func connectionNoteRetryFailure(_ message: String) {
        progressActivityManager.noteConnectionRetryFailure(message)
    }

    func connectionResetRunErrorIfNoActiveProgress() {
        progressActivityManager.resetRunErrorIfNoActiveProgress()
    }

    func connectionRecordError(_ message: String) {
        recordError(message)
    }

    func connectionLogConnectionError(_ message: String) {
        logError(message, source: .connection)
    }

    func connectionClearAck() {
        clearAck()
    }

    func connectionRestoreInFlightFinalSpeechDrafts(reason: String) {
        restoreInFlightFinalSpeechDrafts(reason: reason)
    }

    func connectionFailInterruptedRemoteAudioStream() {
        audioCoordinator.failInterruptedRemoteAudioStream()
    }

    func connectionFailInterruptedInteraction(clearCards: Bool) {
        interactionController.failInterruptedInteraction(clearCards: clearCards)
    }

    func connectionClearRunScopedStateForSocketClosure(runStatus: LogosRunStatus) {
        clearRunScopedStateForSocketClosure(runStatus: runStatus)
    }
}

enum LogosSocketSendError: LocalizedError {
    case staleConnection

    var errorDescription: String? {
        switch self {
        case .staleConnection:
            return "The socket changed before the frame send completed."
        }
    }
}
