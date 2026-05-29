import XCTest
@testable import Logos

/// Cross-implementation contract for the Logos app-layer crypto. These known-answer
/// vectors MUST match `tests/test_crypto_roundtrip.py` exactly — same derived keys and
/// same ciphertext from the same inputs. A divergence here means the iOS app and the
/// Python adapter cannot decrypt each other.
final class LogosCryptoTests: XCTestCase {
    // Shared KAT vectors (identical to the Python test).
    private let deviceSecret = "logos-kat-device-secret-v1"
    private let clientNonce = Data(hex: "00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff")!
    private let serverNonce = Data(hex: "ffeeddccbbaa99887766554433221100ffeeddccbbaa99887766554433221100")!
    private let c2sKeyHex = "b3cdc50921850a9fa40b205f750381a8578ab9e933ea6a889d97ebead1244f0c"
    private let s2cKeyHex = "b1f1f071774e7aa39b52b3d10bfba534b918bf8be5123fc5e3dfd2a468c55c80"
    private let katHeader: [String: Any] = [
        "type": "text_input", "request_id": "kat-req", "device_id": "kat-device", "project_key": "default",
    ]
    // The exact plaintext bytes Python sealed (compact JSON, insertion order).
    private let katPlaintext = Data(#"{"text":"deploy staging","is_final":true}"#.utf8)
    private let katSealCtB64 = "KhQpY27pF/oEtm8ZvX2XExqDZ0yeT48Gw0ORUDQNsjXBFtJK7ff50uDQLb1mKjEt0O4zNMnWobIJ"

    private func client(aead: LogosAEAD = .chaCha20Poly1305) throws -> LogosSessionCrypto {
        try LogosSessionCrypto.deriveSession(deviceSecret: deviceSecret, clientNonce: clientNonce, serverNonce: serverNonce, role: .client, aead: aead)
    }

    private func server(aead: LogosAEAD = .chaCha20Poly1305) throws -> LogosSessionCrypto {
        try LogosSessionCrypto.deriveSession(deviceSecret: deviceSecret, clientNonce: clientNonce, serverNonce: serverNonce, role: .server, aead: aead)
    }

    func testKATDerivedKeysMatchPythonVectors() throws {
        let keys = try LogosSessionCrypto.deriveSessionKeys(deviceSecret: deviceSecret, clientNonce: clientNonce, serverNonce: serverNonce)
        XCTAssertEqual(keys.c2s.hexString, c2sKeyHex)
        XCTAssertEqual(keys.s2c.hexString, s2cKeyHex)
        XCTAssertNotEqual(keys.c2s, keys.s2c) // direction separation
    }

    func testKATClientSealIsByteForByteReproducible() throws {
        let sealed = try client().seal(header: katHeader, plaintext: katPlaintext)
        XCTAssertEqual(sealed["enc"] as? Int, 1)
        XCTAssertEqual(sealed["n"] as? Int, 0)
        XCTAssertEqual(sealed["ct"] as? String, katSealCtB64)
    }

    func testRoundTripBothDirections() throws {
        let c = try client()
        let s = try server()
        // client -> server
        let sealed = try c.seal(header: katHeader, payload: ["text": "hello", "is_final": true])
        let opened = try s.open(header: katHeader, encPayload: sealed)
        XCTAssertEqual(opened as NSDictionary, ["text": "hello", "is_final": true] as NSDictionary)
        // server -> client (distinct key/direction)
        let header2: [String: Any] = ["type": "state_update", "project_key": "default"]
        let sealed2 = try s.seal(header: header2, payload: ["op": "message_appended", "message_id": "m1"])
        let opened2 = try c.open(header: header2, encPayload: sealed2)
        XCTAssertEqual(opened2 as NSDictionary, ["op": "message_appended", "message_id": "m1"] as NSDictionary)
    }

    func testCounterIncrementsAndReplayRejected() throws {
        let c = try client()
        let s = try server()
        let s0 = try c.seal(header: katHeader, plaintext: Data("one".utf8))
        let s1 = try c.seal(header: katHeader, plaintext: Data("two".utf8))
        XCTAssertEqual(s0["n"] as? Int, 0)
        XCTAssertEqual(s1["n"] as? Int, 1)
        XCTAssertEqual(try s.openToData(header: katHeader, encPayload: s0), Data("one".utf8))
        XCTAssertEqual(try s.openToData(header: katHeader, encPayload: s1), Data("two".utf8))
        XCTAssertThrowsError(try s.openToData(header: katHeader, encPayload: s0)) // replay
    }

    func testTamperedCiphertextFails() throws {
        let c = try client()
        let s = try server()
        var sealed = try c.seal(header: katHeader, plaintext: Data("secret-ish".utf8))
        var raw = Data(base64Encoded: sealed["ct"] as! String)!
        raw[0] ^= 0x01
        sealed["ct"] = raw.base64EncodedString()
        XCTAssertThrowsError(try s.openToData(header: katHeader, encPayload: sealed))
    }

    func testMovingFrameToDifferentHeaderFails() throws {
        let c = try client()
        let s = try server()
        let sealed = try c.seal(header: katHeader, plaintext: Data("routed".utf8))
        var moved = katHeader
        moved["device_id"] = "someone-else"
        XCTAssertThrowsError(try s.openToData(header: moved, encPayload: sealed))
    }

    func testSecretsRedactedBeforeSealing() throws {
        let c = try client()
        let s = try server()
        let sealed = try c.seal(header: katHeader, payload: ["text": "hi", "device_secret": "super-secret-value"])
        let opened = try s.open(header: katHeader, encPayload: sealed)
        XCTAssertEqual(opened["text"] as? String, "hi")
        XCTAssertEqual(opened["device_secret"] as? String, "[REDACTED]")
    }

    func testAES256GCMRoundTrips() throws {
        let c = try client(aead: .aes256GCM)
        let s = try server(aead: .aes256GCM)
        let sealed = try c.seal(header: katHeader, plaintext: Data("gcm".utf8))
        XCTAssertEqual(try s.openToData(header: katHeader, encPayload: sealed), Data("gcm".utf8))
    }

    func testAADInjectiveNewlineHeaderDoesNotRelocate() throws {
        // Under a naive "\n".join AAD, project_key "a" + session_id "b" collides with
        // project_key "a\nb" — the length-prefixed AAD must keep them distinct.
        let c = try client()
        let s = try server()
        let headerA: [String: Any] = ["type": "text_input", "request_id": "r", "device_id": "d", "project_key": "a", "session_id": "b"]
        let headerB: [String: Any] = ["type": "text_input", "request_id": "r", "device_id": "d", "project_key": "a\nb"]
        let sealed = try c.seal(header: headerA, plaintext: Data("x".utf8))
        XCTAssertThrowsError(try s.openToData(header: headerB, encPayload: sealed))
    }

    func testSecretsRedactedInsideArrays() throws {
        let c = try client()
        let s = try server()
        let sealed = try c.seal(header: katHeader, payload: ["items": [["api_key": "SENSITIVE"]], "auth_token": "T"])
        let opened = try s.open(header: katHeader, encPayload: sealed)
        let items = opened["items"] as? [[String: Any]]
        XCTAssertEqual(items?.first?["api_key"] as? String, "[REDACTED]")
        XCTAssertEqual(opened["auth_token"] as? String, "[REDACTED]")
    }
}

private extension Data {
    init?(hex: String) {
        let chars = Array(hex)
        guard chars.count % 2 == 0 else { return nil }
        var data = Data(capacity: chars.count / 2)
        var index = 0
        while index < chars.count {
            guard let byte = UInt8(String(chars[index ... index + 1]), radix: 16) else { return nil }
            data.append(byte)
            index += 2
        }
        self = data
    }

    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
