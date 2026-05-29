import XCTest
@testable import Logos

/// WS1 P7: the error-history buffer that replaces the single overwritten `lastError`.
final class ErrorLogTests: XCTestCase {

    func testRecordInsertsMostRecentFirst() {
        var log = ErrorLogBuffer()
        log.record("first", source: .connection)
        log.record("second", source: .adapter)
        XCTAssertEqual(log.entries.map(\.message), ["second", "first"])
        XCTAssertEqual(log.latest?.message, "second")
        XCTAssertEqual(log.latest?.source, .adapter)
    }

    func testRecordIgnoresBlankMessages() {
        var log = ErrorLogBuffer()
        XCTAssertFalse(log.record("   ", source: .action))
        XCTAssertFalse(log.record("", source: .action))
        XCTAssertTrue(log.isEmpty)
    }

    func testConsecutiveDuplicateCollapsesAndRefreshesTimestamp() {
        var log = ErrorLogBuffer()
        let early = Date(timeIntervalSince1970: 1000)
        let later = Date(timeIntervalSince1970: 2000)
        XCTAssertTrue(log.record("boom", source: .connection, date: early))
        // Same message+source in a row should NOT create a second entry, but should refresh.
        XCTAssertFalse(log.record("boom", source: .connection, date: later))
        XCTAssertEqual(log.entries.count, 1)
        XCTAssertEqual(log.latest?.date, later)
    }

    func testSameMessageDifferentSourceIsDistinct() {
        var log = ErrorLogBuffer()
        log.record("boom", source: .connection)
        log.record("boom", source: .adapter)
        XCTAssertEqual(log.entries.count, 2)
    }

    func testNonConsecutiveDuplicateCreatesNewEntry() {
        var log = ErrorLogBuffer()
        log.record("a", source: .action)
        log.record("b", source: .action)
        log.record("a", source: .action)
        XCTAssertEqual(log.entries.map(\.message), ["a", "b", "a"])
    }

    func testCapacityEvictsOldest() {
        var log = ErrorLogBuffer(capacity: 3)
        for index in 0..<5 {
            log.record("error-\(index)", source: .action)
        }
        XCTAssertEqual(log.entries.count, 3)
        XCTAssertEqual(log.entries.map(\.message), ["error-4", "error-3", "error-2"])
    }

    func testDismissRemovesById() {
        var log = ErrorLogBuffer()
        log.record("keep", source: .action)
        log.record("drop", source: .adapter)
        let dropID = try! XCTUnwrap(log.entries.first { $0.message == "drop" }).id
        XCTAssertTrue(log.dismiss(id: dropID))
        XCTAssertEqual(log.entries.map(\.message), ["keep"])
        XCTAssertFalse(log.dismiss(id: dropID))
    }

    func testClearEmptiesHistory() {
        var log = ErrorLogBuffer()
        log.record("x", source: .action)
        log.clear()
        XCTAssertTrue(log.isEmpty)
        XCTAssertNil(log.latest)
    }

    func testSourceLabelsAreStable() {
        XCTAssertEqual(LoggedError.Source.connection.label, "Connection")
        XCTAssertEqual(LoggedError.Source.adapter.label, "Adapter")
        XCTAssertEqual(LoggedError.Source.allCases.count, 6)
    }
}
