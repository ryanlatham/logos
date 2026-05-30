import SwiftUI
import Foundation
import OSLog

/// The scrolling conversation thread (message list + progress card + interaction cards + the
/// jump-to-latest pill), extracted from `ContentView` (WS1 PR4d). It owns the thread `ScrollView`
/// and all auto-follow / scroll wiring into `threadFollow`, but deliberately does NOT take the
/// composer `draft` as an input: the slash-command menu state/height it needs for the timeline
/// snapshot are passed in as already-computed values, so a composer keystroke re-evaluates
/// `ContentView.body` without re-evaluating this view's body.
struct ThreadView: View {
    @Environment(LogosClient.self) private var client
    @Bindable var threadFollow: ThreadFollowModel

    let composerMode: ComposerMode
    /// The in-flight dictation preview (nil unless recording/finalizing). Sourced from
    /// `ContentView`'s `voiceInput` and threaded in so this view doesn't depend on the controller.
    let voiceDraftText: String?
    // Slash-command menu state/height are derived from the composer `draft` upstream and passed in
    // as plain values purely to feed `threadTimelineSnapshot`; ThreadView never reads `draft`.
    let slashCommandMenuStateRawValue: String
    let slashCommandMenuHeight: CGFloat

    @Binding var clarifyAnswer: String
    var clarifyFocus: FocusState<FocusedField?>.Binding

    let onApprove: () -> Void
    let onDeny: () -> Void
    let onClarifyChoice: (String) -> Void
    let onClarifySubmit: () -> Void
    /// "New updates" pill tap → force-follow to the bottom (ContentView keeps `forceFollowThreadContent`).
    let onForceFollow: () -> Void

    @State private var threadBubbleWidthBasis: CGFloat = 0

