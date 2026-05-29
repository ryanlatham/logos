import XCTest
@testable import Logos

/// WS1 P3: the Codable wire layer (JSONValue / LogosEnvelope) and decode-failure surfacing.
final class LogosProtocolTests: XCTestCase {

    // MARK: - JSONValue

    func testJSONValueDecodesEveryVariant() throws {
        let json = """
        {"s":"hi","n":3.5,"i":7,"b":true,"nothing":null,"arr":[1,"two",false],"obj":{"k":"v"}}
        """
        let value = try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
        XCTAssertEqual(value["s"]?.stringValue, "hi")
        XCTAssertEqual(value["n"]?.doubleValue, 3.5)
        XCTAssertEqual(value["i"]?.intValue, 7)
        XCTAssertEqual(value["b"]?.boolValue, true)
        XCTAssertEqual(value["nothing"]?.isNull, true)
        XCTAssertEqual(value["arr"]?.arrayValue?.count, 3)
        XCTAssertEqual(value["arr"]?.arrayValue?[1].stringValue, "two")
        XCTAssertEqual(value["obj"]?["k"]?.stringValue, "v")
    }

    func testJSONValueRoundTripsThroughEncoding() throws {
        let original: JSONValue = .object([
            "type": .string("state_update"),
            "server_seq": .number(42),
            "flag": .bool(false),
            "items": .array([.string("a"), .null]),
        ])
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(JSONValue.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func testJSONValueBoolIsNotCoercedToNumber() throws {
        let value = try JSONDecoder().decode(JSONValue.self, from: Data("true".utf8))
        XCTAssertEqual(value, .bool(true))
        XCTAssertEqual(value.boolValue, true)
    }

    func testJSONValueToDictionaryRehydratesLegacyShape() throws {
        let value: JSONValue = .object(["project_key": .string("archwright"), "server_seq": .number(5)])
        let dictionary = try XCTUnwrap(value.toDictionary())
        XCTAssertEqual(dictionary["project_key"] as? String, "archwright")
        XCTAssertEqual(dictionary["server_seq"] as? Int, 5)
    }

    // MARK: - LogosEnvelope

    func testEnvelopeDecodesRoutingFieldsAndPayloadTree() throws {
        let frame = """
        {"type":"state_update","request_id":"req-1","device_id":"iphone","project_key":"archwright",
         "session_id":"s1","server_seq":12,"payload":{"op":"message_appended","message":{"content":"hi"}}}
        """
        let envelope = try LogosEnvelope.decode(from: frame)
        XCTAssertEqual(envelope.type, "state_update")
        XCTAssertEqual(envelope.requestID, "req-1")
        XCTAssertEqual(envelope.deviceID, "iphone")
        XCTAssertEqual(envelope.projectKey, "archwright")
        XCTAssertEqual(envelope.sessionID, "s1")
        XCTAssertEqual(envelope.serverSeq, 12)
        XCTAssertEqual(envelope.payload?["op"]?.stringValue, "message_appended")
        XCTAssertEqual(envelope.payload?["message"]?["content"]?.stringValue, "hi")
    }

    func testEnvelopeToleratesMissingOptionalRoutingFields() throws {
        let envelope = try LogosEnvelope.decode(from: #"{"type":"hello"}"#)
        XCTAssertEqual(envelope.type, "hello")
        XCTAssertNil(envelope.requestID)
        XCTAssertNil(envelope.serverSeq)
        XCTAssertNil(envelope.payload)
    }

    func testEnvelopeToleratesStringEncodedServerSeq() throws {
        let envelope = try LogosEnvelope.decode(from: #"{"type":"state_update","server_seq":"99"}"#)
        XCTAssertEqual(envelope.serverSeq, 99)
    }

    func testEnvelopeDetectsEncryptedPayload() throws {
        let sealed = try LogosEnvelope.decode(from: #"{"type":"state_update","payload":{"enc":1,"n":4,"ct":"abc"}}"#)
        XCTAssertTrue(sealed.isEncryptedPayload)
        let plain = try LogosEnvelope.decode(from: #"{"type":"state_update","payload":{"op":"x"}}"#)
        XCTAssertFalse(plain.isEncryptedPayload)
    }

    func testEnvelopeThrowsOnMalformedFrame() {
        XCTAssertThrowsError(try LogosEnvelope.decode(from: "not json")) { error in
            guard case LogosWireError.malformed = error else {
                return XCTFail("expected .malformed, got \(error)")
            }
        }
        // Missing the required `type` field is also a hard failure, not a silent drop.
        XCTAssertThrowsError(try LogosEnvelope.decode(from: #"{"request_id":"r"}"#))
    }

    // MARK: - Decode-failure surfacing

    func testDecodeListCountsDroppedEntries() {
        let raw: [[String: Any]] = [
            ["project_key": "a", "title": "Alpha"],
            ["title": "no key -> dropped"],
            ["project_key": "b"],
            ["nonsense": 1],
        ]
        let outcome = LogosWireDecoder.decodeList(raw, LogosProject.from(dictionary:))
        XCTAssertEqual(outcome.decoded.count, 2)
        XCTAssertEqual(outcome.droppedCount, 2)
        XCTAssertTrue(outcome.hasDrops)
        XCTAssertEqual(outcome.decoded.map(\.projectKey), ["a", "b"])
    }

    func testDecodeListReportsNoDropsForCleanInput() {
        let raw: [[String: Any]] = [["project_key": "a"], ["project_key": "b"]]
        let outcome = LogosWireDecoder.decodeList(raw, LogosProject.from(dictionary:))
        XCTAssertEqual(outcome.decoded.count, 2)
        XCTAssertEqual(outcome.droppedCount, 0)
        XCTAssertFalse(outcome.hasDrops)
    }
}
