import XCTest
@testable import Logos

/// WS1 P8 value-equivalence harness for the slash-command wire types: their `Decodable`
/// conformance must equal the proven `from(dictionary:)` decoders (which do slash-normalization
/// + bool coercion + defaults). Guards against drift before the Codable path is trusted.
final class LogosSlashCommandCodableTests: XCTestCase {

    private let specJSON = #"""
    {"id":"help","trigger":"help","canonical":"/help","description":"Show help",
     "aliases":["h","?"],"category":"General","args_hint":"<topic>","subcommands":["a"],
     "source":"hermes","available":true,"unavailable_reason":"","requires_args":false,
     "adds_trailing_space":true,"deprecated":false}
    """#

    private func assertEquivalent<T: Decodable & Equatable>(
        _ type: T.Type, _ json: String, _ fromDict: ([String: Any]) -> T?,
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let data = Data(json.utf8)
        let viaCodable = try JSONDecoder().decode(T.self, from: data)
        let dictionary = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let viaDictionary = try XCTUnwrap(fromDict(dictionary))
        XCTAssertEqual(viaCodable, viaDictionary, file: file, line: line)
    }

    func testSpecDecodableMatchesDictionary() throws {
        try assertEquivalent(SlashCommandSpec.self, specJSON, SlashCommandSpec.from(dictionary:))
    }

    func testCatalogDecodableMatchesDictionary() throws {
        let json = #"""
        {"catalog_version":"v1","schema_version":2,"generated_at":"2026-05-29","fallback_used":true,
         "warnings":["w1"],"commands":[\#(specJSON)]}
        """#
        try assertEquivalent(SlashCommandCatalog.self, json, SlashCommandCatalog.from(dictionary:))
    }

    func testCompletionResultDecodableMatchesDictionary() throws {
        let json = #"{"catalog_version":"v1","items":[],"fallback_used":true,"warnings":["x"]}"#
        try assertEquivalent(SlashCommandCompletionResult.self, json, SlashCommandCompletionResult.from(dictionary:))
    }

    func testCatalogDecodableRejectsMissingVersion() {
        let json = #"{"commands":[]}"#
        XCTAssertThrowsError(try JSONDecoder().decode(SlashCommandCatalog.self, from: Data(json.utf8)))
    }
}