    var body: some View {
        ZStack(alignment: .bottom) {
            ScrollView {
                LazyVStack(spacing: 12) {
                    timePill

                    if client.messages.isEmpty, client.approvalCard == nil, client.clarifyCard == nil, client.connectionRetryState == nil {
                        EmptyThreadGreeting(connectionState: client.connectionState)
                    }

                    ForEach(threadMessagesBeforeProgress) { message in
                        messageBubble(message)
                            .id(message.id)
                    }

                    if let progress = client.progressActivity {
                        ProgressActivityCard(
                            activity: progress,
                            isWorking: isProgressWorking,
                            canStop: canStopProgressRun,
                            canRetry: canRetryProgressRun,
                            onToggleExpanded: { client.toggleProgressActivityExpanded() },
                            onStop: { Task { @MainActor in await client.cancelRun() } },
                            onRetry: { Task { @MainActor in _ = await client.retryProgressActivity() } }
                        )
                        .id("progress-activity")
                    }

                    ForEach(threadMessagesAfterProgress) { message in
                        messageBubble(message)
                            .id(message.id)
                    }

                    if let voiceDraftText {
                        DraftUserBubble(text: voiceDraftText)
                            .id("voice-draft")
                    }

                    interactionCards

                    if let ackText = client.ackText, ackText.isEmpty == false {
                        ThinkingBubble(text: ackText)
                            .id("ack")
                    }

                    if let retry = client.connectionRetryState {
                        ConnectionRetryCard(state: retry)
                            .id(retry.id)
                    }

                    if client.connectionRetryState == nil, let error = client.lastError, error.isEmpty == false {
                        ErrorStrip(text: error)
                            .id("error")
                    }

                    Color.clear
                        .frame(height: 1)
                        .id("thread-bottom")
                }
                .scrollTargetLayout()
                .onGeometryChange(for: CGFloat.self) { proxy in
                    proxy.size.width
                } action: { width in
                    threadBubbleWidthBasis = width
                }
                .padding(.horizontal, 14)
                .padding(.top, 14)
                .padding(.bottom, composerMode == .text ? 16 : 28)
                .animation(.timingCurve(0.2, 0.7, 0.2, 1, duration: 0.26), value: composerMode)
            }
            .scrollPosition($threadFollow.threadScrollPosition)
            .defaultScrollAnchor(.bottom, for: .alignment)
            .scrollDismissesKeyboard(.interactively)
            .accessibilityIdentifier("conversationThreadScrollView")
            .simultaneousGesture(
                DragGesture(minimumDistance: 4)
                    .onChanged { _ in
                        threadFollow.userInitiatedThreadScrollObserved = true
                        if threadFollow.isThreadNearBottom == false {
                            threadFollow.detachThreadFromAutoFollow(client: client, threadContentFingerprint: threadContentFingerprint)
                        }
                    }
            )
            .onScrollGeometryChange(for: Bool.self) { geometry in
                ThreadAutoFollowPolicy.isNearBottom(
                    distanceFromBottom: geometry.contentSize.height - geometry.visibleRect.maxY,
                    visibleHeight: geometry.visibleRect.height
                )
            } action: { _, newValue in
                threadFollow.handleThreadBottomProximityChangedAfterLayout(newValue, client: client, threadContentFingerprint: threadContentFingerprint)
            }
            .onScrollPhaseChange { _, newPhase in
                threadFollow.threadScrollPhase = newPhase
                threadFollow.handleThreadScrollPhaseChanged(newPhase, client: client, threadContentFingerprint: threadContentFingerprint)
            }
            .onChange(of: threadFollow.threadScrollPosition) { _, newValue in
                threadFollow.handleThreadScrollPositionChanged(newValue, client: client, threadContentFingerprint: threadContentFingerprint)
            }
            .onAppear {
                threadFollow.initializeThreadScrollIfNeeded(client: client, threadContentFingerprint: threadContentFingerprint, threadMessageFingerprint: threadMessageFingerprint)
            }
            .onDisappear {
                threadFollow.cancelOnDisappear()
            }
            .onChange(of: client.activeProjectKey) { _, _ in
                threadFollow.resetThreadScrollForProjectChange(client: client, threadContentFingerprint: threadContentFingerprint, threadMessageFingerprint: threadMessageFingerprint)
            }
            .onChange(of: threadTimelineSnapshot) { oldValue, newValue in
                handleThreadTimelineSnapshotChanged(from: oldValue, to: newValue)
            }

            if threadFollow.shouldShowThreadNewUpdatesButton(threadContentFingerprint: threadContentFingerprint, threadMessageFingerprint: threadMessageFingerprint) {
                threadNewUpdatesButton
                    .padding(.bottom, 12)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }

    private var progressInsertionIndex: Int? {
        ThreadProgressPlacement.insertionIndex(
            messages: client.messages,
            completedFinalMessageID: client.progressActivity?.completedFinalMessageID
        )
    }

    private func handleThreadTimelineSnapshotChanged(
        from oldValue: ThreadTimelineSnapshot,
        to newValue: ThreadTimelineSnapshot
    ) {
        guard oldValue.contentFingerprint != newValue.contentFingerprint else { return }
        threadFollow.handleThreadContentChanged(client: client, threadContentFingerprint: threadContentFingerprint, threadMessageFingerprint: threadMessageFingerprint)
    }

    private var threadMessagesBeforeProgress: [LogosMessage] {
        guard let progressInsertionIndex else { return client.messages }
        return Array(client.messages[..<progressInsertionIndex])
    }

    private var threadMessagesAfterProgress: [LogosMessage] {
        guard let progressInsertionIndex else { return [] }
        return Array(client.messages[progressInsertionIndex...])
    }

    private var threadMessageFingerprint: String {
        threadTimelineSnapshot.messageFingerprint
    }

    private var threadContentFingerprint: Int {
        threadTimelineSnapshot.threadContentSignature
    }

    private var threadTimelineSnapshot: ThreadTimelineSnapshot {
        ThreadTimelineSnapshot(
            activeProjectKey: client.activeProjectKey,
            messages: client.messages.map {
                ThreadTimelineSnapshot.Message(
                    id: $0.id,
                    status: $0.status,
                    isFinal: $0.isFinal,
                    content: $0.content,
                    role: $0.role,
                    isProgressUpdate: $0.isProgressUpdate
                )
            },
            progress: client.progressActivity.map {
                ThreadTimelineSnapshot.Progress(
                    id: $0.id,
                    updateCount: $0.updateCount,
                    adapterUpdateCount: $0.adapterUpdateCount,
                    isExpanded: $0.isExpanded,
                    isComplete: $0.isComplete,
                    timedOut: $0.timedOut,
                    finalStatus: $0.finalStatus?.rawValue,
                    canRetry: canRetryProgressRun,
                    completedFinalMessageID: $0.completedFinalMessageID
                )
            },
            connectionRetry: client.connectionRetryState.map {
                ThreadTimelineSnapshot.ConnectionRetry(
                    id: $0.id,
                    attemptCount: $0.attemptCount,
                    eventCount: $0.events.count,
                    nextRetryAt: $0.nextRetryAt
                )
            },
            isRunControlVisible: shouldShowRunControl,
            approvalCardID: client.approvalCard?.id,
            clarifyCardID: client.clarifyCard?.id,
            pendingInteractionResponseID: client.pendingInteractionResponseID,
            ackText: client.ackText,
            errorText: client.lastError,
            voiceDraftText: voiceDraftText,
            composerMode: String(describing: composerMode),
            composerBottomPadding: composerMode == .text ? 16 : 28,
            connectionState: client.connectionState.rawValue,
            runStatus: client.runStatus.rawValue,
            focusRequest: client.threadFocusRequest.map {
                ThreadTimelineSnapshot.FocusRequest(id: $0.id, targetMessageID: $0.targetMessageID)
            },
            slashCommandMenuState: slashCommandMenuStateRawValue,
            slashCommandCatalogFingerprint: client.slashCommandCatalog.catalogVersion,
            slashCommandMenuHeight: slashCommandMenuHeight
        )
    }

    private var threadNewUpdatesButton: some View {
        let unseenThreadUpdateCount = threadFollow.unseenThreadUpdateCount(client: client)
        return Button {
            onForceFollow()
        } label: {
            Label(ThreadUnseenPolicy.label(unseenCount: unseenThreadUpdateCount), systemImage: "arrow.down.circle.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.logosAmberOn)
                .padding(.horizontal, 13)
                .padding(.vertical, 9)
                .background(Color.logosAmber, in: Capsule())
                .shadow(color: Color.black.opacity(0.28), radius: 12, x: 0, y: 4)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("threadNewUpdatesButton")
        .accessibilityLabel(unseenThreadUpdateCount > 0
            ? "Jump to latest, \(unseenThreadUpdateCount) new messages"
            : "Jump to latest")
    }

    private var timePill: some View {
        Text("Today \(Date().formatted(date: .omitted, time: .shortened))")
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(Color.logosLabel3)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Color.logosBG2.opacity(0.72), in: Capsule())
    }

    @ViewBuilder
    private var interactionCards: some View {
        if let approval = client.approvalCard {
            ApprovalCardView(
                approval: approval,
                isPending: client.pendingInteractionResponseID == approval.id,
                isConnected: client.connectionState == .connected && client.runStatus != .cancelling,
                onApprove: onApprove,
                onDeny: onDeny
            )
            .id(approval.id)
        }

        if let clarify = client.clarifyCard {
            ClarifyCardView(
                clarify: clarify,
                answer: $clarifyAnswer,
                isPending: client.pendingInteractionResponseID == clarify.id,
                isConnected: client.connectionState == .connected && client.runStatus != .cancelling,
                focused: clarifyFocus,
                onChoice: onClarifyChoice,
                onFreeText: onClarifySubmit
            )
            .id(clarify.id)
        }
    }

    private func messageBubble(_ message: LogosMessage) -> some View {
        HStack(alignment: .bottom) {
            if message.role == "user" { Spacer(minLength: 48) }

            VStack(alignment: .leading, spacing: 7) {
                Text(message.content)
                    .font(.system(size: 16, weight: message.role == "user" ? .medium : .regular))
                    .lineSpacing(1)
                    .foregroundStyle(message.role == "user" ? Color.logosAmberOn : Color.logosLabel)
                    .textSelection(.enabled)
                    .accessibilityIdentifier(message.content)
                    .accessibilityLabel(messageBubbleAccessibilityLabel(message))

                HStack(spacing: 8) {
                    if message.status != "persisted" {
                        Text(message.status)
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundStyle(message.role == "user" ? Color.logosAmberOn.opacity(0.55) : Color.logosLabel3)
                    }

                    if message.role != "user", message.status == "persisted", message.isProgressUpdate == false {
                        Button {
                            Task { @MainActor in await client.playback(message: message) }
                        } label: {
                            Label("Play", systemImage: "play.circle")
                                .labelStyle(.titleAndIcon)
                                .font(.system(size: 12, weight: .semibold))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.logosLabel2)
                        .accessibilityIdentifier("playMessageButton")
                        .disabled(client.connectionState != .connected)
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: (threadBubbleWidthBasis > 0 ? threadBubbleWidthBasis : 360) * 0.78, alignment: .leading)
            .background(message.role == "user" ? Color.logosAmber : Color.logosBG2)
            .clipShape(ChatBubbleShape(isUser: message.role == "user"))
            .shadow(color: .black.opacity(0.18), radius: 8, x: 0, y: 3)

            if message.role != "user" { Spacer(minLength: 48) }
        }
        .frame(maxWidth: .infinity)
    }

    private func messageBubbleAccessibilityLabel(_ message: LogosMessage) -> String {
        let speaker = message.role == "user" ? "You" : "Hermes"
        return "\(speaker): \(message.content)"
    }

    private var shouldShowRunControl: Bool {
        switch client.runStatus {
        case .running, .queued, .awaitingApproval, .awaitingClarification, .cancelling:
            return true
        case .idle, .error:
            return false
        }
    }

    private var isProgressWorking: Bool {
        guard client.progressActivity?.isComplete == false else { return false }
        switch client.runStatus {
        case .running, .queued:
            return true
        case .idle, .awaitingApproval, .awaitingClarification, .cancelling, .error:
            return false
        }
    }

    private var canStopProgressRun: Bool {
        shouldShowRunControl && client.connectionState == .connected && client.runStatus != .cancelling
    }

    private var canRetryProgressRun: Bool {
        guard client.connectionState == .connected, client.runStatus == .idle else { return false }
        guard let progress = client.progressActivity else { return false }
        return (progress.finalStatus == .failed || progress.finalStatus == .interrupted) && progress.retryRequest != nil
    }
}

struct EmptyThreadGreeting: View {
    let connectionState: LogosConnectionState

    var body: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 7) {
                Text(connectionState == .connected ? "Hermes is on the line." : "Connect Logos to Hermes.")
                    .font(.system(size: 16, weight: .regular))
                    .foregroundStyle(Color.logosLabel)
                Text(connectionState == .connected ? "Send a message or tap the mic to start a turn." : "Open Settings to set the adapter URL and device key.")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.logosLabel2)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color.logosBG2, in: ChatBubbleShape(isUser: false))
            Spacer(minLength: 48)
        }
    }
}

struct DraftUserBubble: View {
    let text: String
    @State private var shimmerPhase = false
    @State private var caretVisible = true
    @State private var rowWidth: CGFloat = 0

