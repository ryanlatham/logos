import CryptoKit
import Foundation
import Security

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
    static let defaultURLString = "ws://ryans-mac-studio:8765"

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
        self.secret = environment["LOGOS_DEVICE_SECRET"]
            ?? LogosKeychain.loadSecret()
            ?? ""
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
        if secret.isEmpty {
            LogosKeychain.deleteSecret()
        } else {
            LogosKeychain.saveSecret(secret)
        }
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
        let message = [
            "logos-v1",
            deviceID,
            requestID,
            projectKey ?? "",
            String(timestampMilliseconds),
            nonce
        ].joined(separator: "\n")
        let key = SymmetricKey(data: Data(secret.utf8))
        let digest = HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: key)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

enum LogosKeychain {
    private static let service = "com.ryan.logos.device-secret"
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
        return LogosMessage(
            projectKey: projectKey,
            sessionID: sessionID,
            messageID: messageID,
            serverSeq: serverSeq,
            role: role,
            content: content,
            timestamp: timestamp,
            status: dictionary["status"] as? String ?? "persisted"
        )
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
        guard pending.status == "pending", pending.role == persisted.role else { return false }
        return pending.messageID == persisted.messageID || pending.content == persisted.content
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
