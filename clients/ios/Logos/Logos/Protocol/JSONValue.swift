import Foundation

/// A type-safe representation of an arbitrary JSON value — the "open payload" half of the
/// two-stage wire decode (WS1 P3). Routing fields decode into typed `LogosEnvelope` properties;
/// the `payload` stays a `JSONValue` tree until a per-`type` consumer re-decodes the parts it
/// needs. Unlike `[String: Any]`, this is `Codable` and `Equatable`, so frames can be decoded,
/// pattern-matched, and asserted on without unchecked `as?` casts.
enum JSONValue: Codable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
            return
        }
        // Bool must be probed before Double: JSON `true`/`false` would otherwise be coerced to a
        // number by NSNumber bridging on some platforms.
        if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported JSON value"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
}

// MARK: - Ergonomic typed access

extension JSONValue {
    var objectValue: [String: JSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }

    var arrayValue: [JSONValue]? {
        if case .array(let value) = self { return value }
        return nil
    }

    var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    var doubleValue: Double? {
        if case .number(let value) = self { return value }
        return nil
    }

    var intValue: Int? {
        switch self {
        case .number(let value): return Int(value)
        case .string(let value): return Int(value)
        default: return nil
        }
    }

    var boolValue: Bool? {
        switch self {
        case .bool(let value): return value
        case .number(let value): return value != 0
        default: return nil
        }
    }

    var isNull: Bool {
        if case .null = self { return true }
        return false
    }

    /// Convenience subscript for walking object trees: `payload["message"]?["content"]?.stringValue`.
    subscript(key: String) -> JSONValue? {
        objectValue?[key]
    }

    /// Re-encode this value back into a loosely-typed dictionary for the legacy `[String: Any]`
    /// dispatch path during the P3 → P8 migration. Returns nil for non-objects.
    func toDictionary() -> [String: Any]? {
        guard
            let data = try? JSONEncoder().encode(self),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return object
    }
}