    var body: some View {
        HStack(alignment: .bottom) {
            Spacer(minLength: 48)
            HStack(alignment: .lastTextBaseline, spacing: 3) {
                Text(text)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(Color.logosAmberOn)
                    .overlay {
                        LinearGradient(
                            colors: [Color.logosAmberOn.opacity(0.55), Color.white.opacity(0.85), Color.logosAmberOn.opacity(0.55)],
                            startPoint: shimmerPhase ? .trailing : .leading,
                            endPoint: shimmerPhase ? .leading : .trailing
                        )
                        .blendMode(.screen)
                        .mask(Text(text).font(.system(size: 16, weight: .medium)))
                    }
                Rectangle()
                    .fill(Color.logosAmberOn)
                    .frame(width: 2, height: 16)
                    .opacity(caretVisible ? 1 : 0)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: (rowWidth > 0 ? rowWidth : 360) * 0.78, alignment: .leading)
            .background(Color.logosAmber, in: ChatBubbleShape(isUser: true))
            .accessibilityElement(children: .combine)
            .accessibilityLabel("You, dictating: \(text)")
        }
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { width in
            rowWidth = width
        }
        .onAppear {
            withAnimation(.linear(duration: 2.4).repeatForever(autoreverses: false)) { shimmerPhase.toggle() }
            withAnimation(.easeInOut(duration: 0.65).repeatForever(autoreverses: true)) { caretVisible.toggle() }
        }
    }
}

struct ProgressActivityCard: View {
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion

    let activity: ProgressActivityState
    let isWorking: Bool
    let canStop: Bool
    let canRetry: Bool
    let onToggleExpanded: () -> Void
    let onStop: () -> Void
    let onRetry: () -> Void

    private var totalEventCount: Int {
        activity.adapterUpdateCount
    }

    private var hasAdapterUpdates: Bool {
        activity.adapterUpdateCount > 0
    }

    private var progressTitleText: String {
        switch activity.finalStatus {
        case .complete: return "Complete"
        case .failed: return "Failed"
        case .stopped: return "Stopped"
        case .interrupted: return "Interrupted"
        case nil: return "Running"
        }
    }

    private var progressSummaryAccessibilityLabel: String {
        var parts = [progressTitleText]
        if isWorking, activity.finalStatus == nil {
            parts.append(activity.currentMilestone.label)
        }
        if hasAdapterUpdates {
            parts.append("\(totalEventCount) update\(totalEventCount == 1 ? "" : "s")")
        }
        return parts.joined(separator: ", ")
    }

    private var accentColor: Color {
        if activity.timedOut || activity.finalStatus == .failed { return .logosRed }
        if activity.finalStatus == .complete { return .logosGreen }
        if activity.finalStatus == .interrupted { return .logosAmber }
        if activity.finalStatus == .stopped { return .logosLabel3 }
        return .logosAmber
    }

