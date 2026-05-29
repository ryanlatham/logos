import CryptoKit
import Foundation

/// Application-layer authenticated encryption for the Logos protocol (iOS side).
///
/// This must stay byte-for-byte compatible with the Python `plugins/logos/crypto.py`.
/// The cross-implementation contract is pinned by the known-answer vectors shared
/// between `LogosCryptoTests` (Swift) and `tests/test_crypto_roundtrip.py` (Python):
/// identical derived keys and identical ciphertext from identical inputs. If you
/// change the KDF/AEAD/AAD/nonce scheme, update both sides together.
///
/// Scheme (v1):
///   - AEAD: ChaCha20-Poly1305 (default) or AES-256-GCM; 256-bit key, 96-bit nonce, 128-bit tag.
///   - Session keys: HKDF-SHA256, IKM = trimmed device secret (UTF-8),
///     salt = clientNonce ‖ serverNonce, expanded twice with distinct info labels
///     ("logos-enc-v1 c2s key" / "logos-enc-v1 s2c key") so the directions never share a key.
///   - Per-frame nonce = directionByte(1) ‖ counter(UInt64 big-endian) ‖ 0x000000.
///     Counters are strictly monotonic per direction; the receiver rejects counter <= last accepted.
///   - AAD binds the ciphertext to the cleartext routing header + counter.
///   - Only `payload` is encrypted; routing fields stay cleartext. Secrets are redacted before sealing.
enum LogosCryptoError: Error, Equatable {
    case invalidInputs
    case invalidCounter
    case replayedOrReordered
    case missingCiphertext
    case invalidCiphertextEncoding
    case authenticationFailed
    case notAnObject
}

enum LogosAEAD: String {
    case chaCha20Poly1305 = "chacha20-poly1305"
    case aes256GCM = "aes-256-gcm"
}

enum LogosCryptoRole {
    case client
    case server
}

final class LogosSessionCrypto {
    static let encVersion = "logos-enc-v1"
    private static let c2sInfo = Data("logos-enc-v1 c2s key".utf8)
    private static let s2cInfo = Data("logos-enc-v1 s2c key".utf8)
    private static let directionC2S: UInt8 = 0x01
    private static let directionS2C: UInt8 = 0x02
    private static let headerFields = ["type", "request_id", "device_id", "project_key", "session_id", "server_seq"]
    private static let secretMarkers = ["secret", "token", "password", "auth_key", "api_key"]

    let role: LogosCryptoRole
    let aead: LogosAEAD
    private let sendKey: SymmetricKey
    private let recvKey: SymmetricKey
    private let sendDirection: UInt8
    private let recvDirection: UInt8
    private var sendCounter: UInt64 = 0
    private var recvLast: Int64 = -1

    init(c2sKey: Data, s2cKey: Data, role: LogosCryptoRole, aead: LogosAEAD = .chaCha20Poly1305) {
        self.role = role
        self.aead = aead
        switch role {
        case .client:
            self.sendKey = SymmetricKey(data: c2sKey)
            self.recvKey = SymmetricKey(data: s2cKey)
            self.sendDirection = Self.directionC2S
            self.recvDirection = Self.directionS2C
        case .server:
            self.sendKey = SymmetricKey(data: s2cKey)
            self.recvKey = SymmetricKey(data: c2sKey)
            self.sendDirection = Self.directionS2C
            self.recvDirection = Self.directionC2S
        }
    }

    /// Pure key derivation — the KAT anchor. Returns raw (c2s, s2c) key bytes.
    static func deriveSessionKeys(deviceSecret: String, clientNonce: Data, serverNonce: Data) throws -> (c2s: Data, s2c: Data) {
        let ikmData = Data(deviceSecret.trimmingCharacters(in: .whitespacesAndNewlines).utf8)
        guard !ikmData.isEmpty, !clientNonce.isEmpty, !serverNonce.isEmpty else { throw LogosCryptoError.invalidInputs }
        let ikm = SymmetricKey(data: ikmData)
        let salt = clientNonce + serverNonce
        let c2s = HKDF<SHA256>.deriveKey(inputKeyMaterial: ikm, salt: salt, info: Self.c2sInfo, outputByteCount: 32)
        let s2c = HKDF<SHA256>.deriveKey(inputKeyMaterial: ikm, salt: salt, info: Self.s2cInfo, outputByteCount: 32)
        return (c2s.withUnsafeBytes { Data($0) }, s2c.withUnsafeBytes { Data($0) })
    }

    static func deriveSession(
        deviceSecret: String,
        clientNonce: Data,
        serverNonce: Data,
        role: LogosCryptoRole,
        aead: LogosAEAD = .chaCha20Poly1305
    ) throws -> LogosSessionCrypto {
        let keys = try deriveSessionKeys(deviceSecret: deviceSecret, clientNonce: clientNonce, serverNonce: serverNonce)
        return LogosSessionCrypto(c2sKey: keys.c2s, s2cKey: keys.s2c, role: role, aead: aead)
    }

    // MARK: - Seal

