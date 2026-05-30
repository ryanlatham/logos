import Foundation
import Observation

/// Client-side dependencies the WebSocket connection/transport subsystem needs from its owner
/// (WS1 P5, mirroring `AudioCoordinatorHost`/`ProgressActivityManagerHost`/`InteractionControllerHost`/
/// `NotificationRouterHost`). The `LogosConnection` reaches back through this narrow seam instead of
/// holding the whole `LogosClient`, so the transport/auth/crypto core stays decoupled from the
/// message store, progress pipeline, interaction cards, and audio. The host is held `weak`; every
/// member is a no-op-safe call the connection routes non-transport work through.
@MainActor
protocol LogosConnectionHost: AnyObject {
    // MARK: Settings the connect/hello/pin paths read
    /// The adapter URL string the socket connects to (mirrors `LogosClient.settings.urlString`).
    var connectionURLString: String { get }
    /// The raw device secret the signed hello + session crypto sign/derive with
    /// (mirrors `LogosClient.settings.secret`; the connection normalizes before use).
    var connectionDeviceSecret: String { get }
    /// The device id stamped onto hello/outbound frames (mirrors `LogosClient.settings.deviceID`).
    var connectionDeviceID: String { get }
    /// The active project key hello/frames are scoped to (mirrors `LogosClient.activeProjectKey`).
    var connectionActiveProjectKey: String { get }
    /// The direct-WSS leaf SPKI pin from settings, or nil (mirrors `LogosClient.settings.certSPKISHA256`).
    var connectionPinnedSPKISHA256: String? { get }
    /// Whether auto-connect is enabled (mirrors `LogosClient.settings.autoConnect`).
    var connectionAutoConnect: Bool { get }
    /// Whether the first connection has completed (mirrors `LogosClient.settings.hasCompletedFirstConnection`).
    var connectionHasCompletedFirstConnection: Bool { get set }

    // MARK: Run-status / error surface the lifecycle drives
    /// The coarse run lifecycle the socket-failure path reads/drives (mirrors `LogosClient.runStatus`).
    var connectionRunStatus: LogosRunStatus { get set }
    /// The transient error banner the send/connect paths clear on success (mirrors `LogosClient.lastError`).
    var connectionLastError: String? { get set }
    /// Whether there is an in-flight, not-yet-complete progress run (mirrors `progressActivity?.isComplete == false`).
    var connectionHasIncompleteProgressActivity: Bool { get }

    // MARK: Frame dispatch + post-connect orchestration
    /// Dispatch an inbound frame string (stays in `LogosClient.handleFrameString`, the frame router).
    func handleInboundFrameString(_ string: String)
    /// Record that the just-sent hello carries this reconnect-replay request id (the client owns the
    /// pending-replay bookkeeping read in `handleMessagesBatch`).
    func noteReconnectReplayRequestID(_ requestID: String)
    /// The store's latest server seq for the active project, stamped into the hello's `after_server_seq`.
    func connectionLatestServerSeq() -> Int
    /// Run the post-`hello` orchestration (register device, list projects, flush pending notification work).
    func connectionDidCompleteHello()
    /// Run the post-`registered` orchestration (clear pending token, flush pending notification work).
    func connectionDidRegister()
    /// Apply adapter-supplied client config (e.g. stale-timeout) from a hello/registered frame.
    func connectionApplyClientConfig(from root: [String: Any])

    // MARK: Side effects the connect/fail/disconnect lifecycle owns elsewhere
    /// Clear the auto-reconnect banner + cancel any pending reconnect (mirrors `clearConnectionRetryState`).
    func connectionClearConnectionRetryState()
    /// Schedule an auto-reconnect after a retryable failure (mirrors `noteConnectionRetryFailure`).
    func connectionNoteRetryFailure(_ message: String)
    /// Drop the run-error state when there is no active progress (mirrors `resetRunErrorIfNoActiveProgress`).
    func connectionResetRunErrorIfNoActiveProgress()
    /// Surface a connect/socket-creation error (mirrors `LogosClient.recordError`).
    func connectionRecordError(_ message: String)
    /// Surface a socket-lifecycle error into the persistent log + banner (mirrors `logError(_:source:.connection)`).
    func connectionLogConnectionError(_ message: String)
    /// Clear the transient fast-ack banner (mirrors `LogosClient.clearAck()`).
    func connectionClearAck()
    /// Restore in-flight final speech drafts when the socket closes/fails (mirrors `restoreInFlightFinalSpeechDrafts`).
    func connectionRestoreInFlightFinalSpeechDrafts(reason: String)
    /// Tear down any in-flight remote audio stream on socket failure (mirrors `failInterruptedRemoteAudioStream`).
    func connectionFailInterruptedRemoteAudioStream()
    /// Resolve in-flight interaction cards when the socket drops (mirrors `failInterruptedInteraction`).
    func connectionFailInterruptedInteraction(clearCards: Bool)
    /// Clear run-scoped state on an explicit disconnect (mirrors `clearRunScopedStateForSocketClosure`).
    func connectionClearRunScopedStateForSocketClosure(runStatus: LogosRunStatus)
}

