import XCTest
@testable import Logos

/// WS1 P7: milestone-based progress derived from structured progress_kind with text fallback.
final class ProgressMilestoneTests: XCTestCase {

    func testStructuredKindMapsDirectly() {
        XCTAssertEqual(ProgressMilestone.from(kind: "queued", text: ""), .queued)
        XCTAssertEqual(ProgressMilestone.from(kind: "thinking", text: ""), .thinking)
        XCTAssertEqual(ProgressMilestone.from(kind: "reasoning", text: ""), .thinking)
        XCTAssertEqual(ProgressMilestone.from(kind: "tool_progress", text: ""), .toolRunning)
        XCTAssertEqual(ProgressMilestone.from(kind: "compaction", text: ""), .compacting)
        XCTAssertEqual(ProgressMilestone.from(kind: "retry", text: ""), .retrying)
        XCTAssertEqual(ProgressMilestone.from(kind: "finalizing", text: ""), .finalizing)
    }

    func testStructuredKindIsCaseAndWhitespaceInsensitive() {
        XCTAssertEqual(ProgressMilestone.from(kind: "  Tool_Running ", text: ""), .toolRunning)
    }

    func testFallsBackToTextWhenKindMissingOrUnknown() {
        XCTAssertEqual(ProgressMilestone.from(kind: nil, text: "Compacting context before continuing..."), .compacting)
        XCTAssertEqual(ProgressMilestone.from(kind: "", text: "Retrying in 3s (attempt 2/5)"), .retrying)
        XCTAssertEqual(ProgressMilestone.from(kind: "mystery", text: "Finalizing response"), .finalizing)
        XCTAssertEqual(ProgressMilestone.from(kind: nil, text: "Calling tool foo"), .toolRunning)
    }

    func testDefaultsToThinking() {
        XCTAssertEqual(ProgressMilestone.from(kind: nil, text: ""), .thinking)
        XCTAssertEqual(ProgressMilestone.from(kind: "still working...", text: "still working..."), .thinking)
    }

    func testEveryMilestoneHasLabelAndIcon() {
        for milestone in ProgressMilestone.allCases {
            XCTAssertFalse(milestone.label.isEmpty)
            XCTAssertFalse(milestone.systemImage.isEmpty)
        }
    }

    func testStateExposesCurrentMilestoneFromLatestEvent() {
        let state = ProgressActivityState(
            requestID: "r1",
            projectKey: "p",
            sessionID: "s",
            events: [
                ProgressActivityEvent(id: "1", kind: "thinking", text: "", timestamp: 1, count: 1),
                ProgressActivityEvent(id: "2", kind: "compaction", text: "", timestamp: 2, count: 1),
            ],
            isExpanded: false,
            timedOut: false,
            isComplete: false,
            completedFinalMessageID: nil,
            updateCount: 2,
            lastUpdateAt: 2
        )
        XCTAssertEqual(state.currentMilestone, .compacting)
    }
}
