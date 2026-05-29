import XCTest
@testable import Logos

/// WS1 P5: the audio stream-timeout watchdog collaborator lifted out of LogosClient.
@MainActor
final class PlaybackStreamTimeoutTests: XCTestCase {

    func testScheduleAndMatchingCancelLifecycle() {
        let timeout = PlaybackStreamTimeout()
        XCTAssertFalse(timeout.isScheduled)

        timeout.schedule(audioID: "a") { _ in }
        XCTAssertTrue(timeout.isScheduled)
        XCTAssertEqual(timeout.audioID, "a")

        timeout.cancel(audioID: "b")  // stale id -> no-op
        XCTAssertTrue(timeout.isScheduled)

        timeout.cancel(audioID: "a")
        XCTAssertFalse(timeout.isScheduled)
        XCTAssertNil(timeout.audioID)
    }

    func testFiresAfterIntervalWithAudioID() async {
        let timeout = PlaybackStreamTimeout(interval: 0.05)
        let fired = expectation(description: "watchdog fired")
        timeout.schedule(audioID: "track-1") { id in
            XCTAssertEqual(id, "track-1")
            fired.fulfill()
        }
        await fulfillment(of: [fired], timeout: 5.0)
    }

    func testCancelPreventsFire() async {
        let timeout = PlaybackStreamTimeout(interval: 0.05)
        var fired = false
        timeout.schedule(audioID: "a") { _ in fired = true }
        timeout.cancel()
        try? await Task.sleep(nanoseconds: 200_000_000)  // well past the 50ms interval
        XCTAssertFalse(fired)
    }

    func testScheduleReplacesPreviousWatchdog() {
        let timeout = PlaybackStreamTimeout()
        timeout.schedule(audioID: "a") { _ in }
        timeout.schedule(audioID: "b") { _ in }
        XCTAssertEqual(timeout.audioID, "b")
        timeout.cancel()
        XCTAssertFalse(timeout.isScheduled)
    }
}
