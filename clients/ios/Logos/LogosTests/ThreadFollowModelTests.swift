import XCTest
@testable import Logos

/// WS1 PR4c: the thread auto-follow / scroll / unseen-updates state machine, extracted out of
/// `ContentView` into `ThreadFollowModel` so it can finally be unit-tested in isolation.
///
/// These exercise the state transitions only — real scrolling (the `ScrollPosition.scrollTo`
/// side effects and the `Task.sleep` 3-pass layout settling) is not unit-testable, so the tests
/// drive the model's entry points directly and assert the follow/detach/unseen flags.
@MainActor
final class ThreadFollowModelTests: XCTestCase {

    // Opaque content/message fingerprints — the model treats them as snapshot tokens, so the
    // tests only care about equality, not the real hashing.
    private let contentA = 1
    private let contentB = 2
    private let messageA = "msg-a"
    private let messageB = "msg-b"

    private func makeClient(serverSeqs: [Int] = []) -> LogosClient {
        // Each client gets an isolated SQLite store so messages don't leak across tests (the
        // default store is a shared on-disk DB). Mirrors the seam used throughout LogosModelTests.
        let client = LogosClient(store: SQLiteMessageStore(filename: "LogosTests-\(UUID().uuidString).sqlite3"))
        for (index, seq) in serverSeqs.enumerated() {
            client.messageManager.applyPersistedMessage(
                LogosMessage(
                    projectKey: client.activeProjectKey,
                    sessionID: "session-follow",
                    messageID: "msg-\(index)",
                    serverSeq: seq,
                    role: "assistant",
                    content: "message \(index)",
                    timestamp: TimeInterval(index + 1),
                    status: "persisted"
                )
            )
        }
        return client
    }

    // MARK: - Detach on user scroll far from bottom

    func testDetachFromAutoFollowOnUserScrollFarFromBottom() {
        let client = makeClient(serverSeqs: [10, 11])
        let model = ThreadFollowModel()
        // The user scrolled away from the bottom.
        model.isThreadNearBottom = false

        model.detachThreadFromAutoFollow(client: client, threadContentFingerprint: contentA)

        XCTAssertFalse(model.shouldFollowThread)
        XCTAssertTrue(model.isThreadUserDetached)
        XCTAssertEqual(model.detachedThreadContentFingerprint, contentA)
        XCTAssertEqual(model.detachedThreadMaxServerSeq, 11)
    }

    func testDetachIsIgnoredWhileNearBottomWithoutUserScroll() {
        let client = makeClient()
        let model = ThreadFollowModel()
        // Near the bottom and no observed user scroll → must stay attached.
        model.isThreadNearBottom = true
        model.userInitiatedThreadScrollObserved = false

        model.detachThreadFromAutoFollow(client: client, threadContentFingerprint: contentA)

        XCTAssertTrue(model.shouldFollowThread)
        XCTAssertFalse(model.isThreadUserDetached)
        XCTAssertNil(model.detachedThreadContentFingerprint)
    }

    func testProximityChangeAwayFromBottomDuringUserDragDetaches() {
        let client = makeClient(serverSeqs: [3])
        let model = ThreadFollowModel()
        model.isThreadNearBottom = true
        model.userInitiatedThreadScrollObserved = true

        model.handleThreadBottomProximityChanged(false, client: client, threadContentFingerprint: contentA)

        XCTAssertFalse(model.isThreadNearBottom)
        XCTAssertFalse(model.shouldFollowThread)
        XCTAssertTrue(model.isThreadUserDetached)
        XCTAssertEqual(model.detachedThreadContentFingerprint, contentA)
    }

    // MARK: - Reattach clears unseen + re-follows

    func testMarkThreadContentSeenAtBottomReattachesAndClearsUnseen() {
        let model = ThreadFollowModel()
        // Arrange a detached, unseen-laden state.
        model.shouldFollowThread = false
        model.isThreadUserDetached = true
        model.hasUnseenThreadUpdates = true
        model.detachedThreadContentFingerprint = contentA
        model.userInitiatedThreadScrollObserved = true

        model.markThreadContentSeenAtBottom(resetUserScrollObservation: true, threadContentFingerprint: contentB)

        XCTAssertTrue(model.shouldFollowThread)
        XCTAssertFalse(model.isThreadUserDetached)
        XCTAssertFalse(model.hasUnseenThreadUpdates)
        XCTAssertNil(model.detachedThreadContentFingerprint)
        XCTAssertEqual(model.lastFollowedThreadContentFingerprint, contentB)
        XCTAssertFalse(model.userInitiatedThreadScrollObserved)
    }

