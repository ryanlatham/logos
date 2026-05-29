import Combine
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
                progressActivityManager.clearConnectionRetryState()
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
    @Published private(set) var threadFocusRequest: ThreadFocusRequest?
    @Published var lastError: String?
    /// Bounded, source-tagged history of client errors (WS1 P7). `lastError` remains the
    /// transient single-error banner; `errorLog` is the persistent, dismissible record.
    @Published private(set) var errorLog = ErrorLogBuffer()
    @Published private(set) var ackText: String?
    @Published private(set) var undeliveredSpeechDraft: UndeliveredSpeechDraft?
    @Published internal(set) var slashCommandCatalog: SlashCommandCatalog = .fallback
    @Published internal(set) var slashCommandCompletion: SlashCommandCompletionResult = .empty

    var task: (any WebSocketTasking)?
    private var connectionLifecycle = LogosConnectionLifecycle()
    private let store: SQLiteMessageStore
    private let socketFactory: any WebSocketTaskMaking
    let audioCoordinator: AudioCoordinator
    private var audioCancellable: AnyCancellable?
    let progressActivityManager: ProgressActivityManager
    private var progressCancellable: AnyCancellable?
    let interactionController: InteractionController
    private var interactionCancellable: AnyCancellable?
    private var staleTimeoutInterval: TimeInterval
    private var autoPlayedMessageKeys = Set<String>()
    private var pendingAPNSToken: String?
    private let pairingExchanger: any PairingCredentialExchanging
    var isWebSocketOpen = false
    private var pendingMessages = PendingMessageBuffer()
    private var inFlightFinalSpeechDrafts: [String: UndeliveredSpeechDraft] = [:]
    private var ackState: FastAckState?
    private let staleTimeoutScheduler: any StaleTimeoutScheduling
    private let ackClearScheduler: any AckClearScheduling
    private var localNoticeMessages: [LogosMessage] = []
    private var localNoticeSequence = 0
    private var pendingCancelRequestID: String?
    var pendingCommandCatalogRequestID: String?
    var pendingCommandCompletionRequestID: String?
    private var pendingReconnectReplayRequestID: String?
    private var pendingOutboundResponseRequestID: String?
    private var outstandingOutboundResponseRequestIDs = Set<String>()
    private var requiresScopedLiveResponse = false
    private var pendingProjectSwitchRequestID: String?
    private var pendingProjectSwitchTarget: String?
    private var pendingNotificationRoute: PendingNotificationRouteState?
    private var pendingFinalAutoPlayMessage: LogosMessage?
    private var fulfilledNotificationRouteKeys = Set<String>()
    private var notificationRouteAnchors: [String: LogosMessage] = [:]
    private var threadFocusRequestSequence = 0
    private var notificationPlaybackSceneActive = false

    private static let staleSilenceNoticeText = "Logos has not heard from Hermes in a while. The run may still be working; waiting for the next adapter update."
    private static let maxStaleTimeoutInterval: TimeInterval = 86_400
    private static let maxInboundFrameBytes = 2_000_000
    private static let maxNotificationRouteAnchors = 8
    private static let notificationReplayContextWindow = 25

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
        self.audioCoordinator = AudioCoordinator(audioPlayback: audioPlayback)
        self.progressActivityManager = ProgressActivityManager()
        self.interactionController = InteractionController()
        self.staleTimeoutInterval = min(max(0.001, staleTimeoutInterval), Self.maxStaleTimeoutInterval)
        self.staleTimeoutScheduler = staleTimeoutScheduler ?? TaskStaleTimeoutScheduler()
        self.ackClearScheduler = ackClearScheduler ?? TaskAckClearScheduler()
        messages = visibleMessages(from: store.loadMessages(projectKey: activeProjectKey))
        audioCoordinator.host = self
        progressActivityManager.host = self
        interactionController.host = self
        // Re-emit the coordinator's published audio-state changes as our own so SwiftUI views
        // observing `LogosClient` refresh when the (forwarded) overlay/status change.
        audioCancellable = audioCoordinator.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        // Re-emit the progress manager's published changes so views reading the forwarded
        // `progressActivity`/`connectionRetryState` refresh (WS1 P5, mirrors the audio wiring).
        progressCancellable = progressActivityManager.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        // Re-emit the interaction controller's published changes so views reading the forwarded
        // `approvalCard`/`clarifyCard`/`pendingInteractionResponseID` refresh (WS1 P5).
        interactionCancellable = interactionController.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
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
            progressActivityManager.clearConnectionRetryState()
        }
        cancelCurrentSocket()
        lastError = nil
        progressActivityManager.resetRunErrorIfNoActiveProgress()
        guard let url = URL(string: settings.urlString) else {
            LogosConnectionLog.logger.error("Connect failed before socket creation: invalid adapter URL value=\(self.settings.urlString, privacy: .public)")
            progressActivityManager.clearConnectionRetryState()
            recordError("Invalid adapter URL")
            connectionState = .error
            return
        }
        guard settings.secret.isEmpty == false else {
            LogosConnectionLog.logger.error("Connect failed before socket creation: missing Logos device secret")
            progressActivityManager.clearConnectionRetryState()
            recordError("Missing Logos device secret")
            connectionState = .error
            return
        }
        let connectionID = connectionLifecycle.startConnection()
        isWebSocketOpen = false
        connectionState = .connecting
        LogosConnectionLog.logger.info("Connection lifecycle started connection_id=\(connectionID.uuidString, privacy: .public) url=\(LogosConnectionLog.urlDescription(url), privacy: .public)")
        let pinnedSPKI = settings.certSPKISHA256.trimmingCharacters(in: .whitespacesAndNewlines)
        let task = socketFactory.webSocketTask(
            with: url,
            lifecycleObserver: self,
            pinnedSPKISHA256: pinnedSPKI.isEmpty ? nil : pinnedSPKI
        )
        self.task = task
        LogosConnectionLog.logger.info("WebSocket task assigned task_id=\(LogosConnectionLog.taskIDDescription(task), privacy: .public) connection_id=\(connectionID.uuidString, privacy: .public)")
        task.resume()
    }

    func disconnect() {
        LogosConnectionLog.logger.info("Disconnect requested state=\(self.connectionState.rawValue, privacy: .public) open=\(self.isWebSocketOpen, privacy: .public) has_task=\(self.task != nil, privacy: .public)")
        progressActivityManager.clearConnectionRetryState()
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

    fileprivate var canAutoRetryConnection: Bool {
        settings.autoConnect
            && URL(string: settings.urlString) != nil
            && LogosSettings.normalizedSecret(settings.secret).isEmpty == false
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
            progressActivityManager.clearProgressActivity()
            progressActivityManager.startProgressActivity(requestID: requestID, projectKey: projectKey, retryRequest: .text(trimmed))
            progressActivityManager.unsuppressRunRequestID(requestID)
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
            progressActivityManager.clearProgressActivity()
            progressActivityManager.startProgressActivity(requestID: requestID, projectKey: projectKey, retryRequest: .speech(text: trimmed))
            progressActivityManager.unsuppressRunRequestID(requestID)
            outstandingOutboundResponseRequestIDs.insert(requestID)
            pendingOutboundResponseRequestID = requestID
            addPendingMessage(pending)
            runStatus = .running
            scheduleStaleTimeout(requestID: requestID, projectKey: projectKey)
        }
        return sent
    }

    @discardableResult
    func retryProgressActivity() -> Bool {
        progressActivityManager.retryProgressActivity()
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
            // WS3 S4: adopt the direct-WSS leaf pin from the (signed) pairing link, if any.
            settings.certSPKISHA256 = (route.certSPKISHA256 ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
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
        let sent = audioCoordinator.requestPlayback(message: message, mode: "final_auto", autoPlayKey: key, notificationRouteKey: notificationRouteKey)
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
        interactionController.approveCurrentRequest()
    }

    func denyCurrentRequest() {
        interactionController.denyCurrentRequest()
    }

    @discardableResult
    func answerClarification(_ text: String) -> Bool {
        interactionController.answerClarification(text)
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
            progressActivityManager.suppressCurrentRunRequestIDs()
            requiresScopedLiveResponse = true
            pendingCancelRequestID = requestID
            runStatus = .cancelling
            suspendStaleTimeout()
            interactionController.clearInteractionStateForCancel()
            clearAck()
        }
    }

    func playback(message: LogosMessage) {
        audioCoordinator.playback(message: message)
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
        guard task != nil, connectionState == .connected else {
            LogosConnectionLog.logger.warning("User action blocked because Logos is not connected action=\(action, privacy: .public) state=\(self.connectionState.rawValue, privacy: .public) open=\(self.isWebSocketOpen, privacy: .public) has_task=\(self.task != nil, privacy: .public)")
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
        audioCoordinator.failInterruptedRemoteAudioStream()
        if connectionState != .disconnected || retryable {
            logError(message, source: .connection)
            clearAck()
            if progressActivity?.isComplete != false {
                runStatus = .idle
            }
            interactionController.failInterruptedInteraction(clearCards: clearInteractionCards)
            connectionState = .error
            if retryable {
                progressActivityManager.noteConnectionRetryFailure(message)
            } else {
                progressActivityManager.clearConnectionRetryState()
            }
        }
        LogosConnectionLog.logger.error("Socket failure state updated state=\(self.connectionState.rawValue, privacy: .public) last_error=\(self.lastError ?? "<none>", privacy: .public)")
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
    func sendFrame(
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
        progressActivityManager.clearConnectionRetryState()
        connectionState = .connected
        lastError = nil
        progressActivityManager.resetRunErrorIfNoActiveProgress()
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
            guard message.projectKey == activeProjectKey, isExplicitTerminalAssistantMessage(message) else { return false }
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
        if let request = threadFocusRequest, request.projectKey != activeProjectKey {
            threadFocusRequest = nil
        }
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

    private func isExplicitTerminalAssistantMessage(_ message: LogosMessage) -> Bool {
        guard message.role != "user", message.isProgressUpdate == false else { return false }
        return message.hasFinalizedMetadata && message.isFinal
    }

    private func clearOutstandingOutboundRequestID(_ requestID: String?) {
        guard let requestID, requestID.isEmpty == false else { return }
        outstandingOutboundResponseRequestIDs.remove(requestID)
        if pendingOutboundResponseRequestID == requestID {
            pendingOutboundResponseRequestID = nil
        }
    }

    private func handleStateUpdate(_ root: [String: Any]) {
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
                    store.upsert(message)
                    refreshMessages()
                }
                return
            }
            let didClearProgressActivity = progressActivityManager.shouldClearProgressActivity(for: message, requestID: messageRequestID)
            if didClearProgressActivity {
                progressActivityManager.completeProgressActivity(requestID: messageRequestID, finalMessage: message, finalStatus: progressActivityManager.progressFinalStatus(for: message), failureMessage: message.metadataIsError ? message.content : nil)
                runStatus = .idle
            }
            store.upsert(message)
            pendingMessages.reconcile(with: message)
            refreshMessages()
            fulfillPendingFinishedNotificationRouteIfPossible()
            if message.projectKey == activeProjectKey && message.role != "user" && (op == "message_appended" || op == "message_updated") && progressActivityManager.isSuppressedRunRequestID(messageRequestID) == false {
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

    private func maybeAutoPlayLiveAssistantMessage(_ message: LogosMessage, op: String?, requestID: String?, matchedCurrentRun: Bool = false) {
        guard connectionState == .connected, task != nil, isWebSocketOpen else { return }
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
        let key = message.id
        guard autoPlayedMessageKeys.contains(key) == false else { return }
        guard notificationPlaybackSceneActive else {
            pendingFinalAutoPlayMessage = message
            return
        }
        _ = requestFinalAutoPlayback(message)
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
        progressActivityManager.clearProgressActivity(requestID: requestID)
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
        progressActivityManager.clearProgressActivity(requestID: requestID)
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
    func sendAudioFrame(_ frame: [String: Any], onCompletion: ((Result<Void, Error>) -> Void)?) -> Bool {
        sendFrame(frame, onCompletion: onCompletion)
    }

    func audioFrameProjectKey(_ root: [String: Any]) -> String? {
        frameProjectKey(root)
    }

    func recordAudioPlaybackError(_ message: String) {
        clearAck()
        logError(message, source: .audio)
    }

    func clearAutoPlayedMessageKey(_ key: String) {
        autoPlayedMessageKeys.remove(key)
    }

    func clearFulfilledNotificationRouteKey(_ key: String) {
        fulfilledNotificationRouteKeys.remove(key)
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

    var progressHasOpenSocket: Bool { task != nil && isWebSocketOpen }

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
        store.upsert(message)
        refreshMessages()
    }

    func isProgressTerminalAssistantMessage(_ message: LogosMessage) -> Bool {
        isExplicitTerminalAssistantMessage(message)
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
    func sendProgressText(_ text: String) -> Bool {
        sendText(text)
    }

    @discardableResult
    func sendProgressSpeech(text: String) -> Bool {
        let inputID = "voice-retry-\(UUID().uuidString)"
        let startedAtMilliseconds = Int64(Date().timeIntervalSince1970 * 1000)
        return sendSpeech(text: text, isFinal: true, inputID: inputID, partialSeq: 0, startedAtMilliseconds: startedAtMilliseconds)
    }

    func reconnectForRetry() {
        guard connectionState == .error || connectionState == .disconnected else { return }
        connect(isAutomaticRetry: true)
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
    func sendInteractionFrame(_ frame: [String: Any], onCompletion: ((Result<Void, Error>) -> Void)?) -> Bool {
        sendFrame(frame, onCompletion: onCompletion)
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

private enum LogosSocketSendError: LocalizedError {
    case staleConnection

    var errorDescription: String? {
        switch self {
        case .staleConnection:
            return "The socket changed before the frame send completed."
        }
    }
}