/// Owns the WebSocket connection/transport lifecycle lifted out of `LogosClient` (WS1 P5 — the
/// plan's riskiest collaborator): the published `connectionState`, the socket task + injected
/// `socketFactory` seam, the per-connection lifecycle UUID, the app-layer encryption session
/// (`sessionCrypto`), and the connect/disconnect/hello/sendFrame/receiveLoop/markConnected machinery.
///
/// It is the `WebSocketLifecycleObserving` delegate (it owns the socket), seals outbound payloads on
/// `sendFrame`, and exposes `openInboundPayload(header:encPayload:)` so the client can open inbound
/// sealed frames in its frame dispatcher (`handleFrameString`, which stays in `LogosClient`). Every
/// inbound message is handed back to the client via `host.handleInboundFrameString(_:)`, and the
/// post-connect orchestration (registerDevice/requestProjects/pending flushes) stays in the client
/// behind `host.connectionDidCompleteHello()`/`connectionDidRegister()`. All client-side
/// dependencies are routed through `host` (held `weak`).
@MainActor
@Observable
final class LogosConnection: WebSocketLifecycleObserving {
    private(set) var connectionState: LogosConnectionState = .disconnected

    @ObservationIgnored weak var host: LogosConnectionHost?

    private let socketFactory: any WebSocketTaskMaking
    private(set) var task: (any WebSocketTasking)?
    private var connectionLifecycle = LogosConnectionLifecycle()
    private(set) var isWebSocketOpen = false

    // App-layer encryption session (negotiated during hello); nil = cleartext / not negotiated.
    private var sessionCrypto: LogosSessionCrypto?
    private var pendingEncClientNonce: Data?

    private static let maxInboundFrameBytes = 2_000_000

    init(socketFactory: any WebSocketTaskMaking) {
        self.socketFactory = socketFactory
    }

    /// Whether the underlying task exists (mirrors the former `task != nil` reads).
    var hasTask: Bool { task != nil }

    /// Whether the underlying task + open socket both exist (mirrors `task != nil && isWebSocketOpen`).
    var hasOpenSocket: Bool { task != nil && isWebSocketOpen }

    // MARK: - Connect / disconnect entry points

    func connectIfRequestedByEnvironment() {
        LogosConnectionLog.logger.info("connectIfRequestedByEnvironment called")
        connectIfAutoConnectEnabled()
    }

    func connectIfAutoConnectEnabled() {
        let autoConnect = host?.connectionAutoConnect ?? false
        let hasCompletedFirstConnection = host?.connectionHasCompletedFirstConnection ?? false
        let shouldAttempt = LogosAutoConnectPolicy.shouldAttempt(
            autoConnect: autoConnect,
            hasCompletedFirstConnection: hasCompletedFirstConnection,
            connectionState: connectionState
        )
        LogosConnectionLog.logger.info("Auto-connect evaluated should_attempt=\(shouldAttempt, privacy: .public) auto_connect=\(autoConnect, privacy: .public) has_completed_first_connection=\(hasCompletedFirstConnection, privacy: .public) state=\(self.connectionState.rawValue, privacy: .public)")
        guard shouldAttempt else { return }
        connect(isAutomaticRetry: true)
    }

    func connect() {
        connect(isAutomaticRetry: false)
    }

