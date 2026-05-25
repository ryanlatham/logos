import CryptoKit
import Foundation
import Security
import UIKit

enum LogosConnectionState: String {
    case disconnected
    case connecting
    case connected
    case error
}

enum LogosRunStatus: String {
    case idle
    case running
    case queued
    case awaitingApproval = "awaiting_approval"
    case awaitingClarification = "awaiting_clarification"
    case cancelling
    case error
}

struct LogosConnectionLifecycle: Equatable {
    private(set) var activeConnectionID = UUID()

    mutating func startConnection() -> UUID {
        activeConnectionID = UUID()
        return activeConnectionID
    }

    mutating func invalidate() {
        activeConnectionID = UUID()
    }

    func accepts(_ connectionID: UUID) -> Bool {
        connectionID == activeConnectionID
    }
}

struct LogosSettings: Equatable {
    static let defaultURLString = "wss://your-mac.your-tailnet.ts.net/"

    private static let urlKey = "logos.adapter.url"
    private static let deviceIDKey = "logos.device.id"
    private static let autoConnectKey = "logos.autoconnect"
    private static let hasCompletedFirstConnectionKey = "logos.hasCompletedFirstConnection"

    var urlString: String
    var deviceID: String
    var secret: String
    var autoConnect: Bool
    var hasCompletedFirstConnection: Bool

    init(environment: [String: String] = ProcessInfo.processInfo.environment, userDefaults: UserDefaults = .standard) {
        self.urlString = environment["LOGOS_WS_URL"]
            ?? userDefaults.string(forKey: Self.urlKey)
            ?? Self.defaultURLString
        self.deviceID = environment["LOGOS_DEVICE_ID"]
            ?? userDefaults.string(forKey: Self.deviceIDKey)
            ?? "ios-simulator"
        self.secret = Self.normalizedSecret(
            environment["LOGOS_DEVICE_SECRET"]
                ?? LogosKeychain.loadSecret()
                ?? ""
        )
        if let envAutoConnect = environment["LOGOS_AUTOCONNECT"] {
            self.autoConnect = envAutoConnect == "1" || envAutoConnect.lowercased() == "true"
            self.hasCompletedFirstConnection = self.autoConnect || userDefaults.bool(forKey: Self.hasCompletedFirstConnectionKey)
        } else {
            self.autoConnect = Self.storedBool(forKey: Self.autoConnectKey, userDefaults: userDefaults, defaultValue: true)
            self.hasCompletedFirstConnection = userDefaults.bool(forKey: Self.hasCompletedFirstConnectionKey)
        }
    }

    func persist(userDefaults: UserDefaults = .standard) {
        userDefaults.set(urlString, forKey: Self.urlKey)
        userDefaults.set(deviceID, forKey: Self.deviceIDKey)
        userDefaults.set(autoConnect, forKey: Self.autoConnectKey)
        userDefaults.set(hasCompletedFirstConnection, forKey: Self.hasCompletedFirstConnectionKey)
        let normalizedSecret = Self.normalizedSecret(secret)
        if normalizedSecret.isEmpty {
            LogosKeychain.deleteSecret()
        } else {
            LogosKeychain.saveSecret(normalizedSecret)
        }
    }

    static func normalizedSecret(_ secret: String) -> String {
        secret.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func storedBool(forKey key: String, userDefaults: UserDefaults, defaultValue: Bool) -> Bool {
        guard userDefaults.object(forKey: key) != nil else { return defaultValue }
        return userDefaults.bool(forKey: key)
    }
}

enum LogosAutoConnectPolicy {
    static func shouldAttempt(
        autoConnect: Bool,
        hasCompletedFirstConnection: Bool,
        connectionState: LogosConnectionState
    ) -> Bool {
        guard autoConnect, hasCompletedFirstConnection else { return false }
        switch connectionState {
        case .disconnected, .error:
            return true
        case .connecting, .connected:
            return false
        }
    }
}

enum LogosAuthentication {
    static func signHello(secret: String, deviceID: String, requestID: String, projectKey: String?, timestampMilliseconds: Int64, nonce: String) -> String {
        let normalizedSecret = LogosSettings.normalizedSecret(secret)
        let message = [
            "logos-v1",
            deviceID,
            requestID,
            projectKey ?? "",
            String(timestampMilliseconds),
            nonce
        ].joined(separator: "\n")
        let key = SymmetricKey(data: Data(normalizedSecret.utf8))
        let digest = HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: key)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

struct LogosPairingRoute: Equatable, Identifiable {
    var id: String { "\(adapterURL)|\(deviceID)|\(Int(expiresAt?.timeIntervalSince1970 ?? 0))" }
    let adapterURL: String
    let deviceID: String
    let pairToken: String?
    let deviceSecret: String?
    let expiresAt: Date?
    let autoConnect: Bool

