import XCTest
@testable import Logos

/// WS1 P7: the unseen-count policy behind the jump-to-latest pill badge.
final class ThreadUnseenPolicyTests: XCTestCase {

    func testCountsOnlyServerSeqsBeyondDetachment() {
        let seqs = [10, 11, 12, 13]
        XCTAssertEqual(ThreadUnseenPolicy.unseenCount(serverSeqs: seqs, since: 11), 2)  // 12, 13
        XCTAssertEqual(ThreadUnseenPolicy.unseenCount(serverSeqs: seqs, since: 13), 0)
        XCTAssertEqual(ThreadUnseenPolicy.unseenCount(serverSeqs: seqs, since: 0), 4)
    }

    func testLocalAndPendingZeroSeqMessagesAreExcludedOnceDetached() {
        // Local notices / pending messages carry server_seq 0; after detaching past real
        // traffic (base >= 1) they must not inflate the unseen count.
        let seqs = [0, 0, 42, 0, 43]
        XCTAssertEqual(ThreadUnseenPolicy.unseenCount(serverSeqs: seqs, since: 41), 2)
    }

    func testEmptyThreadHasNoUnseen() {
        XCTAssertEqual(ThreadUnseenPolicy.unseenCount(serverSeqs: [], since: 0), 0)
    }

    func testLabelReflectsCountWithPluralization() {
        XCTAssertEqual(ThreadUnseenPolicy.label(unseenCount: 0), "New updates")
        XCTAssertEqual(ThreadUnseenPolicy.label(unseenCount: 1), "1 new message")
        XCTAssertEqual(ThreadUnseenPolicy.label(unseenCount: 5), "5 new messages")
    }
}
