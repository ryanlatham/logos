import Foundation
import UIKit

protocol WebSocketTasking: AnyObject {
    func resume()
    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?)
    func send(_ message: URLSessionWebSocketTask.Message, completionHandler: @escaping @Sendable (Error?) -> Void)
    func receive(completionHandler: @escaping @Sendable (Result<URLSessionWebSocketTask.Message, Error>) -> Void)
}

extension URLSessionWebSocketTask: WebSocketTasking {}

protocol WebSocketTaskMaking {
    func webSocketTask(with url: URL) -> any WebSocketTasking
}

struct URLSessionWebSocketTaskFactory: WebSocketTaskMaking {
    func webSocketTask(with url: URL) -> any WebSocketTasking {
        URLSession.shared.webSocketTask(with: url)
    }
}

@MainActor
final class LogosClient: ObservableObject {
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
    private var didAutoConnect = false
    private var pendingAPNSToken: String?
    private var pendingMessages = PendingMessageBuffer()
    private var inFlightFinalSpeechDrafts: [String: UndeliveredSpeechDraft] = [:]

    init(
        store: SQLiteMessageStore = SQLiteMessageStore(),
        socketFactory: any WebSocketTaskMaking = URLSessionWebSocketTaskFactory()
    ) {
        self.store = store
        self.socketFactory = socketFactory
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
        guard settings.autoConnect, didAutoConnect == false else { return }
        didAutoConnect = true
        connect()
    }

    func connect() {
        cancelCurrentSocket()
        lastError = nil
        guard let url = URL(string: settings.urlString) else {
            lastError = "Invalid adapter URL"
            connectionState = .error
            return
        }
        guard settings.secret.isEmpty == false else {
            lastError = "Missing Logos device secret"
            connectionState = .error
            return
        }
        let connectionID = connectionLifecycle.startConnection()
        connectionState = .connecting
        let task = socketFactory.webSocketTask(with: url)
        self.task = task
        task.resume()
        receiveLoop(connectionID: connectionID)
        sendHello()
        registerDevice(apnsToken: pendingAPNSToken)
        requestProjects()
    }

    func disconnect() {
        cancelCurrentSocket()
        lastError = nil
        connectionState = .disconnected
    }

    private func cancelCurrentSocket() {
        let oldTask = task
        task = nil
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
        }
        guard task != nil else { return }
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
        if sent, payload["apns_token"] != nil {
            pendingAPNSToken = nil
        }
    }

    func handleNotificationRoute(_ route: LogosNotificationRoute) {
        activeProjectKey = route.projectKey
        if connectionState != .connected {
            connect()
        }
        let afterSeq = max((route.serverSeq ?? 1) - 1, 0)
        requestMessages(afterServerSeq: afterSeq)
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
                "mode": "summary",
                "text": message.content
            ]
        ])
    }

    private func ensureConnectedForUserAction(_ action: String) -> Bool {
        guard task != nil, connectionState == .connected else {
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

    private func sendHello() {
        let requestID = UUID().uuidString
        let timestampMilliseconds = Int64(Date().timeIntervalSince1970 * 1000)
        let nonce = UUID().uuidString
        let signature = LogosAuthentication.signHello(
            secret: settings.secret,
            deviceID: settings.deviceID,
            requestID: requestID,
            projectKey: activeProjectKey,
            timestampMilliseconds: timestampMilliseconds,
            nonce: nonce
        )
        sendFrame([
            "type": "hello",
            "request_id": requestID,
            "device_id": settings.deviceID,
            "project_key": activeProjectKey,
            "payload": [
                "timestamp_ms": timestampMilliseconds,
                "nonce": nonce,
                "signature": signature,
                "after_server_seq": latestServerSeq(),
                "capabilities": ["text", "speech", "projects", "approval", "clarification", "playback_audio"]
            ]
        ])
    }

    @discardableResult
    private func sendFrame(
        _ frame: [String: Any],
        onCompletion: ((Result<Void, Error>) -> Void)? = nil
    ) -> Bool {
        guard let task else {
            lastError = "Not connected to Logos adapter. Reconnect before sending."
            connectionState = .disconnected
            return false
        }
        let connectionID = connectionLifecycle.activeConnectionID
        do {
            let data = try JSONSerialization.data(withJSONObject: frame, options: [])
            let string = String(decoding: data, as: UTF8.self)
            task.send(.string(string)) { [weak self, weak task] error in
                Task { @MainActor in
                    guard let self else { return }
                    guard self.connectionLifecycle.accepts(connectionID), let task, self.isCurrentTask(task) else {
                        onCompletion?(.failure(LogosSocketSendError.staleConnection))
                        return
                    }
                    if let error {
                        self.lastError = error.localizedDescription
                        self.connectionState = .error
                        onCompletion?(.failure(error))
                    } else {
                        self.lastError = nil
                        onCompletion?(.success(()))
                    }
                }
            }
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    private func receiveLoop(connectionID: UUID) {
        guard let task else { return }
        task.receive { [weak self, weak task] result in
                Task { @MainActor in
                    guard let self else { return }
                    guard self.connectionLifecycle.accepts(connectionID), let task, self.isCurrentTask(task) else { return }
                    switch result {
                    case .success(let message):
                        self.markConnected()
                    self.handleSocketMessage(message)
                    self.receiveLoop(connectionID: connectionID)
                    case .failure(let error):
                        self.restoreInFlightFinalSpeechDrafts(reason: error.localizedDescription)
                        self.task = nil
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
        connectionState = .connected
        lastError = nil
    }

    private func handleSocketMessage(_ message: URLSessionWebSocketTask.Message) {
        switch message {
        case .string(let string):
            handleFrameString(string)
        case .data(let data):
            if let string = String(data: data, encoding: .utf8) {
                handleFrameString(string)
            }
        @unknown default:
            break
        }
    }

    func handleFrameString(_ string: String) {
        guard
            let data = string.data(using: .utf8),
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let type = root["type"] as? String
        else { return }
        if type != "error" {
            lastError = nil
        }
        switch type {
        case "hello", "registered":
            markConnected()
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
            lastError = payload?["message"] as? String ?? "Logos adapter error"
        default:
            break
        }
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
