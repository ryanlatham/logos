import CryptoKit
import Foundation
import Security

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
enum LogosAuthentication {
    static func signHello(secret: String, deviceID: String, requestID: String, projectKey: String?, timestampMilliseconds: Int64, nonce: String, encClientNonce: String? = nil) -> String {
        let normalizedSecret = LogosSettings.normalizedSecret(secret)
        // v1 (encClientNonce == nil) is unchanged for back-compat; v2 appends the base64 enc nonce
        // so it is authenticated by the HMAC. Must match plugins/logos/ws_server.py canonical_hello_message.
        var fields = [
            encClientNonce == nil ? "logos-v1" : "logos-v2",
            deviceID,
            requestID,
            projectKey ?? "",
            String(timestampMilliseconds),
            nonce
        ]
        if let encClientNonce {
            fields.append(encClientNonce)
        }
        let message = fields.joined(separator: "\n")
        let key = SymmetricKey(data: Data(normalizedSecret.utf8))
        let digest = HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: key)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
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
