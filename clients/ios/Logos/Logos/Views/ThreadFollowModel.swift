import SwiftUI
import OSLog

private enum ThreadFocusLog {
    static let logger = Logger(subsystem: "dev.logos", category: "thread_focus")
}

@MainActor
private final class ThreadScrollProximityScheduler {
    private var pendingTask: Task<Void, Never>?
    private var epoch = 0

    func schedule(_ isNearBottom: Bool, apply: @MainActor @escaping (Bool) -> Void) {
        pendingTask?.cancel()
        let scheduledEpoch = epoch
        pendingTask = Task { @MainActor in
            await Task.yield()
            guard Task.isCancelled == false, scheduledEpoch == epoch else { return }
            apply(isNearBottom)
        }
    }

    func cancel() {
        epoch += 1
        pendingTask?.cancel()
        pendingTask = nil
    }
}

/// Owns the conversation thread's auto-follow / scroll / "unseen updates" state machine, which
/// previously lived as `@State` plus a tangle of private methods on `ContentView` (WS1 PR4c).
/// Extracting it makes the otherwise view-trapped logic unit-testable.
///
/// This is a faithful mechanical move: every method body is byte-for-byte identical to the
/// `ContentView` original except that (a) the former `@State` vars are this class's own stored
/// properties (read unqualified), and (b) reads of the SwiftUI environment `client`, the
/// `threadContentFingerprint` (`Int`), and the `threadMessageFingerprint` (`String`) are now
/// passed in as parameters — the model deliberately does NOT hold the `@Environment`/`client`.
/// It is `@MainActor`, so the `threadFollowTask`/`threadScrollProximityScheduler` lifecycle and
/// the epoch logic keep their original actor isolation.
@MainActor
@Observable
final class ThreadFollowModel {
    /// Bound at the thread `ScrollView`'s `.scrollPosition($…)` call site via `@Bindable`.
    var threadScrollPosition = ScrollPosition(edge: .bottom)
    var shouldFollowThread = true
    var isThreadNearBottom = true
    var hasUnseenThreadUpdates = false
    var detachedThreadMaxServerSeq: Int?
    var threadScrollPhase: ScrollPhase = .idle
    var isThreadUserDetached = false
    var userInitiatedThreadScrollObserved = false
    var detachedThreadContentFingerprint: Int?
    var lastFollowedThreadContentFingerprint: Int?
    var lastForceFollowedThreadContentFingerprint: String?
    var lastHandledThreadFocusRequestID: String?
    var suppressNextThreadContentChangeForFocusClear = false
    var hasInitializedThreadScroll = false
    @ObservationIgnored private var threadScrollProximityScheduler = ThreadScrollProximityScheduler()
    @ObservationIgnored private var threadFollowTask: Task<Void, Never>?
    @ObservationIgnored private var threadFollowEpoch = 0

    func handleThreadContentChanged(
        forceFollow: Bool = false,
        client: LogosClient,
        threadContentFingerprint: Int,
        threadMessageFingerprint: String
    ) {
        // ThreadTimelineSnapshot is the single visible-thread trigger; ThreadAutoFollowPolicy defines when to stay attached.
        // Only detach after an intentional user scroll far enough from bottom.
        if suppressNextThreadContentChangeForFocusClear, forceFollow == false {
            suppressNextThreadContentChangeForFocusClear = false
            return
        }
        if forceFollow {
            let followedFingerprint = threadContentFingerprint
            lastForceFollowedThreadContentFingerprint = threadMessageFingerprint
            scrollThreadToBottomAfterLayout(
                animated: true,
                recordFollowedSnapshot: true,
                followedFingerprint: followedFingerprint,
                force: true,
                client: client,
                threadContentFingerprint: threadContentFingerprint,
                threadMessageFingerprint: threadMessageFingerprint
            )
        } else if let focus = client.threadFocusRequest, handleThreadFocusRequest(focus, client: client, threadContentFingerprint: threadContentFingerprint, threadMessageFingerprint: threadMessageFingerprint) {
            return
        } else if shouldFollowThread && isThreadUserDetached == false {
            let followedFingerprint = threadContentFingerprint
            scrollThreadToBottomAfterLayout(
                animated: true,
                recordFollowedSnapshot: true,
                followedFingerprint: followedFingerprint,
                client: client,
                threadContentFingerprint: threadContentFingerprint,
                threadMessageFingerprint: threadMessageFingerprint
            )
        } else {
            withAnimation(.easeOut(duration: 0.18)) {
                hasUnseenThreadUpdates = true
            }
        }
    }