    func testMarkSeenKeepsUserScrollObservationWhenNotResetting() {
        let model = ThreadFollowModel()
        model.userInitiatedThreadScrollObserved = true

        model.markThreadContentSeenAtBottom(resetUserScrollObservation: false, threadContentFingerprint: contentA)

        XCTAssertTrue(model.userInitiatedThreadScrollObserved)
    }

    func testProximityBackToBottomReattachesAfterDetach() {
        let client = makeClient(serverSeqs: [5, 6])
        let model = ThreadFollowModel()
        // Start detached and away from bottom.
        model.isThreadNearBottom = false
        model.shouldFollowThread = false
        model.isThreadUserDetached = true
        model.hasUnseenThreadUpdates = true
        model.detachedThreadContentFingerprint = contentA
        model.threadScrollPhase = .idle

        model.handleThreadBottomProximityChanged(true, client: client, threadContentFingerprint: contentB)

        XCTAssertTrue(model.isThreadNearBottom)
        XCTAssertTrue(model.shouldFollowThread)
        XCTAssertFalse(model.isThreadUserDetached)
        XCTAssertFalse(model.hasUnseenThreadUpdates)
        XCTAssertNil(model.detachedThreadContentFingerprint)
    }

    // MARK: - recordDetachedThreadContentIfNeeded snapshots once

    func testRecordDetachedThreadContentSnapshotsOnlyOnce() {
        let client = makeClient(serverSeqs: [40, 41, 42])
        let model = ThreadFollowModel()

        model.recordDetachedThreadContentIfNeeded(client: client, threadContentFingerprint: contentA)
        XCTAssertEqual(model.detachedThreadContentFingerprint, contentA)
        XCTAssertEqual(model.detachedThreadMaxServerSeq, 42)

        // A second call with a *different* fingerprint must not overwrite the first snapshot.
        model.recordDetachedThreadContentIfNeeded(client: client, threadContentFingerprint: contentB)
        XCTAssertEqual(model.detachedThreadContentFingerprint, contentA)
        XCTAssertEqual(model.detachedThreadMaxServerSeq, 42)
    }

    func testRecordDetachedThreadContentDefaultsServerSeqToZeroWhenEmpty() {
        let client = makeClient()
        let model = ThreadFollowModel()

        model.recordDetachedThreadContentIfNeeded(client: client, threadContentFingerprint: contentA)

        XCTAssertEqual(model.detachedThreadContentFingerprint, contentA)
        XCTAssertEqual(model.detachedThreadMaxServerSeq, 0)
    }

    // MARK: - unseenThreadUpdateCount via ThreadUnseenPolicy

    func testUnseenThreadUpdateCountIsZeroWhileAttached() {
        let client = makeClient(serverSeqs: [10, 11, 12])
        let model = ThreadFollowModel()
        // No detachment snapshot recorded → attached → zero unseen.
        XCTAssertEqual(model.unseenThreadUpdateCount(client: client), 0)
    }

    func testUnseenThreadUpdateCountAfterDetachMatchesPolicy() {
        let client = makeClient(serverSeqs: [10, 11, 12, 13])
        let model = ThreadFollowModel()
        // Simulate detaching when the latest seen server_seq was 11.
        model.detachedThreadContentFingerprint = contentA
        model.detachedThreadMaxServerSeq = 11

        // 12 and 13 arrived after detachment.
        XCTAssertEqual(model.unseenThreadUpdateCount(client: client), 2)
        XCTAssertEqual(
            model.unseenThreadUpdateCount(client: client),
            ThreadUnseenPolicy.unseenCount(serverSeqs: client.messages.map(\.serverSeq), since: 11)
        )
    }

    func testUnseenThreadUpdateCountResetsWhenReattached() {
        let client = makeClient(serverSeqs: [10, 11, 12, 13])
        let model = ThreadFollowModel()
        model.detachedThreadContentFingerprint = contentA
        model.detachedThreadMaxServerSeq = 11
        XCTAssertEqual(model.unseenThreadUpdateCount(client: client), 2)

        // Re-attaching clears the detachment fingerprint → count returns to zero.
        model.markThreadContentSeenAtBottom(resetUserScrollObservation: true, threadContentFingerprint: contentB)
        XCTAssertEqual(model.unseenThreadUpdateCount(client: client), 0)
    }

