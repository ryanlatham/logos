import Foundation

/// The decoded routing header of any inbound Logos frame (WS1 P3, two-stage decode).
///
/// Routing fields are cleartext on the wire and decode into typed properties here; the
/// `payload` stays an open `JSONValue` tree so a per-`type` consumer re-decodes only the parts
/// it needs. Decode failures `throw` (and are surfaced) rather than being silently dropped the
/// way `JSONSerialization` + unchecked `as?` casts do today.
struct LogosEnvelope: Decodable, Equatable {
    let type: String
    let requestID: String?
    let deviceID: String?
    let projectKey: String?
    let sessionID: String?
    let serverSeq: Int?
    let payload: JSONValue?

    enum CodingKeys: String, CodingKey {
        case type
        case requestID = "request_id"
        case deviceID = "device_id"
        case projectKey = "project_key"
        case sessionID = "session_id"
        case serverSeq = "server_seq"
        case payload
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decode(String.self, forKey: .type)
        requestID = try container.decodeIfPresent(String.self, forKey: .requestID)
        deviceID = try container.decodeIfPresent(String.self, forKey: .deviceID)
        projectKey = try container.decodeIfPresent(String.self, forKey: .projectKey)
        sessionID = try container.decodeIfPresent(String.self, forKey: .sessionID)
        // server_seq is an int on the wire, but tolerate a string form defensively.
        if let intSeq = try? container.decodeIfPresent(Int.self, forKey: .serverSeq) {
            serverSeq = intSeq
        } else if let stringSeq = try? container.decodeIfPresent(String.self, forKey: .serverSeq) {
            // `try?` flattens the optional, so `stringSeq` is a non-optional String here.
            serverSeq = Int(stringSeq)
        } else {
            serverSeq = nil
        }
        payload = try container.decodeIfPresent(JSONValue.self, forKey: .payload)
    }

    /// Whether this frame's payload is application-layer sealed (`{enc:1, n, ct}`). The decrypt
    /// step still operates on the cleartext routing header, so this only classifies the frame.
    var isEncryptedPayload: Bool {
        payload?["enc"]?.intValue == 1
    }

    /// Decode a frame string into a typed envelope, throwing `LogosWireError` on malformed input.
    static func decode(from string: String) throws -> LogosEnvelope {
        guard let data = string.data(using: .utf8) else {
            throw LogosWireError.notUTF8
        }
        do {
            return try JSONDecoder().decode(LogosEnvelope.self, from: data)
        } catch {
            throw LogosWireError.malformed(underlying: error)
        }
    }
}

/// Errors surfaced (not silently swallowed) when an inbound frame cannot be decoded.
enum LogosWireError: Error, CustomStringConvertible {
    case notUTF8
    case malformed(underlying: Error)

    var description: String {
        switch self {
        case .notUTF8:
            return "Inbound Logos frame was not valid UTF-8."
        case .malformed(let underlying):
            return "Inbound Logos frame was malformed: \(underlying)"
        }
    }
}