    func connect(isAutomaticRetry: Bool) {
        let urlString = host?.connectionURLString ?? ""
        let deviceID = host?.connectionDeviceID ?? ""
        let activeProjectKey = host?.connectionActiveProjectKey ?? "default"
        let secret = host?.connectionDeviceSecret ?? ""
        LogosConnectionLog.logger.info("Connect requested url=\(LogosConnectionLog.urlDescription(urlString), privacy: .public) state=\(self.connectionState.rawValue, privacy: .public) device_id=\(deviceID, privacy: .public) project_key=\(activeProjectKey, privacy: .public) has_secret=\(!secret.isEmpty, privacy: .public)")
        if isAutomaticRetry == false {
            host?.connectionClearConnectionRetryState()
        }
        cancelCurrentSocket()
        host?.connectionLastError = nil
        host?.connectionResetRunErrorIfNoActiveProgress()
        guard let url = URL(string: urlString) else {
            LogosConnectionLog.logger.error("Connect failed before socket creation: invalid adapter URL value=\(urlString, privacy: .public)")
            host?.connectionClearConnectionRetryState()
            host?.connectionRecordError("Invalid adapter URL")
            connectionState = .error
            return
        }
        guard secret.isEmpty == false else {
            LogosConnectionLog.logger.error("Connect failed before socket creation: missing Logos device secret")
            host?.connectionClearConnectionRetryState()
            host?.connectionRecordError("Missing Logos device secret")
            connectionState = .error
            return
        }
        let connectionID = connectionLifecycle.startConnection()
        isWebSocketOpen = false
        connectionState = .connecting
        LogosConnectionLog.logger.info("Connection lifecycle started connection_id=\(connectionID.uuidString, privacy: .public) url=\(LogosConnectionLog.urlDescription(url), privacy: .public)")
        let pinnedSPKI = (host?.connectionPinnedSPKISHA256 ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
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
        host?.connectionClearConnectionRetryState()
        cancelCurrentSocket()
        host?.connectionLastError = nil
        host?.connectionClearRunScopedStateForSocketClosure(runStatus: .idle)
        connectionState = .disconnected
        LogosConnectionLog.logger.info("Disconnect complete state=\(self.connectionState.rawValue, privacy: .public)")
    }

    private func cancelCurrentSocket() {
        let oldTask = task
        LogosConnectionLog.logger.info("Cancelling current socket has_task=\(oldTask != nil, privacy: .public) open=\(self.isWebSocketOpen, privacy: .public) state=\(self.connectionState.rawValue, privacy: .public)")
        task = nil
        isWebSocketOpen = false
        sessionCrypto = nil
        pendingEncClientNonce = nil
        connectionLifecycle.invalidate()
        host?.connectionRestoreInFlightFinalSpeechDrafts(reason: "The socket closed before Logos confirmed the final speech frame was sent.")
        oldTask?.cancel(with: .goingAway, reason: nil)
    }

    func reconnectForRetry() {
        guard connectionState == .error || connectionState == .disconnected else { return }
        connect(isAutomaticRetry: true)
    }

    // MARK: - Pairing-route transport control

    /// Tear down the current socket without the disconnect run-scoped clearing, for the pairing flow
    /// (mirrors the former `LogosClient.applyPairingRoute`'s bare `cancelCurrentSocket()` call before
    /// re-pointing settings). The caller drives the subsequent `connect()`/state transition.
    func cancelSocketForPairing() {
        cancelCurrentSocket()
    }

    /// Move to the disconnected state when a successful pairing leaves auto-connect off (mirrors the
    /// former `connectionState = .disconnected` tail of `applyPairingRoute`).
    func markDisconnectedForPairing() {
        connectionState = .disconnected
    }

    /// Restore the connection state after a failed pairing exchange: back to connected when the prior
    /// socket was usable, otherwise error (mirrors the catch tail of `applyPairingRoute`).
    func restoreStateAfterFailedPairing(hadUsableConnection: Bool) {
        connectionState = hadUsableConnection ? .connected : .error
    }

    // MARK: - Socket lifecycle (WebSocketLifecycleObserving)

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
        LogosConnectionLog.logger.error("Failing current socket message=\(message, privacy: .public) previous_state=\(self.connectionState.rawValue, privacy: .public) open=\(self.isWebSocketOpen, privacy: .public)")
        self.task = nil
        isWebSocketOpen = false
        host?.connectionRestoreInFlightFinalSpeechDrafts(reason: message)
        host?.connectionFailInterruptedRemoteAudioStream()
        if connectionState != .disconnected || retryable {
            host?.connectionLogConnectionError(message)
            host?.connectionClearAck()
            if host?.connectionHasIncompleteProgressActivity != true {
                host?.connectionRunStatus = .idle
            }
            host?.connectionFailInterruptedInteraction(clearCards: clearInteractionCards)
            connectionState = .error
            if retryable {
                host?.connectionNoteRetryFailure(message)
            } else {
                host?.connectionClearConnectionRetryState()
            }
        }
        LogosConnectionLog.logger.error("Socket failure state updated state=\(self.connectionState.rawValue, privacy: .public) last_error=\(self.host?.connectionLastError ?? "<none>", privacy: .public)")
    }