    func handleThreadFocusRequest(
        _ focus: ThreadFocusRequest,
        client: LogosClient,
        threadContentFingerprint: Int,
        threadMessageFingerprint: String
    ) -> Bool {
        guard focus.projectKey == client.activeProjectKey else { return false }
        guard client.messages.contains(where: { $0.id == focus.targetMessageID }) else { return false }
        guard lastHandledThreadFocusRequestID != focus.id else { return true }
        lastHandledThreadFocusRequestID = focus.id
        lastForceFollowedThreadContentFingerprint = threadMessageFingerprint
        suppressNextThreadContentChangeForFocusClear = true
        // Finished-notification taps are explicit route focus events; generic bottom scrolling is insufficient for notification replay.
        scrollThreadToTargetAfterLayout(targetID: focus.targetMessageID, anchor: .bottom, animated: true, force: true, client: client, threadContentFingerprint: threadContentFingerprint)
        ThreadFocusLog.logger.info("Thread focus scheduled focus_id=\(focus.id, privacy: .public) project_key=\(focus.projectKey, privacy: .public) target_message_id=\(focus.targetMessageID, privacy: .public) visible=true")
        client.completeThreadFocusRequest(id: focus.id)
        return true
    }

    func detachThreadFromAutoFollow(client: LogosClient, threadContentFingerprint: Int) {
        if isThreadNearBottom == false || userInitiatedThreadScrollObserved {
            cancelPendingThreadFollow()
            shouldFollowThread = false
            isThreadUserDetached = true
            recordDetachedThreadContentIfNeeded(client: client, threadContentFingerprint: threadContentFingerprint)
        }
    }

    func recordDetachedThreadContentIfNeeded(client: LogosClient, threadContentFingerprint: Int) {
        if detachedThreadContentFingerprint == nil {
            detachedThreadContentFingerprint = threadContentFingerprint
            detachedThreadMaxServerSeq = client.messages.map(\.serverSeq).max() ?? 0
        }
    }

    /// Number of server-delivered messages that arrived since the user detached from the bottom.
    /// Gated on the detachment fingerprint so it resets to 0 whenever the thread re-attaches.
    func unseenThreadUpdateCount(client: LogosClient) -> Int {
        guard detachedThreadContentFingerprint != nil, let base = detachedThreadMaxServerSeq else { return 0 }
        return ThreadUnseenPolicy.unseenCount(serverSeqs: client.messages.map(\.serverSeq), since: base)
    }

    func handleThreadBottomProximityChangedAfterLayout(_ isNearBottom: Bool, client: LogosClient, threadContentFingerprint: Int) {
        threadScrollProximityScheduler.schedule(isNearBottom) { [self] coalescedValue in
            handleThreadBottomProximityChanged(coalescedValue, client: client, threadContentFingerprint: threadContentFingerprint)
        }
    }

    func handleThreadBottomProximityChanged(_ isNearBottom: Bool, client: LogosClient, threadContentFingerprint: Int) {
        if isThreadNearBottom == isNearBottom {
            if isNearBottom {
                markThreadContentSeenAtBottom(resetUserScrollObservation: isUserDrivenThreadScrollPhase(threadScrollPhase) == false, threadContentFingerprint: threadContentFingerprint)
            }
            return
        }
        isThreadNearBottom = isNearBottom
        if isNearBottom {
            markThreadContentSeenAtBottom(resetUserScrollObservation: isUserDrivenThreadScrollPhase(threadScrollPhase) == false, threadContentFingerprint: threadContentFingerprint)
        } else {
            recordDetachedThreadContentIfNeeded(client: client, threadContentFingerprint: threadContentFingerprint)
            if isUserDrivenThreadScrollPhase(threadScrollPhase) || userInitiatedThreadScrollObserved {
                detachThreadFromAutoFollow(client: client, threadContentFingerprint: threadContentFingerprint)
            }
        }
    }

