import Foundation
import OSLog
import UIKit

protocol WebSocketTasking: AnyObject {
    func resume()
    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?)
    func send(_ message: URLSessionWebSocketTask.Message, completionHandler: @escaping @Sendable (Error?) -> Void)
    func receive(completionHandler: @escaping @Sendable (Result<URLSessionWebSocketTask.Message, Error>) -> Void)
}

protocol WebSocketLifecycleObserving: AnyObject {
    func webSocketDidOpen(taskID: ObjectIdentifier)
    func webSocketDidClose(taskID: ObjectIdentifier, closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?)
    func webSocketDidFail(taskID: ObjectIdentifier, message: String)
}

protocol WebSocketTaskMaking {
    func webSocketTask(with url: URL, lifecycleObserver: (any WebSocketLifecycleObserving)?) -> any WebSocketTasking
}

private enum LogosConnectionLog {
    static let logger = Logger(subsystem: "com.ryan.logos", category: "connection")

    static func urlDescription(_ url: URL) -> String {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.user = nil
        components?.password = nil
        components?.query = nil
        components?.fragment = nil
        return components?.string ?? url.absoluteString
    }

    static func urlDescription(_ urlString: String) -> String {
        guard let url = URL(string: urlString) else { return "<invalid-url>" }
        return urlDescription(url)
    }

    static func closeReasonDescription(_ reason: Data?) -> String {
        guard let reason else { return "<none>" }
        if let text = String(data: reason, encoding: .utf8), text.isEmpty == false {
            return text
        }
        return "<\(reason.count) bytes>"
    }

    static func errorDescription(_ error: Error, url: URL? = nil) -> String {
        let nsError = error as NSError
        var parts = [
            error.localizedDescription,
            "[\(nsError.domain) \(nsError.code)]"
        ]
        if let url {
            parts.append("url=\(urlDescription(url))")
        }
        if let failingURL = nsError.userInfo[NSURLErrorFailingURLErrorKey] as? URL {
            parts.append("failingURL=\(urlDescription(failingURL))")
        } else if let failingURLString = nsError.userInfo[NSURLErrorFailingURLStringErrorKey] as? String,
                  let failingURL = URL(string: failingURLString) {
            parts.append("failingURL=\(urlDescription(failingURL))")
        } else if let failingURLString = nsError.userInfo[NSURLErrorFailingURLStringErrorKey] as? String {
            parts.append("failingURL=\(failingURLString)")
        }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
            parts.append("underlying=[\(underlying.domain) \(underlying.code)] \(underlying.localizedDescription)")
        }
        return parts.joined(separator: " ")
    }

    static func frameSummary(_ frame: [String: Any]) -> String {
        let type = stringValue(frame["type"])
        let requestID = stringValue(frame["request_id"])
        let projectKey = stringValue(frame["project_key"])
        let payloadKeys = dictionaryKeysDescription(frame["payload"])
        return "type=\(type) request_id=\(requestID) project_key=\(projectKey) payload_keys=\(payloadKeys)"
    }

    static func inboundFrameSummary(_ root: [String: Any]) -> String {
        let type = stringValue(root["type"])
        let requestID = stringValue(root["request_id"])
        let projectKey = stringValue(root["project_key"])
        let payloadKeys = dictionaryKeysDescription(root["payload"])
        return "type=\(type) request_id=\(requestID) project_key=\(projectKey) payload_keys=\(payloadKeys)"
    }

    static func messageSummary(_ message: URLSessionWebSocketTask.Message) -> String {
        switch message {
        case .string(let string):
            return "string bytes=\(string.utf8.count)"
        case .data(let data):
            return "data bytes=\(data.count)"
        @unknown default:
            return "unknown"
        }
    }

    static func taskIDDescription(_ task: (any WebSocketTasking)?) -> String {
        guard let task else { return "<none>" }
        return String(describing: ObjectIdentifier(task))
    }

    private static func stringValue(_ value: Any?) -> String {
        guard let value else { return "<none>" }
        if let text = value as? String {
            return text.isEmpty ? "<empty>" : text
        }
        return String(describing: value)
    }

    private static func dictionaryKeysDescription(_ value: Any?) -> String {
        guard let dictionary = value as? [String: Any] else { return "[]" }
        return "[" + dictionary.keys.sorted().joined(separator: ",") + "]"
    }
}

