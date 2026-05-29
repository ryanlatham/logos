import Foundation
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

private struct PendingNotificationRouteState {
    var route: LogosNotificationRoute
    var didRequestMessages: Bool = false
}


@MainActor
final class LogosClient: ObservableObject, WebSocketLifecycleObserving {
    @Published var settings = LogosSettings() {
        didSet {
            settings.persist()
            if settings.urlString != oldValue.urlString
                || settings.secret != oldValue.secret
                || settings.autoConnect != oldValue.autoConnect
            {
                clearConnectionRetryState()
            }
        }
    }
    @Published private(set) var connectionState: LogosConnectionState = .disconnected
    @Published private(set) var projects: [LogosProject] = []
    @Published var activeProjectKey: String = "default" {
        didSet {
            refreshMessages()
            if oldValue != activeProjectKey {
                clearRunScopedStateForProjectChange()
            } else {
                clearCardsNotMatchingActiveProject()
            }
        }
    }
    @Published private(set) var messages: [LogosMessage] = []
    @Published private(set) var runStatus: LogosRunStatus = .idle
    @Published private(set) var approvalCard: ApprovalCard?
    @Published private(set) var clarifyCard: ClarifyCard?
    @Published private(set) var pendingInteractionResponseID: String?
    @Published private(set) var threadFocusRequest: ThreadFocusRequest?
    @Published var lastError: String?
    @Published var playbackStatus: String?
    @Published private(set) var ackText: String?
    @Published private(set) var undeliveredSpeechDraft: UndeliveredSpeechDraft?
    @Published private(set) var progressActivity: ProgressActivityState?
    @Published private(set) var connectionRetryState: ConnectionRetryState?
    @Published private(set) var audioPlaybackOverlay: AudioPlaybackOverlayState?
    @Published private(set) var slashCommandCatalog: SlashCommandCatalog = .fallback
    @Published private(set) var slashCommandCompletion: SlashCommandCompletionResult = .empty

    private var task: (any WebSocketTasking)?
    private var connectionLifecycle = LogosConnectionLifecycle()
    private let store: SQLiteMessageStore
    private let socketFactory: any WebSocketTaskMaking
    private let audioPlayback: AudioPlaybackController
    private var staleTimeoutInterval: TimeInterval
    private var requestedAudioIDs = Set<String>()
    private var stoppedAudioIDs = Set<String>()
    private var activeAudioID: String?
    private var spectrumUpdateTask: Task<Void, Never>?
    private var spectrumUpdateAudioID: String?
    private var autoPlayedMessageKeys = Set<String>()
    private var pendingAPNSToken: String?
    private let pairingExchanger: any PairingCredentialExchanging
    private var isWebSocketOpen = false
    private var pendingMessages = PendingMessageBuffer()
    private var inFlightFinalSpeechDrafts: [String: UndeliveredSpeechDraft] = [:]
    private var ackState: FastAckState?
    private let staleTimeoutScheduler: any StaleTimeoutScheduling
    private let ackClearScheduler: any AckClearScheduling
    private var localNoticeMessages: [LogosMessage] = []
    private var localNoticeSequence = 0
    private var pendingCancelRequestID: String?
    private var pendingCommandCatalogRequestID: String?
    private var pendingCommandCompletionRequestID: String?
    private var pendingReconnectReplayRequestID: String?
    private var pendingOutboundResponseRequestID: String?
    private var outstandingOutboundResponseRequestIDs = Set<String>()
    private var suppressedRunRequestIDs = Set<String>()
    private var requiresScopedLiveResponse = false
    private var pendingProjectSwitchRequestID: String?
    private var pendingProjectSwitchTarget: String?
    private var reconnectTask: Task<Void, Never>?
    private var connectionRetryAttemptCount = 0
    private var connectionRetryEventSequence = 0
    private var pendingNotificationRoute: PendingNotificationRouteState?
    private var pendingFinalAutoPlayMessage: LogosMessage?
    private var fulfilledNotificationRouteKeys = Set<String>()
    private var notificationRouteAnchors: [String: LogosMessage] = [:]
    private var threadFocusRequestSequence = 0
    private var notificationPlaybackSceneActive = false
    private var playbackAutoPlayKeysByAudioID: [String: String] = [:]
    private var playbackNotificationRouteKeysByAudioID: [String: String] = [:]
    private var audioPlaybackStreamTimeoutAudioID: String?
    private var audioPlaybackStreamTimeoutTask: Task<Void, Never>?

    private static let staleSilenceNoticeText = "Logos has not heard from Hermes in a while. The run may still be working; waiting for the next adapter update."
    private static let maxStaleTimeoutInterval: TimeInterval = 86_400
    private static let maxInboundFrameBytes = 2_000_000
    private static let stoppedAudioIDRetentionLimit = 128
    private static let maxConnectionRetryEvents = 8
    private static let maxNotificationRouteAnchors = 8
    private static let notificationReplayContextWindow = 25
    private static let audioPlaybackStreamTimeoutNanoseconds: UInt64 = 60_000_000_000

    init(
        store: SQLiteMessageStore = SQLiteMessageStore(),
        socketFactory: any WebSocketTaskMaking = URLSessionWebSocketTaskFactory(),
        pairingExchanger: any PairingCredentialExchanging = WebSocketPairingCredentialExchanger(),
        audioPlayback: AudioPlaybackController = AudioPlaybackController(),
        staleTimeoutInterval: TimeInterval = 900,
        staleTimeoutScheduler: (any StaleTimeoutScheduling)? = nil,
        ackClearScheduler: (any AckClearScheduling)? = nil
    ) {
        self.store = store
        self.socketFactory = socketFactory
        self.pairingExchanger = pairingExchanger
        self.audioPlayback = audioPlayback
        self.staleTimeoutInterval = min(max(0.001, staleTimeoutInterval), Self.maxStaleTimeoutInterval)
        self.staleTimeoutScheduler = staleTimeoutScheduler ?? TaskStaleTimeoutScheduler()
        self.ackClearScheduler = ackClearScheduler ?? TaskAckClearScheduler()
        messages = visibleMessages(from: store.loadMessages(projectKey: activeProjectKey))
        audioPlayback.onPlaybackFinished = { [weak self] audioID, succeeded in
            Task { @MainActor in
                guard let self, self.activeAudioID == audioID else { return }
                self.stopSpectrumUpdates(audioID: audioID)
                self.activeAudioID = nil
                self.requestedAudioIDs.remove(audioID)
                self.rememberStoppedAudioID(audioID)
                self.cancelAudioPlaybackStreamTimeout(audioID: audioID)
                if succeeded {
                    self.clearPlaybackRetryKeys(audioID: audioID, allowRetry: false)
                    self.updateAudioOverlay(
                        audioID: audioID,
                        phase: .finished,
                        detail: "Audio finished",
                        canPause: false,
                        canStop: false,
                        spectrumBins: Array(repeating: 0.12, count: 12)
                    )
                    self.playbackStatus = "Audio finished"
                    Task { @MainActor [weak self] in
                        try? await Task.sleep(nanoseconds: 3_000_000_000)
                        guard let self else { return }
                        if self.audioPlaybackOverlay?.audioID == audioID,
                           self.audioPlaybackOverlay?.phase == .finished {
                            self.audioPlaybackOverlay = nil
                            self.playbackStatus = nil
                        }
                    }
                } else {
                    self.failAudioPlayback(
                        audioID: audioID,
                        message: "Audio playback ended unexpectedly. Check device volume and output route."
                    )
                }
            }
        }
    }

    func connectIfRequestedByEnvironment() {
        LogosConnectionLog.logger.info("connectIfRequestedByEnvironment called")
        connectIfAutoConnectEnabled()
    }

    func connectIfAutoConnectEnabled() {
        let shouldAttempt = LogosAutoConnectPolicy.shouldAttempt(
            autoConnect: settings.autoConnect,
            hasCompletedFirstConnection: settings.hasCompletedFirstConnection,
            connectionState: connectionState
        )
        LogosConnectionLog.logger.info("Auto-connect evaluated should_attempt=\(shouldAttempt, privacy: .public) auto_connect=\(self.settings.autoConnect, privacy: .public) has_completed_first_connection=\(self.settings.hasCompletedFirstConnection, privacy: .public) state=\(self.connectionState.rawValue, privacy: .public)")
        guard shouldAttempt else { return }
        connect(isAutomaticRetry: true)
    }

    func connect() {
        connect(isAutomaticRetry: false)
    }

    private func connect(isAutomaticRetry: Bool) {
        LogosConnectionLog.logger.info("Connect requested url=\(LogosConnectionLog.urlDescription(self.settings.urlString), privacy: .public) state=\(self.connectionState.rawValue, privacy: .public) device_id=\(self.settings.deviceID, privacy: .public) project_key=\(self.activeProjectKey, privacy: .public) has_secret=\(!self.settings.secret.isEmpty, privacy: .public) pending_apns_token=\(self.pendingAPNSToken != nil, privacy: .public)")
        if isAutomaticRetry == false {
            clearConnectionRetryState()
        }
        cancelCurrentSocket()
        lastError = nil
        resetRunErrorIfNoActiveProgress()
        guard let url = URL(string: settings.urlString) else {
            LogosConnectionLog.logger.error("Connect failed before socket creation: invalid adapter URL value=\(self.settings.urlString, privacy: .public)")
            clearConnectionRetryState()
            recordError("Invalid adapter URL")
            connectionState = .error
            return
        }
        guard settings.secret.isEmpty == false else {
            LogosConnectionLog.logger.error("Connect failed before socket creation: missing Logos device secret")
            clearConnectionRetryState()
            recordError("Missing Logos device secret")
            connectionState = .error
            return
        }
        let connectionID = connectionLifecycle.startConnection()
        isWebSocketOpen = false
        connectionState = .connecting
        LogosConnectionLog.logger.info("Connection lifecycle started connection_id=\(connectionID.uuidString, privacy: .public) url=\(LogosConnectionLog.urlDescription(url), privacy: .public)")
        let task = socketFactory.webSocketTask(with: url, lifecycleObserver: self)
        self.task = task
        LogosConnectionLog.logger.info("WebSocket task assigned task_id=\(LogosConnectionLog.taskIDDescription(task), privacy: .public) connection_id=\(connectionID.uuidString, privacy: .public)")
        task.resume()
    }

    func disconnect() {
        LogosConnectionLog.logger.info("Disconnect requested state=\(self.connectionState.rawValue, privacy: .public) open=\(self.isWebSocketOpen, privacy: .public) has_task=\(self.task != nil, privacy: .public)")
        clearConnectionRetryState()
        cancelCurrentSocket()
        lastError = nil
        clearRunScopedStateForSocketClosure(runStatus: .idle)
        connectionState = .disconnected
        LogosConnectionLog.logger.info("Disconnect complete state=\(self.connectionState.rawValue, privacy: .public)")
    }

    // App-layer encryption session (negotiated during hello); nil = cleartext / not negotiated.
    private var sessionCrypto: LogosSessionCrypto?
    private var pendingEncClientNonce: Data?

    private func cancelCurrentSocket() {
        let oldTask = task
        LogosConnectionLog.logger.info("Cancelling current socket has_task=\(oldTask != nil, privacy: .public) open=\(self.isWebSocketOpen, privacy: .public) state=\(self.connectionState.rawValue, privacy: .public) in_flight_final_speech=\(self.inFlightFinalSpeechDrafts.count, privacy: .public)")
        task = nil
        isWebSocketOpen = false
        sessionCrypto = nil
        pendingEncClientNonce = nil
        connectionLifecycle.invalidate()
        restoreInFlightFinalSpeechDrafts(reason: "The socket closed before Logos confirmed the final speech frame was sent.")
        oldTask?.cancel(with: .goingAway, reason: nil)
    }

    private func clearConnectionRetryState() {
        reconnectTask?.cancel()
        reconnectTask = nil
        connectionRetryAttemptCount = 0
        connectionRetryState = nil
    }