    func handleThreadScrollPhaseChanged(_ phase: ScrollPhase, client: LogosClient, threadContentFingerprint: Int) {
        if isUserDrivenThreadScrollPhase(phase) {
            userInitiatedThreadScrollObserved = true
            if isThreadNearBottom == false {
                detachThreadFromAutoFollow(client: client, threadContentFingerprint: threadContentFingerprint)
            }
            return
        }

        if phase == .idle, isThreadNearBottom {
            markThreadContentSeenAtBottom(resetUserScrollObservation: true, threadContentFingerprint: threadContentFingerprint)
        } else if phase == .idle, userInitiatedThreadScrollObserved {
            detachThreadFromAutoFollow(client: client, threadContentFingerprint: threadContentFingerprint)
        }
    }

    func handleThreadScrollPositionChanged(_ position: ScrollPosition, client: LogosClient, threadContentFingerprint: Int) {
        guard position.isPositionedByUser else { return }
        userInitiatedThreadScrollObserved = true
        if isThreadNearBottom == false {
            detachThreadFromAutoFollow(client: client, threadContentFingerprint: threadContentFingerprint)
        }
    }

    func markThreadContentSeenAtBottom(resetUserScrollObservation: Bool, threadContentFingerprint: Int) {
        shouldFollowThread = true
        hasUnseenThreadUpdates = false
        isThreadUserDetached = false
        detachedThreadContentFingerprint = nil
        lastFollowedThreadContentFingerprint = threadContentFingerprint
        if resetUserScrollObservation {
            userInitiatedThreadScrollObserved = false
        }
    }

    func isUserDrivenThreadScrollPhase(_ phase: ScrollPhase) -> Bool {
        switch phase {
        case .tracking, .interacting, .decelerating:
            return true
        case .idle, .animating:
            return false
        }
    }

    func scrollThreadToBottom(
        animated: Bool,
        recordFollowedSnapshot: Bool = true,
        followedFingerprint: Int? = nil,
        threadContentFingerprint: Int
    ) {
        let action = {
            self.threadScrollPosition.scrollTo(id: "thread-bottom", anchor: .bottom)
            self.shouldFollowThread = true
            self.hasUnseenThreadUpdates = false
            self.isThreadUserDetached = false
            self.userInitiatedThreadScrollObserved = false
            self.detachedThreadContentFingerprint = nil
            if recordFollowedSnapshot {
                self.lastFollowedThreadContentFingerprint = followedFingerprint ?? threadContentFingerprint
            }
        }
        if animated {
            withAnimation(.easeOut(duration: 0.18), action)
        } else {
            action()
        }
    }

    func scrollThreadToTarget(
        targetID: String,
        anchor: UnitPoint,
        animated: Bool,
        recordFollowedSnapshot: Bool = true,
        followedFingerprint: Int? = nil,
        threadContentFingerprint: Int
    ) {
        let action = {
            self.threadScrollPosition.scrollTo(id: targetID, anchor: anchor)
            self.shouldFollowThread = true
            self.hasUnseenThreadUpdates = false
            self.isThreadUserDetached = false
            self.userInitiatedThreadScrollObserved = false
            self.detachedThreadContentFingerprint = nil
            if recordFollowedSnapshot {
                self.lastFollowedThreadContentFingerprint = followedFingerprint ?? threadContentFingerprint
            }
        }
        if animated {
            withAnimation(.easeOut(duration: 0.18), action)
        } else {
            action()
        }
    }