    var adapterHostDescription: String {
        URL(string: adapterURL)?.host ?? adapterURL
    }

    var isExpired: Bool {
        guard let expiresAt else { return false }
        return expiresAt <= Date()
    }

    var allowsPairingTransport: Bool {
        guard let url = URL(string: adapterURL), let scheme = url.scheme?.lowercased() else { return false }
        if scheme == "wss" { return true }
        return scheme == "ws" && LogosPairingRoute.isLoopbackHost(url.host)
    }

    static func from(url: URL) -> LogosPairingRoute? {
        guard url.scheme == "logos", url.host == "pair", let fragment = url.fragment, fragment.isEmpty == false else {
            return nil
        }
        guard let data = Data(base64URLEncoded: fragment),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        let version = root["v"] as? Int ?? Int(root["v"] as? String ?? "")
        guard version == 1 else { return nil }
        guard let adapterURL = (root["adapter_url"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              adapterURL.isEmpty == false,
              let parsedAdapterURL = URL(string: adapterURL),
              let scheme = parsedAdapterURL.scheme?.lowercased(),
              ["ws", "wss"].contains(scheme),
              parsedAdapterURL.host?.isEmpty == false,
              let deviceID = (root["device_id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              deviceID.isEmpty == false
        else { return nil }
        guard let pairToken = (root["pair_token"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty else {
            return nil
        }
        let expiresAt: Date?
        if let raw = root["expires_at"] as? TimeInterval {
            expiresAt = raw > 0 ? Date(timeIntervalSince1970: raw) : nil
        } else if let text = root["expires_at"] as? String, let raw = TimeInterval(text), raw > 0 {
            expiresAt = Date(timeIntervalSince1970: raw)
        } else {
            expiresAt = nil
        }
        let autoConnect = root["autoconnect"] as? Bool ?? true
        return LogosPairingRoute(
            adapterURL: adapterURL,
            deviceID: deviceID,
            pairToken: pairToken,
            deviceSecret: nil,
            expiresAt: expiresAt,
            autoConnect: autoConnect
        )
    }

    private static func isLoopbackHost(_ host: String?) -> Bool {
        guard let host = host?.lowercased(), host.isEmpty == false else { return false }
        if host == "localhost" || host == "ip6-localhost" { return true }
        if host == "::1" { return true }
        if host.hasPrefix("127.") { return true }
        return false
    }
}

struct LogosPairingCredential: Equatable {
    let adapterURL: String
    let deviceID: String
    let deviceSecret: String
}

protocol PairingCredentialExchanging {
    func exchange(route: LogosPairingRoute) async throws -> LogosPairingCredential
}

enum LogosPairingExchangeError: LocalizedError {
    case missingToken
    case invalidAdapterURL
    case insecureAdapterURL
    case expired
    case invalidResponse
    case adapterRejected(String)

    var errorDescription: String? {
        switch self {
        case .missingToken:
            return "Pairing link is missing its one-time token."
        case .invalidAdapterURL:
            return "Pairing link contains an invalid adapter URL."
        case .insecureAdapterURL:
            return "Pairing requires wss:// unless the adapter is loopback for Simulator testing."
        case .expired:
            return "Pairing QR code has expired. Generate a fresh QR code and scan again."
        case .invalidResponse:
            return "Logos adapter returned an invalid pairing response."
        case .adapterRejected(let message):
            return message
        }
    }
}

final class WebSocketPairingCredentialExchanger: PairingCredentialExchanging {
    func exchange(route: LogosPairingRoute) async throws -> LogosPairingCredential {
        guard route.isExpired == false else { throw LogosPairingExchangeError.expired }
        guard route.allowsPairingTransport else { throw LogosPairingExchangeError.insecureAdapterURL }
        guard let pairToken = route.pairToken else { throw LogosPairingExchangeError.missingToken }
        guard let url = URL(string: route.adapterURL) else { throw LogosPairingExchangeError.invalidAdapterURL }
        let session = URLSession(configuration: .ephemeral)
        let task = session.webSocketTask(with: url)
        task.resume()
        defer {
            task.cancel(with: .goingAway, reason: nil)
            session.invalidateAndCancel()
        }
        let requestID = UUID().uuidString
        let displayName = await MainActor.run { UIDevice.current.name }
        let frame: [String: Any] = [
            "type": "pair",
            "request_id": requestID,
            "device_id": route.deviceID,
            "payload": [
                "pair_token": pairToken,
                "device_id": route.deviceID,
                "display_name": displayName,
                "adapter_url": route.adapterURL
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: frame, options: [])
        try await send(task: task, string: String(decoding: data, as: UTF8.self))
        let response = try await receiveDictionary(task: task)
        if response["type"] as? String == "error" {
            let payload = response["payload"] as? [String: Any]
            let message = payload?["message"] as? String ?? "Logos pairing failed."
            throw LogosPairingExchangeError.adapterRejected(message)
        }
        guard response["type"] as? String == "pairing_complete",
              let payload = response["payload"] as? [String: Any],
              let deviceSecret = payload["device_secret"] as? String
        else { throw LogosPairingExchangeError.invalidResponse }
        let adapterURL = (payload["adapter_url"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? route.adapterURL
        let deviceID = (payload["device_id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? route.deviceID
        guard adapterURL == route.adapterURL, deviceID == route.deviceID else {
            throw LogosPairingExchangeError.invalidResponse
        }
        return LogosPairingCredential(
            adapterURL: adapterURL,
            deviceID: deviceID,
            deviceSecret: LogosSettings.normalizedSecret(deviceSecret)
        )
    }

    private func send(task: URLSessionWebSocketTask, string: String) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            task.send(.string(string)) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    private func receiveDictionary(task: URLSessionWebSocketTask) async throws -> [String: Any] {
        let message = try await withCheckedThrowingContinuation { continuation in
            task.receive { result in
                continuation.resume(with: result)
            }
        }
        let data: Data
        switch message {
        case .string(let string):
            guard let encoded = string.data(using: .utf8) else { throw LogosPairingExchangeError.invalidResponse }
            data = encoded
        case .data(let raw):
            data = raw
        @unknown default:
            throw LogosPairingExchangeError.invalidResponse
        }
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LogosPairingExchangeError.invalidResponse
        }
        return root
    }
}

private extension Data {
    init?(base64URLEncoded string: String) {
        var base64 = string.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let padding = (4 - base64.count % 4) % 4
        if padding > 0 {
            base64 += String(repeating: "=", count: padding)
        }
        self.init(base64Encoded: base64)
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

enum LogosKeychain {
    private static let service = "dev.logos.device-secret"
    private static let account = "logos-device-secret"

    static func loadSecret() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func saveSecret(_ secret: String) -> Bool {
        let data = Data(secret.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return true }
        guard updateStatus == errSecItemNotFound else { return false }
        var addQuery = query
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(addQuery as CFDictionary, nil) == errSecSuccess
    }

    @discardableResult
    static func deleteSecret() -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}

struct LogosProject: Identifiable, Hashable {
    var id: String { projectKey }
    let projectKey: String
    var title: String
    var currentSessionID: String?
    var lastPreview: String?

    static func from(dictionary: [String: Any]) -> LogosProject? {
        guard let projectKey = dictionary["project_key"] as? String else { return nil }
        return LogosProject(
            projectKey: projectKey,
            title: dictionary["title"] as? String ?? projectKey,
            currentSessionID: dictionary["current_session_id"] as? String,
            lastPreview: dictionary["last_preview"] as? String
        )
    }
}

enum AudioPlaybackPhase: String, Hashable {
    case requesting
    case receiving
    case playing
    case paused
    case finished
    case failed
}

struct AudioPlaybackOverlayState: Identifiable, Hashable {
    var id: String { audioID }
    let audioID: String
    let messageID: String?
    let projectKey: String
    var phase: AudioPlaybackPhase
    var detail: String
    var spectrumBins: [Double]
    var canPause: Bool
    var canStop: Bool
}

struct ProgressActivityEvent: Identifiable, Hashable {
    let id: String
    let kind: String
    let text: String
    let timestamp: TimeInterval
    let count: Int
}

struct ProgressActivityState: Identifiable, Hashable {
    var id: String { requestID }
    let requestID: String
    let projectKey: String
    let sessionID: String?
    var events: [ProgressActivityEvent]
    var isExpanded: Bool
    var timedOut: Bool
    var isComplete: Bool
    var completedFinalMessageID: String?
    var updateCount: Int
    var lastUpdateAt: TimeInterval
}

struct LogosMessage: Identifiable, Hashable {
    var id: String { "\(sessionID):\(messageID)" }
    let projectKey: String
    let sessionID: String
    let messageID: String
    let serverSeq: Int
    let role: String
    let content: String
    let timestamp: TimeInterval
    var status: String
    var isFinal: Bool = true
    var hasFinalizedMetadata: Bool = false
    var metadataSource: String? = nil
    var progressKind: String? = nil
    var metadataRequestID: String? = nil
    var metadataTransient: Bool? = nil
    var metadataKind: String? = nil
    var metadataJSON: String = "{}"

    var gatewayProgressKind: String? {
        Self.gatewayProgressKind(for: content)
    }

    var progressEventKind: String {
        progressKind ?? metadataSource ?? gatewayProgressKind ?? "progress"
    }

    var isGatewayStatusUpdate: Bool {
        progressEventKind == "gateway_status" || gatewayProgressKind != nil
    }

    var isProgressUpdate: Bool {
        guard role != "user" else { return false }
        if hasFinalizedMetadata && isFinal {
            return false
        }
        return isFinal == false
            || progressKind != nil
            || metadataSource == "tool_progress"
            || metadataSource == "progress"
            || gatewayProgressKind != nil
    }

    static func gatewayProgressKind(for content: String) -> String? {
        var trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["⏳", "⚠️", "⚠"] where trimmed.hasPrefix(prefix) {
            trimmed = String(trimmed.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            break
        }
        let lower = trimmed.lowercased()
        if lower.hasPrefix("still working...") || lower.hasPrefix("still working…") {
            return "gateway_status"
        }
        if lower.hasPrefix("gateway restarting") || lower.hasPrefix("gateway shutting down") {
            return "gateway_status"
        }
        return nil
    }

    static func from(dictionary: [String: Any]) -> LogosMessage? {
        guard
            let projectKey = dictionary["project_key"] as? String,
            let sessionID = dictionary["session_id"] as? String,
            let messageID = dictionary["message_id"] as? String,
            let role = dictionary["role"] as? String,
            let content = dictionary["content"] as? String
        else { return nil }
        let serverSeq = dictionary["server_seq"] as? Int ?? Int(dictionary["server_seq"] as? String ?? "") ?? 0
        let timestamp = dictionary["timestamp"] as? TimeInterval ?? Date().timeIntervalSince1970
        let metadata = dictionary["metadata"] as? [String: Any]
        let finalized = metadata?["finalized"] as? Bool
        let source = metadata?["source"] as? String
        let progressKind = metadata?["progress_kind"] as? String ?? metadata?["kind"] as? String
        let requestID = metadata?["request_id"] as? String
        let transient = Self.boolValue(metadata?["transient"])
        let kind = metadata?["kind"] as? String
        return LogosMessage(
            projectKey: projectKey,
            sessionID: sessionID,
            messageID: messageID,
            serverSeq: serverSeq,
            role: role,
            content: content,
            timestamp: timestamp,
            status: dictionary["status"] as? String ?? "persisted",
            isFinal: finalized ?? true,
            hasFinalizedMetadata: finalized != nil,
            metadataSource: source,
            progressKind: progressKind,
            metadataRequestID: requestID,
            metadataTransient: transient,
            metadataKind: kind,
            metadataJSON: metadata.map(Self.metadataJSONString(from:)) ?? "{}"
        )
    }

    var metadataDictionary: [String: Any] {
        var metadata = Self.metadataDictionary(fromJSON: metadataJSON)
        if hasFinalizedMetadata {
            metadata["finalized"] = isFinal
        }
        if let metadataSource {
            metadata["source"] = metadataSource
        }
        if let progressKind {
            metadata["progress_kind"] = progressKind
        }
        if let metadataRequestID {
            metadata["request_id"] = metadataRequestID
        }
        if let metadataTransient {
            metadata["transient"] = metadataTransient
        }
        if let metadataKind {
            metadata["kind"] = metadataKind
        }
        return metadata
    }

    private static func boolValue(_ value: Any?) -> Bool? {
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

    private static func metadataDictionary(fromJSON json: String) -> [String: Any] {
        guard let data = json.data(using: .utf8),
              let decoded = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return decoded
    }

    private static func metadataJSONString(from metadata: [String: Any]) -> String {
        guard JSONSerialization.isValidJSONObject(metadata),
              let data = try? JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8)
        else { return "{}" }
        return json
    }

    static func pending(projectKey: String, messageID: String = UUID().uuidString, content: String) -> LogosMessage {
        LogosMessage(
            projectKey: projectKey,
            sessionID: "pending",
            messageID: messageID,
            serverSeq: 0,
            role: "user",
            content: content,
            timestamp: Date().timeIntervalSince1970,
            status: "pending"
        )
    }

    static func localNotice(projectKey: String, requestID: String, sequence: Int, content: String, timestamp: TimeInterval = Date().timeIntervalSince1970) -> LogosMessage {
        LogosMessage(
            projectKey: projectKey,
            sessionID: "local:\(projectKey)",
            messageID: "local-stale-\(requestID)-\(sequence)",
            serverSeq: 0,
            role: "assistant",
            content: content,
            timestamp: timestamp,
            status: "local_notice",
            isFinal: true,
            hasFinalizedMetadata: true,
            metadataSource: "local_notice",
            progressKind: nil,
            metadataRequestID: requestID,
            metadataTransient: false
        )
    }
}

struct UndeliveredSpeechDraft: Identifiable, Equatable {
    var id: String { inputID }
    let inputID: String
    let projectKey: String
    let text: String
    let reason: String
}

enum PendingMessageReconciliation {
    static func shouldRemove(pending: LogosMessage, whenPersisted persisted: LogosMessage) -> Bool {
        guard pending.status == "pending",
              pending.role == persisted.role,
              pending.projectKey == persisted.projectKey else { return false }
        if pending.messageID == persisted.messageID { return true }
        return pending.content == persisted.content && persisted.timestamp >= pending.timestamp
    }
}

struct PendingMessageBuffer: Equatable {
    private var pendingByID: [String: LogosMessage] = [:]

    var isEmpty: Bool { pendingByID.isEmpty }

    mutating func add(_ message: LogosMessage, persisted: [LogosMessage] = []) {
        guard message.status == "pending" else { return }
        guard persisted.contains(where: { PendingMessageReconciliation.shouldRemove(pending: message, whenPersisted: $0) }) == false else {
            pendingByID.removeValue(forKey: message.messageID)
            return
        }
        pendingByID[message.messageID] = message
    }

    mutating func remove(messageID: String) {
        pendingByID.removeValue(forKey: messageID)
    }

    mutating func reconcile(with persisted: LogosMessage) {
        pendingByID = pendingByID.filter { _, pending in
            PendingMessageReconciliation.shouldRemove(pending: pending, whenPersisted: persisted) == false
        }
    }

    mutating func reconcile(with persisted: [LogosMessage]) {
        for message in persisted {
            reconcile(with: message)
        }
    }

    func merged(with persisted: [LogosMessage], projectKey: String) -> [LogosMessage] {
        let pending = pendingByID.values
            .filter { $0.projectKey == projectKey }
            .filter { pending in
                persisted.contains(where: { PendingMessageReconciliation.shouldRemove(pending: pending, whenPersisted: $0) }) == false
            }
            .sorted { lhs, rhs in
                if lhs.timestamp == rhs.timestamp { return lhs.messageID < rhs.messageID }
                return lhs.timestamp < rhs.timestamp
            }
        return persisted + pending
    }
}

struct ApprovalCard: Identifiable, Equatable {
    let id: String
    let projectKey: String
    let title: String
    let summary: String
    let commandPreview: String
    let risk: String
}

struct ClarifyCard: Identifiable, Equatable {
    let id: String
    let projectKey: String
    let question: String
    let choices: [String]
    let allowFreeText: Bool
}