    private var leadingToggleTransition: AnyTransition {
        accessibilityReduceMotion ? AnyTransition.opacity : AnyTransition.opacity.combined(with: .move(edge: .leading))
    }

    private var firstUpdateAnimation: Animation {
        accessibilityReduceMotion
            ? .easeInOut(duration: 0.18)
            : .timingCurve(0.18, 0.82, 0.2, 1, duration: 0.46)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .center, spacing: 10) {
                if hasAdapterUpdates || accessibilityReduceMotion {
                    Button(action: onToggleExpanded) {
                        Image(systemName: activity.isExpanded ? "chevron.down.circle.fill" : "chevron.right.circle.fill")
                            .foregroundStyle(accentColor)
                            .frame(width: 24, height: 24)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("progressActivityToggle")
                    .accessibilityLabel(activity.isExpanded ? "Collapse progress updates" : "Expand progress updates")
                    .accessibilityHidden(hasAdapterUpdates == false)
                    .disabled(hasAdapterUpdates == false)
                    .opacity(hasAdapterUpdates ? 1 : 0)
                    .transition(leadingToggleTransition)
                }

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(progressTitleText)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Color.logosLabel)
                        if isWorking {
                            SpinningHourglassIcon(isAnimating: isWorking)
                        }
                        if isWorking, activity.finalStatus == nil {
                            Label(activity.currentMilestone.label, systemImage: activity.currentMilestone.systemImage)
                                .labelStyle(.titleAndIcon)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(Color.logosLabel3)
                                .transition(.opacity)
                                .accessibilityIdentifier("progressMilestoneLabel")
                        }
                    }
                    if hasAdapterUpdates {
                        Text("\(totalEventCount) update\(totalEventCount == 1 ? "" : "s")")
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundStyle(Color.logosLabel3)
                            .transition(.opacity)
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(progressSummaryAccessibilityLabel)

                Spacer(minLength: 8)

                switch activity.finalStatus {
                case .complete, .stopped:
                    HStack(spacing: 5) {
                        Text("Duration")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Color.logosLabel3)
                        ProgressElapsedTimeLabel(activity: activity)
                    }
                    .frame(minWidth: 92, alignment: .trailing)
                case .failed, .interrupted:
                    ProgressElapsedTimeLabel(activity: activity)
                        .frame(minWidth: 58)

                    Spacer(minLength: 8)

                    Button {
                        onRetry()
                    } label: {
                        Label("Retry", systemImage: "arrow.clockwise")
                            .labelStyle(.titleAndIcon)
                    }
                    .buttonStyle(AmberChipButtonStyle())
                    .disabled(canRetry == false)
                    .opacity(canRetry ? 1 : 0.45)
                    .accessibilityIdentifier("retryRunButton")
                    .accessibilityLabel("Retry failed Hermes request")
                case nil:
                    ProgressElapsedTimeLabel(activity: activity)
                        .frame(minWidth: 58)

                    Spacer(minLength: 8)

                    if canStop {
                        Button {
                            onStop()
                        } label: {
                            Label("Stop", systemImage: "stop.fill")
                                .labelStyle(.titleAndIcon)
                        }
                        .buttonStyle(RedChipButtonStyle())
                        .accessibilityIdentifier("stopRunButton")
                        .accessibilityLabel("Stop current Hermes run")
                    }
                }
            }
            .animation(firstUpdateAnimation, value: hasAdapterUpdates)