    func scrollThreadToBottomAfterLayout(
        animated: Bool,
        recordFollowedSnapshot: Bool = true,
        followedFingerprint: Int? = nil,
        force: Bool = false,
        client: LogosClient,
        threadContentFingerprint: Int,
        threadMessageFingerprint: String
    ) {
        cancelPendingThreadFollow()
        threadFollowEpoch += 1
        let scheduledEpoch = threadFollowEpoch
        let scheduledProjectKey = client.activeProjectKey
        let scheduledCanFollow = ThreadAutoFollowPolicy.shouldApplyFollow(
            force: force,
            shouldFollowThread: shouldFollowThread,
            isThreadUserDetached: isThreadUserDetached
        )
        threadFollowTask = Task { @MainActor in
            defer {
                if scheduledEpoch == threadFollowEpoch {
                    threadFollowTask = nil
                }
            }
            await Task.yield()
            guard shouldApplyScheduledThreadFollow(epoch: scheduledEpoch, projectKey: scheduledProjectKey, force: force, scheduledCanFollow: scheduledCanFollow, client: client) else { return }
            scrollThreadToBottom(
                animated: animated,
                recordFollowedSnapshot: recordFollowedSnapshot,
                followedFingerprint: followedFingerprint,
                threadContentFingerprint: threadContentFingerprint
            )
            try? await Task.sleep(for: .milliseconds(180))
            guard shouldApplyScheduledThreadFollow(epoch: scheduledEpoch, projectKey: scheduledProjectKey, force: false, scheduledCanFollow: scheduledCanFollow, client: client) else { return }
            scrollThreadToBottom(
                animated: false,
                recordFollowedSnapshot: recordFollowedSnapshot,
                followedFingerprint: followedFingerprint,
                threadContentFingerprint: threadContentFingerprint
            )
            confirmPassiveThreadFollowIfStillAtBottom(threadContentFingerprint: threadContentFingerprint)
            if recordFollowedSnapshot == false {
                try? await Task.sleep(for: .milliseconds(600))
                guard shouldApplyScheduledThreadFollow(epoch: scheduledEpoch, projectKey: scheduledProjectKey, force: false, scheduledCanFollow: scheduledCanFollow, client: client) else { return }
                refreshForceFollowedThreadSnapshotIfStillAtBottom(threadMessageFingerprint: threadMessageFingerprint)
            }
        }
    }

    func scrollThreadToTargetAfterLayout(
        targetID: String,
        anchor: UnitPoint,
        animated: Bool,
        force: Bool = false,
        client: LogosClient,
        threadContentFingerprint: Int
    ) {
        cancelPendingThreadFollow()
        threadFollowEpoch += 1
        let scheduledEpoch = threadFollowEpoch
        let scheduledProjectKey = client.activeProjectKey
        let followedFingerprint = threadContentFingerprint
        let scheduledCanFollow = ThreadAutoFollowPolicy.shouldApplyFollow(
            force: force,
            shouldFollowThread: shouldFollowThread,
            isThreadUserDetached: isThreadUserDetached
        )
        threadFollowTask = Task { @MainActor in
            defer {
                if scheduledEpoch == threadFollowEpoch {
                    threadFollowTask = nil
                }
            }
            await Task.yield()
            guard shouldApplyScheduledThreadTargetFollow(epoch: scheduledEpoch, projectKey: scheduledProjectKey, targetID: targetID, force: force, scheduledCanFollow: scheduledCanFollow, client: client) else { return }
            scrollThreadToTarget(targetID: targetID, anchor: anchor, animated: animated, followedFingerprint: followedFingerprint, threadContentFingerprint: threadContentFingerprint)
            ThreadFocusLog.logger.info("Thread focus applied pass=1 target_message_id=\(targetID, privacy: .public) project_key=\(scheduledProjectKey, privacy: .public)")

            try? await Task.sleep(for: .milliseconds(180))
            guard shouldApplyScheduledThreadTargetFollow(epoch: scheduledEpoch, projectKey: scheduledProjectKey, targetID: targetID, force: force, scheduledCanFollow: scheduledCanFollow, client: client) else { return }
            scrollThreadToTarget(targetID: targetID, anchor: anchor, animated: false, followedFingerprint: followedFingerprint, threadContentFingerprint: threadContentFingerprint)
            ThreadFocusLog.logger.info("Thread focus applied pass=2 target_message_id=\(targetID, privacy: .public) project_key=\(scheduledProjectKey, privacy: .public)")

            try? await Task.sleep(for: .milliseconds(420))
            guard shouldApplyScheduledThreadTargetFollow(epoch: scheduledEpoch, projectKey: scheduledProjectKey, targetID: targetID, force: force, scheduledCanFollow: scheduledCanFollow, client: client) else { return }
            scrollThreadToTarget(targetID: targetID, anchor: anchor, animated: false, followedFingerprint: followedFingerprint, threadContentFingerprint: threadContentFingerprint)
            ThreadFocusLog.logger.info("Thread focus applied pass=3 target_message_id=\(targetID, privacy: .public) project_key=\(scheduledProjectKey, privacy: .public)")
        }
    }