struct URLSessionWebSocketTaskFactory: WebSocketTaskMaking {
    func webSocketTask(with url: URL, lifecycleObserver: (any WebSocketLifecycleObserving)?) -> any WebSocketTasking {
        URLSessionWebSocketTaskBox(url: url, lifecycleObserver: lifecycleObserver)
    }
}

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

final class URLSessionWebSocketTaskBox: NSObject, WebSocketTasking, URLSessionWebSocketDelegate {
    private weak var lifecycleObserver: (any WebSocketLifecycleObserving)?
    private let url: URL
    private var session: URLSession?
    private var task: URLSessionWebSocketTask?

    init(url: URL, lifecycleObserver: (any WebSocketLifecycleObserving)?) {
        self.lifecycleObserver = lifecycleObserver
        self.url = url
        super.init()
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        self.session = session
        self.task = session.webSocketTask(with: url)
        LogosConnectionLog.logger.info("WebSocket task created url=\(LogosConnectionLog.urlDescription(url), privacy: .public)")
    }

    deinit {
        session?.invalidateAndCancel()
    }

    func resume() {
        LogosConnectionLog.logger.info("WebSocket task resume requested url=\(LogosConnectionLog.urlDescription(self.url), privacy: .public)")
        task?.resume()
    }

    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        LogosConnectionLog.logger.info("WebSocket task cancel requested close_code=\(closeCode.rawValue, privacy: .public) reason=\(LogosConnectionLog.closeReasonDescription(reason), privacy: .public)")
        task?.cancel(with: closeCode, reason: reason)
        session?.invalidateAndCancel()
        session = nil
        task = nil
    }

    func send(_ message: URLSessionWebSocketTask.Message, completionHandler: @escaping @Sendable (Error?) -> Void) {
        guard let task else {
            LogosConnectionLog.logger.error("WebSocket send requested after task was released")
            completionHandler(URLError(.notConnectedToInternet))
            return
        }
        task.send(message, completionHandler: completionHandler)
    }

    func receive(completionHandler: @escaping @Sendable (Result<URLSessionWebSocketTask.Message, Error>) -> Void) {
        guard let task else {
            LogosConnectionLog.logger.error("WebSocket receive requested after task was released")
            completionHandler(.failure(URLError(.notConnectedToInternet)))
            return
        }
        task.receive(completionHandler: completionHandler)
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        LogosConnectionLog.logger.info("URLSession WebSocket did open url=\(LogosConnectionLog.urlDescription(self.url), privacy: .public) protocol=\(`protocol` ?? "<none>", privacy: .public)")
        lifecycleObserver?.webSocketDidOpen(taskID: ObjectIdentifier(self))
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        LogosConnectionLog.logger.warning("URLSession WebSocket did close url=\(LogosConnectionLog.urlDescription(self.url), privacy: .public) close_code=\(closeCode.rawValue, privacy: .public) reason=\(LogosConnectionLog.closeReasonDescription(reason), privacy: .public)")
        lifecycleObserver?.webSocketDidClose(taskID: ObjectIdentifier(self), closeCode: closeCode, reason: reason)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else {
            LogosConnectionLog.logger.info("URLSession WebSocket task completed without error url=\(LogosConnectionLog.urlDescription(self.url), privacy: .public)")
            return
        }
        let message = failureMessage(for: error)
        LogosConnectionLog.logger.error("URLSession WebSocket task completed with error \(message, privacy: .public)")
        lifecycleObserver?.webSocketDidFail(taskID: ObjectIdentifier(self), message: message)
    }

    private func failureMessage(for error: Error) -> String {
        "WebSocket failed: \(LogosConnectionLog.errorDescription(error, url: url))"
    }
}