            if let failureMessage = activity.failureMessage, failureMessage.isEmpty == false {
                Text(failureMessage)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.logosLabel2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if activity.isExpanded && hasAdapterUpdates {
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(activity.events) { event in
                        HStack(alignment: .firstTextBaseline, spacing: 7) {
                            Text(event.text)
                                .font(.system(size: 12, weight: .regular, design: .monospaced))
                                .foregroundStyle(Color.logosLabel2)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            if event.count > 1 {
                                Text("x\(event.count)")
                                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                                    .foregroundStyle(Color.logosAmber)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.logosAmber.opacity(0.15), in: Capsule())
                            }
                        }
                    }
                }
                .padding(.top, 2)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.logosBG2.opacity(0.78), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(accentColor.opacity(0.24), lineWidth: 0.5))
    }
}

struct ProgressElapsedTimeLabel: View {
    let activity: ProgressActivityState

    var body: some View {
        if activity.isComplete {
            // Completed: elapsed is measured to `completedAt`, so the value is frozen — no clock.
            label(now: Date(timeIntervalSince1970: 0))
        } else {
            TimelineView(.periodic(from: Date(), by: 1)) { context in
                label(now: context.date)
            }
        }
    }

    @ViewBuilder
    private func label(now: Date) -> some View {
        let text = elapsedTimeText(startedAt: activity.startedAt, completedAt: activity.completedAt, now: now)
        Text(text)
            .font(.system(size: 12, weight: .semibold, design: .monospaced))
            .foregroundStyle(activity.isComplete ? Color.logosLabel3 : Color.logosAmber)
            .lineLimit(1)
            .monospacedDigit()
            .accessibilityLabel(activity.isComplete ? "Completed in \(text)" : "Elapsed \(text)")
    }
}

private func elapsedTimeText(startedAt: TimeInterval, completedAt: TimeInterval?, now: Date) -> String {
    let end = completedAt ?? now.timeIntervalSince1970
    let elapsed = max(0, Int((end - startedAt).rounded(.down)))
    let hours = elapsed / 3600
    let minutes = (elapsed % 3600) / 60
    let seconds = elapsed % 60
    if hours > 0 {
        return "\(hours):\(String(format: "%02d", minutes)):\(String(format: "%02d", seconds))"
    }
    return "\(minutes):\(String(format: "%02d", seconds))"
}

struct ConnectionRetryCard: View {
    let state: ConnectionRetryState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 8) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.logosAmber)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Reconnecting")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.logosLabel)
                    Text("\(state.attemptCount) attempt\(state.attemptCount == 1 ? "" : "s")")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(Color.logosLabel3)
                }
                Spacer(minLength: 8)
                // Only the countdown needs the per-second clock; the rest of the card is static
                // until `state` changes, so scope the TimelineView to just this label rather than
                // rebuilding the whole card (icon + attempts + error + event list) every second.
                TimelineView(.periodic(from: Date(), by: 1)) { context in
                    Text(retryCountdownText(now: context.date))
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Color.logosAmber)
                        .monospacedDigit()
                }
            }

            Text(state.latestError)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.logosLabel2)
                .fixedSize(horizontal: false, vertical: true)

            ForEach(state.events.suffix(3)) { event in
                Text(event.text)
                    .font(.system(size: 11, weight: .regular, design: .monospaced))
                    .foregroundStyle(Color.logosLabel3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.logosBG2.opacity(0.78), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.logosAmber.opacity(0.24), lineWidth: 0.5))
        .accessibilityIdentifier("connectionRetryCard")
    }

    private func retryCountdownText(now: Date) -> String {
        guard let nextRetryAt = state.nextRetryAt else { return "Retrying now…" }
        let remaining = max(0, Int(ceil(nextRetryAt - now.timeIntervalSince1970)))
        return remaining > 0 ? "Retrying in \(remaining)s" : "Retrying now…"
    }
}

struct SpinningHourglassIcon: View {
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @State private var rotationDegrees = 0.0

    let isAnimating: Bool

    var body: some View {
        Image(systemName: "hourglass")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Color.logosAmber)
            .rotationEffect(.degrees(accessibilityReduceMotion || isAnimating == false ? 0 : rotationDegrees))
            .accessibilityHidden(true)
            .onAppear(perform: updateAnimation)
            .onChange(of: isAnimating) { _, _ in updateAnimation() }
            .onChange(of: accessibilityReduceMotion) { _, _ in updateAnimation() }
    }

    private func updateAnimation() {
        if isAnimating, accessibilityReduceMotion == false {
            rotationDegrees = 0
            withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: false)) {
                rotationDegrees = 360
            }
        } else {
            withAnimation(.easeOut(duration: 0.15)) {
                rotationDegrees = 0
            }
        }
    }
}