    // MARK: - shouldShowThreadNewUpdatesButton across branches

    func testNewUpdatesButtonHiddenWhileNearBottom() {
        let model = ThreadFollowModel()
        model.isThreadNearBottom = true
        model.hasUnseenThreadUpdates = true

        XCTAssertFalse(
            model.shouldShowThreadNewUpdatesButton(threadContentFingerprint: contentA, threadMessageFingerprint: messageA)
        )
    }

    func testNewUpdatesButtonShownWhenUnseenFlagSetAwayFromBottom() {
        let model = ThreadFollowModel()
        model.isThreadNearBottom = false
        model.hasUnseenThreadUpdates = true

        XCTAssertTrue(
            model.shouldShowThreadNewUpdatesButton(threadContentFingerprint: contentA, threadMessageFingerprint: messageA)
        )
    }

    func testNewUpdatesButtonDetachedBranchComparesDetachedFingerprint() {
        let model = ThreadFollowModel()
        model.isThreadNearBottom = false
        model.isThreadUserDetached = true
        model.detachedThreadContentFingerprint = contentA

        // Content changed since detachment → show.
        XCTAssertTrue(
            model.shouldShowThreadNewUpdatesButton(threadContentFingerprint: contentB, threadMessageFingerprint: messageA)
        )
        // Content unchanged since detachment → hide.
        XCTAssertFalse(
            model.shouldShowThreadNewUpdatesButton(threadContentFingerprint: contentA, threadMessageFingerprint: messageA)
        )
    }

    func testNewUpdatesButtonFollowedBranchComparesLastFollowedFingerprint() {
        let model = ThreadFollowModel()
        model.isThreadNearBottom = false
        model.shouldFollowThread = false
        model.lastFollowedThreadContentFingerprint = contentA

        // Content drifted past the last followed snapshot → show.
        XCTAssertTrue(
            model.shouldShowThreadNewUpdatesButton(threadContentFingerprint: contentB, threadMessageFingerprint: messageA)
        )
        // Still matches the last followed snapshot → hide.
        XCTAssertFalse(
            model.shouldShowThreadNewUpdatesButton(threadContentFingerprint: contentA, threadMessageFingerprint: messageA)
        )
    }

    func testNewUpdatesButtonForceFollowedBranchComparesMessageFingerprint() {
        let model = ThreadFollowModel()
        model.isThreadNearBottom = false
        model.shouldFollowThread = false
        // Neither detached nor last-followed snapshots set → fall through to the force-followed branch.
        model.lastForceFollowedThreadContentFingerprint = messageA

        // Message fingerprint changed since the force-follow → show.
        XCTAssertTrue(
            model.shouldShowThreadNewUpdatesButton(threadContentFingerprint: contentA, threadMessageFingerprint: messageB)
        )
        // Message fingerprint unchanged → hide.
        XCTAssertFalse(
            model.shouldShowThreadNewUpdatesButton(threadContentFingerprint: contentA, threadMessageFingerprint: messageA)
        )
    }

    // MARK: - handleThreadContentChanged detached branch sets unseen

    func testHandleThreadContentChangedSetsUnseenWhenDetached() {
        let client = makeClient()
        let model = ThreadFollowModel()
        model.shouldFollowThread = false
        model.isThreadUserDetached = true
        XCTAssertFalse(model.hasUnseenThreadUpdates)

        model.handleThreadContentChanged(
            client: client,
            threadContentFingerprint: contentA,
            threadMessageFingerprint: messageA
        )

        XCTAssertTrue(model.hasUnseenThreadUpdates)
    }

    func testHandleThreadContentChangedClearsFocusSuppressionWithoutForce() {
        let client = makeClient()
        let model = ThreadFollowModel()
        // A pending focus-clear suppression should swallow exactly one non-forced content change.
        model.suppressNextThreadContentChangeForFocusClear = true
        model.shouldFollowThread = false
        model.isThreadUserDetached = true

        model.handleThreadContentChanged(
            client: client,
            threadContentFingerprint: contentA,
            threadMessageFingerprint: messageA
        )

        XCTAssertFalse(model.suppressNextThreadContentChangeForFocusClear)
        XCTAssertFalse(model.hasUnseenThreadUpdates)
    }
}
