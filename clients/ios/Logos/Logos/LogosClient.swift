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
            clearCardsNotMatchingActiveProject()
        }
    }
    @Published private(set) var messages: [LogosMessage] = []
    @Published private(set) var runStatus: LogosRunStatus = .idle
    @Published private(set) var approvalCard: ApprovalCard?
    @Published private(set) var clarifyCard: ClarifyCard?
    @Published private(set) var pendingInteractionResponseID: String?
    @Published var lastError: String?
    @Published var playbackStatus: String?
    @Published var ackText: String?
    @Published private(set) var undeliveredSpeechDraft: UndeliveredSpeechDraft?

    private var task: (any WebSocketTasking)?
    private var connectionLifecycle = LogosConnectionLifecycle()
    private let store: SQLiteMessageStore
    private let socketFactory: any WebSocketTaskMaking
    private let audioPlayback = AudioPlaybackController()
    private var requestedAudioIDs = Set<String>()
    private var activeAudioID: String?
    private var autoPlayedMessageKeys = Set<String>()
    private var pendingAPNSToken: String?
    private let pairingExchanger: any PairingCredentialExchanging
    private var isWebSocketOpen = false
    private var pendingMessages = PendingMessageBuffer()
    private var inFlightFinalSpeechDrafts: [String: UndeliveredSpeechDraft] = [:]

    init(
        store: SQLiteMessageStore = SQLiteMessageStore(),
        socketFactory: any WebSocketTaskMaking = URLSessionWebSocketTaskFactory(),
        pairingExchanger: any PairingCredentialExchanging = WebSocketPairingCredentialExchanger()
    ) {
        self.store = store
        self.socketFactory = socketFactory
        self.pairingExchanger = pairingExchanger
        messages = store.loadMessages(projectKey: activeProjectKey)
        audioPlayback.onPlaybackFinished = { [weak self] audioID, succeeded in
            Task { @MainActor in
                guard let self, self.activeAudioID == audioID else { return }
                self.activeAudioID = nil
                self.playbackStatus = succeeded ? "Audio finished" : nil
                if !succeeded {
                    self.lastError = "Audio playback ended unexpectedly. Check device volume and output route."
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
            lastError = "Invalid adapter URL"
            connectionState = .error
            return
        }
        guard settings.secret.isEmpty == false else {
            LogosConnectionLog.logger.error("Connect failed before socket creation: missing Logos device secret")
            lastError = "Missing Logos device secret"
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
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let pending = LogosMessage.pending(projectKey: activeProjectKey, content: trimmed)
        let sent = sendFrame([
            "type": "text_input",
            "request_id": UUID().uuidString,
            "device_id": settings.deviceID,
            "project_key": activeProjectKey,
            "payload": [
                "text": trimmed,
                "client_msg_id": pending.messageID,
                "is_final": true
            ]
        ])
        if sent {
            addPendingMessage(pending)
        }
        return sent
    }

    @discardableResult
    func sendSpeech(text: String, isFinal: Bool, inputID: String, partialSeq: Int, startedAtMilliseconds: Int64) -> Bool {
        guard ensureConnectedForUserAction(isFinal ? "send speech" : "stream speech") else { return false }
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
            lastError = "Logos pairing failed: \(error.localizedDescription)"
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
        activeProjectKey = projectKey
        sendFrame([
            "type": "switch_project",
            "request_id": UUID().uuidString,
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
        guard ensureConnectedForUserAction("approve request") else { return }
        let sent = sendFrame([
            "type": "approval_response",
            "request_id": approvalCard.id,
            "device_id": settings.deviceID,
            "project_key": approvalCard.projectKey,
            "payload": ["decision": "approve"]
        ])
        if sent {
            pendingInteractionResponseID = approvalCard.id
            ackText = "Approval sent; waiting for Hermes."
        }
    }

    func denyCurrentRequest() {
        guard let approvalCard else { return }
        guard ensureConnectedForUserAction("deny request") else { return }
        let sent = sendFrame([
            "type": "approval_response",
            "request_id": approvalCard.id,
            "device_id": settings.deviceID,
            "project_key": approvalCard.projectKey,
            "payload": ["decision": "deny"]
        ])
        if sent {
            pendingInteractionResponseID = approvalCard.id
            ackText = "Denial sent; waiting for Hermes."
        }
    }

    @discardableResult
    func answerClarification(_ text: String) -> Bool {
        guard let clarifyCard else { return false }
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
        ])
        if sent {
            pendingInteractionResponseID = clarifyCard.id
            ackText = "Clarification sent; waiting for Hermes."
        }
        return sent
    }

    func cancelRun() {
        guard ensureConnectedForUserAction("stop the run") else { return }
        sendFrame([
            "type": "run_cancel",
            "request_id": UUID().uuidString,
            "device_id": settings.deviceID,
            "project_key": activeProjectKey,
            "payload": [:]
        ])
    }

    func playback(message: LogosMessage) {
        guard ensureConnectedForUserAction("play audio") else { return }
        let audioID = "ios-\(UUID().uuidString)"
        requestedAudioIDs.insert(audioID)
        playbackStatus = "Requesting audio"
        sendFrame([
            "type": "playback_audio",
            "request_id": UUID().uuidString,
            "device_id": settings.deviceID,
            "project_key": message.projectKey,
            "session_id": message.sessionID,
            "payload": [
                "message_id": message.messageID,
                "audio_id": audioID,
                "mode": "full",
                "text": message.content
            ]
        ])
    }

    private func ensureConnectedForUserAction(_ action: String) -> Bool {
        guard task != nil, connectionState == .connected else {
            LogosConnectionLog.logger.warning("User action blocked because Logos is not connected action=\(action, privacy: .public) state=\(self.connectionState.rawValue, privacy: .public) open=\(self.isWebSocketOpen, privacy: .public) has_task=\(self.task != nil, privacy: .public)")
            lastError = "Cannot \(action): Logos is not connected."
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
            lastError = message
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
                lastError = "Not connected to Logos adapter. Reconnect before sending."
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
                        self.lastError = error.localizedDescription
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
            lastError = error.localizedDescription
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
                    self.lastError = error.localizedDescription
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
                lastError = message
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
        if let active = payload["active_project_key"] as? String, !active.isEmpty {
            activeProjectKey = active
        } else if projects.contains(where: { $0.projectKey == activeProjectKey }) == false, let first = projects.first {
            activeProjectKey = first.projectKey
        }
    }

    private func handleMessagesBatch(_ root: [String: Any]) {
        guard let payload = root["payload"] as? [String: Any] else { return }
        let rawMessages = payload["messages"] as? [[String: Any]] ?? []
        let decodedMessages = rawMessages.compactMap(LogosMessage.from(dictionary:))
        for message in decodedMessages {
            store.upsert(message)
        }
        pendingMessages.reconcile(with: decodedMessages)
        let pending = payload["pending_interactions"] as? [[String: Any]] ?? []
        for interaction in pending {
            handlePendingInteraction(interaction)
        }
        if payload.keys.contains("pending_interactions") {
            reconcilePendingInteractionCards(pending, projectKey: root["project_key"] as? String ?? activeProjectKey)
        }
        refreshMessages()
    }

    private func reconcilePendingInteractionCards(_ pending: [[String: Any]], projectKey: String) {
        guard projectKey == activeProjectKey else { return }
        let pendingIDs = Set(pending.compactMap { interaction in
            interaction["request_id"] as? String ?? (interaction["payload"] as? [String: Any])?["approval_id"] as? String ?? (interaction["payload"] as? [String: Any])?["clarify_id"] as? String
        })
        if let approvalCard, pendingIDs.contains(approvalCard.id) == false {
            self.approvalCard = nil
        }
        if let clarifyCard, pendingIDs.contains(clarifyCard.id) == false {
            self.clarifyCard = nil
        }
        if let pendingInteractionResponseID, pendingIDs.contains(pendingInteractionResponseID) == false {
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

    private func handleStateUpdate(_ root: [String: Any]) {
        guard let payload = root["payload"] as? [String: Any] else { return }
        let op = payload["op"] as? String
        if op == "fast_ack" {
            ackText = payload["ack_text"] as? String
        }
        if let projectDict = payload["project"] as? [String: Any], let project = LogosProject.from(dictionary: projectDict) {
            upsertProject(project)
            activeProjectKey = project.projectKey
        }
        if let messageDict = payload["message"] as? [String: Any], let message = LogosMessage.from(dictionary: messageDict) {
            store.upsert(message)
            pendingMessages.reconcile(with: message)
            refreshMessages()
            maybeAutoPlayLiveAssistantMessage(message, op: op)
        }
    }

    private func handleRunStatus(_ root: [String: Any]) {
        guard let payload = root["payload"] as? [String: Any], let statusRaw = payload["status"] as? String else { return }
        let previous = runStatus
        let next = LogosRunStatus(rawValue: statusRaw) ?? .error
        runStatus = next
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

    private func maybeAutoPlayLiveAssistantMessage(_ message: LogosMessage, op: String?) {
        guard connectionState == .connected, task != nil, isWebSocketOpen else { return }
        guard message.projectKey == activeProjectKey else { return }
        guard message.status == "persisted", message.role != "user" else { return }
        guard op == "message_appended" || op == "message_updated" else { return }
        let key = message.id
        guard autoPlayedMessageKeys.insert(key).inserted else { return }
        playback(message: message)
    }

    private func handleApprovalRequest(_ root: [String: Any]) {
        guard let payload = root["payload"] as? [String: Any] else { return }
        let projectKey = root["project_key"] as? String ?? activeProjectKey
        guard projectKey == activeProjectKey else { return }
        approvalCard = ApprovalCard(
            id: root["request_id"] as? String ?? payload["approval_id"] as? String ?? UUID().uuidString,
            projectKey: projectKey,
            title: payload["title"] as? String ?? "Approval required",
            summary: payload["summary"] as? String ?? "Hermes needs approval.",
            commandPreview: payload["command_preview"] as? String ?? "",
            risk: payload["risk"] as? String ?? ""
        )
        runStatus = .awaitingApproval
        pendingInteractionResponseID = nil
    }

    private func handleClarifyRequest(_ root: [String: Any]) {
        guard let payload = root["payload"] as? [String: Any] else { return }
        let projectKey = root["project_key"] as? String ?? activeProjectKey
        guard projectKey == activeProjectKey else { return }
        clarifyCard = ClarifyCard(
            id: root["request_id"] as? String ?? payload["clarify_id"] as? String ?? UUID().uuidString,
            projectKey: projectKey,
            question: payload["question"] as? String ?? "Hermes needs clarification.",
            choices: payload["choices"] as? [String] ?? [],
            allowFreeText: payload["allow_free_text"] as? Bool ?? true
        )
        runStatus = .awaitingClarification
        pendingInteractionResponseID = nil
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
            playbackStatus = "Receiving audio"
        } catch {
            requestedAudioIDs.remove(audioID)
            lastError = error.localizedDescription
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
            playbackStatus = result.started ? "Playing audio" : "Audio did not start"
        } catch {
            requestedAudioIDs.remove(audioID)
            lastError = error.localizedDescription
            playbackStatus = nil
        }
    }

    private func shouldAcceptAudioFrame(_ root: [String: Any], audioID: String) -> Bool {
        if let frameDeviceID = root["device_id"] as? String, frameDeviceID.isEmpty == false {
            guard frameDeviceID == settings.deviceID else { return false }
            return true
        }
        return requestedAudioIDs.contains(audioID)
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

    private func handleFinalSpeechSendSuccess(inputID: String, pending: LogosMessage) {
        inFlightFinalSpeechDrafts.removeValue(forKey: inputID)
        addPendingMessage(pending)
    }

    private func handleFinalSpeechSendFailure(_ draft: UndeliveredSpeechDraft, error: Error) {
        inFlightFinalSpeechDrafts.removeValue(forKey: draft.inputID)
        pendingMessages.remove(messageID: draft.inputID)
        refreshMessages()
        undeliveredSpeechDraft = UndeliveredSpeechDraft(
            inputID: draft.inputID,
            projectKey: draft.projectKey,
            text: draft.text,
            reason: error.localizedDescription
        )
        lastError = "Speech was not sent: \(error.localizedDescription)"
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
        let persisted = store.loadMessages(projectKey: activeProjectKey)
        pendingMessages.reconcile(with: persisted)
        messages = pendingMessages.merged(with: persisted, projectKey: activeProjectKey)
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