    private var canAutoRetryConnection: Bool {
        settings.autoConnect
            && URL(string: settings.urlString) != nil
            && LogosSettings.normalizedSecret(settings.secret).isEmpty == false
    }

    private func resetRunErrorIfNoActiveProgress() {
        guard runStatus == .error else { return }
        guard progressActivity?.isComplete == false else {
            runStatus = .idle
            return
        }
    }

    private func noteConnectionRetryFailure(_ message: String) {
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
            guard self.connectionState == .error || self.connectionState == .disconnected else { return }
            self.connect(isAutomaticRetry: true)
        }
    }

    @discardableResult
    func sendText(_ text: String) -> Bool {
        guard ensureConnectedForUserAction("send a message") else { return false }
        guard runStatus != .cancelling else { return false }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let projectKey = activeProjectKey
        let pending = LogosMessage.pending(projectKey: projectKey, content: trimmed)
        let requestID = UUID().uuidString
        let sent = sendFrame([
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
            clearProgressActivity()
            startProgressActivity(requestID: requestID, projectKey: projectKey, retryRequest: .text(trimmed))
            suppressedRunRequestIDs.remove(requestID)
            outstandingOutboundResponseRequestIDs.insert(requestID)
            pendingOutboundResponseRequestID = requestID
            addPendingMessage(pending)
            runStatus = .running
            scheduleStaleTimeout(requestID: requestID, projectKey: projectKey)
            if Self.shouldRefreshCommandCatalog(afterSending: trimmed) {
                requestCommandCatalog()
            }
        }
        return sent
    }

    private static func shouldRefreshCommandCatalog(afterSending text: String) -> Bool {
        let firstToken = text.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
        return firstToken == "/reload-skills" || firstToken == "/reload-mcp"
    }

    @discardableResult
    func sendSpeech(text: String, isFinal: Bool, inputID: String, partialSeq: Int, startedAtMilliseconds: Int64) -> Bool {
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
        if isFinal {
            inFlightFinalSpeechDrafts[inputID] = failedDraft
        }
        let requestID = UUID().uuidString
        let sent = sendFrame(LogosSpeechFrame.make(
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
            inFlightFinalSpeechDrafts.removeValue(forKey: inputID)
        } else if sent, isFinal {
            clearProgressActivity()
            startProgressActivity(requestID: requestID, projectKey: projectKey, retryRequest: .speech(text: trimmed))
            suppressedRunRequestIDs.remove(requestID)
            outstandingOutboundResponseRequestIDs.insert(requestID)
            pendingOutboundResponseRequestID = requestID
            addPendingMessage(pending)
            runStatus = .running
            scheduleStaleTimeout(requestID: requestID, projectKey: projectKey)
        }
        return sent
    }

    private func startProgressActivity(requestID: String, projectKey: String, sessionID: String? = nil, retryRequest: ProgressRetryRequest? = nil) {
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
        guard connectionState == .connected, task != nil, isWebSocketOpen else { return false }
        guard runStatus == .idle else { return false }
        guard let activity = progressActivity,
              activity.finalStatus == .failed || activity.finalStatus == .interrupted,
              let retryRequest = activity.retryRequest
        else { return false }
        switch retryRequest {
        case .text(let text):
            return sendText(text)
        case .speech(let text):
            let inputID = "voice-retry-\(UUID().uuidString)"
            let startedAtMilliseconds = Int64(Date().timeIntervalSince1970 * 1000)
            return sendSpeech(text: text, isFinal: true, inputID: inputID, partialSeq: 0, startedAtMilliseconds: startedAtMilliseconds)
        }
    }

    func clearUndeliveredSpeechDraft(id: String) {
        guard undeliveredSpeechDraft?.id == id else { return }
        undeliveredSpeechDraft = nil
    }

    func requestProjects() {
        LogosConnectionLog.logger.info("Requesting project list active_project=\(self.activeProjectKey, privacy: .public)")
        sendFrame([
            "type": "list_projects",
            "request_id": UUID().uuidString,
            "device_id": settings.deviceID,
            "payload": ["limit": 50]
        ])
    }

    @discardableResult
    func requestCommandCatalog(includeUnavailable: Bool = true) -> Bool {
        guard connectionState == .connected, task != nil, isWebSocketOpen else { return false }
        let requestID = UUID().uuidString
        pendingCommandCatalogRequestID = requestID
        return sendFrame([
            "type": "commands_get",
            "request_id": requestID,
            "device_id": settings.deviceID,
            "project_key": activeProjectKey,
            "payload": ["include_unavailable": includeUnavailable]
        ])
    }

    @discardableResult
    func requestSlashCommandCompletion(text: String) -> Bool {
        guard connectionState == .connected, task != nil, isWebSocketOpen else { return false }
        guard text.hasPrefix("/"), text.count <= 500, text.rangeOfCharacter(from: .controlCharacters) == nil else { return false }
        let requestID = UUID().uuidString
        pendingCommandCompletionRequestID = requestID
        return sendFrame([
            "type": "commands_complete",
            "request_id": requestID,
            "device_id": settings.deviceID,
            "project_key": activeProjectKey,
            "payload": [
                "text": text,
                "catalog_version": slashCommandCatalog.catalogVersion
            ]
        ])
    }

    func registerDevice(apnsToken: String?) {
        if let token = apnsToken, token.isEmpty == false {
            pendingAPNSToken = token
            LogosConnectionLog.logger.info("Stored pending APNS token for registration token_bytes=\(token.utf8.count, privacy: .public)")
        }
        guard isWebSocketOpen, connectionState == .connected else {
            LogosConnectionLog.logger.info("Device registration deferred until signed hello is authenticated pending_apns_token=\(self.pendingAPNSToken != nil, privacy: .public) state=\(self.connectionState.rawValue, privacy: .public) open=\(self.isWebSocketOpen, privacy: .public) has_task=\(self.task != nil, privacy: .public)")
            return
        }
        var payload: [String: Any] = [
            "display_name": UIDevice.current.name,
            "apns_environment": LogosAPNSEnvironment.resolved(),
            "capabilities": ["text", "speech", "projects", "approval", "clarification", "playback_audio", "notifications"]
        ]
        if let token = pendingAPNSToken, token.isEmpty == false {
            payload["apns_token"] = token
        }
        let sent = sendFrame([
            "type": "register_device",
            "request_id": UUID().uuidString,
            "device_id": settings.deviceID,
            "project_key": activeProjectKey,
            "payload": payload
        ])
        LogosConnectionLog.logger.info("Device registration send requested sent=\(sent, privacy: .public) device_id=\(self.settings.deviceID, privacy: .public) project_key=\(self.activeProjectKey, privacy: .public) includes_apns_token=\(payload["apns_token"] != nil, privacy: .public)")
    }

    func handleNotificationRoute(_ route: LogosNotificationRoute) {
        activeProjectKey = route.projectKey
        pendingNotificationRoute = PendingNotificationRouteState(route: route)
        if connectionState != .connected || task == nil || isWebSocketOpen == false {
            connect()
        } else {
            processPendingNotificationRouteIfReady()
        }
    }

    func updateSceneActivationForPlayback(isActive: Bool) {
        let wasActive = notificationPlaybackSceneActive
        notificationPlaybackSceneActive = isActive
        guard isActive, wasActive == false else { return }
        processPendingNotificationRouteIfReady()
        processPendingFinalAutoPlayIfReady()
    }

    func applyPairingRoute(_ route: LogosPairingRoute) async {
        LogosConnectionLog.logger.info("Applying Logos pairing route host=\(route.adapterHostDescription, privacy: .public) device_id=\(route.deviceID, privacy: .public) autoconnect=\(route.autoConnect, privacy: .public)")
        let previousState = connectionState
        let hadUsableConnection = previousState == .connected && task != nil && isWebSocketOpen
        lastError = nil
        do {
            if route.isExpired {
                throw LogosPairingExchangeError.expired
            }
            let credential = try await pairingExchanger.exchange(route: route)
            cancelCurrentSocket()
            settings.urlString = credential.adapterURL
            settings.deviceID = credential.deviceID
            settings.secret = LogosSettings.normalizedSecret(credential.deviceSecret)
            settings.autoConnect = route.autoConnect
            settings.hasCompletedFirstConnection = true
            lastError = nil
            if route.autoConnect {
                connect()
            } else {
                connectionState = .disconnected
            }
        } catch {
            LogosConnectionLog.logger.error("Pairing route failed error=\(error.localizedDescription, privacy: .public)")
            recordError("Logos pairing failed: \(error.localizedDescription)")
            if hadUsableConnection {
                connectionState = .connected
            } else {
                connectionState = .error
            }
        }
    }

    @discardableResult
    func createProject(title: String) -> Bool {
        guard ensureConnectedForUserAction("create a project") else { return false }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return sendFrame([
            "type": "new_project",
            "request_id": UUID().uuidString,
            "device_id": settings.deviceID,
            "payload": ["title": trimmed]
        ])
    }

    func switchProject(_ projectKey: String) {
        let requestID = UUID().uuidString
        pendingProjectSwitchRequestID = requestID
        pendingProjectSwitchTarget = projectKey
        activeProjectKey = projectKey
        sendFrame([
            "type": "switch_project",
            "request_id": requestID,
            "device_id": settings.deviceID,
            "payload": ["project_key": projectKey]
        ])
        requestMessages(afterServerSeq: 0)
    }

    func requestMessages(afterServerSeq: Int) {
        sendFrame([
            "type": "messages_get",
            "request_id": UUID().uuidString,
            "device_id": settings.deviceID,
            "project_key": activeProjectKey,
            "payload": [
                "after_server_seq": afterServerSeq,
                "limit": 100
            ]
        ])
    }

    private func processPendingNotificationRouteIfReady() {
        guard connectionState == .connected, task != nil, isWebSocketOpen else { return }
        guard var pending = pendingNotificationRoute else { return }
        if pending.didRequestMessages == false {
            requestMessages(afterServerSeq: notificationFetchAfterServerSeq(for: pending.route))
            pending.didRequestMessages = true
            pendingNotificationRoute = pending
        }
        if pending.route.kind.lowercased() == PrivateNotificationRouteKind.finished {
            fulfillPendingFinishedNotificationRouteIfPossible()
        } else {
            pendingNotificationRoute = nil
        }
    }

    private func notificationFetchAfterServerSeq(for route: LogosNotificationRoute) -> Int {
        if let serverSeq = route.serverSeq {
            return max(serverSeq - Self.notificationReplayContextWindow, 0)
        }
        return latestServerSeq(projectKey: route.projectKey)
    }

    private enum PrivateNotificationRouteKind {
        static let finished = "finished"
    }

    private func notificationRouteKey(_ route: LogosNotificationRoute) -> String {
        [
            route.kind.lowercased(),
            route.projectKey,
            route.sessionID ?? "",
            route.messageID ?? "",
            route.requestID ?? "",
            route.serverSeq.map(String.init) ?? ""
        ].joined(separator: "|")
    }

    private func fulfillPendingFinishedNotificationRouteIfPossible() {
        guard let pending = pendingNotificationRoute else { return }
        let route = pending.route
        guard route.kind.lowercased() == PrivateNotificationRouteKind.finished else { return }
        let routeKey = notificationRouteKey(route)
        guard fulfilledNotificationRouteKeys.contains(routeKey) == false else {
            pendingNotificationRoute = nil
            return
        }
        guard let message = notificationFinalMessage(for: route) else { return }
        anchorNotificationRouteMessage(message, routeKey: routeKey)
        guard notificationPlaybackSceneActive else { return }
        guard requestNotificationPlayback(message, routeKey: routeKey) else { return }
        pendingNotificationRoute = nil
        fulfilledNotificationRouteKeys.insert(routeKey)
    }

    private func anchorNotificationRouteMessage(_ message: LogosMessage, routeKey: String) {
        guard message.isProgressUpdate == false else { return }
        notificationRouteAnchors[message.id] = message
        trimNotificationRouteAnchors()
        refreshMessages()
        let isVisible = messages.contains { $0.id == message.id }
        LogosConnectionLog.logger.info("Finished notification route anchored project_key=\(message.projectKey, privacy: .public) session_id=\(message.sessionID, privacy: .public) message_id=\(message.messageID, privacy: .public) server_seq=\(message.serverSeq, privacy: .public) route_key=\(routeKey, privacy: .public) visible=\(isVisible, privacy: .public)")
        setThreadFocusRequest(
            targetMessageID: message.id,
            projectKey: message.projectKey,
            reason: .finishedNotification,
            routeKey: routeKey,
            serverSeq: message.serverSeq,
            isVisible: isVisible
        )
    }

    private func setThreadFocusRequest(
        targetMessageID: String,
        projectKey: String,
        reason: ThreadFocusReason,
        routeKey: String,
        serverSeq: Int,
        isVisible: Bool
    ) {
        threadFocusRequestSequence += 1
        let request = ThreadFocusRequest(
            id: "thread-focus-\(threadFocusRequestSequence)",
            projectKey: projectKey,
            targetMessageID: targetMessageID,
            reason: reason,
            createdAt: Date().timeIntervalSince1970
        )
        threadFocusRequest = request
        LogosConnectionLog.logger.info("Thread focus requested project_key=\(projectKey, privacy: .public) target_message_id=\(targetMessageID, privacy: .public) server_seq=\(serverSeq, privacy: .public) route_key=\(routeKey, privacy: .public) focus_id=\(request.id, privacy: .public) visible=\(isVisible, privacy: .public)")
    }

    func completeThreadFocusRequest(id: String) {
        guard threadFocusRequest?.id == id else { return }
        LogosConnectionLog.logger.info("Thread focus completed focus_id=\(id, privacy: .public) target_message_id=\(self.threadFocusRequest?.targetMessageID ?? "<none>", privacy: .public)")
        threadFocusRequest = nil
    }

    private func trimNotificationRouteAnchors() {
        guard notificationRouteAnchors.count > Self.maxNotificationRouteAnchors else { return }
        let removeCount = notificationRouteAnchors.count - Self.maxNotificationRouteAnchors
        let oldestKeys = notificationRouteAnchors
            .sorted { lhs, rhs in
                if lhs.value.serverSeq != rhs.value.serverSeq {
                    return lhs.value.serverSeq < rhs.value.serverSeq
                }
                if lhs.value.timestamp != rhs.value.timestamp {
                    return lhs.value.timestamp < rhs.value.timestamp
                }
                return lhs.key < rhs.key
            }
            .prefix(removeCount)
            .map(\.key)
        for key in oldestKeys {
            notificationRouteAnchors.removeValue(forKey: key)
        }
    }

    @discardableResult
    private func requestNotificationPlayback(_ message: LogosMessage, routeKey: String) -> Bool {
        requestFinalAutoPlayback(message, notificationRouteKey: routeKey)
    }

    @discardableResult
    private func requestFinalAutoPlayback(_ message: LogosMessage, notificationRouteKey: String? = nil) -> Bool {
        let key = message.id
        guard autoPlayedMessageKeys.contains(key) == false else {
            if pendingFinalAutoPlayMessage?.id == key {
                pendingFinalAutoPlayMessage = nil
            }
            return true
        }
        let sent = requestPlayback(message: message, mode: "final_auto", autoPlayKey: key, notificationRouteKey: notificationRouteKey)
        if sent {
            autoPlayedMessageKeys.insert(key)
            if pendingFinalAutoPlayMessage?.id == key {
                pendingFinalAutoPlayMessage = nil
            }
        }
        return sent
    }

    private func processPendingFinalAutoPlayIfReady() {
        guard notificationPlaybackSceneActive else { return }
        guard connectionState == .connected, task != nil, isWebSocketOpen else { return }
        guard let message = pendingFinalAutoPlayMessage else { return }
        guard message.projectKey == activeProjectKey else { return }
        _ = requestFinalAutoPlayback(message)
    }

    private func notificationFinalMessage(for route: LogosNotificationRoute) -> LogosMessage? {
        if let messageID = route.messageID, messageID.isEmpty == false {
            guard let message = store.message(projectKey: route.projectKey, sessionID: route.sessionID, messageID: messageID) else {
                return nil
            }
            guard message.status == "persisted",
                  message.role != "user",
                  message.isFinal,
                  message.hasFinalizedMetadata,
                  message.isProgressUpdate == false
            else {
                return nil
            }
            if let serverSeq = route.serverSeq, message.serverSeq < serverSeq {
                return nil
            }
            return message
        }
        guard let sessionID = route.sessionID, sessionID.isEmpty == false,
              let serverSeq = route.serverSeq else {
            return nil
        }
        return store.latestFinalMessage(projectKey: route.projectKey, sessionID: sessionID, atOrAfterServerSeq: serverSeq)
    }

    func approveCurrentRequest() {
        guard let approvalCard else { return }
        guard runStatus != .cancelling else { return }
        guard ensureConnectedForUserAction("approve request") else { return }
        let sent = sendFrame([
            "type": "approval_response",
            "request_id": approvalCard.id,
            "device_id": settings.deviceID,
            "project_key": approvalCard.projectKey,
            "payload": ["decision": "approve"]
        ]) { [weak self, requestID = approvalCard.id, projectKey = approvalCard.projectKey] result in
            guard case .failure = result else { return }
            self?.clearPendingInteractionResponse(requestID: requestID, projectKey: projectKey)
        }
        if sent {
            pendingInteractionResponseID = approvalCard.id
            setTransientAck("Approved. Waiting for Hermes…", id: approvalCard.id, projectKey: approvalCard.projectKey)
        }
    }

    func denyCurrentRequest() {
        guard let approvalCard else { return }
        guard runStatus != .cancelling else { return }
        guard ensureConnectedForUserAction("deny request") else { return }
        let sent = sendFrame([
            "type": "approval_response",
            "request_id": approvalCard.id,
            "device_id": settings.deviceID,
            "project_key": approvalCard.projectKey,
            "payload": ["decision": "deny"]
        ]) { [weak self, requestID = approvalCard.id, projectKey = approvalCard.projectKey] result in
            guard case .failure = result else { return }
            self?.clearPendingInteractionResponse(requestID: requestID, projectKey: projectKey)
        }
        if sent {
            pendingInteractionResponseID = approvalCard.id
            setTransientAck("Denied. Waiting for Hermes…", id: approvalCard.id, projectKey: approvalCard.projectKey)
        }
    }

    @discardableResult
    func answerClarification(_ text: String) -> Bool {
        guard let clarifyCard else { return false }
        guard runStatus != .cancelling else { return false }
        guard ensureConnectedForUserAction("answer clarification") else { return false }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let sent = sendFrame([
            "type": "clarify_response",
            "request_id": clarifyCard.id,
            "device_id": settings.deviceID,
            "project_key": clarifyCard.projectKey,
            "payload": [
                "clarify_id": clarifyCard.id,
                "text": trimmed
            ]
        ]) { [weak self, requestID = clarifyCard.id, projectKey = clarifyCard.projectKey] result in
            guard case .failure = result else { return }
            self?.clearPendingInteractionResponse(requestID: requestID, projectKey: projectKey)
        }
        if sent {
            pendingInteractionResponseID = clarifyCard.id
            setTransientAck("Clarification sent. Waiting for Hermes…", id: clarifyCard.id, projectKey: clarifyCard.projectKey)
        }
        return sent
    }

    func cancelRun() {
        guard ensureConnectedForUserAction("stop the run") else { return }
        guard runStatus != .cancelling else { return }
        let requestID = UUID().uuidString
        let sent = sendFrame([
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
        if sent {
            suppressCurrentRunRequestIDs()
            requiresScopedLiveResponse = true
            pendingCancelRequestID = requestID
            runStatus = .cancelling
            suspendStaleTimeout()
            clearInteractionStateForCancel()
            clearAck()
        }
    }

    func playback(message: LogosMessage) {
        _ = requestPlayback(message: message, mode: "full")
    }

    func pausePlayback() {
        guard let audioID = audioPlaybackOverlay?.audioID ?? activeAudioID else { return }
        guard audioPlayback.pause(audioID: audioID) else { return }
        stopSpectrumUpdates(audioID: audioID)
        activeAudioID = audioID
        updateAudioOverlay(audioID: audioID, phase: .paused, detail: "Paused", canPause: false, canStop: true)
        playbackStatus = nil
    }

    func resumePlayback() {
        guard let audioID = audioPlaybackOverlay?.audioID ?? activeAudioID else { return }
        do {
            guard try audioPlayback.resume(audioID: audioID) else { return }
            activeAudioID = audioID
            updateAudioOverlay(audioID: audioID, phase: .playing, detail: "Playing", canPause: true, canStop: true)
            startSpectrumUpdates(audioID: audioID)
            playbackStatus = nil
        } catch {
            failAudioPlayback(audioID: audioID, message: error.localizedDescription)
        }
    }

    func stopPlayback() {
        guard let audioID = audioPlaybackOverlay?.audioID ?? activeAudioID else { return }
        stoppedAudioIDs.insert(audioID)
        requestedAudioIDs.remove(audioID)
        stopSpectrumUpdates(audioID: audioID)
        cancelAudioPlaybackStreamTimeout(audioID: audioID)
        clearPlaybackRetryKeys(audioID: audioID, allowRetry: false)
        _ = audioPlayback.stop(audioID: audioID)
        if activeAudioID == audioID { activeAudioID = nil }
        audioPlaybackOverlay = nil
        playbackStatus = nil
    }

    func pauseAudioForSceneBackground() {
        let snapshots = audioPlayback.pauseForLifecycle(reason: "scene_background")
        guard let snapshot = snapshots.first else { return }
        stopSpectrumUpdates(audioID: snapshot.audioID)
        activeAudioID = snapshot.audioID
        updateAudioOverlay(audioID: snapshot.audioID, phase: .paused, detail: "Paused", canPause: false, canStop: true)
        playbackStatus = nil
    }

    func resumeAudioForSceneActive() {
        do {
            let results = try audioPlayback.resumeAfterLifecycle()
            guard let result = results.first, result.started else { return }
            activeAudioID = result.audioID
            updateAudioOverlay(audioID: result.audioID, phase: .playing, detail: "Playing", canPause: true, canStop: true)
            startSpectrumUpdates(audioID: result.audioID)
            playbackStatus = nil
        } catch {
            if let audioID = activeAudioID ?? audioPlaybackOverlay?.audioID {
                failAudioPlayback(audioID: audioID, message: error.localizedDescription)
            } else {
                recordAudioPlaybackError(error.localizedDescription)
            }
        }
    }

    func toggleProgressActivityExpanded() {
        guard var activity = progressActivity else { return }
        activity.isExpanded.toggle()
        progressActivity = activity
    }

    @discardableResult
    private func requestPlayback(message: LogosMessage, mode: String, autoPlayKey: String? = nil, notificationRouteKey: String? = nil) -> Bool {
        guard message.isProgressUpdate == false else { return false }
        guard ensureConnectedForUserAction("play audio") else { return false }
        let audioID = "ios-\(UUID().uuidString)"
        return requestPlaybackAudio(
            audioID: audioID,
            projectKey: message.projectKey,
            sessionID: message.sessionID,
            messageID: message.messageID,
            mode: mode,
            text: message.content,
            autoPlayKey: autoPlayKey,
            notificationRouteKey: notificationRouteKey
        )
    }

    @discardableResult
    private func requestPlaybackAudio(audioID: String, projectKey: String, sessionID: String?, messageID: String?, mode: String, text: String, autoPlayKey: String? = nil, notificationRouteKey: String? = nil) -> Bool {
        prepareForNewPlaybackRequest(audioID: audioID)
        requestedAudioIDs.insert(audioID)
        stoppedAudioIDs.remove(audioID)
        audioPlaybackOverlay = AudioPlaybackOverlayState(
            audioID: audioID,
            messageID: messageID,
            projectKey: projectKey,
            phase: .requesting,
            detail: "Requesting audio",
            spectrumBins: idleSpectrumBins(),
            canPause: false,
            canStop: true
        )
        playbackStatus = "Requesting audio"
        var payload: [String: Any] = [
            "audio_id": audioID,
            "mode": mode,
            "text": text
        ]
        if let messageID { payload["message_id"] = messageID }
        let sent = sendFrame([
            "type": "playback_audio",
            "request_id": UUID().uuidString,
            "device_id": settings.deviceID,
            "project_key": projectKey,
            "session_id": sessionID ?? "project:\(projectKey)",
            "payload": payload
        ]) { [weak self] result in
            guard case .failure = result else { return }
            if let autoPlayKey {
                self?.autoPlayedMessageKeys.remove(autoPlayKey)
            }
            if let notificationRouteKey {
                self?.fulfilledNotificationRouteKeys.remove(notificationRouteKey)
            }
            self?.clearFailedPlaybackRequest(audioID: audioID)
        }
        if sent {
            if let autoPlayKey {
                playbackAutoPlayKeysByAudioID[audioID] = autoPlayKey
            }
            if let notificationRouteKey {
                playbackNotificationRouteKeysByAudioID[audioID] = notificationRouteKey
            }
            scheduleAudioPlaybackStreamTimeout(audioID: audioID)
        } else {
            stoppedAudioIDs.insert(audioID)
            requestedAudioIDs.remove(audioID)
            if audioPlaybackOverlay?.audioID == audioID {
                audioPlaybackOverlay = nil
            }
            playbackStatus = nil
        }
        return sent
    }

    private func markStopped(_ audioID: String?) {
        guard let audioID, audioID.isEmpty == false else { return }
        stoppedAudioIDs.insert(audioID)
    }

    private func clearFailedPlaybackRequest(audioID: String) {
        stoppedAudioIDs.insert(audioID)
        requestedAudioIDs.remove(audioID)
        stopSpectrumUpdates(audioID: audioID)
        cancelAudioPlaybackStreamTimeout(audioID: audioID)
        clearPlaybackRetryKeys(audioID: audioID, allowRetry: true)
        if activeAudioID == audioID {
            activeAudioID = nil
        }
        if audioPlaybackOverlay?.audioID == audioID {
            audioPlaybackOverlay = nil
        }
        playbackStatus = nil
    }

    private func failAudioPlayback(audioID: String, message: String, exposeError: Bool = true) {
        rememberStoppedAudioID(audioID)
        requestedAudioIDs.remove(audioID)
        stopSpectrumUpdates(audioID: audioID)
        cancelAudioPlaybackStreamTimeout(audioID: audioID)
        clearPlaybackRetryKeys(audioID: audioID, allowRetry: true)
        _ = audioPlayback.stop(audioID: audioID)
        if activeAudioID == audioID {
            activeAudioID = nil
        }
        if audioPlaybackOverlay?.audioID == audioID {
            updateAudioOverlay(audioID: audioID, phase: .failed, detail: message, canPause: false, canStop: false, spectrumBins: idleSpectrumBins())
            scheduleFailedAudioOverlayDismissal(audioID: audioID)
        }
        playbackStatus = nil
        if exposeError {
            recordAudioPlaybackError(message)
        }
    }

    private func clearPlaybackRetryKeys(audioID: String, allowRetry: Bool) {
        let autoPlayKey = playbackAutoPlayKeysByAudioID.removeValue(forKey: audioID)
        let notificationRouteKey = playbackNotificationRouteKeysByAudioID.removeValue(forKey: audioID)
        guard allowRetry else { return }
        if let autoPlayKey {
            autoPlayedMessageKeys.remove(autoPlayKey)
        }
        if let notificationRouteKey {
            fulfilledNotificationRouteKeys.remove(notificationRouteKey)
        }
    }

    private func scheduleFailedAudioOverlayDismissal(audioID: String) {
        Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: 6_000_000_000)
            } catch {
                return
            }
            guard let self,
                  self.audioPlaybackOverlay?.audioID == audioID,
                  self.audioPlaybackOverlay?.phase == .failed
            else { return }
            self.audioPlaybackOverlay = nil
            self.playbackStatus = nil
        }
    }

    private func scheduleAudioPlaybackStreamTimeout(audioID: String) {
        audioPlaybackStreamTimeoutTask?.cancel()
        audioPlaybackStreamTimeoutAudioID = audioID
        audioPlaybackStreamTimeoutTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: Self.audioPlaybackStreamTimeoutNanoseconds)
            } catch {
                return
            }
            guard let self,
                  self.audioPlaybackStreamTimeoutAudioID == audioID,
                  self.requestedAudioIDs.contains(audioID),
                  self.audioPlaybackOverlay?.audioID == audioID
            else { return }
            switch self.audioPlaybackOverlay?.phase {
            case .requesting, .receiving:
                self.failAudioPlayback(audioID: audioID, message: "Audio stream timed out.")
            default:
                break
            }
        }
    }

    private func cancelAudioPlaybackStreamTimeout(audioID: String? = nil) {
        guard audioID == nil || audioPlaybackStreamTimeoutAudioID == audioID else { return }
        audioPlaybackStreamTimeoutTask?.cancel()
        audioPlaybackStreamTimeoutTask = nil
        audioPlaybackStreamTimeoutAudioID = nil
    }

    private func recordAudioPlaybackError(_ message: String) {
        clearAck()
        lastError = message
    }

    private func prepareForNewPlaybackRequest(audioID: String) {
        stopSpectrumUpdates()
        for requestedID in requestedAudioIDs where requestedID != audioID {
            stoppedAudioIDs.insert(requestedID)
            clearPlaybackRetryKeys(audioID: requestedID, allowRetry: false)
        }
        if audioPlaybackOverlay?.audioID != audioID {
            markStopped(audioPlaybackOverlay?.audioID)
            if let overlayAudioID = audioPlaybackOverlay?.audioID {
                clearPlaybackRetryKeys(audioID: overlayAudioID, allowRetry: false)
            }
        }
        if activeAudioID != audioID {
            markStopped(activeAudioID)
            if let activeAudioID {
                clearPlaybackRetryKeys(audioID: activeAudioID, allowRetry: false)
            }
        }
        audioPlayback.stopAll()
        requestedAudioIDs.removeAll()
        activeAudioID = nil
        cancelAudioPlaybackStreamTimeout()
    }

    private func clearAudioPlaybackForProjectSwitch() {
        stopSpectrumUpdates()
        for requestedID in requestedAudioIDs {
            stoppedAudioIDs.insert(requestedID)
            clearPlaybackRetryKeys(audioID: requestedID, allowRetry: false)
        }
        markStopped(audioPlaybackOverlay?.audioID)
        if let overlayAudioID = audioPlaybackOverlay?.audioID {
            clearPlaybackRetryKeys(audioID: overlayAudioID, allowRetry: false)
        }
        markStopped(activeAudioID)
        if let activeAudioID {
            clearPlaybackRetryKeys(audioID: activeAudioID, allowRetry: false)
        }
        audioPlayback.stopAll()
        requestedAudioIDs.removeAll()
        activeAudioID = nil
        cancelAudioPlaybackStreamTimeout()
        audioPlaybackOverlay = nil
        playbackStatus = nil
    }

    private func ensureConnectedForUserAction(_ action: String) -> Bool {
        guard task != nil, connectionState == .connected else {
            LogosConnectionLog.logger.warning("User action blocked because Logos is not connected action=\(action, privacy: .public) state=\(self.connectionState.rawValue, privacy: .public) open=\(self.isWebSocketOpen, privacy: .public) has_task=\(self.task != nil, privacy: .public)")
            recordError("Cannot \(action): Logos is not connected.")
            return false
        }
        return true
    }

    private func clearCardsNotMatchingActiveProject() {
        if let approvalCard, approvalCard.projectKey != activeProjectKey {
            self.approvalCard = nil
        }
        if let clarifyCard, clarifyCard.projectKey != activeProjectKey {
            self.clarifyCard = nil
        }
    }

    private func recordError(_ message: String) {
        clearAck()
        clearProgressActivity()
        lastError = message
    }

    private func updateAudioOverlay(audioID: String, phase: AudioPlaybackPhase, detail: String, canPause: Bool, canStop: Bool, spectrumBins: [Double]? = nil) {
        guard var overlay = audioPlaybackOverlay, overlay.audioID == audioID else { return }
        overlay.phase = phase
        overlay.detail = detail
        overlay.canPause = canPause
        overlay.canStop = canStop
        overlay.spectrumBins = spectrumBins ?? audioPlayback.spectrumBins(audioID: audioID, count: 12)
        audioPlaybackOverlay = overlay
    }

    private func idleSpectrumBins(count: Int = 12) -> [Double] {
        Array(repeating: 0.04, count: max(1, count))
    }

    private func startSpectrumUpdates(audioID: String) {
        stopSpectrumUpdates()
        spectrumUpdateAudioID = audioID
        spectrumUpdateTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: 50_000_000)
                } catch {
                    return
                }
                guard let self else { return }
                self.refreshPlaybackSpectrum(audioID: audioID)
            }
        }
    }

    private func stopSpectrumUpdates(audioID: String? = nil) {
        if let audioID, spectrumUpdateAudioID != audioID { return }
        spectrumUpdateTask?.cancel()
        spectrumUpdateTask = nil
        spectrumUpdateAudioID = nil
    }

    func refreshPlaybackSpectrumForTesting(audioID: String) {
        refreshPlaybackSpectrum(audioID: audioID)
    }

    private func refreshPlaybackSpectrum(audioID: String) {
        guard activeAudioID == audioID,
              stoppedAudioIDs.contains(audioID) == false,
              var overlay = audioPlaybackOverlay,
              overlay.audioID == audioID,
              overlay.phase == .playing
        else { return }
        overlay.spectrumBins = audioPlayback.spectrumBins(audioID: audioID, count: 12)
        audioPlaybackOverlay = overlay
    }

    private func appendProgressEvent(requestID: String, projectKey: String, sessionID: String?, kind: String, text: String, eventID: String? = nil) {
        guard projectKey == activeProjectKey else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return }
        guard isSuppressedRunRequestID(requestID) == false else { return }
        if outstandingOutboundResponseRequestIDs.contains(requestID) {
            clearOutstandingOutboundRequestID(requestID)
        } else if let pendingOutboundResponseRequestID {
            guard requestID == pendingOutboundResponseRequestID else { return }
            clearOutstandingOutboundRequestID(requestID)
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
        if runStatus != .cancelling {
            runStatus = .running
        }
        if runStatus == .cancelling {
            suspendStaleTimeout()
        } else {
            scheduleStaleTimeout(requestID: requestID, projectKey: projectKey)
        }
    }

    private func scheduleStaleTimeout(requestID: String, projectKey: String) {
        guard projectKey == activeProjectKey else { return }
        guard runStatus != .cancelling, runStatus != .awaitingApproval, runStatus != .awaitingClarification else { return }
        guard isActiveRunRequestID(requestID) else { return }
        staleTimeoutScheduler.schedule(after: staleTimeoutInterval) { [weak self] in
            self?.handleStaleTimeout(requestID: requestID, projectKey: projectKey)
        }
    }

    private func handleStaleTimeout(requestID: String, projectKey: String) {
        guard projectKey == activeProjectKey else { return }
        guard runStatus == .running || runStatus == .queued else { return }
        guard isActiveRunRequestID(requestID) else { return }
        let now = Date().timeIntervalSince1970
        if var activity = progressActivity, activity.requestID == requestID, activity.projectKey == projectKey {
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
        localNoticeSequence += 1
        let notice = LogosMessage.localNotice(
            projectKey: projectKey,
            requestID: requestID,
            sequence: localNoticeSequence,
            content: Self.staleSilenceNoticeText,
            timestamp: now
        )
        store.upsert(notice)
        localNoticeMessages.append(notice)
        refreshMessages()
        scheduleStaleTimeout(requestID: requestID, projectKey: projectKey)
    }

    private func suspendStaleTimeout() {
        staleTimeoutScheduler.cancel()
    }

    private func clearProgressActivity(requestID: String? = nil) {
        if let requestID, progressActivity?.requestID != requestID { return }
        suspendStaleTimeout()
        progressActivity = nil
    }

    private func completeProgressActivity(
        requestID: String? = nil,
        finalMessage: LogosMessage? = nil,
        finalStatus: ProgressActivityFinalStatus = .complete,
        failureMessage: String? = nil
    ) {
        if let requestID, progressActivity?.requestID != requestID { return }
        suspendStaleTimeout()
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

    nonisolated func webSocketDidOpen(taskID: ObjectIdentifier) {
        Task { @MainActor [weak self] in
            self?.handleSocketOpen(taskID: taskID)
        }
    }

    nonisolated func webSocketDidClose(taskID: ObjectIdentifier, closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        Task { @MainActor [weak self] in
            self?.handleSocketClose(taskID: taskID, closeCode: closeCode, reason: reason)
        }
    }

    nonisolated func webSocketDidFail(taskID: ObjectIdentifier, message: String) {
        Task { @MainActor [weak self] in
            self?.handleSocketFailure(taskID: taskID, message: message)
        }
    }

    private func handleSocketOpen(taskID: ObjectIdentifier) {
        guard let task, ObjectIdentifier(task) == taskID else {
            LogosConnectionLog.logger.warning("Ignoring stale WebSocket open callback task_id=\(String(describing: taskID), privacy: .public) current_task=\(LogosConnectionLog.taskIDDescription(self.task), privacy: .public)")
            return
        }
        isWebSocketOpen = true
        let connectionID = connectionLifecycle.activeConnectionID
        LogosConnectionLog.logger.info("WebSocket open accepted task_id=\(String(describing: taskID), privacy: .public) connection_id=\(connectionID.uuidString, privacy: .public); starting receive loop and signed hello")
        receiveLoop(connectionID: connectionID)
        sendHello()
    }

    private func handleSocketClose(taskID: ObjectIdentifier, closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        guard let task, ObjectIdentifier(task) == taskID else {
            LogosConnectionLog.logger.warning("Ignoring stale WebSocket close callback task_id=\(String(describing: taskID), privacy: .public) close_code=\(closeCode.rawValue, privacy: .public) current_task=\(LogosConnectionLog.taskIDDescription(self.task), privacy: .public)")
            return
        }
        let message = socketCloseMessage(closeCode: closeCode, reason: reason)
        LogosConnectionLog.logger.warning("WebSocket close accepted task_id=\(String(describing: taskID), privacy: .public) close_code=\(closeCode.rawValue, privacy: .public) reason=\(LogosConnectionLog.closeReasonDescription(reason), privacy: .public)")
        failCurrentSocket(message: message, retryable: true)
    }

    private func handleSocketFailure(taskID: ObjectIdentifier, message: String) {
        guard let task, ObjectIdentifier(task) == taskID else {
            LogosConnectionLog.logger.warning("Ignoring stale WebSocket failure callback task_id=\(String(describing: taskID), privacy: .public) message=\(message, privacy: .public) current_task=\(LogosConnectionLog.taskIDDescription(self.task), privacy: .public)")
            return
        }
        LogosConnectionLog.logger.error("WebSocket failure accepted task_id=\(String(describing: taskID), privacy: .public) message=\(message, privacy: .public)")
        failCurrentSocket(message: message, retryable: true)
    }

    private func failCurrentSocket(message: String, retryable: Bool, clearInteractionCards: Bool = true) {
        LogosConnectionLog.logger.error("Failing current socket message=\(message, privacy: .public) previous_state=\(self.connectionState.rawValue, privacy: .public) open=\(self.isWebSocketOpen, privacy: .public) in_flight_final_speech=\(self.inFlightFinalSpeechDrafts.count, privacy: .public)")
        self.task = nil
        isWebSocketOpen = false
        restoreInFlightFinalSpeechDrafts(reason: message)
        failInterruptedRemoteAudioStream()
        if connectionState != .disconnected || retryable {
            lastError = message
            clearAck()
            if progressActivity?.isComplete != false {
                runStatus = .idle
            }
            if clearInteractionCards {
                clearInteractionStateForCancel()
            } else if let pendingInteractionResponseID {
                clearPendingInteractionResponse(requestID: pendingInteractionResponseID, projectKey: activeProjectKey)
            }
            connectionState = .error
            if retryable {
                noteConnectionRetryFailure(message)
            } else {
                clearConnectionRetryState()
            }
        }
        LogosConnectionLog.logger.error("Socket failure state updated state=\(self.connectionState.rawValue, privacy: .public) last_error=\(self.lastError ?? "<none>", privacy: .public)")
    }

    private func failInterruptedRemoteAudioStream() {
        if let overlay = audioPlaybackOverlay {
            switch overlay.phase {
            case .requesting, .receiving:
                failAudioPlayback(
                    audioID: overlay.audioID,
                    message: "Audio stream interrupted. Reconnect and try again.",
                    exposeError: false
                )
                return
            default:
                break
            }
        }
        let interruptedAudioIDs = requestedAudioIDs.filter { $0 != activeAudioID }
        for audioID in interruptedAudioIDs {
            rememberStoppedAudioID(audioID)
            clearPlaybackRetryKeys(audioID: audioID, allowRetry: true)
            requestedAudioIDs.remove(audioID)
        }
        cancelAudioPlaybackStreamTimeout()
    }

    private func socketCloseMessage(closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) -> String {
        if let reason, let text = String(data: reason, encoding: .utf8), text.isEmpty == false {
            return "Logos socket closed: \(text)"
        }
        return "Logos socket closed with code \(closeCode.rawValue)."
    }

    private func sendHello() {
        let requestID = UUID().uuidString
        let timestampMilliseconds = Int64(Date().timeIntervalSince1970 * 1000)
        let nonce = UUID().uuidString
        // Offer app-layer encryption: send a fresh client nonce (bound into the signed v2
        // canonical) and the AEADs we support. The adapter chooses whether to negotiate.
        let encClientNonce = LogosSessionCrypto.randomNonce()
        let encClientNonceB64 = encClientNonce.base64EncodedString()
        pendingEncClientNonce = encClientNonce
        let signature = LogosAuthentication.signHello(
            secret: LogosSettings.normalizedSecret(settings.secret),
            deviceID: settings.deviceID,
            requestID: requestID,
            projectKey: activeProjectKey,
            timestampMilliseconds: timestampMilliseconds,
            nonce: nonce,
            encClientNonce: encClientNonceB64
        )
        let afterServerSeq = latestServerSeq()
        pendingReconnectReplayRequestID = requestID
        LogosConnectionLog.logger.info("Sending hello request_id=\(requestID, privacy: .public) device_id=\(self.settings.deviceID, privacy: .public) project_key=\(self.activeProjectKey, privacy: .public) after_server_seq=\(afterServerSeq, privacy: .public) timestamp_ms=\(timestampMilliseconds, privacy: .public)")
        let sent = sendFrame([
            "type": "hello",
            "request_id": requestID,
            "device_id": settings.deviceID,
            "project_key": activeProjectKey,
            "payload": [
                "timestamp_ms": timestampMilliseconds,
                "nonce": nonce,
                "signature": signature,
                "after_server_seq": afterServerSeq,
                "capabilities": ["text", "speech", "projects", "approval", "clarification", "playback_audio"],
                "enc_supported": ["chacha20-poly1305", "aes-256-gcm"],
                "enc_client_nonce": encClientNonceB64
            ]
        ], requiresAuthentication: false)
        LogosConnectionLog.logger.info("Hello send requested sent=\(sent, privacy: .public) request_id=\(requestID, privacy: .public)")
    }

    /// Derive the per-connection encryption session from the adapter's hello `enc` block, if it
    /// negotiated one. Absent `enc` (older adapter or LOGOS_ENC_MODE=off) keeps the session cleartext.
    private func setupSessionCrypto(from root: [String: Any]) {
        guard
            let payload = root["payload"] as? [String: Any],
            let enc = payload["enc"] as? [String: Any],
            let aeadName = enc["aead"] as? String,
            let aead = LogosAEAD(rawValue: aeadName),
            let serverNonceB64 = enc["enc_server_nonce"] as? String,
            let serverNonce = Data(base64Encoded: serverNonceB64),
            let clientNonce = pendingEncClientNonce
        else {
            sessionCrypto = nil
            pendingEncClientNonce = nil
            return
        }
        do {
            sessionCrypto = try LogosSessionCrypto.deriveSession(
                deviceSecret: LogosSettings.normalizedSecret(settings.secret),
                clientNonce: clientNonce,
                serverNonce: serverNonce,
                role: .client,
                aead: aead
            )
            LogosConnectionLog.logger.info("Logos session encryption negotiated aead=\(aeadName, privacy: .public)")
        } catch {
            sessionCrypto = nil
            LogosConnectionLog.logger.error("Failed to derive Logos session crypto")
        }
        pendingEncClientNonce = nil
    }

    @discardableResult
    private func sendFrame(
        _ frame: [String: Any],
        requiresAuthentication: Bool = true,
        onCompletion: ((Result<Void, Error>) -> Void)? = nil
    ) -> Bool {
        let summary = LogosConnectionLog.frameSummary(frame)
        guard let task, isWebSocketOpen else {
            LogosConnectionLog.logger.warning("Frame send blocked \(summary, privacy: .public) state=\(self.connectionState.rawValue, privacy: .public) open=\(self.isWebSocketOpen, privacy: .public) has_task=\(self.task != nil, privacy: .public)")
            if connectionState != .connecting {
                recordError("Not connected to Logos adapter. Reconnect before sending.")
                connectionState = .disconnected
            }
            return false
        }
        guard requiresAuthentication == false || connectionState == .connected else {
            LogosConnectionLog.logger.warning("Frame send blocked until signed hello is authenticated \(summary, privacy: .public) state=\(self.connectionState.rawValue, privacy: .public) open=\(self.isWebSocketOpen, privacy: .public)")
            return false
        }
        let connectionID = connectionLifecycle.activeConnectionID
        var workingFrame = frame
        if requiresAuthentication, let crypto = sessionCrypto, let payload = workingFrame["payload"] as? [String: Any] {
            // Seal the payload; routing fields stay cleartext for the adapter to route on.
            let header = workingFrame.filter { $0.key != "payload" }
            do {
                workingFrame["payload"] = try crypto.seal(header: header, payload: payload)
            } catch {
                LogosConnectionLog.logger.error("Failed to seal outbound Logos frame \(summary, privacy: .public)")
                return false
            }
        }
        do {
            let data = try JSONSerialization.data(withJSONObject: workingFrame, options: [])
            let string = String(decoding: data, as: UTF8.self)
            LogosConnectionLog.logger.info("Frame send queued \(summary, privacy: .public) bytes=\(data.count, privacy: .public) connection_id=\(connectionID.uuidString, privacy: .public)")
            task.send(.string(string)) { [weak self, weak task] error in
                Task { @MainActor in
                    guard let self else { return }
                    guard self.connectionLifecycle.accepts(connectionID), let task, self.isCurrentTask(task) else {
                        LogosConnectionLog.logger.warning("Frame send completed on stale connection \(summary, privacy: .public) connection_id=\(connectionID.uuidString, privacy: .public)")
                        onCompletion?(.failure(LogosSocketSendError.staleConnection))
                        return
                    }
                    if let error {
                        LogosConnectionLog.logger.error("Frame send failed \(summary, privacy: .public) error=\(LogosConnectionLog.errorDescription(error), privacy: .public) connection_id=\(connectionID.uuidString, privacy: .public)")
                        let frameType = frame["type"] as? String
                        let shouldKeepInteractionCards = frameType == "approval_response" || frameType == "clarify_response"
                        self.failCurrentSocket(message: error.localizedDescription, retryable: true, clearInteractionCards: shouldKeepInteractionCards == false)
                        onCompletion?(.failure(error))
                    } else {
                        LogosConnectionLog.logger.info("Frame send completed \(summary, privacy: .public) connection_id=\(connectionID.uuidString, privacy: .public)")
                        self.lastError = nil
                        onCompletion?(.success(()))
                    }
                }
            }
            return true
        } catch {
            LogosConnectionLog.logger.error("Frame serialization failed \(summary, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            recordError(error.localizedDescription)
            return false
        }
    }

    private func receiveLoop(connectionID: UUID) {
        guard let task else {
            LogosConnectionLog.logger.warning("Receive loop not started because task is nil connection_id=\(connectionID.uuidString, privacy: .public)")
            return
        }
        LogosConnectionLog.logger.info("Receive loop waiting connection_id=\(connectionID.uuidString, privacy: .public) task_id=\(LogosConnectionLog.taskIDDescription(task), privacy: .public)")
        task.receive { [weak self, weak task] result in
            Task { @MainActor in
                guard let self else { return }
                guard self.connectionLifecycle.accepts(connectionID), let task, self.isCurrentTask(task) else {
                    LogosConnectionLog.logger.warning("Receive result ignored for stale connection connection_id=\(connectionID.uuidString, privacy: .public)")
                    return
                }
                switch result {
                case .success(let message):
                    LogosConnectionLog.logger.info("Receive loop got message \(LogosConnectionLog.messageSummary(message), privacy: .public) connection_id=\(connectionID.uuidString, privacy: .public)")
                    self.handleSocketMessage(message)
                    self.receiveLoop(connectionID: connectionID)
                case .failure(let error):
                    LogosConnectionLog.logger.error("Receive loop failed error=\(LogosConnectionLog.errorDescription(error), privacy: .public) connection_id=\(connectionID.uuidString, privacy: .public)")
                    self.failCurrentSocket(message: error.localizedDescription, retryable: true)
                }
            }
        }
    }

    private func isCurrentTask(_ candidate: any WebSocketTasking) -> Bool {
        guard let task else { return false }
        return ObjectIdentifier(candidate) == ObjectIdentifier(task)
    }

    private func markConnected() {
        let previousState = connectionState
        let hadCompletedFirstConnection = settings.hasCompletedFirstConnection
        isWebSocketOpen = true
        if settings.hasCompletedFirstConnection == false {
            settings.hasCompletedFirstConnection = true
        }
        clearConnectionRetryState()
        connectionState = .connected
        lastError = nil
        resetRunErrorIfNoActiveProgress()
        LogosConnectionLog.logger.info("Marked connected previous_state=\(previousState.rawValue, privacy: .public) had_completed_first_connection=\(hadCompletedFirstConnection, privacy: .public) active_project=\(self.activeProjectKey, privacy: .public)")
    }

    private func handleSocketMessage(_ message: URLSessionWebSocketTask.Message) {
        switch message {
        case .string(let string):
            handleFrameString(string)
        case .data(let data):
            guard data.count <= Self.maxInboundFrameBytes else {
                LogosConnectionLog.logger.error("Inbound binary frame rejected because it exceeded size limit bytes=\(data.count, privacy: .public)")
                return
            }
            if let string = String(data: data, encoding: .utf8) {
                handleFrameString(string)
            } else {
                LogosConnectionLog.logger.error("Inbound data frame was not valid UTF-8 bytes=\(data.count, privacy: .public)")
            }
        @unknown default:
            LogosConnectionLog.logger.warning("Inbound WebSocket message used an unknown message case")
            break
        }
    }

    func handleFrameString(_ string: String) {
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
        if let crypto = sessionCrypto,
           let payload = root["payload"] as? [String: Any],
           payload["enc"] as? Int == 1 {
            // Sealed frame: decrypt using the cleartext routing fields as the AAD header.
            do {
                root["payload"] = try crypto.open(header: root, encPayload: payload)
            } catch {
                LogosConnectionLog.logger.error("Failed to open encrypted Logos frame type=\(type, privacy: .public)")
                return
            }
        }
        switch type {
        case "hello":
            setupSessionCrypto(from: root)
            applyClientConfig(from: root)
            markConnected()
            if task != nil {
                registerDevice(apnsToken: pendingAPNSToken)
                requestProjects()
                processPendingNotificationRouteIfReady()
                processPendingFinalAutoPlayIfReady()
            }
        case "registered":
            applyClientConfig(from: root)
            markConnected()
            pendingAPNSToken = nil
            processPendingNotificationRouteIfReady()
            processPendingFinalAutoPlayIfReady()
        case "projects_list":
            handleProjectsList(root)
        case "commands_list":
            handleCommandsList(root)
        case "commands_complete_result":
            handleCommandsCompleteResult(root)
        case "messages_batch":
            handleMessagesBatch(root)
        case "state_update":
            handleStateUpdate(root)
        case "run_status":
            handleRunStatus(root)
        case "approval_request":
            handleApprovalRequest(root)
        case "clarify_request":
            handleClarifyRequest(root)
        case "tool_progress", "progress_update":
            handleToolProgress(root)
        case "audio_chunk":
            handleAudioChunk(root)
        case "audio_end":
            handleAudioEnd(root)
        case "error":
            let payload = root["payload"] as? [String: Any]
            let code = payload?["code"] as? String ?? "<none>"
            let message = adapterErrorMessage(payload: payload)
            LogosConnectionLog.logger.error("Inbound adapter error code=\(code, privacy: .public) reason=\(payload?["reason"] as? String ?? "<none>", privacy: .public) message=\(message, privacy: .public)")
            if code == "auth_failed" {
                failCurrentSocket(message: message, retryable: false)
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

    private func handleCommandsList(_ root: [String: Any]) {
        let requestID = root["request_id"] as? String
        if let pendingCommandCatalogRequestID, requestID != pendingCommandCatalogRequestID {
            LogosConnectionLog.logger.info("Ignoring stale command catalog request_id=\(requestID ?? "<none>", privacy: .public)")
            return
        }
        guard let payload = root["payload"] as? [String: Any],
              let catalog = SlashCommandCatalog.from(dictionary: payload)
        else { return }
        slashCommandCatalog = catalog
        pendingCommandCatalogRequestID = nil
    }

    private func handleCommandsCompleteResult(_ root: [String: Any]) {
        let requestID = root["request_id"] as? String
        if let pendingCommandCompletionRequestID, requestID != pendingCommandCompletionRequestID {
            LogosConnectionLog.logger.info("Ignoring stale command completion request_id=\(requestID ?? "<none>", privacy: .public)")
            return
        }
        guard let payload = root["payload"] as? [String: Any],
              let completion = SlashCommandCompletionResult.from(dictionary: payload)
        else { return }
        slashCommandCompletion = completion
        pendingCommandCompletionRequestID = nil
    }

    private func handleMessagesBatch(_ root: [String: Any]) {
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
            let progressRequestID = progressRoutingRequestID(for: message, frameRequestID: batchRequestID, allowGatewayStatusActiveFallback: true)
            if message.role != "user", isSuppressedRunRequestID(progressRequestID) {
                continue
            }
            if shouldRouteMessageToProgress(message, requestID: progressRequestID) {
                if shouldApplyBatchProgressToLiveRun(requestID: progressRequestID, projectKey: message.projectKey) {
                    appendProgressEvent(
                        requestID: progressRequestID,
                        projectKey: message.projectKey,
                        sessionID: message.sessionID,
                        kind: progressEventKind(for: message),
                        text: message.content,
                        eventID: message.messageID
                    )
                }
                if shouldPersistProgressMessage(message) {
                    store.upsert(message)
                    persistedMessages.append(message)
                }
            } else {
                store.upsert(message)
                persistedMessages.append(message)
            }
        }
        pendingMessages.reconcile(with: persistedMessages)
        let pending = payload["pending_interactions"] as? [[String: Any]] ?? []
        for interaction in pending {
            handlePendingInteraction(interaction)
        }
        if payload.keys.contains("pending_interactions") {
            reconcilePendingInteractionCards(pending, projectKey: root["project_key"] as? String ?? activeProjectKey)
        }
        if let replayedRunStatus {
            handleReplayedRunStatus(
                replayedRunStatus,
                fallbackProjectKey: frameProjectKey(root) ?? activeProjectKey,
                fallbackSessionID: root["session_id"] as? String
            )
        }
        let completingFinalMessage = persistedMessages.first { message in
            guard message.projectKey == activeProjectKey, isExplicitTerminalAssistantMessage(message) else { return false }
            let finalRequestID = message.metadataRequestID ?? batchRequestID
            guard progressActivity != nil else { return isActiveRunRequestID(finalRequestID) }
            return shouldClearProgressActivity(for: message, requestID: finalRequestID)
        }
        if let completingFinalMessage, runStatus != .cancelling {
            completeProgressActivity(
                requestID: completingFinalMessage.metadataRequestID ?? batchRequestID,
                finalMessage: completingFinalMessage,
                finalStatus: progressFinalStatus(for: completingFinalMessage),
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
                finishProgressRun(
                    finalStatus: .interrupted,
                    failureMessage: "Logos reconnected after Hermes restarted; this run may have been interrupted.",
                    suppressLateFrames: true
                )
            }
        }
        refreshMessages()
        fulfillPendingFinishedNotificationRouteIfPossible()
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

    private func reconcilePendingInteractionCards(_ pending: [[String: Any]], projectKey: String) {
        guard projectKey == activeProjectKey else { return }
        let pendingIDs = Set(pending.compactMap { interaction in
            interaction["request_id"] as? String ?? (interaction["payload"] as? [String: Any])?["approval_id"] as? String ?? (interaction["payload"] as? [String: Any])?["clarify_id"] as? String
        })
        if let approvalCard, pendingIDs.contains(approvalCard.id) == false {
            clearAck(matching: approvalCard.id, projectKey: approvalCard.projectKey)
            self.approvalCard = nil
        }
        if let clarifyCard, pendingIDs.contains(clarifyCard.id) == false {
            clearAck(matching: clarifyCard.id, projectKey: clarifyCard.projectKey)
            self.clarifyCard = nil
        }
        if let pendingInteractionResponseID, pendingIDs.contains(pendingInteractionResponseID) == false {
            clearAck(matching: pendingInteractionResponseID, projectKey: projectKey)
            self.pendingInteractionResponseID = nil
        }
    }

    private func handlePendingInteraction(_ interaction: [String: Any]) {
        let type = interaction["type"] as? String ?? interaction["frame_type"] as? String
        if type == "approval_request" {
            handleApprovalRequest(interaction)
        } else if type == "clarify_request" {
            handleClarifyRequest(interaction)
        }
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

    private func clearPendingInteractionResponse(requestID: String, projectKey: String) {
        if pendingInteractionResponseID == requestID {
            pendingInteractionResponseID = nil
        }
        clearAck(matching: requestID, projectKey: projectKey)
    }

    private func clearInteractionStateForCancel() {
        approvalCard = nil
        clarifyCard = nil
        pendingInteractionResponseID = nil
    }

    private func clearRunScopedStateForProjectChange() {
        runStatus = .idle
        if let request = threadFocusRequest, request.projectKey != activeProjectKey {
            threadFocusRequest = nil
        }
        pendingCancelRequestID = nil
        pendingReconnectReplayRequestID = nil
        pendingOutboundResponseRequestID = nil
        outstandingOutboundResponseRequestIDs.removeAll()
        suppressedRunRequestIDs.removeAll()
        requiresScopedLiveResponse = false
        clearInteractionStateForCancel()
        suspendStaleTimeout()
        clearAck()
        clearProgressActivity()
        clearAudioPlaybackForProjectSwitch()
    }

    private func clearRunScopedStateForSocketClosure(runStatus nextStatus: LogosRunStatus) {
        runStatus = nextStatus
        pendingCancelRequestID = nil
        pendingReconnectReplayRequestID = nil
        pendingOutboundResponseRequestID = nil
        outstandingOutboundResponseRequestIDs.removeAll()
        clearInteractionStateForCancel()
        clearAck()
        clearProgressActivity()
        clearAudioPlaybackForProjectSwitch()
    }

    private func finishProgressRun(
        requestID: String? = nil,
        finalStatus: ProgressActivityFinalStatus,
        failureMessage: String? = nil,
        suppressLateFrames: Bool = false
    ) {
        if suppressLateFrames {
            suppressCurrentRunRequestIDs()
            requiresScopedLiveResponse = true
        }
        completeProgressActivity(requestID: requestID, finalStatus: finalStatus, failureMessage: failureMessage)
        runStatus = .idle
        pendingCancelRequestID = nil
        pendingOutboundResponseRequestID = nil
        outstandingOutboundResponseRequestIDs.removeAll()
        clearInteractionStateForCancel()
        clearAck()
        clearAudioPlaybackForProjectSwitch()
    }

    private func activeRunErrorMatches(_ requestID: String?) -> Bool {
        guard let activity = progressActivity, activity.isComplete == false else { return false }
        guard let requestID, requestID.isEmpty == false else { return false }
        return activity.requestID == requestID
            || pendingOutboundResponseRequestID == requestID
            || outstandingOutboundResponseRequestIDs.contains(requestID)
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
            clearPendingInteractionResponse(requestID: requestID, projectKey: projectKey)
        }
        if activeRunErrorMatches(requestID) {
            finishProgressRun(requestID: requestID, finalStatus: .failed, failureMessage: message, suppressLateFrames: true)
            return
        }
        if code == "approval_not_pending" {
            if approvalCard?.id == requestID { approvalCard = nil }
            if runStatus == .awaitingApproval { runStatus = .idle }
        } else if code == "clarify_not_pending" {
            if clarifyCard?.id == requestID { clarifyCard = nil }
            if runStatus == .awaitingClarification { runStatus = .idle }
        }
        if progressActivity?.isComplete == false {
            clearAck()
            lastError = message
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

    private func isSuppressedRunRequestID(_ requestID: String?) -> Bool {
        guard let requestID, requestID.isEmpty == false else { return false }
        return suppressedRunRequestIDs.contains(requestID)
    }

    private func isActiveRunRequestID(_ requestID: String?) -> Bool {
        guard let requestID, requestID.isEmpty == false else { return false }
        guard isSuppressedRunRequestID(requestID) == false else { return false }
        return (progressActivity?.requestID == requestID && progressActivity?.isComplete == false)
            || pendingOutboundResponseRequestID == requestID
            || outstandingOutboundResponseRequestIDs.contains(requestID)
    }

    private func isExplicitTerminalAssistantMessage(_ message: LogosMessage) -> Bool {
        guard message.role != "user", message.isProgressUpdate == false else { return false }
        return message.hasFinalizedMetadata && message.isFinal
    }

    private func shouldRouteMessageToProgress(_ message: LogosMessage, requestID: String?) -> Bool {
        if message.isProgressUpdate { return true }
        guard message.projectKey == activeProjectKey, message.role != "user" else { return false }
        guard let requestID, requestID.isEmpty == false, isActiveRunRequestID(requestID) else { return false }
        return isExplicitTerminalAssistantMessage(message) == false
    }

    private func progressRoutingRequestID(for message: LogosMessage, frameRequestID: String?, allowGatewayStatusActiveFallback: Bool = false) -> String {
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

    private func progressEventKind(for message: LogosMessage) -> String {
        message.isProgressUpdate ? message.progressEventKind : "gateway_status"
    }

    private func suppressRunRequestID(_ requestID: String?) {
        guard let requestID, requestID.isEmpty == false else { return }
        suppressedRunRequestIDs.insert(requestID)
    }

    private func clearOutstandingOutboundRequestID(_ requestID: String?) {
        guard let requestID, requestID.isEmpty == false else { return }
        outstandingOutboundResponseRequestIDs.remove(requestID)
        if pendingOutboundResponseRequestID == requestID {
            pendingOutboundResponseRequestID = nil
        }
    }

    private func suppressCurrentRunRequestIDs() {
        suppressRunRequestID(progressActivity?.requestID)
        suppressRunRequestID(pendingOutboundResponseRequestID)
        for requestID in outstandingOutboundResponseRequestIDs {
            suppressRunRequestID(requestID)
        }
    }

    private func shouldClearProgressActivity(for message: LogosMessage, requestID: String?) -> Bool {
        guard let activity = progressActivity else { return false }
        guard runStatus != .cancelling else { return false }
        guard isSuppressedRunRequestID(requestID) == false else { return false }
        guard message.projectKey == activeProjectKey, isExplicitTerminalAssistantMessage(message) else { return false }
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

    private func progressFinalStatus(for message: LogosMessage) -> ProgressActivityFinalStatus {
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

    private func handleStateUpdate(_ root: [String: Any]) {
        guard let payload = root["payload"] as? [String: Any] else { return }
        let op = payload["op"] as? String
        if op == "fast_ack" {
            guard isActiveProjectFrame(root) else { return }
            let ackID = root["request_id"] as? String ?? payload["audio_id"] as? String ?? UUID().uuidString
            setTransientAck(payload["ack_text"] as? String, id: ackID, projectKey: frameProjectKey(root) ?? activeProjectKey, ttlMilliseconds: ackTTLMilliseconds(from: payload))
            if let audioID = payload["audio_id"] as? String, audioID.isEmpty == false {
                stoppedAudioIDs.remove(audioID)
                requestedAudioIDs.insert(audioID)
            }
        }
        if let projectDict = payload["project"] as? [String: Any], let project = LogosProject.from(dictionary: projectDict) {
            upsertProject(project)
            handleProjectStateUpdate(project: project, op: op, requestID: root["request_id"] as? String)
        }
        if let messageDict = payload["message"] as? [String: Any], let message = LogosMessage.from(dictionary: messageDict) {
            let frameRequestID = root["request_id"] as? String
            let messageRequestID = message.metadataRequestID ?? frameRequestID
            let progressRequestID = progressRoutingRequestID(for: message, frameRequestID: frameRequestID)
            if message.role != "user", isSuppressedRunRequestID(messageRequestID) || isSuppressedRunRequestID(progressRequestID) {
                return
            }
            if shouldRouteMessageToProgress(message, requestID: progressRequestID) {
                appendProgressEvent(
                    requestID: progressRequestID,
                    projectKey: message.projectKey,
                    sessionID: message.sessionID,
                    kind: progressEventKind(for: message),
                    text: message.content,
                    eventID: message.messageID
                )
                if shouldPersistProgressMessage(message) {
                    store.upsert(message)
                    refreshMessages()
                }
                return
            }
            let didClearProgressActivity = shouldClearProgressActivity(for: message, requestID: messageRequestID)
            if didClearProgressActivity {
                completeProgressActivity(requestID: messageRequestID, finalMessage: message, finalStatus: progressFinalStatus(for: message), failureMessage: message.metadataIsError ? message.content : nil)
                runStatus = .idle
            }
            store.upsert(message)
            pendingMessages.reconcile(with: message)
            refreshMessages()
            fulfillPendingFinishedNotificationRouteIfPossible()
            if message.projectKey == activeProjectKey && message.role != "user" && (op == "message_appended" || op == "message_updated") && isSuppressedRunRequestID(messageRequestID) == false {
                clearAck()
            }
            maybeAutoPlayLiveAssistantMessage(message, op: op, requestID: messageRequestID, matchedCurrentRun: didClearProgressActivity)
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

    private func shouldPersistProgressMessage(_ message: LogosMessage) -> Bool {
        message.isProgressUpdate && message.isGatewayStatusUpdate == false
    }

    private func shouldApplyBatchProgressToLiveRun(requestID: String, projectKey: String) -> Bool {
        projectKey == activeProjectKey && isActiveRunRequestID(requestID)
    }

    private func syntheticProgressMessage(
        root: [String: Any],
        payload: [String: Any],
        projectKey: String,
        requestID: String,
        sessionID: String?,
        kind: String,
        text: String
    ) -> LogosMessage? {
        let transient = boolValue(payload["transient"]) ?? (kind == "gateway_status")
        guard transient == false || kind != "gateway_status" else { return nil }
        let messageID = payload["message_id"] as? String ?? requestID
        let serverSeq = integerValue(root["server_seq"]) ?? integerValue(payload["server_seq"]) ?? 0
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

    private func handleToolProgress(_ root: [String: Any]) {
        guard isActiveProjectFrame(root) else { return }
        let payload = root["payload"] as? [String: Any] ?? [:]
        let projectKey = frameProjectKey(root) ?? activeProjectKey
        let requestID = root["request_id"] as? String ?? payload["request_id"] as? String ?? "progress-\(projectKey)"
        let sessionID = root["session_id"] as? String ?? payload["session_id"] as? String
        let kind = payload["progress_kind"] as? String ?? payload["kind"] as? String ?? root["type"] as? String ?? "progress"
        let text = payload["text"] as? String ?? payload["message"] as? String ?? payload["summary"] as? String ?? kind
        if let messageDict = payload["message"] as? [String: Any], let message = LogosMessage.from(dictionary: messageDict) {
            appendProgressEvent(requestID: requestID, projectKey: projectKey, sessionID: sessionID, kind: kind, text: text, eventID: message.messageID)
            if shouldPersistProgressMessage(message) {
                store.upsert(message)
                refreshMessages()
            }
        } else if let message = syntheticProgressMessage(root: root, payload: payload, projectKey: projectKey, requestID: requestID, sessionID: sessionID, kind: kind, text: text),
                  shouldPersistProgressMessage(message) {
            appendProgressEvent(requestID: requestID, projectKey: projectKey, sessionID: sessionID, kind: kind, text: text, eventID: message.messageID)
            store.upsert(message)
            refreshMessages()
        } else {
            appendProgressEvent(requestID: requestID, projectKey: projectKey, sessionID: sessionID, kind: kind, text: text, eventID: payload["message_id"] as? String)
        }
    }

    private func handleRunStatus(_ root: [String: Any]) {
        guard isActiveProjectFrame(root) else { return }
        guard let payload = root["payload"] as? [String: Any], let statusRaw = payload["status"] as? String else { return }
        let previous = runStatus
        let next = LogosRunStatus(rawValue: statusRaw) ?? .error
        let requestID = root["request_id"] as? String
        if isInterruptedRunStatus(payload) {
            guard activeRunInterruptionMatches(requestID) else { return }
            finishProgressRun(
                requestID: requestID,
                finalStatus: .interrupted,
                failureMessage: interruptionFailureMessage(reason: payload["reason"] as? String),
                suppressLateFrames: true
            )
            return
        }
        if previous == .cancelling {
            if isCurrentCancelTerminalRunStatus(root: root, payload: payload, status: next) {
                finishProgressRun(finalStatus: .stopped, suppressLateFrames: true)
            }
            return
        }
        if payload["cancelled"] as? Bool == true, isTerminalRunStatus(next) {
            finishProgressRun(finalStatus: .stopped, suppressLateFrames: true)
            return
        }
        if next == .error, activeRunErrorMatches(requestID) {
            let message = payload["message"] as? String
                ?? payload["error"] as? String
                ?? "Hermes run failed."
            finishProgressRun(requestID: requestID, finalStatus: .failed, failureMessage: message, suppressLateFrames: true)
            return
        }
        if next == .idle, let activity = progressActivity, activity.timedOut == false, activity.isComplete == false {
            if idleRunStatusMatchesActiveProgress(requestID: requestID, projectKey: frameProjectKey(root)) {
                completeProgressActivity(requestID: requestID, finalStatus: .complete)
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
            suppressCurrentRunRequestIDs()
            requiresScopedLiveResponse = true
        }
        if next == .cancelling || next == .awaitingApproval || next == .awaitingClarification {
            suspendStaleTimeout()
        }
        if next == .running || next == .queued {
            if let requestID, isActiveRunRequestID(requestID) {
                scheduleStaleTimeout(requestID: requestID, projectKey: frameProjectKey(root) ?? activeProjectKey)
            }
        }
        if isTerminalRunStatus(next) {
            suspendStaleTimeout()
            clearAck()
        }
        if previous == .awaitingApproval && next != .awaitingApproval {
            approvalCard = nil
            pendingInteractionResponseID = nil
        } else if let approvalCard, pendingInteractionResponseID == approvalCard.id, next != .awaitingApproval {
            self.approvalCard = nil
            pendingInteractionResponseID = nil
        }
        if previous == .awaitingClarification && next != .awaitingClarification {
            clarifyCard = nil
            pendingInteractionResponseID = nil
        } else if let clarifyCard, pendingInteractionResponseID == clarifyCard.id, next != .awaitingClarification {
            self.clarifyCard = nil
            pendingInteractionResponseID = nil
        }
    }

    private func idleRunStatusMatchesActiveProgress(requestID: String?, projectKey: String?) -> Bool {
        guard let activity = progressActivity, activity.isComplete == false else { return false }
        guard let requestID, requestID.isEmpty == false else { return false }
        if let projectKey, projectKey != activity.projectKey { return false }
        return activity.requestID == requestID || isActiveRunRequestID(requestID)
    }

    private func isInterruptedRunStatus(_ payload: [String: Any]) -> Bool {
        if boolValue(payload["interrupted"]) == true { return true }
        return payload["final_status"] as? String == ProgressActivityFinalStatus.interrupted.rawValue
    }

    private func activeRunInterruptionMatches(_ requestID: String?) -> Bool {
        guard progressActivity?.isComplete == false else {
            return runStatus == .running || runStatus == .queued
        }
        guard let requestID, requestID.isEmpty == false else { return true }
        return isActiveRunRequestID(requestID)
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

    private func maybeAutoPlayLiveAssistantMessage(_ message: LogosMessage, op: String?, requestID: String?, matchedCurrentRun: Bool = false) {
        guard connectionState == .connected, task != nil, isWebSocketOpen else { return }
        guard message.projectKey == activeProjectKey else { return }
        guard runStatus != .cancelling else { return }
        guard isSuppressedRunRequestID(requestID) == false else { return }
        var matchedActiveRun = matchedCurrentRun
        guard message.status == "persisted", message.role != "user", message.isFinal, message.isProgressUpdate == false else { return }
        guard op == "message_appended" || op == "message_updated" else { return }
        if let requestID, requestID.isEmpty == false, outstandingOutboundResponseRequestIDs.contains(requestID) {
            clearOutstandingOutboundRequestID(requestID)
            completeProgressActivity(requestID: requestID, finalMessage: message, finalStatus: progressFinalStatus(for: message), failureMessage: message.metadataIsError ? message.content : nil)
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
            completeProgressActivity(requestID: requestID, finalMessage: message, finalStatus: progressFinalStatus(for: message), failureMessage: message.metadataIsError ? message.content : nil)
            runStatus = .idle
            matchedActiveRun = true
        }
        if requiresScopedLiveResponse, matchedActiveRun == false { return }
        let key = message.id
        guard autoPlayedMessageKeys.contains(key) == false else { return }
        guard notificationPlaybackSceneActive else {
            pendingFinalAutoPlayMessage = message
            return
        }
        _ = requestFinalAutoPlayback(message)
    }

    private func handleApprovalRequest(_ root: [String: Any]) {
        guard let payload = root["payload"] as? [String: Any] else { return }
        let projectKey = root["project_key"] as? String ?? activeProjectKey
        guard projectKey == activeProjectKey else { return }
        guard runStatus != .cancelling else { return }
        approvalCard = ApprovalCard(
            id: root["request_id"] as? String ?? payload["approval_id"] as? String ?? UUID().uuidString,
            projectKey: projectKey,
            title: payload["title"] as? String ?? "Approval required",
            summary: payload["summary"] as? String ?? "Hermes needs approval.",
            commandPreview: payload["command_preview"] as? String ?? "",
            risk: payload["risk"] as? String ?? ""
        )
        runStatus = .awaitingApproval
        suspendStaleTimeout()
        pendingInteractionResponseID = nil
        clearAck()
    }

    private func handleClarifyRequest(_ root: [String: Any]) {
        guard let payload = root["payload"] as? [String: Any] else { return }
        let projectKey = root["project_key"] as? String ?? activeProjectKey
        guard projectKey == activeProjectKey else { return }
        guard runStatus != .cancelling else { return }
        clarifyCard = ClarifyCard(
            id: root["request_id"] as? String ?? payload["clarify_id"] as? String ?? UUID().uuidString,
            projectKey: projectKey,
            question: payload["question"] as? String ?? "Hermes needs clarification.",
            choices: payload["choices"] as? [String] ?? [],
            allowFreeText: payload["allow_free_text"] as? Bool ?? true
        )
        runStatus = .awaitingClarification
        suspendStaleTimeout()
        pendingInteractionResponseID = nil
        clearAck()
    }

    private func handleAudioChunk(_ root: [String: Any]) {
        guard
            let payload = root["payload"] as? [String: Any],
            let audioID = payload["audio_id"] as? String,
            let data = payload["data"] as? String
        else { return }
        guard shouldAcceptAudioFrame(root, audioID: audioID) else {
            guard stoppedAudioIDs.contains(audioID) == false else { return }
            if audioPlaybackOverlay?.audioID == audioID {
                failAudioPlayback(audioID: audioID, message: "Audio stream no longer matches this conversation.")
            }
            return
        }
        guard let chunkIndex = audioChunkIndex(from: payload) else {
            failAudioPlayback(audioID: audioID, message: AudioPlaybackError.invalidChunkIndex.localizedDescription)
            return
        }
        do {
            requestedAudioIDs.insert(audioID)
            try audioPlayback.appendChunk(audioID: audioID, chunkIndex: chunkIndex, base64: data)
            updateAudioOverlay(audioID: audioID, phase: .receiving, detail: "Receiving audio", canPause: false, canStop: true, spectrumBins: idleSpectrumBins())
            scheduleAudioPlaybackStreamTimeout(audioID: audioID)
            playbackStatus = "Receiving audio"
        } catch {
            requestedAudioIDs.remove(audioID)
            failAudioPlayback(audioID: audioID, message: error.localizedDescription)
        }
    }

    private func audioChunkIndex(from payload: [String: Any]) -> Int? {
        if let index = payload["chunk_index"] as? Int {
            return index
        }
        if let rawIndex = payload["chunk_index"] as? String {
            return Int(rawIndex)
        }
        return nil
    }

    private func handleAudioEnd(_ root: [String: Any]) {
        guard
            let payload = root["payload"] as? [String: Any],
            let audioID = payload["audio_id"] as? String
        else { return }
        guard shouldAcceptAudioFrame(root, audioID: audioID) else {
            guard stoppedAudioIDs.contains(audioID) == false else { return }
            if audioPlaybackOverlay?.audioID == audioID {
                failAudioPlayback(audioID: audioID, message: "Audio stream ended for a different conversation.")
            }
            return
        }
        let chunkCount = payload["chunk_count"] as? Int ?? Int(payload["chunk_count"] as? String ?? "")
        do {
            let result = try audioPlayback.finish(audioID: audioID, expectedChunkCount: chunkCount)
            requestedAudioIDs.remove(audioID)
            cancelAudioPlaybackStreamTimeout(audioID: audioID)
            activeAudioID = audioID
            updateAudioOverlay(audioID: audioID, phase: .playing, detail: "Playing", canPause: true, canStop: true)
            startSpectrumUpdates(audioID: audioID)
            playbackStatus = result.started ? "Playing audio" : "Audio did not start"
        } catch {
            requestedAudioIDs.remove(audioID)
            failAudioPlayback(audioID: audioID, message: error.localizedDescription)
        }
    }

    private func rememberStoppedAudioID(_ audioID: String) {
        stoppedAudioIDs.insert(audioID)
        if stoppedAudioIDs.count > Self.stoppedAudioIDRetentionLimit {
            stoppedAudioIDs.subtract(stoppedAudioIDs.sorted().prefix(stoppedAudioIDs.count - Self.stoppedAudioIDRetentionLimit))
        }
    }

    private func shouldAcceptAudioFrame(_ root: [String: Any], audioID: String) -> Bool {
        guard stoppedAudioIDs.contains(audioID) == false else { return false }
        if let frameDeviceID = root["device_id"] as? String, frameDeviceID.isEmpty == false {
            guard frameDeviceID == settings.deviceID else { return false }
        }
        if let projectKey = frameProjectKey(root), projectKey != activeProjectKey {
            return false
        }
        if let overlay = audioPlaybackOverlay, overlay.audioID == audioID {
            guard overlay.projectKey == activeProjectKey else { return false }
            if let projectKey = frameProjectKey(root), projectKey != overlay.projectKey {
                return false
            }
            return true
        }
        if requestedAudioIDs.contains(audioID) {
            return true
        }
        return false
    }

    private func upsertProject(_ project: LogosProject) {
        if let index = projects.firstIndex(where: { $0.projectKey == project.projectKey }) {
            projects[index] = project
        } else {
            projects.insert(project, at: 0)
        }
    }

    private func latestServerSeq(projectKey: String? = nil) -> Int {
        store.latestServerSeq(projectKey: projectKey ?? activeProjectKey)
    }

    private func addPendingMessage(_ message: LogosMessage) {
        pendingMessages.add(message, persisted: store.loadMessages(projectKey: message.projectKey))
        refreshMessages()
    }

    private func handlePendingTextSendFailure(messageID: String, projectKey: String, requestID: String, error _: Error) {
        clearOutstandingOutboundRequestID(requestID)
        clearProgressActivity(requestID: requestID)
        if outstandingOutboundResponseRequestIDs.isEmpty && pendingOutboundResponseRequestID == nil && progressActivity?.requestID != requestID {
            suspendStaleTimeout()
        }
        pendingMessages.remove(messageID: messageID)
        if projectKey == activeProjectKey {
            refreshMessages()
        }
    }

    private func handleFinalSpeechSendSuccess(inputID: String) {
        inFlightFinalSpeechDrafts.removeValue(forKey: inputID)
    }

    private func handleFinalSpeechSendFailure(_ draft: UndeliveredSpeechDraft, requestID: String, error: Error) {
        guard inFlightFinalSpeechDrafts.removeValue(forKey: draft.inputID) != nil else { return }
        clearOutstandingOutboundRequestID(requestID)
        clearProgressActivity(requestID: requestID)
        if outstandingOutboundResponseRequestIDs.isEmpty && pendingOutboundResponseRequestID == nil && progressActivity?.requestID != requestID {
            suspendStaleTimeout()
        }
        pendingMessages.remove(messageID: draft.inputID)
        refreshMessages()
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
            pendingMessages.remove(messageID: draft.inputID)
        }
        inFlightFinalSpeechDrafts.removeAll()
        refreshMessages()
        if let draft = drafts.last {
            undeliveredSpeechDraft = UndeliveredSpeechDraft(
                inputID: draft.inputID,
                projectKey: draft.projectKey,
                text: draft.text,
                reason: reason
            )
        }
    }

    private func refreshMessages() {
        var visibleByID: [String: LogosMessage] = [:]
        for message in visibleMessages(from: store.loadMessages(projectKey: activeProjectKey)) {
            visibleByID[message.id] = message
        }
        for message in notificationRouteAnchors.values where message.projectKey == activeProjectKey && message.isProgressUpdate == false {
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

private enum LogosSocketSendError: LocalizedError {
    case staleConnection

    var errorDescription: String? {
        switch self {
        case .staleConnection:
            return "The socket changed before the frame send completed."
        }
    }
}