    private func socketCloseMessage(closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) -> String {
        if let reason, let text = String(data: reason, encoding: .utf8), text.isEmpty == false {
            return "Logos socket closed: \(text)"
        }
        return "Logos socket closed with code \(closeCode.rawValue)."
    }

    // MARK: - Hello handshake + session crypto

    private func sendHello() {
        let requestID = UUID().uuidString
        let timestampMilliseconds = Int64(Date().timeIntervalSince1970 * 1000)
        let nonce = UUID().uuidString
        let deviceID = host?.connectionDeviceID ?? ""
        let activeProjectKey = host?.connectionActiveProjectKey ?? "default"
        // Offer app-layer encryption: send a fresh client nonce (bound into the signed v2
        // canonical) and the AEADs we support. The adapter chooses whether to negotiate.
        let encClientNonce = LogosSessionCrypto.randomNonce()
        let encClientNonceB64 = encClientNonce.base64EncodedString()
        pendingEncClientNonce = encClientNonce
        let signature = LogosAuthentication.signHello(
            secret: LogosSettings.normalizedSecret(host?.connectionDeviceSecret ?? ""),
            deviceID: deviceID,
            requestID: requestID,
            projectKey: activeProjectKey,
            timestampMilliseconds: timestampMilliseconds,
            nonce: nonce,
            encClientNonce: encClientNonceB64
        )
        let afterServerSeq = host?.connectionLatestServerSeq() ?? 0
        host?.noteReconnectReplayRequestID(requestID)
        LogosConnectionLog.logger.info("Sending hello request_id=\(requestID, privacy: .public) device_id=\(deviceID, privacy: .public) project_key=\(activeProjectKey, privacy: .public) after_server_seq=\(afterServerSeq, privacy: .public) timestamp_ms=\(timestampMilliseconds, privacy: .public)")
        let sent = sendFrame([
            "type": "hello",
            "request_id": requestID,
            "device_id": deviceID,
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
                deviceSecret: LogosSettings.normalizedSecret(host?.connectionDeviceSecret ?? ""),
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

    /// Open an inbound sealed payload using the negotiated session crypto. The client's frame
    /// dispatcher (`handleFrameString`) calls this for frames carrying `payload.enc == 1`; absent a
    /// session this returns nil and the caller treats the payload as cleartext.
    func openInboundPayload(header: [String: Any], encPayload: [String: Any]) throws -> [String: Any]? {
        guard let crypto = sessionCrypto else { return nil }
        return try crypto.open(header: header, encPayload: encPayload)
    }

    // MARK: - Send

    @discardableResult
    func sendFrame(
        _ frame: [String: Any],
        requiresAuthentication: Bool = true,
        onCompletion: (@MainActor @Sendable (Result<Void, Error>) -> Void)? = nil
    ) -> Bool {
        let summary = LogosConnectionLog.frameSummary(frame)
        guard let task, isWebSocketOpen else {
            LogosConnectionLog.logger.warning("Frame send blocked \(summary, privacy: .public) state=\(self.connectionState.rawValue, privacy: .public) open=\(self.isWebSocketOpen, privacy: .public) has_task=\(self.task != nil, privacy: .public)")
            if connectionState != .connecting {
                host?.connectionRecordError("Not connected to Logos adapter. Reconnect before sending.")
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
            let frameType = frame["type"] as? String
            let taskID = ObjectIdentifier(task)
            LogosConnectionLog.logger.info("Frame send queued \(summary, privacy: .public) bytes=\(data.count, privacy: .public) connection_id=\(connectionID.uuidString, privacy: .public)")
            task.send(.string(string)) { [weak self] error in
                Task { @MainActor in
                    guard let self else { return }
                    guard self.connectionLifecycle.accepts(connectionID), self.isCurrentTaskID(taskID) else {
                        LogosConnectionLog.logger.warning("Frame send completed on stale connection \(summary, privacy: .public) connection_id=\(connectionID.uuidString, privacy: .public)")
                        onCompletion?(.failure(LogosSocketSendError.staleConnection))
                        return
                    }
                    if let error {
                        LogosConnectionLog.logger.error("Frame send failed \(summary, privacy: .public) error=\(LogosConnectionLog.errorDescription(error), privacy: .public) connection_id=\(connectionID.uuidString, privacy: .public)")
                        let shouldKeepInteractionCards = frameType == "approval_response" || frameType == "clarify_response"
                        self.failCurrentSocket(message: error.localizedDescription, retryable: true, clearInteractionCards: shouldKeepInteractionCards == false)
                        onCompletion?(.failure(error))
                    } else {
                        LogosConnectionLog.logger.info("Frame send completed \(summary, privacy: .public) connection_id=\(connectionID.uuidString, privacy: .public)")
                        self.host?.connectionLastError = nil
                        onCompletion?(.success(()))
                    }
                }
            }
            return true
        } catch {
            LogosConnectionLog.logger.error("Frame serialization failed \(summary, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            host?.connectionRecordError(error.localizedDescription)
            return false
        }
    }

    // MARK: - Receive

    private func receiveLoop(connectionID: UUID) {
        guard let task else {
            LogosConnectionLog.logger.warning("Receive loop not started because task is nil connection_id=\(connectionID.uuidString, privacy: .public)")
            return
        }
        LogosConnectionLog.logger.info("Receive loop waiting connection_id=\(connectionID.uuidString, privacy: .public) task_id=\(LogosConnectionLog.taskIDDescription(task), privacy: .public)")
        let taskID = ObjectIdentifier(task)
        task.receive { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                guard self.connectionLifecycle.accepts(connectionID), self.isCurrentTaskID(taskID) else {
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

    private func isCurrentTaskID(_ id: ObjectIdentifier) -> Bool {
        guard let task else { return false }
        return ObjectIdentifier(task) == id
    }

    private func handleSocketMessage(_ message: URLSessionWebSocketTask.Message) {
        switch message {
        case .string(let string):
            host?.handleInboundFrameString(string)
        case .data(let data):
            guard data.count <= Self.maxInboundFrameBytes else {
                LogosConnectionLog.logger.error("Inbound binary frame rejected because it exceeded size limit bytes=\(data.count, privacy: .public)")
                return
            }
            if let string = String(data: data, encoding: .utf8) {
                host?.handleInboundFrameString(string)
            } else {
                LogosConnectionLog.logger.error("Inbound data frame was not valid UTF-8 bytes=\(data.count, privacy: .public)")
            }
        @unknown default:
            LogosConnectionLog.logger.warning("Inbound WebSocket message used an unknown message case")
            break
        }
    }

    // MARK: - Mark connected + post-connect orchestration

    private func markConnected() {
        let previousState = connectionState
        let hadCompletedFirstConnection = host?.connectionHasCompletedFirstConnection ?? false
        isWebSocketOpen = true
        if host?.connectionHasCompletedFirstConnection == false {
            host?.connectionHasCompletedFirstConnection = true
        }
        host?.connectionClearConnectionRetryState()
        connectionState = .connected
        host?.connectionLastError = nil
        host?.connectionResetRunErrorIfNoActiveProgress()
        LogosConnectionLog.logger.info("Marked connected previous_state=\(previousState.rawValue, privacy: .public) had_completed_first_connection=\(hadCompletedFirstConnection, privacy: .public) active_project=\(self.host?.connectionActiveProjectKey ?? "<none>", privacy: .public)")
    }

    /// Handle the `hello` frame's connection-side work: derive the session crypto, apply client
    /// config, mark connected, then (if the socket is still live) run the post-connect orchestration
    /// the client owns. Mirrors the former `handleFrameString` `case "hello"`.
    func handleHelloFrame(_ root: [String: Any]) {
        setupSessionCrypto(from: root)
        host?.connectionApplyClientConfig(from: root)
        markConnected()
        if task != nil {
            host?.connectionDidCompleteHello()
        }
    }

    /// Handle the `registered` frame's connection-side work. Mirrors the former `handleFrameString`
    /// `case "registered"`.
    func handleRegisteredFrame(_ root: [String: Any]) {
        host?.connectionApplyClientConfig(from: root)
        markConnected()
        host?.connectionDidRegister()
    }

    /// Fail the current socket from the client's `auth_failed` path (non-retryable). Mirrors the
    /// former in-client `failCurrentSocket(message:retryable:false)` call.
    func failForAuthFailure(message: String) {
        failCurrentSocket(message: message, retryable: false)
    }
}