    /// Encrypt raw plaintext bytes. The cross-impl ciphertext KAT exercises this path.
    func seal(header: [String: Any], plaintext: Data) throws -> [String: Any] {
        let counter = sendCounter
        sendCounter += 1
        let nonce = Self.makeNonce(direction: sendDirection, counter: counter)
        let aad = Self.makeAAD(header: header, counter: counter)
        let combinedCipher: Data
        switch aead {
        case .chaCha20Poly1305:
            let box = try ChaChaPoly.seal(plaintext, using: sendKey, nonce: ChaChaPoly.Nonce(data: nonce), authenticating: aad)
            combinedCipher = box.ciphertext + box.tag
        case .aes256GCM:
            let box = try AES.GCM.seal(plaintext, using: sendKey, nonce: AES.GCM.Nonce(data: nonce), authenticating: aad)
            combinedCipher = box.ciphertext + box.tag
        }
        return ["enc": 1, "n": Int(counter), "ct": combinedCipher.base64EncodedString()]
    }

    /// Encrypt a payload object (redacting secret-keyed fields first, matching the adapter).
    func seal(header: [String: Any], payload: [String: Any]) throws -> [String: Any] {
        let redacted = Self.redactSecrets(payload)
        let plaintext = try JSONSerialization.data(withJSONObject: redacted, options: [])
        return try seal(header: header, plaintext: plaintext)
    }

    // MARK: - Open

    func openToData(header: [String: Any], encPayload: [String: Any]) throws -> Data {
        guard let counterInt = Self.intCounter(encPayload["n"]) else { throw LogosCryptoError.invalidCounter }
        let counter = Int64(counterInt)
        if counter <= recvLast { throw LogosCryptoError.replayedOrReordered }
        guard let ctB64 = encPayload["ct"] as? String, !ctB64.isEmpty else { throw LogosCryptoError.missingCiphertext }
        guard let combined = Data(base64Encoded: ctB64), combined.count >= 16 else {
            throw LogosCryptoError.invalidCiphertextEncoding
        }
        let tag = combined.suffix(16)
        let body = combined.prefix(combined.count - 16)
        let nonce = Self.makeNonce(direction: recvDirection, counter: UInt64(counter))
        let aad = Self.makeAAD(header: header, counter: UInt64(counter))
        let plaintext: Data
        do {
            switch aead {
            case .chaCha20Poly1305:
                let box = try ChaChaPoly.SealedBox(nonce: ChaChaPoly.Nonce(data: nonce), ciphertext: body, tag: tag)
                plaintext = try ChaChaPoly.open(box, using: recvKey, authenticating: aad)
            case .aes256GCM:
                let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: nonce), ciphertext: body, tag: tag)
                plaintext = try AES.GCM.open(box, using: recvKey, authenticating: aad)
            }
        } catch {
            throw LogosCryptoError.authenticationFailed
        }
        recvLast = counter
        return plaintext
    }

    func open(header: [String: Any], encPayload: [String: Any]) throws -> [String: Any] {
        let data = try openToData(header: header, encPayload: encPayload)
        guard let object = try? JSONSerialization.jsonObject(with: data), let dict = object as? [String: Any] else {
            throw LogosCryptoError.notAnObject
        }
        return dict
    }

    var nextSendCounter: UInt64 { sendCounter }
    var lastReceivedCounter: Int64 { recvLast }

    // MARK: - Helpers

    private static func makeNonce(direction: UInt8, counter: UInt64) -> Data {
        var data = Data([direction])
        var bigEndian = counter.bigEndian
        withUnsafeBytes(of: &bigEndian) { data.append(contentsOf: $0) }
        data.append(contentsOf: [0, 0, 0])
        return data
    }

    private static func makeAAD(header: [String: Any], counter: UInt64) -> Data {
        // Length-prefixed (UInt32 big-endian length + UTF-8 bytes per field) so the AAD is
        // injective — must match plugins/logos/crypto.py `_aad`. A separator-join would let
        // distinct header tuples collide (routing fields are free-form), enabling ciphertext
        // relocation to a different route with a valid tag.
        var fields = [encVersion]
        for field in headerFields {
            if let value = header[field], !(value is NSNull) {
                fields.append(stringify(value))
            } else {
                fields.append("")
            }
        }
        fields.append(String(counter))
        var data = Data()
        for field in fields {
            let encoded = Data(field.utf8)
            var length = UInt32(encoded.count).bigEndian
            withUnsafeBytes(of: &length) { data.append(contentsOf: $0) }
            data.append(encoded)
        }
        return data
    }

    private static func stringify(_ value: Any) -> String {
        if let string = value as? String { return string }
        if let number = value as? NSNumber { return number.stringValue }
        return String(describing: value)
    }

    /// Reject JSON booleans bridged to NSNumber; accept genuine integers (matches Python's `isinstance(n, bool)` rejection).
    private static func intCounter(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber else { return nil }
        if CFGetTypeID(number) == CFBooleanGetTypeID() { return nil }
        return number.intValue
    }

    static func redactSecrets(_ value: [String: Any]) -> [String: Any] {
        var result: [String: Any] = [:]
        for (key, item) in value {
            if secretMarkers.contains(where: { key.lowercased().contains($0) }) {
                result[key] = "[REDACTED]"
            } else {
                result[key] = redactValue(item)
            }
        }
        return result
    }

    // Recurse into nested objects AND arrays, matching Python `schema.redact_secrets`.
    private static func redactValue(_ item: Any) -> Any {
        if let nested = item as? [String: Any] {
            return redactSecrets(nested)
        }
        if let array = item as? [Any] {
            return array.map { redactValue($0) }
        }
        return item
    }
}