    func shouldApplyScheduledThreadFollow(epoch: Int, projectKey: String?, force: Bool, scheduledCanFollow: Bool, client: LogosClient) -> Bool {
        guard Task.isCancelled == false, epoch == threadFollowEpoch, client.activeProjectKey == projectKey else { return false }
        return ThreadAutoFollowPolicy.shouldApplyFollow(
            force: force,
            shouldFollowThread: scheduledCanFollow && shouldFollowThread,
            isThreadUserDetached: isThreadUserDetached
        )
    }

    func shouldApplyScheduledThreadTargetFollow(epoch: Int, projectKey: String?, targetID: String, force: Bool, scheduledCanFollow: Bool, client: LogosClient) -> Bool {
        guard Task.isCancelled == false, epoch == threadFollowEpoch, client.activeProjectKey == projectKey else { return false }
        guard client.messages.contains(where: { $0.id == targetID }) else { return false }
        return ThreadAutoFollowPolicy.shouldApplyFollow(
            force: force,
            shouldFollowThread: scheduledCanFollow && shouldFollowThread,
            isThreadUserDetached: isThreadUserDetached
        )
    }

    func cancelPendingThreadFollow() {
        threadFollowEpoch += 1
        threadFollowTask?.cancel()
        threadFollowTask = nil
    }

    func confirmPassiveThreadFollowIfStillAtBottom(threadContentFingerprint: Int) {
        guard isThreadNearBottom, isThreadUserDetached == false, threadScrollPosition.isPositionedByUser == false else { return }
        shouldFollowThread = true
        hasUnseenThreadUpdates = false
        detachedThreadContentFingerprint = nil
        lastFollowedThreadContentFingerprint = threadContentFingerprint
    }

    func refreshForceFollowedThreadSnapshotIfStillAtBottom(threadMessageFingerprint: String) {
        guard isThreadNearBottom, isThreadUserDetached == false, threadScrollPosition.isPositionedByUser == false else { return }
        lastForceFollowedThreadContentFingerprint = threadMessageFingerprint
    }

    func initializeThreadScrollIfNeeded(client: LogosClient, threadContentFingerprint: Int, threadMessageFingerprint: String) {
        guard hasInitializedThreadScroll == false else { return }
        hasInitializedThreadScroll = true
        scrollThreadToBottomAfterLayout(animated: false, client: client, threadContentFingerprint: threadContentFingerprint, threadMessageFingerprint: threadMessageFingerprint)
    }

    func resetThreadScrollForProjectChange(client: LogosClient, threadContentFingerprint: Int, threadMessageFingerprint: String) {
        threadScrollProximityScheduler.cancel()
        cancelPendingThreadFollow()
        threadScrollPhase = .idle
        shouldFollowThread = true
        hasUnseenThreadUpdates = false
        isThreadUserDetached = false
        userInitiatedThreadScrollObserved = false
        detachedThreadContentFingerprint = nil
        lastFollowedThreadContentFingerprint = threadContentFingerprint
        lastForceFollowedThreadContentFingerprint = threadMessageFingerprint
        lastHandledThreadFocusRequestID = nil
        suppressNextThreadContentChangeForFocusClear = false
        scrollThreadToBottomAfterLayout(animated: false, force: true, client: client, threadContentFingerprint: threadContentFingerprint, threadMessageFingerprint: threadMessageFingerprint)
    }

    func cancelOnDisappear() {
        threadScrollProximityScheduler.cancel()
        cancelPendingThreadFollow()
    }

    func shouldShowThreadNewUpdatesButton(threadContentFingerprint: Int, threadMessageFingerprint: String) -> Bool {
        guard isThreadNearBottom == false else { return false }
        guard isThreadUserDetached || shouldFollowThread == false || isThreadNearBottom == false || threadScrollPosition.isPositionedByUser else {
            return false
        }
        if hasUnseenThreadUpdates { return true }
        if let detachedThreadContentFingerprint {
            return detachedThreadContentFingerprint != threadContentFingerprint
        }
        if lastFollowedThreadContentFingerprint != nil {
            return lastFollowedThreadContentFingerprint != threadContentFingerprint
        }
        if let lastForceFollowedThreadContentFingerprint {
            return lastForceFollowedThreadContentFingerprint != threadMessageFingerprint
        }
        return false
    }
}
