import XCTest
@testable import Logos

/// WS1 P8 value-equivalence harness: `LogosMessage`'s new `Decodable` conformance must produce
/// EXACTLY what the proven `from(dictionary:)` decoder produces, across every coercion branch
/// (strict-bool `finalized`, coerced `transient`/`error`, `progress_kind`/`kind` fallback,
/// string `server_seq`, missing fields, sorted-keys `metadataJSON`). If they ever diverge, this
/// fails — the guardrail the memory file requires before trusting the Codable path.
final class LogosMessageCodableTests: XCTestCase {

    private let corpus: [String] = [
        // Full assistant message with rich metadata.
        #"{"project_key":"p","session_id":"s","message_id":"m","role":"assistant","content":"hi","server_seq":12,"timestamp":1000.5,"status":"persisted","metadata":{"finalized":true,"source":"hermes","request_id":"r1","final_status":"completed"}}"#,
        // Progress message: progress_kind present, finalized false, transient as Int.
        #"{"project_key":"p","session_id":"s","message_id":"m2","role":"assistant","content":"working","server_seq":13,"timestamp":1001,"metadata":{"finalized":false,"source":"tool_progress","progress_kind":"tool","transient":1,"kind":"tool"}}"#,
        // kind-only (progress_kind falls back to kind); error coerced from string.
        #"{"project_key":"p","session_id":"s","message_id":"m3","role":"assistant","content":"x","server_seq":14,"timestamp":1002,"metadata":{"kind":"compaction","error":"true"}}"#,
        // server_seq as a string; no metadata.
        #"{"project_key":"p","session_id":"s","message_id":"m4","role":"user","content":"hello","server_seq":"99","timestamp":1003}"#,
        // Missing optional status/server_seq/metadata -> defaults.
        #"{"project_key":"p","session_id":"s","message_id":"m5","role":"assistant","content":"y","timestamp":1004}"#,
        // transient false via Int 0; error false via Bool.
        #"{"project_key":"p","session_id":"s","message_id":"m6","role":"assistant","content":"z","server_seq":15,"timestamp":1005,"metadata":{"transient":0,"error":false,"final_status":"failed"}}"#,
    ]

    func testDecodableMatchesDictionaryDecoderAcrossCorpus() throws {
        for json in corpus {
            let data = Data(json.utf8)
            let viaCodable = try JSONDecoder().decode(LogosMessage.self, from: data)
            let dictionary = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let viaDictionary = try XCTUnwrap(LogosMessage.from(dictionary: dictionary))

            // LogosMessage is Hashable/Equatable — full structural equality across every field.
            XCTAssertEqual(viaCodable, viaDictionary, "Codable vs dictionary decode diverged for: \(json)")
            // Spot-check a couple of derived fields stay consistent too.
            XCTAssertEqual(viaCodable.metadataJSON, viaDictionary.metadataJSON)
            XCTAssertEqual(viaCodable.isProgressUpdate, viaDictionary.isProgressUpdate)
        }
    }

    func testDecodableRejectsFramesMissingRequiredFields() {
        // Missing content -> from(dictionary:) returns nil -> Decodable throws (not a silent default).
        let badJSON = #"{"project_key":"p","session_id":"s","message_id":"m","role":"assistant"}"#
        XCTAssertThrowsError(try JSONDecoder().decode(LogosMessage.self, from: Data(badJSON.utf8)))
    }

    func testDecodableSurfacesCoercedMetadataFields() throws {
        let json = #"{"project_key":"p","session_id":"s","message_id":"m","role":"assistant","content":"c","server_seq":7,"timestamp":1,"metadata":{"finalized":true,"progress_kind":"thinking","request_id":"req","transient":true,"error":1}}"#
        let message = try JSONDecoder().decode(LogosMessage.self, from: Data(json.utf8))
        XCTAssertTrue(message.isFinal)
        XCTAssertTrue(message.hasFinalizedMetadata)
        XCTAssertEqual(message.progressKind, "thinking")
        XCTAssertEqual(message.metadataRequestID, "req")
        XCTAssertEqual(message.metadataTransient, true)
        XCTAssertTrue(message.metadataIsError)  // coerced from Int 1
    }
}
