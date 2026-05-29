import XCTest
@testable import Logos

/// WS1 P5: the spectrum-animation loop collaborator lifted out of LogosClient.
@MainActor
final class SpectrumAnimatorTests: XCTestCase {

    func testStartSetsAnimatingAndMatchingStopClears() {
        let animator = SpectrumAnimator()
        XCTAssertFalse(animator.isAnimating)

        animator.start(audioID: "a") { _ in }
        XCTAssertTrue(animator.isAnimating)
        XCTAssertEqual(animator.audioID, "a")

        // A stale stop for a superseded track is a no-op.
        animator.stop(audioID: "b")
        XCTAssertTrue(animator.isAnimating)

        animator.stop(audioID: "a")
        XCTAssertFalse(animator.isAnimating)
        XCTAssertNil(animator.audioID)
    }

    func testStartReplacesPreviousLoop() {
        let animator = SpectrumAnimator()
        animator.start(audioID: "a") { _ in }
        animator.start(audioID: "b") { _ in }
        XCTAssertEqual(animator.audioID, "b")
        animator.stop()
        XCTAssertFalse(animator.isAnimating)
    }

    func testTickFiresWithTheActiveAudioID() async {
        let animator = SpectrumAnimator()
        let fired = expectation(description: "tick fired")
        fired.assertForOverFulfill = false
        animator.start(audioID: "track-1") { id in
            XCTAssertEqual(id, "track-1")
            fired.fulfill()
        }
        await fulfillment(of: [fired], timeout: 2.0)
        animator.stop()
        XCTAssertFalse(animator.isAnimating)
    }
}
