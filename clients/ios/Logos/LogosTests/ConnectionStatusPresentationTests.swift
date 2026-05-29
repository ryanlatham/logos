import XCTest
@testable import Logos

/// WS1 P6: the connection-status view-model projection (title / action / indicator).
final class ConnectionStatusPresentationTests: XCTestCase {

    func testTitleForEachState() {
        XCTAssertEqual(ConnectionStatusPresentation.title(for: .connected), "Connected")
        XCTAssertEqual(ConnectionStatusPresentation.title(for: .connecting), "Connecting…")
        XCTAssertEqual(ConnectionStatusPresentation.title(for: .disconnected), "Disconnected")
        XCTAssertEqual(ConnectionStatusPresentation.title(for: .error), "Error")
    }

    func testActionTitleForEachState() {
        XCTAssertEqual(ConnectionStatusPresentation.actionTitle(for: .connected), "Disconnect")
        XCTAssertEqual(ConnectionStatusPresentation.actionTitle(for: .connecting), "Connecting…")
        XCTAssertEqual(ConnectionStatusPresentation.actionTitle(for: .disconnected), "Connect")
        XCTAssertEqual(ConnectionStatusPresentation.actionTitle(for: .error), "Connect")
    }

    func testIndicatorForEachState() {
        XCTAssertEqual(ConnectionStatusPresentation.indicator(for: .connected), .ok)
        XCTAssertEqual(ConnectionStatusPresentation.indicator(for: .connecting), .pending)
        XCTAssertEqual(ConnectionStatusPresentation.indicator(for: .disconnected), .idle)
        XCTAssertEqual(ConnectionStatusPresentation.indicator(for: .error), .error)
    }
}
