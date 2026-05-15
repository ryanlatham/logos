import Foundation
import UIKit

@MainActor
final class LogosClient: ObservableObject {
    @Published var settings = LogosSettings() {
        didSet { settings.persist() }
    }
    @Published private(set) var connectionState: LogosConnectionState = .disconnected
    @Published private(set) var projects: [LogosProject] = []
    @Published var activeProjectKey: String = "default" {
        didSet {
            messages = store.loadMessages(projectKey: activeProjectKey)
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

    private var task: URLSessionWebSocketTask?
    private let store = SQLiteMessageStore()
    private let audioPlayback = AudioPlaybackController()
    private var didAutoConnect = false
    private var pendingAPNSToken: String?

    init() {
        messages = store.loadMessages(projectKey: activeProjectKey)
    }

    func connectIfRequestedByEnvironment() {
        guard settings.autoConnect, didAutoConnect == false else { return }
        didAutoConnect = true
        connect()
    }

    func connect() {
        disconnect()
        guard let url = URL(string: settings.urlString) else {
            lastError = "Invalid adapter URL"
            connectionState = .error
            return
        }
        connectionState = .connecting
        let task = URLSession.shared.webSocketTask(with: url)
        self.task = task
        task.resume()
        receiveLoop()
        sendHello()
        registerDevice(apnsToken: pendingAPNSToken)
        requestProjects()
    }

    func disconnect() {
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        connectionState = .disconnected
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
        if sent { messages.append(pending) }
        return sent
    }

    func sendSpeech(text: String, isFinal: Bool, inputID: String, partialSeq: Int, startedAtMilliseconds: Int64) {
        guard ensureConnectedForUserAction(isFinal ? "send speech" : "stream speech") else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if isFinal {
            messages.append(LogosMessage.pending(projectKey: activeProjectKey, content: trimmed))
        }
        sendFrame(LogosSpeechFrame.make(
            text: trimmed,
            isFinal: isFinal,
            inputID: inputID,
            partialSeq: partialSeq,
            startedAtMilliseconds: startedAtMilliseconds,
            deviceID: settings.deviceID,
            projectKey: activeProjectKey
        ))
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
        playbackStatus = "Requesting audio"
        sendFrame([
            "type": "playback_audio",
            "request_id": UUID().uuidString,
            "device_id": settings.deviceID,
            "project_key": message.projectKey,
            "session_id": message.sessionID,
            "payload": [
                "message_id": message.messageID,
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
        guard settings.secret.isEmpty == false else {
            lastError = "Missing Logos device secret"
            connectionState = .error
            return
        }
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
    private func sendFrame(_ frame: [String: Any]) -> Bool {
        guard let task else {
            lastError = "Not connected to Logos adapter. Reconnect before sending."
            connectionState = .disconnected
            return false
        }
        do {
            let data = try JSONSerialization.data(withJSONObject: frame, options: [])
            let string = String(decoding: data, as: UTF8.self)
            task.send(.string(string)) { [weak self] error in
                guard let error else { return }
                Task { @MainActor in
                    self?.lastError = error.localizedDescription
                    self?.connectionState = .error
                }
            }
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    private func receiveLoop() {
        task?.receive { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                switch result {
                case .success(let message):
                    self.connectionState = .connected
                    self.handleSocketMessage(message)
                    self.receiveLoop()
                case .failure(let error):
                    self.lastError = error.localizedDescription
                    self.connectionState = .error
                }
            }
        }
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

    private func handleFrameString(_ string: String) {
        guard
            let data = string.data(using: .utf8),
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let type = root["type"] as? String
        else { return }
        switch type {
        case "hello", "registered":
            connectionState = .connected
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
        for message in rawMessages.compactMap(LogosMessage.from(dictionary:)) {
            store.upsert(message)
        }
        let pending = payload["pending_interactions"] as? [[String: Any]] ?? []
        for interaction in pending {
            handlePendingInteraction(interaction)
        }
        if payload.keys.contains("pending_interactions") {
            reconcilePendingInteractionCards(pending, projectKey: root["project_key"] as? String ?? activeProjectKey)
        }
        messages = store.loadMessages(projectKey: activeProjectKey)
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
            messages.removeAll { $0.status == "pending" && $0.content == message.content && $0.role == message.role }
            messages = store.loadMessages(projectKey: activeProjectKey)
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
            let data = payload["data"] as? String
        else { return }
        let chunkIndex = payload["chunk_index"] as? Int ?? Int(payload["chunk_index"] as? String ?? "") ?? 0
        do {
            try audioPlayback.appendChunk(audioID: audioID, chunkIndex: chunkIndex, base64: data)
            playbackStatus = "Receiving audio"
        } catch {
            lastError = error.localizedDescription
            playbackStatus = nil
        }
    }

    private func handleAudioEnd(_ root: [String: Any]) {
        guard
            let payload = root["payload"] as? [String: Any],
            let audioID = payload["audio_id"] as? String
        else { return }
        let chunkCount = payload["chunk_count"] as? Int ?? Int(payload["chunk_count"] as? String ?? "")
        do {
            _ = try audioPlayback.finish(audioID: audioID, expectedChunkCount: chunkCount)
            playbackStatus = "Playing audio"
        } catch {
            lastError = error.localizedDescription
            playbackStatus = nil
        }
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
}