@MainActor
final class LogosClient: ObservableObject, WebSocketLifecycleObserving {
    @Published var settings = LogosSettings() {
        didSet { settings.persist() }
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
    @Published var lastError: String?
    @Published var playbackStatus: String?
    @Published private(set) var ackText: String?
    @Published private(set) var undeliveredSpeechDraft: UndeliveredSpeechDraft?
    @Published private(set) var progressActivity: ProgressActivityState?
    @Published private(set) var audioPlaybackOverlay: AudioPlaybackOverlayState?

    private var task: (any WebSocketTasking)?
    private var connectionLifecycle = LogosConnectionLifecycle()
    private let store: SQLiteMessageStore
    private let socketFactory: any WebSocketTaskMaking
    private let audioPlayback: AudioPlaybackController
    private let progressTimeoutInterval: TimeInterval
    private var requestedAudioIDs = Set<String>()
    private var stoppedAudioIDs = Set<String>()
    private var activeAudioID: String?
    private var autoPlayedMessageKeys = Set<String>()
    private var pendingAPNSToken: String?
    private let pairingExchanger: any PairingCredentialExchanging
    private var isWebSocketOpen = false
    private var pendingMessages = PendingMessageBuffer()
    private var inFlightFinalSpeechDrafts: [String: UndeliveredSpeechDraft] = [:]
    private var ackState: FastAckState?
    private var ackClearTask: Task<Void, Never>?
    private var progressTimeoutTask: Task<Void, Never>?
    private var pendingCancelRequestID: String?
    private var pendingProjectSwitchRequestID: String?
    private var pendingProjectSwitchTarget: String?

    private static let gatewayTimeoutAudioText = "The gateway stopped sending updates before a final response arrived."

    init(
        store: SQLiteMessageStore = SQLiteMessageStore(),
        socketFactory: any WebSocketTaskMaking = URLSessionWebSocketTaskFactory(),
        pairingExchanger: any PairingCredentialExchanging = WebSocketPairingCredentialExchanger(),
        audioPlayback: AudioPlaybackController = AudioPlaybackController(),
        progressTimeoutInterval: TimeInterval = 45
    ) {
        self.store = store
        self.socketFactory = socketFactory
        self.pairingExchanger = pairingExchanger
        self.audioPlayback = audioPlayback
        self.progressTimeoutInterval = progressTimeoutInterval
        messages = visibleMessages(from: store.loadMessages(projectKey: activeProjectKey))
        audioPlayback.onPlaybackFinished = { [weak self] audioID, succeeded in
            Task { @MainActor in
                guard let self, self.activeAudioID == audioID else { return }
                self.activeAudioID = nil
                self.requestedAudioIDs.remove(audioID)
                if succeeded {
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
                    self.audioPlaybackOverlay = nil
                    self.playbackStatus = nil
                    self.recordError("Audio playback ended unexpectedly. Check device volume and output route.")
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
        connect()
    }

    func connect() {
        LogosConnectionLog.logger.info("Connect requested url=\(LogosConnectionLog.urlDescription(self.settings.urlString), privacy: .public) state=\(self.connectionState.rawValue, privacy: .public) device_id=\(self.settings.deviceID, privacy: .public) project_key=\(self.activeProjectKey, privacy: .public) has_secret=\(!self.settings.secret.isEmpty, privacy: .public) pending_apns_token=\(self.pendingAPNSToken != nil, privacy: .public)")
        cancelCurrentSocket()
        lastError = nil
        guard let url = URL(string: settings.urlString) else {
            LogosConnectionLog.logger.error("Connect failed before socket creation: invalid adapter URL value=\(self.settings.urlString, privacy: .public)")
            recordError("Invalid adapter URL")
            connectionState = .error
            return
        }
        guard settings.secret.isEmpty == false else {
            LogosConnectionLog.logger.error("Connect failed before socket creation: missing Logos device secret")
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
        cancelCurrentSocket()
        lastError = nil
        clearRunScopedStateForSocketClosure(runStatus: .idle)
        connectionState = .disconnected
        LogosConnectionLog.logger.info("Disconnect complete state=\(self.connectionState.rawValue, privacy: .public)")
    }

    private func cancelCurrentSocket() {
        let oldTask = task
        LogosConnectionLog.logger.info("Cancelling current socket has_task=\(oldTask != nil, privacy: .public) open=\(self.isWebSocketOpen, privacy: .public) state=\(self.connectionState.rawValue, privacy: .public) in_flight_final_speech=\(self.inFlightFinalSpeechDrafts.count, privacy: .public)")
        task = nil
        isWebSocketOpen = false
        connectionLifecycle.invalidate()
        restoreInFlightFinalSpeechDrafts(reason: "The socket closed before Logos confirmed the final speech frame was sent.")
        oldTask?.cancel(with: .goingAway, reason: nil)
    }

    @discardableResult
    func sendText(_ text: String) -> Bool {
        guard ensureConnectedForUserAction("send a message") else { return false }
        guard runStatus != .cancelling else { return false }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let projectKey = activeProjectKey
        let pending = LogosMessage.pending(projectKey: projectKey, content: trimmed)
        let sent = sendFrame([
            "type": "text_input",
            "request_id": UUID().uuidString,
            "device_id": settings.deviceID,
            "project_key": projectKey,
            "payload": [
                "text": trimmed,
                "client_msg_id": pending.messageID,
                "is_final": true
            ]
        ]) { [weak self] result in
            guard case .failure(let error) = result else { return }
            self?.handlePendingTextSendFailure(messageID: pending.messageID, projectKey: projectKey, error: error)
        }
        if sent {
            addPendingMessage(pending)
        }
        return sent
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
        let sent = sendFrame(LogosSpeechFrame.make(
            text: trimmed,
            isFinal: isFinal,
            inputID: inputID,
            partialSeq: partialSeq,
            startedAtMilliseconds: startedAtMilliseconds,
            deviceID: settings.deviceID,
            projectKey: projectKey
        )) { [weak self] result in
            guard isFinal else { return }
            switch result {
            case .success:
                self?.handleFinalSpeechSendSuccess(inputID: inputID, pending: pending)
            case .failure(let error):
                self?.handleFinalSpeechSendFailure(failedDraft, error: error)
            }
        }
        if sent == false, isFinal {
            inFlightFinalSpeechDrafts.removeValue(forKey: inputID)
        }
        return sent
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
            "apns_environment": "sandbox",
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
        if connectionState != .connected {
            connect()
        }
        let afterSeq = max((route.serverSeq ?? 1) - 1, 0)
        requestMessages(afterServerSeq: afterSeq)
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
            pendingCancelRequestID = requestID
            runStatus = .cancelling
            suspendProgressTimeout()
            clearInteractionStateForCancel()
            clearAck()
        }
    }

    func playback(message: LogosMessage) {
        requestPlayback(message: message, mode: "full")
    }

    func pausePlayback() {
        guard let audioID = audioPlaybackOverlay?.audioID ?? activeAudioID else { return }
        guard audioPlayback.pause(audioID: audioID) else { return }
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
            playbackStatus = nil
        } catch {
            recordError(error.localizedDescription)
        }
    }

    func stopPlayback() {
        guard let audioID = audioPlaybackOverlay?.audioID ?? activeAudioID else { return }
        stoppedAudioIDs.insert(audioID)
        requestedAudioIDs.remove(audioID)
        _ = audioPlayback.stop(audioID: audioID)
        if activeAudioID == audioID { activeAudioID = nil }
        audioPlaybackOverlay = nil
        playbackStatus = nil
    }

    func pauseAudioForSceneBackground() {
        let snapshots = audioPlayback.pauseForLifecycle(reason: "scene_background")
        guard let snapshot = snapshots.first else { return }
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
            playbackStatus = nil
        } catch {
            recordError(error.localizedDescription)
        }
    }

    func toggleProgressActivityExpanded() {
        guard var activity = progressActivity else { return }
        activity.isExpanded.toggle()
        progressActivity = activity
    }

    private func requestPlayback(message: LogosMessage, mode: String) {
        guard message.isProgressUpdate == false else { return }
        guard ensureConnectedForUserAction("play audio") else { return }
        let audioID = "ios-\(UUID().uuidString)"
        requestPlaybackAudio(
            audioID: audioID,
            projectKey: message.projectKey,
            sessionID: message.sessionID,
            messageID: message.messageID,
            mode: mode,
            text: message.content
        )
    }

    private func requestPlaybackAudio(audioID: String, projectKey: String, sessionID: String?, messageID: String?, mode: String, text: String) {
        prepareForNewPlaybackRequest(audioID: audioID)
        requestedAudioIDs.insert(audioID)
        stoppedAudioIDs.remove(audioID)
        audioPlaybackOverlay = AudioPlaybackOverlayState(
            audioID: audioID,
            messageID: messageID,
            projectKey: projectKey,
            phase: .requesting,
            detail: "Requesting audio",
            spectrumBins: Array(repeating: 0.12, count: 12),
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
            self?.clearFailedPlaybackRequest(audioID: audioID)
        }
        if sent == false {
            stoppedAudioIDs.insert(audioID)
            requestedAudioIDs.remove(audioID)
            if audioPlaybackOverlay?.audioID == audioID {
                audioPlaybackOverlay = nil
            }
            playbackStatus = nil
        }
    }

    private func markStopped(_ audioID: String?) {
        guard let audioID, audioID.isEmpty == false else { return }
        stoppedAudioIDs.insert(audioID)
    }

    private func clearFailedPlaybackRequest(audioID: String) {
        stoppedAudioIDs.insert(audioID)
        requestedAudioIDs.remove(audioID)
        if activeAudioID == audioID {
            activeAudioID = nil
        }
        if audioPlaybackOverlay?.audioID == audioID {
            audioPlaybackOverlay = nil
        }
        playbackStatus = nil
    }

    private func prepareForNewPlaybackRequest(audioID: String) {
        for requestedID in requestedAudioIDs where requestedID != audioID {
            stoppedAudioIDs.insert(requestedID)
        }
        if audioPlaybackOverlay?.audioID != audioID {
            markStopped(audioPlaybackOverlay?.audioID)
        }
        if activeAudioID != audioID {
            markStopped(activeAudioID)
        }
        audioPlayback.stopAll()
        requestedAudioIDs.removeAll()
        activeAudioID = nil
    }

    private func clearAudioPlaybackForProjectSwitch() {
        for requestedID in requestedAudioIDs {
            stoppedAudioIDs.insert(requestedID)
        }
        markStopped(audioPlaybackOverlay?.audioID)
        markStopped(activeAudioID)
        audioPlayback.stopAll()
        requestedAudioIDs.removeAll()
        activeAudioID = nil
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

    private func spectrumBins(fromBase64 base64: String, count: Int = 12) -> [Double] {
        guard let data = Data(base64Encoded: base64), data.isEmpty == false else {
            return Array(repeating: 0.12, count: count)
        }
        return (0..<count).map { index in
            max(0.05, Double(data[index % data.count]) / 255.0)
        }
    }

    private func appendProgressEvent(requestID: String, projectKey: String, sessionID: String?, kind: String, text: String) {
        guard projectKey == activeProjectKey else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return }
        let now = Date().timeIntervalSince1970
        var activity = progressActivity ?? ProgressActivityState(
            requestID: requestID,
            projectKey: projectKey,
            sessionID: sessionID,
            events: [],
            isExpanded: false,
            timedOut: false,
            lastUpdateAt: now
        )
        if activity.requestID != requestID || activity.projectKey != projectKey {
            activity = ProgressActivityState(
                requestID: requestID,
                projectKey: projectKey,
                sessionID: sessionID,
                events: [],
                isExpanded: false,
                timedOut: false,
                lastUpdateAt: now
            )
        }
        activity.events.append(ProgressActivityEvent(
            id: "\(requestID)-\(activity.events.count)-\(Int(now * 1000))",
            kind: kind,
            text: trimmed,
            timestamp: now
        ))
        activity.lastUpdateAt = now
        activity.timedOut = false
        progressActivity = activity
        if runStatus != .cancelling {
            runStatus = .running
        }
        if runStatus == .cancelling {
            suspendProgressTimeout()
        } else if shouldScheduleProgressTimeout(for: kind) {
            scheduleProgressTimeout(requestID: requestID, projectKey: projectKey)
        } else {
            suspendProgressTimeout()
        }
    }

    private func shouldScheduleProgressTimeout(for kind: String) -> Bool {
        kind != "gateway_status"
    }

    private func scheduleProgressTimeout(requestID: String, projectKey: String) {
        progressTimeoutTask?.cancel()
        let interval = progressTimeoutInterval
        progressTimeoutTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: UInt64(max(0.001, interval) * 1_000_000_000))
            } catch {
                return
            }
            await MainActor.run {
                self?.handleProgressTimeout(requestID: requestID, projectKey: projectKey)
            }
        }
    }

    private func handleProgressTimeout(requestID: String, projectKey: String) {
        guard var activity = progressActivity, activity.requestID == requestID, activity.projectKey == projectKey, activity.timedOut == false else { return }
        activity.timedOut = true
        activity.events.append(ProgressActivityEvent(
            id: "\(requestID)-timeout",
            kind: "timeout",
            text: Self.gatewayTimeoutAudioText,
            timestamp: Date().timeIntervalSince1970
        ))
        progressActivity = activity
        runStatus = .error
    }

    private func suspendProgressTimeout() {
        progressTimeoutTask?.cancel()
        progressTimeoutTask = nil
    }

    private func clearProgressActivity(requestID: String? = nil) {
        if let requestID, progressActivity?.requestID != requestID { return }
        suspendProgressTimeout()
        progressActivity = nil
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
        failCurrentSocket(message: message)
    }

    private func handleSocketFailure(taskID: ObjectIdentifier, message: String) {
        guard let task, ObjectIdentifier(task) == taskID else {
            LogosConnectionLog.logger.warning("Ignoring stale WebSocket failure callback task_id=\(String(describing: taskID), privacy: .public) message=\(message, privacy: .public) current_task=\(LogosConnectionLog.taskIDDescription(self.task), privacy: .public)")
            return
        }
        LogosConnectionLog.logger.error("WebSocket failure accepted task_id=\(String(describing: taskID), privacy: .public) message=\(message, privacy: .public)")
        failCurrentSocket(message: message)
    }

    private func failCurrentSocket(message: String) {
        LogosConnectionLog.logger.error("Failing current socket message=\(message, privacy: .public) previous_state=\(self.connectionState.rawValue, privacy: .public) open=\(self.isWebSocketOpen, privacy: .public) in_flight_final_speech=\(self.inFlightFinalSpeechDrafts.count, privacy: .public)")
        self.task = nil
        isWebSocketOpen = false
        restoreInFlightFinalSpeechDrafts(reason: message)
        if connectionState != .disconnected {
            recordError(message)
            clearRunScopedStateForSocketClosure(runStatus: .error)
            connectionState = .error
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
        let signature = LogosAuthentication.signHello(
            secret: LogosSettings.normalizedSecret(settings.secret),
            deviceID: settings.deviceID,
            requestID: requestID,
            projectKey: activeProjectKey,
            timestampMilliseconds: timestampMilliseconds,
            nonce: nonce
        )
        let afterServerSeq = latestServerSeq()
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
                "capabilities": ["text", "speech", "projects", "approval", "clarification", "playback_audio"]
            ]
        ], requiresAuthentication: false)
        LogosConnectionLog.logger.info("Hello send requested sent=\(sent, privacy: .public) request_id=\(requestID, privacy: .public)")
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
        do {
            let data = try JSONSerialization.data(withJSONObject: frame, options: [])
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
                        self.recordError(error.localizedDescription)
                        self.connectionState = .error
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
                    self.restoreInFlightFinalSpeechDrafts(reason: error.localizedDescription)
                    self.task = nil
                    self.isWebSocketOpen = false
                    self.recordError(error.localizedDescription)
                    self.clearRunScopedStateForSocketClosure(runStatus: .error)
                    self.connectionState = .error
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
        connectionState = .connected
        lastError = nil
        LogosConnectionLog.logger.info("Marked connected previous_state=\(previousState.rawValue, privacy: .public) had_completed_first_connection=\(hadCompletedFirstConnection, privacy: .public) active_project=\(self.activeProjectKey, privacy: .public)")
    }

    private func handleSocketMessage(_ message: URLSessionWebSocketTask.Message) {
        switch message {
        case .string(let string):
            handleFrameString(string)
        case .data(let data):
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
        guard
            let data = string.data(using: .utf8),
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let type = root["type"] as? String
        else {
            LogosConnectionLog.logger.error("Inbound frame parse failed bytes=\(string.utf8.count, privacy: .public)")
            return
        }
        LogosConnectionLog.logger.info("Inbound frame parsed \(LogosConnectionLog.inboundFrameSummary(root), privacy: .public) bytes=\(string.utf8.count, privacy: .public)")
        if type != "error" {
            lastError = nil
        }
        switch type {
        case "hello":
            markConnected()
            if task != nil {
                registerDevice(apnsToken: pendingAPNSToken)
                requestProjects()
            }
        case "registered":
            markConnected()
            pendingAPNSToken = nil
        case "projects_list":
            handleProjectsList(root)
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
                failCurrentSocket(message: message)
            } else {
                handleAdapterError(root: root, code: code, message: message)
            }
        default:
            LogosConnectionLog.logger.warning("Unhandled inbound frame type=\(type, privacy: .public)")
            break
        }
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
        projects = rawProjects.compactMap(LogosProject.from(dictionary:))
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
        let decodedMessages = rawMessages.compactMap(LogosMessage.from(dictionary:))
        var persistedMessages: [LogosMessage] = []
        for message in decodedMessages {
            if message.isProgressUpdate {
                appendProgressEvent(
                    requestID: root["request_id"] as? String ?? message.messageID,
                    projectKey: message.projectKey,
                    sessionID: message.sessionID,
                    kind: message.progressEventKind,
                    text: message.content
                )
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
        let batchRequestID = root["request_id"] as? String
        let finalMessageArrived = persistedMessages.contains { message in
            guard message.projectKey == activeProjectKey, message.role != "user", message.isFinal else { return false }
            guard progressActivity != nil else { return true }
            return shouldClearProgressActivity(for: message, requestID: batchRequestID)
        }
        if finalMessageArrived, runStatus != .cancelling {
            clearProgressActivity()
            runStatus = .idle
        }
        refreshMessages()
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
        ackClearTask?.cancel()
        let ackID = id?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? id! : UUID().uuidString
        let ackProjectKey = projectKey ?? activeProjectKey
        guard let state = FastAckState.next(id: ackID, projectKey: ackProjectKey, text: text, ttlMilliseconds: ttlMilliseconds) else {
            clearAck()
            return
        }
        ackState = state
        ackText = state.text
        let delay = UInt64(state.ttlMilliseconds) * 1_000_000
        ackClearTask = Task { [weak self, ackID = state.id, ackProjectKey = state.projectKey] in
            do {
                try await Task.sleep(nanoseconds: delay)
            } catch {
                return
            }
            self?.clearAck(matching: ackID, projectKey: ackProjectKey)
        }
    }

    private func clearAck(matching id: String? = nil, projectKey: String? = nil) {
        if let id, ackState?.id != id { return }
        if let projectKey, ackState?.projectKey != projectKey { return }
        ackClearTask?.cancel()
        ackClearTask = nil
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
        pendingCancelRequestID = nil
        clearInteractionStateForCancel()
        suspendProgressTimeout()
        clearAck()
        clearProgressActivity()
        clearAudioPlaybackForProjectSwitch()
    }

    private func clearRunScopedStateForSocketClosure(runStatus nextStatus: LogosRunStatus) {
        runStatus = nextStatus
        pendingCancelRequestID = nil
        clearInteractionStateForCancel()
        clearAck()
        clearProgressActivity()
        clearAudioPlaybackForProjectSwitch()
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
        if code == "approval_not_pending" {
            if approvalCard?.id == requestID { approvalCard = nil }
            if runStatus == .awaitingApproval { runStatus = .idle }
        } else if code == "clarify_not_pending" {
            if clarifyCard?.id == requestID { clarifyCard = nil }
            if runStatus == .awaitingClarification { runStatus = .idle }
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

    private func shouldClearProgressActivity(for message: LogosMessage, requestID: String?) -> Bool {
        guard let activity = progressActivity else { return false }
        guard runStatus != .cancelling else { return false }
        guard message.projectKey == activeProjectKey, message.role != "user", message.isFinal else { return false }
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
            if message.isProgressUpdate {
                appendProgressEvent(
                    requestID: root["request_id"] as? String ?? message.messageID,
                    projectKey: message.projectKey,
                    sessionID: message.sessionID,
                    kind: message.progressEventKind,
                    text: message.content
                )
                return
            }
            if shouldClearProgressActivity(for: message, requestID: root["request_id"] as? String) {
                clearProgressActivity()
                runStatus = .idle
            }
            store.upsert(message)
            pendingMessages.reconcile(with: message)
            refreshMessages()
            if message.projectKey == activeProjectKey && message.role != "user" && (op == "message_appended" || op == "message_updated") {
                clearAck()
            }
            maybeAutoPlayLiveAssistantMessage(message, op: op, requestID: root["request_id"] as? String)
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

    private func handleToolProgress(_ root: [String: Any]) {
        guard isActiveProjectFrame(root) else { return }
        let payload = root["payload"] as? [String: Any] ?? [:]
        let projectKey = frameProjectKey(root) ?? activeProjectKey
        let requestID = root["request_id"] as? String ?? payload["request_id"] as? String ?? "progress-\(projectKey)"
        let sessionID = root["session_id"] as? String ?? payload["session_id"] as? String
        let kind = payload["kind"] as? String ?? payload["progress_kind"] as? String ?? root["type"] as? String ?? "progress"
        let text = payload["text"] as? String ?? payload["message"] as? String ?? payload["summary"] as? String ?? kind
        appendProgressEvent(requestID: requestID, projectKey: projectKey, sessionID: sessionID, kind: kind, text: text)
    }

    private func handleRunStatus(_ root: [String: Any]) {
        guard isActiveProjectFrame(root) else { return }
        guard let payload = root["payload"] as? [String: Any], let statusRaw = payload["status"] as? String else { return }
        let previous = runStatus
        let next = LogosRunStatus(rawValue: statusRaw) ?? .error
        if previous == .cancelling {
            if isCurrentCancelTerminalRunStatus(root: root, payload: payload, status: next) {
                clearRunScopedStateForSocketClosure(runStatus: next)
            }
            return
        }
        if next == .idle, let activity = progressActivity, activity.timedOut == false {
            runStatus = .running
            return
        }
        runStatus = next
        if next == .cancelling || next == .awaitingApproval || next == .awaitingClarification {
            suspendProgressTimeout()
        }
        if isTerminalRunStatus(next) {
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

    private func maybeAutoPlayLiveAssistantMessage(_ message: LogosMessage, op: String?, requestID: String?) {
        guard connectionState == .connected, task != nil, isWebSocketOpen else { return }
        guard message.projectKey == activeProjectKey else { return }
        guard runStatus != .cancelling else { return }
        guard message.status == "persisted", message.role != "user", message.isFinal, message.isProgressUpdate == false else { return }
        guard op == "message_appended" || op == "message_updated" else { return }
        if let progress = progressActivity {
            guard let requestID, requestID.isEmpty == false, requestID == progress.requestID else { return }
            if let progressSessionID = progress.sessionID, progressSessionID != message.sessionID {
                return
            }
        }
        let key = message.id
        guard autoPlayedMessageKeys.insert(key).inserted else { return }
        requestPlayback(message: message, mode: "final_auto")
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
        suspendProgressTimeout()
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
        suspendProgressTimeout()
        pendingInteractionResponseID = nil
        clearAck()
    }

    private func handleAudioChunk(_ root: [String: Any]) {
        guard
            let payload = root["payload"] as? [String: Any],
            let audioID = payload["audio_id"] as? String,
            shouldAcceptAudioFrame(root, audioID: audioID),
            let data = payload["data"] as? String
        else { return }
        let chunkIndex = payload["chunk_index"] as? Int ?? Int(payload["chunk_index"] as? String ?? "") ?? 0
        do {
            requestedAudioIDs.insert(audioID)
            try audioPlayback.appendChunk(audioID: audioID, chunkIndex: chunkIndex, base64: data)
            updateAudioOverlay(audioID: audioID, phase: .receiving, detail: "Receiving audio", canPause: false, canStop: true, spectrumBins: spectrumBins(fromBase64: data))
            playbackStatus = "Receiving audio"
        } catch {
            requestedAudioIDs.remove(audioID)
            recordError(error.localizedDescription)
            playbackStatus = nil
        }
    }

    private func handleAudioEnd(_ root: [String: Any]) {
        guard
            let payload = root["payload"] as? [String: Any],
            let audioID = payload["audio_id"] as? String,
            shouldAcceptAudioFrame(root, audioID: audioID)
        else { return }
        let chunkCount = payload["chunk_count"] as? Int ?? Int(payload["chunk_count"] as? String ?? "")
        do {
            let result = try audioPlayback.finish(audioID: audioID, expectedChunkCount: chunkCount)
            requestedAudioIDs.remove(audioID)
            activeAudioID = audioID
            updateAudioOverlay(audioID: audioID, phase: .playing, detail: "Playing", canPause: true, canStop: true)
            playbackStatus = result.started ? "Playing audio" : "Audio did not start"
        } catch {
            requestedAudioIDs.remove(audioID)
            recordError(error.localizedDescription)
            playbackStatus = nil
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

    private func latestServerSeq() -> Int {
        messages.map(\.serverSeq).max() ?? 0
    }

    private func addPendingMessage(_ message: LogosMessage) {
        pendingMessages.add(message, persisted: store.loadMessages(projectKey: message.projectKey))
        refreshMessages()
    }

    private func handlePendingTextSendFailure(messageID: String, projectKey: String, error _: Error) {
        pendingMessages.remove(messageID: messageID)
        if projectKey == activeProjectKey {
            refreshMessages()
        }
    }

    private func handleFinalSpeechSendSuccess(inputID: String, pending: LogosMessage) {
        guard inFlightFinalSpeechDrafts.removeValue(forKey: inputID) != nil else { return }
        addPendingMessage(pending)
    }

    private func handleFinalSpeechSendFailure(_ draft: UndeliveredSpeechDraft, error: Error) {
        guard inFlightFinalSpeechDrafts.removeValue(forKey: draft.inputID) != nil else { return }
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
        let persisted = visibleMessages(from: store.loadMessages(projectKey: activeProjectKey))
        pendingMessages.reconcile(with: persisted)
        messages = pendingMessages.merged(with: persisted, projectKey: activeProjectKey)
    }

    private func visibleMessages(from persisted: [LogosMessage]) -> [LogosMessage] {
        persisted.filter { $0.isProgressUpdate == false }
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
