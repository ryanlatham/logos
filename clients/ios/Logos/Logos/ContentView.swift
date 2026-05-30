import SwiftUI
import UIKit
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

struct ThreadAutoFollowPolicy {
    static let minimumDetachDistance: CGFloat = 160
    static let viewportDetachFraction: CGFloat = 0.25

    static func detachThreshold(visibleHeight: CGFloat) -> CGFloat {
        max(minimumDetachDistance, max(0, visibleHeight) * viewportDetachFraction)
    }

    static func isNearBottom(distanceFromBottom: CGFloat, visibleHeight: CGFloat) -> Bool {
        max(0, distanceFromBottom) <= detachThreshold(visibleHeight: visibleHeight)
    }

    static func shouldDetachForUserScroll(distanceFromBottom: CGFloat, visibleHeight: CGFloat) -> Bool {
        isNearBottom(distanceFromBottom: distanceFromBottom, visibleHeight: visibleHeight) == false
    }

    static func shouldDetachForProgrammaticScroll(distanceFromBottom _: CGFloat, visibleHeight _: CGFloat) -> Bool {
        false
    }

    static func shouldApplyFollow(force: Bool, shouldFollowThread: Bool, isThreadUserDetached: Bool) -> Bool {
        force || (shouldFollowThread && isThreadUserDetached == false)
    }
}

/// Counts thread messages that arrived after the user detached from the bottom, for the
/// jump-to-latest pill's unseen badge (WS1 P7). server_seq is monotonic from the adapter;
/// local/pending messages carry 0 and are naturally excluded once detached past real traffic.
struct ThreadUnseenPolicy {
    static func unseenCount(serverSeqs: [Int], since lastSeenSeq: Int) -> Int {
        serverSeqs.reduce(into: 0) { count, seq in
            if seq > lastSeenSeq { count += 1 }
        }
    }

    /// The pill's label: a count when known (>0), otherwise the generic prompt.
    static func label(unseenCount: Int) -> String {
        guard unseenCount > 0 else { return "New updates" }
        return unseenCount == 1 ? "1 new message" : "\(unseenCount) new messages"
    }
}

struct ThreadTimelineSnapshot: Equatable {
    struct Message: Equatable {
        let id: String
        let role: String
        let status: String
        let isFinal: Bool
        let isProgressUpdate: Bool
        let content: String

        init(
            id: String,
            status: String,
            isFinal: Bool,
            content: String,
            role: String = "assistant",
            isProgressUpdate: Bool = false
        ) {
            self.id = id
            self.role = role
            self.status = status
            self.isFinal = isFinal
            self.isProgressUpdate = isProgressUpdate
            self.content = content
        }
    }

    struct Progress: Equatable {
        let id: String
        let updateCount: Int
        let adapterUpdateCount: Int
        let isExpanded: Bool
        let isComplete: Bool
        let timedOut: Bool
        let finalStatus: String?
        let canRetry: Bool
        let completedFinalMessageID: String?
    }

    struct ConnectionRetry: Equatable {
        let id: String
        let attemptCount: Int
        let eventCount: Int
        let nextRetryAt: TimeInterval?
    }

    struct FocusRequest: Equatable {
        let id: String
        let targetMessageID: String
    }

    let activeProjectKey: String
    let messages: [Message]
    let progress: Progress?
    let connectionRetry: ConnectionRetry?
    let isRunControlVisible: Bool
    let approvalCardID: String?
    let clarifyCardID: String?
    let pendingInteractionResponseID: String?
    let ackText: String?
    let errorText: String?
    let voiceDraftText: String?
    let composerMode: String
    let composerBottomPadding: CGFloat
    let connectionState: String
    let runStatus: String
    let focusRequest: FocusRequest?
    let slashCommandMenuState: String
    let slashCommandCatalogFingerprint: String
    let slashCommandMenuHeight: CGFloat

    var messageFingerprint: String {
        [
            activeProjectKey,
            "\(messages.count)",
            messages.last?.id ?? "no-message",
            messages.last?.role ?? "no-role",
            messages.last?.status ?? "no-status",
            "\(messages.last?.isFinal ?? true)",
            "\(messages.last?.isProgressUpdate ?? false)"
        ].joined(separator: "|")
    }

    var contentFingerprint: String {
        let progressFingerprint: String
        if let progress {
            progressFingerprint = [
                progress.id,
                "\(progress.updateCount)",
                "\(progress.adapterUpdateCount)",
                "\(progress.isExpanded)",
                "\(progress.isComplete)",
                "\(progress.timedOut)",
                progress.finalStatus ?? "no-final-status",
                "\(progress.canRetry)",
                progress.completedFinalMessageID ?? "no-final"
            ].joined(separator: "\u{1f}")
        } else {
            progressFingerprint = "no-progress"
        }
        let connectionRetryFingerprint: String
        if let connectionRetry {
            let nextRetry = connectionRetry.nextRetryAt.map { "\($0)" } ?? "no-next-retry"
            connectionRetryFingerprint = [
                connectionRetry.id,
                "\(connectionRetry.attemptCount)",
                "\(connectionRetry.eventCount)",
                nextRetry
            ].joined(separator: "\u{1f}")
        } else {
            connectionRetryFingerprint = "no-connection-retry"
        }
        let parts = [
            activeProjectKey,
            "\(messages.count)",
            messages.map { "\($0.id)\u{1f}\($0.role)\u{1f}\($0.status)\u{1f}\($0.isFinal)\u{1f}\($0.isProgressUpdate)\u{1f}\($0.content)" }.joined(separator: "\u{1e}"),
            progressFingerprint,
            connectionRetryFingerprint,
            "\(isRunControlVisible)",
            approvalCardID ?? "no-approval",
            clarifyCardID ?? "no-clarify",
            pendingInteractionResponseID ?? "no-pending-interaction",
            ackText ?? "no-ack",
            errorText ?? "no-error",
            voiceDraftText ?? "no-voice-draft",
            composerMode,
            "\(composerBottomPadding)",
            connectionState,
            runStatus,
            focusRequest?.id ?? "no-focus",
            focusRequest?.targetMessageID ?? "no-focus-target"
        ]
        return parts.joined(separator: "|")
    }
}

struct ThreadProgressPlacement {
    static func insertionIndex(messages: [LogosMessage], completedFinalMessageID: String?) -> Int? {
        guard let completedFinalMessageID else { return nil }
        return messages.firstIndex { $0.id == completedFinalMessageID }
    }
}

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var client: LogosClient
    @EnvironmentObject private var notifications: NotificationCoordinator

    @State private var draft = ""
    @State private var clarifyAnswer = ""
    @State private var threadBubbleWidthBasis: CGFloat = 0
    @StateObject private var voiceInput = VoiceInputController()
    @StateObject private var appCoordinator = AppCoordinator()
    @AppStorage("logos.slashCommandRecents") private var slashCommandRecentsStorage = ""

    @State private var composerMode: ComposerMode = .paused
    @State private var showProjectSwitcher = false
    @State private var showAttachSheet = false
    @State private var showSettings = false
    @State private var switcherSearch = ""
    @State private var isCreatingProject = false
    @State private var newProjectTitle = ""
    @State private var createSource: ProjectCreateSource = .blank
    @State private var justCreatedProject = false

    @State private var editingAdapterURL = false
    @State private var adapterURLDraft = ""
    @State private var editingDeviceKey = false
    @State private var deviceKeyDraft = ""
    @State private var generatedDeviceKey: String?
    @State private var copiedDeviceKey = false
    @State private var expandedSettingsPicker: SettingsPickerKind?
    @State private var hermesProfile = "default"
    @State private var defaultInput = "tap"
    @State private var speakMode = "summary"
    @State private var onDeviceSpeech = true
    @State private var pushEnabled = false
    @State private var notifyDone = true
    @State private var notifyApproval = true
    @State private var notifySummary = false
    @State private var pendingPairingRoute: LogosPairingRoute?
    @State private var threadScrollPosition = ScrollPosition(edge: .bottom)
    @State private var shouldFollowThread = true
    @State private var isThreadNearBottom = true
    @State private var hasUnseenThreadUpdates = false
    @State private var detachedThreadMaxServerSeq: Int?
    @State private var threadScrollPhase: ScrollPhase = .idle
    @State private var isThreadUserDetached = false
    @State private var userInitiatedThreadScrollObserved = false
    @State private var detachedThreadContentFingerprint: String?
    @State private var lastFollowedThreadContentFingerprint = ""
    @State private var lastForceFollowedThreadContentFingerprint: String?
    @State private var lastHandledThreadFocusRequestID: String?
    @State private var slashCommandDismissedDraft: String?
    @State private var suppressNextThreadContentChangeForFocusClear = false
    @State private var hasInitializedThreadScroll = false
    @State private var threadScrollProximityScheduler = ThreadScrollProximityScheduler()
    @State private var threadFollowTask: Task<Void, Never>?
    @State private var threadFollowEpoch = 0

    @ScaledMetric(relativeTo: .body) private var composerPillHeight: CGFloat = 44
    @ScaledMetric(relativeTo: .body) private var composerIconSize: CGFloat = 22
    @ScaledMetric(relativeTo: .body) private var composerInputFontSize: CGFloat = 16
    @ScaledMetric(relativeTo: .body) private var composerLabelFontSize: CGFloat = 15
    @ScaledMetric(relativeTo: .body) private var sendTapSize: CGFloat = 44
    @ScaledMetric(relativeTo: .body) private var sendVisualSize: CGFloat = 32
    @ScaledMetric(relativeTo: .body) private var sendIconSize: CGFloat = 16
    @ScaledMetric(relativeTo: .body) private var recordDotSize: CGFloat = 10
    @ScaledMetric(relativeTo: .body) private var recordDotHaloSize: CGFloat = 16
    private let composerBottomSpacing: CGFloat = 8
    private var composerTopSpacing: CGFloat { isSlashCommandMenuVisible ? 14 : 8 }

    @FocusState private var focusedField: FocusedField?

    var body: some View {
        ZStack(alignment: .top) {
            Color.logosBG.ignoresSafeArea()

            VStack(spacing: 0) {
                navBar
                thread
            }
            .safeAreaInset(edge: .bottom) {
                composerBar
            }

            if let overlay = client.audioPlaybackOverlay {
                AudioPlaybackOverlayView(
                    overlay: overlay,
                    onPauseResume: {
                        if overlay.phase == .paused {
                            client.resumePlayback()
                        } else {
                            client.pausePlayback()
                        }
                    },
                    onStop: { client.stopPlayback() }
                )
                .padding(.horizontal, 14)
                .padding(.top, 66)
                .transition(.move(edge: .top).combined(with: .opacity))
                .zIndex(6)
            }

            if showProjectSwitcher {
                projectSwitcherLayer
                    .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
                    .zIndex(10)
            }

            if showAttachSheet {
                attachSheetLayer
                    .transition(.opacity)
                    .zIndex(20)
            }

            if showSettings {
                settingsOverlay
                    .transition(.move(edge: .trailing))
                    .zIndex(30)
            }
        }
        .preferredColorScheme(.dark)
        .tint(.logosAmber)
        .animation(.easeOut(duration: 0.22), value: showProjectSwitcher)
        .animation(.easeOut(duration: 0.22), value: showAttachSheet)
        .animation(.timingCurve(0.2, 0.85, 0.25, 1, duration: 0.28), value: showSettings)
        .onAppear(perform: configureRuntime)
        .onChange(of: scenePhase) { _, newPhase in
            handleScenePhaseChange(newPhase)
        }
        .onChange(of: client.connectionState) { _, newState in
            handleConnectionStateChange(newState)
        }
        .onChange(of: draft) { _, newValue in
            handleDraftChangedForSlashCommands(newValue)
        }
        .onChange(of: client.undeliveredSpeechDraft?.id) { _, _ in
            restoreUndeliveredSpeechDraft()
        }
        .onChange(of: voiceInput.mode) { _, newMode in
            if newMode == .idle { syncComposerWithVoiceState() }
        }
        .onChange(of: voiceInput.pendingMode) { _, _ in
            syncComposerWithVoiceState()
        }
        .onChange(of: voiceInput.isFinalizingTranscript) { _, _ in
            syncComposerWithVoiceState()
        }
        .onChange(of: voiceInput.isRecording) { _, isRecording in
            if isRecording {
                LogosHaptics.recordStart()
            } else {
                LogosHaptics.recordStop()
            }
        }
        .onOpenURL { url in
            if let route = appCoordinator.handleURL(url) {
                pendingPairingRoute = route
            }
        }
        .alert(
            "Pair Logos?",
            isPresented: Binding(
                get: { pendingPairingRoute != nil },
                set: { isPresented in
                    if isPresented == false { pendingPairingRoute = nil }
                }
            ),
            presenting: pendingPairingRoute
        ) { route in
            Button("Pair") {
                pendingPairingRoute = nil
                Task { await client.applyPairingRoute(route) }
            }
            Button("Cancel", role: .cancel) {
                pendingPairingRoute = nil
            }
        } message: { route in
            Text("Pair this iPhone with \(route.adapterHostDescription) as \(route.deviceID)?")
        }
    }

    private var navBar: some View {
        ZStack(alignment: .center) {
            VStack(alignment: .center, spacing: 6) {
                Button {
                    withAnimation(.timingCurve(0.2, 0.85, 0.25, 1, duration: 0.28)) {
                        closeTransientOverlays(exceptProjectSwitcher: true)
                        showProjectSwitcher.toggle()
                    }
                } label: {
                    HStack(spacing: 6) {
                        Text(activeProjectTitle)
                            .lineLimit(1)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 13, weight: .semibold))
                            .rotationEffect(.degrees(showProjectSwitcher ? 180 : 0))
                    }
                    .font(.system(size: 15, weight: .semibold))
                    .tracking(-0.2)
                    .foregroundStyle(Color.logosLabel)
                    .padding(.leading, 14)
                    .padding(.trailing, 12)
                    .padding(.vertical, 6)
                    .background(Color(red: 120 / 255, green: 120 / 255, blue: 128 / 255, opacity: 0.18), in: Capsule())
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity)
                .accessibilityIdentifier("projectPicker")

                HStack(spacing: 6) {
                    Circle()
                        .fill(statusChipColor)
                        .frame(width: 6, height: 6)
                    Text(statusChipText)
                        .font(.system(size: 11, weight: .semibold))
                        .textCase(.uppercase)
                        .foregroundStyle(statusChipColor)
                        .lineLimit(1)
                        .accessibilityIdentifier("connectionStatusLabel")
                        .accessibilityLabel(connectionTitle)
                        .accessibilityValue(statusChipText)
                }
                .frame(maxWidth: .infinity, alignment: .center)
            }
            .padding(.horizontal, 62)
            .frame(maxWidth: .infinity, alignment: .center)

            HStack {
                Spacer(minLength: 0)

                Button {
                    closeTransientOverlays()
                    adapterURLDraft = client.settings.urlString
                    withAnimation(.timingCurve(0.2, 0.85, 0.25, 1, duration: 0.28)) {
                        showSettings = true
                    }
                } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(Color.logosLabel)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Settings")
            }
        }
        .frame(height: 56)
        .padding(.horizontal, 14)
        .background(Color.logosGlass)
        .background(.ultraThinMaterial)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.logosHairline)
                .frame(height: 0.5)
        }
    }

    private var thread: some View {
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
                            onStop: { client.cancelRun() },
                            onRetry: { _ = client.retryProgressActivity() }
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
                .padding(.horizontal, 14)
                .padding(.top, 14)
                .padding(.bottom, composerMode == .text ? 16 : 28)
                .animation(.timingCurve(0.2, 0.7, 0.2, 1, duration: 0.26), value: composerMode)
            }
            .scrollPosition($threadScrollPosition)
            .defaultScrollAnchor(.bottom, for: .alignment)
            .scrollDismissesKeyboard(.interactively)
            .accessibilityIdentifier("conversationThreadScrollView")
            .simultaneousGesture(
                DragGesture(minimumDistance: 4)
                    .onChanged { _ in
                        userInitiatedThreadScrollObserved = true
                        if isThreadNearBottom == false {
                            detachThreadFromAutoFollow()
                        }
                    }
            )
            .onScrollGeometryChange(for: Bool.self) { geometry in
                ThreadAutoFollowPolicy.isNearBottom(
                    distanceFromBottom: geometry.contentSize.height - geometry.visibleRect.maxY,
                    visibleHeight: geometry.visibleRect.height
                )
            } action: { _, newValue in
                handleThreadBottomProximityChangedAfterLayout(newValue)
            }
            .onScrollPhaseChange { _, newPhase in
                threadScrollPhase = newPhase
                handleThreadScrollPhaseChanged(newPhase)
            }
            .onChange(of: threadScrollPosition) { _, newValue in
                handleThreadScrollPositionChanged(newValue)
            }
            .onAppear {
                initializeThreadScrollIfNeeded()
            }
            .onDisappear {
                threadScrollProximityScheduler.cancel()
                cancelPendingThreadFollow()
            }
            .onChange(of: client.activeProjectKey) { _, _ in
                resetThreadScrollForProjectChange()
            }
            .onChange(of: threadTimelineSnapshot) { oldValue, newValue in
                handleThreadTimelineSnapshotChanged(from: oldValue, to: newValue)
            }

            if shouldShowThreadNewUpdatesButton {
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
        handleThreadContentChanged()
    }

    private var threadMessagesBeforeProgress: [LogosMessage] {
        guard let progressInsertionIndex else { return client.messages }
        return Array(client.messages[..<progressInsertionIndex])
    }

    private var threadMessagesAfterProgress: [LogosMessage] {
        guard let progressInsertionIndex else { return [] }
        return Array(client.messages[progressInsertionIndex...])
    }

    private var shouldShowThreadNewUpdatesButton: Bool {
        guard isThreadNearBottom == false else { return false }
        guard isThreadUserDetached || shouldFollowThread == false || isThreadNearBottom == false || threadScrollPosition.isPositionedByUser else {
            return false
        }
        if hasUnseenThreadUpdates { return true }
        if let detachedThreadContentFingerprint {
            return detachedThreadContentFingerprint != threadContentFingerprint
        }
        if lastFollowedThreadContentFingerprint.isEmpty == false {
            return lastFollowedThreadContentFingerprint != threadContentFingerprint
        }
        if let lastForceFollowedThreadContentFingerprint {
            return lastForceFollowedThreadContentFingerprint != threadMessageFingerprint
        }
        return false
    }

    private var threadMessageFingerprint: String {
        threadTimelineSnapshot.messageFingerprint
    }

    private var threadContentFingerprint: String {
        threadTimelineSnapshot.contentFingerprint
    }

    private var voiceDraftText: String? {
        guard voiceInput.isRecording || voiceInput.isFinalizingTranscript else { return nil }
        return voiceInput.partialTranscript.isEmpty ? "Listening…" : voiceInput.partialTranscript
    }

    private var slashCommandDraftToken: String {
        guard draft.hasPrefix("/") else { return "" }
        return String(draft.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false).first ?? "")
    }

    private var slashCommandRecents: [String] {
        slashCommandRecentsStorage
            .split(separator: "\n")
            .map(String.init)
            .filter { $0.hasPrefix("/") }
    }

    private var slashCommandMatches: [SlashCommandSpec] {
        client.slashCommandCatalog.rankedCommands(for: slashCommandDraftToken.isEmpty ? draft : slashCommandDraftToken, recents: slashCommandRecents)
    }

    private var slashCompletionItems: [SlashCommandCompletionItem] {
        guard draft.contains(" ") else { return [] }
        guard client.slashCommandCompletion.catalogVersion == client.slashCommandCatalog.catalogVersion else { return [] }
        return client.slashCommandCompletion.items
    }

    private var selectedSlashCommand: SlashCommandSpec? {
        guard slashCommandDraftToken.isEmpty == false else { return nil }
        return client.slashCommandCatalog.command(canonical: slashCommandDraftToken)
            ?? slashCommandMatches.first
    }

    private var slashCommandMenuState: SlashCommandMenuState {
        guard draft.hasPrefix("/"), composerMode == .text else { return .inactive }
        if slashCommandDismissedDraft == draft { return .dismissed }
        if client.slashCommandCatalog.commands.isEmpty { return .loadingCatalog }
        if let selectedSlashCommand, slashCommandDraftToken == selectedSlashCommand.canonical {
            return selectedSlashCommand.argsHint.isEmpty ? .browsing : .argumentHelp
        }
        if slashCommandMatches.isEmpty { return .emptyResults }
        if client.slashCommandCatalog.fallbackUsed { return .errorFallback }
        return .browsing
    }

    private var isSlashCommandMenuVisible: Bool {
        switch slashCommandMenuState {
        case .inactive, .dismissed:
            return false
        case .loadingCatalog, .browsing, .argumentHelp, .emptyResults, .errorFallback:
            return true
        }
    }

    private var slashCommandMenuHeight: CGFloat {
        isSlashCommandMenuVisible ? 236 : 0
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
            slashCommandMenuState: slashCommandMenuState.rawValue,
            slashCommandCatalogFingerprint: client.slashCommandCatalog.catalogVersion,
            slashCommandMenuHeight: slashCommandMenuHeight
        )
    }

    private var threadNewUpdatesButton: some View {
        Button {
            scrollThreadToBottom(animated: true)
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
                onApprove: {
                    client.approveCurrentRequest()
                    handleThreadContentChanged(forceFollow: true)
                },
                onDeny: {
                    client.denyCurrentRequest()
                    handleThreadContentChanged(forceFollow: true)
                }
            )
            .id(approval.id)
        }

        if let clarify = client.clarifyCard {
            ClarifyCardView(
                clarify: clarify,
                answer: $clarifyAnswer,
                isPending: client.pendingInteractionResponseID == clarify.id,
                isConnected: client.connectionState == .connected && client.runStatus != .cancelling,
                focused: $focusedField,
                onChoice: {
                    if client.answerClarification($0) {
                        handleThreadContentChanged(forceFollow: true)
                    }
                },
                onFreeText: submitClarificationAnswer
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
                            client.playback(message: message)
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
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { width in
            threadBubbleWidthBasis = width
        }
    }

    private var composerBar: some View {
        VStack(alignment: .leading, spacing: isSlashCommandMenuVisible ? 8 : 0) {
            if isSlashCommandMenuVisible {
                slashCommandMenu
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            composerPillSurface
        }
        .padding(.horizontal, 12)
        .padding(.top, composerTopSpacing)
        .padding(.bottom, composerBottomSpacing)
        .animation(.snappy(duration: 0.2), value: isSlashCommandMenuVisible)
    }

    @ViewBuilder
    private var composerPillSurface: some View {
        GlassEffectContainer(spacing: 8) {
            composerPillRow
        }
    }

    private var composerPillRow: some View {
        HStack(spacing: 8) {
            Button {
                closeTransientOverlays(exceptAttachSheet: true)
                withAnimation(.smooth(duration: 0.2)) {
                    showAttachSheet.toggle()
                }
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: composerIconSize, weight: .semibold))
                    .foregroundStyle(Color.logosLabel)
                    .frame(width: composerPillHeight, height: composerPillHeight)
                    .liquidGlassPill(isInteractive: true)
            }
            .buttonStyle(LiquidGlassScaleButtonStyle())
            .accessibilityIdentifier("attachButton")
            .accessibilityLabel("Attach")
            .accessibilityHint("Opens attachment options")

            composerCenterPill
                .frame(maxWidth: .infinity)

            Button {
                handleComposerRightPillButton()
            } label: {
                Image(systemName: composerRightPillSystemImage)
                    .font(.system(size: composerIconSize, weight: .semibold))
                    .foregroundStyle(composerMode == .text ? Color.logosAmberBright : Color.logosLabel)
                    .frame(width: composerPillHeight, height: composerPillHeight)
                    .liquidGlassPill(
                        tint: composerMode == .text ? Color.logosAmber.opacity(0.25) : Color.white.opacity(0.07),
                        isInteractive: true
                    )
            }
            .buttonStyle(LiquidGlassScaleButtonStyle())
            .accessibilityIdentifier(composerRightPillAccessibilityID)
            .accessibilityLabel(composerRightPillAccessibilityLabel)
            .accessibilityHint(composerRightPillAccessibilityHint)
            .disabled(composerRightPillDisabled)
            .opacity(composerRightPillDisabled ? 0.45 : 1)
        }
        .animation(.smooth(duration: 0.2), value: composerMode)
        .animation(.snappy(duration: 0.22), value: hasComposerDraft)
        .animation(.smooth(duration: 0.2), value: voiceInput.isFinalizingTranscript)
    }

    @ViewBuilder
    private var composerCenterPill: some View {
        switch composerMode {
        case .text:
            composerInputPill
        case .paused:
            recordPill(isRecording: false)
        case .recording:
            recordPill(isRecording: true)
        }
    }

    private var composerInputPill: some View {
        HStack(spacing: 8) {
            TextField("Message Hermes", text: $draft, axis: .vertical)
                .accessibilityIdentifier("composerTextField")
                .focused($focusedField, equals: .composer)
                .font(.system(size: composerInputFontSize, weight: .regular))
                .foregroundStyle(Color.logosLabel)
                .lineLimit(1...4)
                .submitLabel(.send)
                .textInputAutocapitalization(.sentences)
                .onSubmit { submitDraft() }
                .accessibilityLabel("Message Hermes")

            if hasComposerDraft {
                Button {
                    submitDraft()
                } label: {
                    ZStack {
                        Circle()
                            .fill(Color.logosAmber)
                            .frame(width: sendVisualSize, height: sendVisualSize)
                            .shadow(color: Color.logosAmberGlow.opacity(0.4), radius: 10, x: 0, y: 4)
                        Image(systemName: "arrow.up")
                            .font(.system(size: sendIconSize, weight: .bold))
                            .foregroundStyle(Color.logosAmberOn)
                    }
                    .frame(width: sendTapSize, height: sendTapSize)
                }
                .buttonStyle(LiquidGlassScaleButtonStyle())
                .accessibilityIdentifier("sendButton")
                .accessibilityLabel("Send message")
                .accessibilityHint("Sends the current draft to Hermes")
                .transition(.scale(scale: 0.72).combined(with: .opacity))
            }
        }
        .padding(.leading, 16)
        .padding(.trailing, hasComposerDraft ? 0 : 16)
        .frame(minHeight: composerPillHeight)
        .liquidGlassPill(isFocused: focusedField == .composer, isInteractive: true)
        .contentShape(Capsule())
        .onTapGesture {
            focusedField = .composer
        }
    }

    private var slashCommandMenu: some View {
        VStack(alignment: .leading, spacing: 8) {
            slashCommandMenuHeader
            ScrollView(.vertical, showsIndicators: true) {
                LazyVStack(spacing: 4) {
                    switch slashCommandMenuState {
                    case .loadingCatalog:
                        slashCommandStatusRow(icon: "clock", title: "Loading commands", detail: "Using local fallback until Hermes responds")
                    case .emptyResults:
                        slashCommandStatusRow(icon: "magnifyingglass", title: "No matches", detail: "Send anyway to let Hermes handle this slash command")
                    case .argumentHelp:
                        if let selectedSlashCommand {
                            SlashCommandRow(command: selectedSlashCommand, isSelected: true) {
                                applySlashCommand(selectedSlashCommand)
                            }
                        }
                    case .errorFallback:
                        slashCommandStatusRow(icon: "wifi.exclamationmark", title: "Fallback commands", detail: "Hermes catalog is unavailable; slash text still sends normally")
                        slashCommandRows
                    case .browsing:
                        if slashCompletionItems.isEmpty {
                            slashCommandRows
                        } else {
                            slashCompletionRows
                        }
                    case .inactive, .dismissed:
                        EmptyView()
                    }
                }
                .padding(.vertical, 2)
            }
            .frame(maxHeight: 168)
            .scrollBounceBehavior(.basedOnSize)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.logosGlass)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.logosHairline, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.34), radius: 18, x: 0, y: 10)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("slashCommandMenu")
    }

    private var slashCommandMenuHeader: some View {
        HStack(spacing: 8) {
            Image(systemName: "terminal")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Color.logosAmber)
            Text("Commands")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.logosLabel2)
            Spacer()
            if client.slashCommandCatalog.fallbackUsed {
                Text("Fallback")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.logosLabel3)
            }
        }
        .padding(.horizontal, 4)
        .accessibilityElement(children: .combine)
    }

    private var slashCommandRows: some View {
        ForEach(Array(slashCommandMatches.prefix(8))) { command in
            SlashCommandRow(command: command, isSelected: command.canonical == selectedSlashCommand?.canonical) {
                applySlashCommand(command)
            }
            .disabled(command.available == false)
        }
    }

    private var slashCompletionRows: some View {
        ForEach(Array(slashCompletionItems.prefix(8))) { item in
            SlashCommandCompletionRow(item: item) {
                applySlashCompletion(item)
            }
        }
    }

    private func slashCommandStatusRow(icon: String, title: String, detail: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.logosLabel3)
                .frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.logosLabel)
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.logosLabel3)
                    .lineLimit(2)
            }
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(Color.logosBG2.opacity(0.68), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private func recordPill(isRecording: Bool) -> some View {
        let isFinishing = voiceInput.isFinalizingTranscript && isRecording == false
        return Button {
            handleRecordPillTapped()
        } label: {
            HStack(spacing: isRecording ? 9 : 8) {
                if isRecording {
                    Image(systemName: "stop.fill")
                        .font(.system(size: composerLabelFontSize, weight: .bold))
                        .frame(width: composerLabelFontSize, height: composerLabelFontSize)
                    Text("Stop")
                        .font(.system(size: composerLabelFontSize, weight: .semibold))
                        .tracking(0.2)
                        .lineLimit(1)
                        .minimumScaleFactor(0.78)
                } else if isFinishing {
                    Image(systemName: "hourglass")
                        .font(.system(size: composerLabelFontSize, weight: .semibold))
                    Text("Finishing…")
                        .font(.system(size: composerLabelFontSize, weight: .medium))
                        .tracking(-0.2)
                        .lineLimit(1)
                        .minimumScaleFactor(0.78)
                } else {
                    Image(systemName: "circle.fill")
                        .font(.system(size: recordDotSize, weight: .bold))
                        .foregroundStyle(Color.logosRed)
                        .frame(width: recordDotHaloSize, height: recordDotHaloSize)
                        .background(Color.logosRed.opacity(0.22), in: Circle())
                    Text("Tap to record")
                        .font(.system(size: composerLabelFontSize, weight: .medium))
                        .tracking(-0.2)
                        .lineLimit(1)
                        .minimumScaleFactor(0.78)
                }
            }
            .foregroundStyle(isRecording ? Color.white : isFinishing ? Color.logosLabel2 : Color.logosLabel)
            .frame(maxWidth: .infinity)
            .frame(minHeight: composerPillHeight)
            .liquidGlassPill(
                tint: isRecording ? Color.logosRed : Color.white.opacity(0.07),
                isRecording: isRecording,
                isInteractive: !isFinishing
            )
        }
        .buttonStyle(LiquidGlassScaleButtonStyle())
        .accessibilityIdentifier(isRecording ? "stopTapToTalkButton" : "recordButton")
        .accessibilityLabel(recordPillAccessibilityLabel(isRecording: isRecording))
        .accessibilityValue(recordPillAccessibilityValue(isRecording: isRecording))
        .accessibilityHint(recordPillAccessibilityHint(isRecording: isRecording))
        .disabled(recordPillDisabled(isRecording: isRecording))
        .opacity(recordPillDisabled(isRecording: isRecording) ? 0.55 : 1)
    }

    private var projectSwitcherLayer: some View {
        GeometryReader { proxy in
            ZStack(alignment: .top) {
                Color.black.opacity(0.36)
                    .ignoresSafeArea()
                    .onTapGesture {
                        closeProjectSwitcher()
                    }

                switcherDropdown(screenHeight: proxy.size.height)
                    .padding(.top, 66)
                    .padding(.horizontal, 12)
            }
        }
    }

    private func switcherDropdown(screenHeight: CGFloat) -> some View {
        let dropdownMaxHeight = ProjectSwitcherLayout.dropdownMaxHeight(for: screenHeight)
        let projectListMaxHeight = ProjectSwitcherLayout.projectListMaxHeight(
            for: screenHeight,
            projectCount: displayedProjects.count,
            isCreatingProject: isCreatingProject
        )

        return VStack(alignment: .leading, spacing: 12) {
            if isCreatingProject == false {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.logosLabel3)
                    TextField("Search projects", text: $switcherSearch)
                        .focused($focusedField, equals: .switcherSearch)
                        .font(.system(size: 15))
                        .foregroundStyle(Color.logosLabel)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Text("⌘K")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Color.logosLabel3)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 4)
                        .background(Color.logosBG3, in: RoundedRectangle(cornerRadius: 7))
                }
                .padding(12)
                .background(Color.logosBG2.opacity(0.78), in: RoundedRectangle(cornerRadius: 14))
            }

            ScrollView(.vertical, showsIndicators: true) {
                LazyVStack(spacing: ProjectSwitcherLayout.projectRowSpacing) {
                    ForEach(displayedProjects) { project in
                        Button {
                            client.switchProject(project.projectKey)
                            closeProjectSwitcher()
                        } label: {
                            ProjectRowView(
                                project: project,
                                isSelected: project.projectKey == client.activeProjectKey
                            )
                        }
                        .buttonStyle(.plain)
                        .disabled(client.connectionState != .connected && project.projectKey != client.activeProjectKey)
                    }
                }
                .padding(.vertical, 1)
            }
            .frame(maxHeight: projectListMaxHeight, alignment: .top)
            .scrollBounceBehavior(.basedOnSize)
            .accessibilityIdentifier("projectSwitcherList")

            Divider().overlay(Color.logosHairline)

            if isCreatingProject {
                createProjectCard
            } else {
                Button {
                    withAnimation(.easeOut(duration: 0.18)) {
                        isCreatingProject = true
                        switcherSearch = ""
                    }
                    focusedField = .newProjectTitle
                } label: {
                    Label("New project", systemImage: "plus")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.logosAmber)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: dropdownMaxHeight, alignment: .top)
        .background(Color.logosGlass)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22).stroke(Color.logosHairline, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.42), radius: 24, x: 0, y: 14)
    }

    private var createProjectCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("Project title", text: $newProjectTitle)
                .accessibilityIdentifier("newProjectTitleField")
                .focused($focusedField, equals: .newProjectTitle)
                .font(.system(size: 15, weight: .medium, design: .monospaced))
                .foregroundStyle(Color.logosLabel)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .textContentType(.none)
                .submitLabel(.done)
                .onSubmit { createProjectFromTitleField() }
                .padding(.horizontal, 12)
                .frame(height: 42)
                .background(Color.black.opacity(0.34), in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.logosAmber, lineWidth: 1))

            VStack(alignment: .leading, spacing: 8) {
                Text("Start from")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.logosLabel3)
                    .textCase(.uppercase)
                HStack(spacing: 6) {
                    ForEach(ProjectCreateSource.allCases) { source in
                        Button {
                            createSource = source
                        } label: {
                            Text(source.title)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(createSource == source ? Color.logosAmberOn : Color.logosLabel2)
                                .padding(.horizontal, 9)
                                .padding(.vertical, 7)
                                .background(createSource == source ? Color.logosAmber : Color.logosBG2.opacity(0.8), in: Capsule())
                                .overlay(Capsule().stroke(createSource == source ? Color.clear : Color.logosHairline, lineWidth: 0.5))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            HStack(spacing: 10) {
                Button("Cancel") {
                    withAnimation(.easeOut(duration: 0.18)) {
                        isCreatingProject = false
                        newProjectTitle = ""
                    }
                }
                .buttonStyle(SecondaryPillButtonStyle())

                Button("Create & open") {
                    createProjectFromTitleField()
                }
                .buttonStyle(AmberPillButtonStyle())
                .accessibilityIdentifier("createProjectButton")
                .disabled(client.connectionState != .connected || newProjectTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(12)
        .background(Color.logosBG1.opacity(0.86), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.logosHairline, lineWidth: 0.5))
    }

    private var attachSheetLayer: some View {
        ZStack(alignment: .bottom) {
            Color.black.opacity(0.30)
                .ignoresSafeArea()
                .onTapGesture { showAttachSheet = false }

            VStack(alignment: .leading, spacing: 16) {
                SectionHead(title: "Attach to message")
                VStack(spacing: 0) {
                    AttachRow(icon: "photo.on.rectangle", title: "Photo Library", detail: "Stubbed until attachments ship")
                    AttachRow(icon: "camera", title: "Take Photo", detail: "Stubbed until camera capture ships")
                    AttachRow(icon: "doc", title: "Files", detail: "Stubbed until file upload ships")
                    Button {
                        showAttachSheet = false
                        composerMode = .text
                        draft = "/"
                        slashCommandDismissedDraft = nil
                        focusedField = .composer
                    } label: {
                        AttachRow(icon: "terminal", title: "Commands", detail: "Browse Hermes slash commands")
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("commandsAttachRow")
                    AttachRow(icon: "curlybraces", title: "Paste code", detail: "Stubbed until rich snippets ship", isLast: true)
                }
                .background(Color.logosBG2, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.logosHairline, lineWidth: 0.5))
            }
            .padding(14)
            .background(Color.logosGlass)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 22).stroke(Color.logosHairline, lineWidth: 0.5))
            .padding(.horizontal, 12)
            .padding(.bottom, 106)
            .shadow(color: .black.opacity(0.45), radius: 24, x: 0, y: 12)
        }
    }

    private var settingsOverlay: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button {
                    closeSettings()
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 17, weight: .semibold))
                        Text("Logos")
                            .font(.system(size: 17, weight: .medium))
                    }
                    .foregroundStyle(Color.logosAmber)
                }
                .buttonStyle(.plain)

                Spacer()

                Text("Settings")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Color.logosLabel)

                Spacer()
                Color.clear.frame(width: 72, height: 1)
            }
            .frame(height: 56)
            .padding(.horizontal, 14)
            .background(Color.logosGlass)
            .background(.ultraThinMaterial)
            .overlay(alignment: .bottom) {
                Rectangle().fill(Color.logosHairline).frame(height: 0.5)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    hermesAdapterSection
                    voiceSettingsSection
                    notificationSettingsSection
                    diagnosticsSettingsSection
                    settingsFooter
                }
                .padding(.horizontal, 14)
                .padding(.top, 22)
                .padding(.bottom, 44)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.logosBG.ignoresSafeArea())
        .onAppear {
            adapterURLDraft = client.settings.urlString
            pushEnabled = notifications.authorizationStatus.contains("allowed")
            onDeviceSpeech = voiceInput.voiceEnabled
        }
    }

    private var hermesAdapterSection: some View {
        SettingsSection(title: "Hermes Adapter") {
            VStack(spacing: 0) {
                SettingRowChrome(isLast: false) {
                    HStack(spacing: 12) {
                        BreathingDot(color: connectionColor, isActive: client.connectionState == .connecting)
                            .frame(width: 8, height: 8)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(connectionTitle)
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(Color.logosLabel)
                                .accessibilityIdentifier("connectionStatusText")
                            Text(connectionDetail)
                                .font(.system(size: 13))
                                .foregroundStyle(Color.logosLabel3)
                        }
                        Spacer()
                        if client.connectionState == .connected {
                            Button(connectionActionTitle) { client.disconnect() }
                                .buttonStyle(RedChipButtonStyle())
                        } else {
                            Button(connectionActionTitle) { client.connect() }
                                .buttonStyle(AmberChipButtonStyle())
                                .disabled(client.connectionState == .connecting)
                        }
                    }
                }

                adapterURLRow
                autoConnectRow
                deviceKeyRow

                ExpandableSelectRow(
                    kind: .hermesProfile,
                    title: "Hermes profile",
                    detail: selectedLabel(for: hermesProfile, in: hermesProfileOptions),
                    selectedValue: $hermesProfile,
                    expanded: $expandedSettingsPicker,
                    options: hermesProfileOptions,
                    monoLabels: true,
                    isLast: true
                )
            }
            .settingsGroup()
        }
    }

    private var autoConnectRow: some View {
        SettingRowChrome(isLast: false) {
            HStack(spacing: 12) {
                Image(systemName: "bolt.horizontal.circle")
                    .settingsIcon()
                VStack(alignment: .leading, spacing: 2) {
                    Text("Auto connect")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.logosLabel)
                    Text(autoConnectDetail)
                        .font(.system(size: 13))
                        .foregroundStyle(Color.logosLabel3)
                        .lineLimit(2)
                }
                Spacer()
                LogosToggle(
                    isOn: Binding(
                        get: { client.settings.autoConnect },
                        set: { newValue in
                            client.settings.autoConnect = newValue
                            if newValue {
                                client.connectIfAutoConnectEnabled()
                            }
                        }
                    ),
                    label: "Auto connect"
                )
                .accessibilityIdentifier("autoConnectToggle")
            }
        }
    }

    private var adapterURLRow: some View {
        SettingRowChrome(isLast: false) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    Image(systemName: "link")
                        .settingsIcon()
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Adapter")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Color.logosLabel)
                        Text(client.settings.urlString)
                            .font(.system(size: 12.5, weight: .regular, design: .monospaced))
                            .foregroundStyle(Color.logosLabel3)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer()
                    Button(editingAdapterURL ? "Cancel" : "Edit") {
                        if editingAdapterURL {
                            editingAdapterURL = false
                            adapterURLDraft = client.settings.urlString
                            focusedField = nil
                        } else {
                            adapterURLDraft = client.settings.urlString
                            editingAdapterURL = true
                            focusedField = .adapterURL
                        }
                    }
                    .buttonStyle(NeutralChipButtonStyle())
                }

                if editingAdapterURL {
                    HStack(spacing: 8) {
                        TextField(LogosSettings.defaultURLString, text: $adapterURLDraft)
                            .accessibilityIdentifier("adapterURLField")
                            .focused($focusedField, equals: .adapterURL)
                            .font(.system(size: 12.5, weight: .regular, design: .monospaced))
                            .foregroundStyle(Color.logosLabel)
                            .keyboardType(.URL)
                            .textContentType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .submitLabel(.done)
                            .onSubmit { saveAdapterURL() }
                            .padding(.horizontal, 10)
                            .frame(height: 38)
                            .background(Color.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
                            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.logosAmber, lineWidth: 1))
                        Button("Save") { saveAdapterURL() }
                            .buttonStyle(AmberChipButtonStyle())
                    }
                }
            }
        }
    }

    private var deviceKeyRow: some View {
        SettingRowChrome(isLast: false) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    Image(systemName: "lock.shield")
                        .settingsIcon()
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Device key")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Color.logosLabel)
                        Text(maskedDeviceKey)
                            .font(.system(size: 12.5, weight: .regular, design: .monospaced))
                            .foregroundStyle(Color.logosLabel3)
                            .lineLimit(1)
                    }
                    Spacer()
                    Button(editingDeviceKey ? "Cancel" : "Edit") {
                        if editingDeviceKey {
                            editingDeviceKey = false
                            deviceKeyDraft = ""
                            focusedField = nil
                        } else {
                            deviceKeyDraft = client.settings.secret
                            generatedDeviceKey = nil
                            copiedDeviceKey = false
                            editingDeviceKey = true
                            focusedField = .deviceKey
                        }
                    }
                    .buttonStyle(NeutralChipButtonStyle())
                    Button {
                        generateDeviceKey()
                    } label: {
                        Label("Generate", systemImage: "plus")
                    }
                    .buttonStyle(AmberChipButtonStyle())
                }

                if editingDeviceKey {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Paste the same shared secret configured on the Logos adapter. It is stored in Keychain and only the suffix is shown after saving.")
                            .font(.system(size: 13))
                            .foregroundStyle(Color.logosLabel3)
                        HStack(spacing: 8) {
                            SecureField("Shared secret", text: $deviceKeyDraft)
                                .accessibilityIdentifier("deviceKeyField")
                                .focused($focusedField, equals: .deviceKey)
                                .font(.system(size: 12.5, weight: .regular, design: .monospaced))
                                .foregroundStyle(Color.logosLabel)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .textContentType(.password)
                                .submitLabel(.done)
                                .onSubmit { saveDeviceKeyDraft() }
                                .padding(.horizontal, 10)
                                .frame(height: 38)
                                .background(Color.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
                                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.logosAmber, lineWidth: 1))
                            Button("Save") { saveDeviceKeyDraft() }
                                .buttonStyle(AmberChipButtonStyle())
                                .disabled(deviceKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }
                    .padding(12)
                    .background(Color.logosBG2.opacity(0.62), in: RoundedRectangle(cornerRadius: 14))
                    .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.logosHairline, lineWidth: 0.8))
                }

                if let generatedDeviceKey {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Save this key — it won't be shown again")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Color.logosAmber)
                        Text(groupedSecret(generatedDeviceKey))
                            .font(.system(size: 13, weight: .semibold, design: .monospaced))
                            .foregroundStyle(Color.logosLabel)
                            .textSelection(.enabled)
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.black, in: RoundedRectangle(cornerRadius: 10))
                            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.logosAmber.opacity(0.45), lineWidth: 0.8))
                        HStack(spacing: 8) {
                            if copiedDeviceKey {
                                Button("✓ Copied") {
                                    UIPasteboard.general.string = generatedDeviceKey
                                }
                                .buttonStyle(GreenChipButtonStyle())
                            } else {
                                Button("Copy key") {
                                    UIPasteboard.general.string = generatedDeviceKey
                                    copiedDeviceKey = true
                                    Task { @MainActor in
                                        try? await Task.sleep(nanoseconds: 1_600_000_000)
                                        copiedDeviceKey = false
                                    }
                                }
                                .buttonStyle(AmberChipButtonStyle())
                            }
                            Button("Done") {
                                self.generatedDeviceKey = nil
                                copiedDeviceKey = false
                            }
                            .buttonStyle(SecondaryPillButtonStyle())
                        }
                    }
                    .padding(12)
                    .background(Color.logosAmberSoft2, in: RoundedRectangle(cornerRadius: 14))
                    .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.logosAmber.opacity(0.45), lineWidth: 0.8))
                }
            }
        }
    }

    private var voiceSettingsSection: some View {
        SettingsSection(title: "Voice") {
            VStack(spacing: 0) {
                ExpandableSelectRow(
                    kind: .defaultInput,
                    title: "Default input",
                    detail: selectedLabel(for: defaultInput, in: defaultInputOptions),
                    selectedValue: $defaultInput,
                    expanded: $expandedSettingsPicker,
                    options: defaultInputOptions,
                    monoLabels: false,
                    isLast: false
                )

                SettingRowChrome(isLast: false) {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("On-device speech")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(Color.logosLabel)
                            Text(voiceInput.voiceEnabled ? "Available" : voiceInput.availabilityMessage)
                                .font(.system(size: 13))
                                .foregroundStyle(Color.logosLabel3)
                                .lineLimit(2)
                        }
                        Spacer()
                        LogosToggle(isOn: $onDeviceSpeech, label: "On-device speech")
                            .disabled(true)
                            .opacity(0.65)
                    }
                }

                ExpandableSelectRow(
                    kind: .speakResponses,
                    title: "Speak responses",
                    detail: selectedLabel(for: speakMode, in: speakModeOptions),
                    selectedValue: $speakMode,
                    expanded: $expandedSettingsPicker,
                    options: speakModeOptions,
                    monoLabels: false,
                    isLast: true
                )
            }
            .settingsGroup()
        }
    }

    private var notificationSettingsSection: some View {
        SettingsSection(title: "Notifications") {
            VStack(spacing: 0) {
                SettingRowChrome(isLast: false) {
                    HStack(spacing: 12) {
                        Image(systemName: "bell")
                            .settingsIcon()
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Push notifications")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(Color.logosLabel)
                            Text(pushEnabled ? "Enabled" : notifications.authorizationStatus)
                                .font(.system(size: 13))
                                .foregroundStyle(Color.logosLabel3)
                                .lineLimit(2)
                                .accessibilityIdentifier("notificationStatusLabel")
                        }
                        Spacer()
                        LogosToggle(isOn: Binding(
                            get: { pushEnabled },
                            set: { newValue in
                                pushEnabled = newValue
                                if newValue { notifications.requestAuthorizationAndRegister() }
                            }
                        ), label: "Push notifications")
                        .accessibilityIdentifier("enableNotificationsButton")
                    }
                }

                NotificationToggleRow(title: "When Hermes finishes a run", detail: nil, isOn: $notifyDone, enabled: pushEnabled, isLast: false)
                NotificationToggleRow(title: "When Hermes needs approval", detail: nil, isOn: $notifyApproval, enabled: pushEnabled, isLast: false)
                NotificationToggleRow(title: "Include summary in push", detail: notifySummary ? "On" : "Off — fetch on reconnect", isOn: $notifySummary, enabled: pushEnabled, isLast: true)
            }
            .settingsGroup()
        }
    }

    private var diagnosticsSettingsSection: some View {
        SettingsSection(title: "Diagnostics") {
            VStack(spacing: 0) {
                if client.errorLog.isEmpty {
                    SettingRowChrome(isLast: true) {
                        HStack(spacing: 12) {
                            Image(systemName: "checkmark.seal")
                                .settingsIcon()
                            Text("No recent errors")
                                .font(.system(size: 15))
                                .foregroundStyle(Color.logosLabel3)
                                .accessibilityIdentifier("diagnosticsEmptyLabel")
                            Spacer()
                        }
                    }
                } else {
                    let entries = client.errorLog.entries
                    ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                        SettingRowChrome(isLast: false) {
                            HStack(alignment: .top, spacing: 12) {
                                Image(systemName: "exclamationmark.triangle")
                                    .settingsIcon()
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("\(entry.source.label) · \(Self.errorRelativeTime(entry.date))")
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(Color.logosLabel3)
                                    Text(entry.message)
                                        .font(.system(size: 14))
                                        .foregroundStyle(Color.logosLabel)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                Spacer()
                                Button {
                                    client.dismissError(id: entry.id)
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundStyle(Color.logosLabel3)
                                }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier("dismissErrorButton")
                            }
                        }
                        .accessibilityIdentifier("errorHistoryRow")
                    }

                    SettingRowChrome(isLast: true) {
                        Button {
                            client.clearErrorHistory()
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "trash")
                                    .settingsIcon()
                                Text("Clear error history")
                                    .font(.system(size: 15, weight: .medium))
                                    .foregroundStyle(Color.logosAmber)
                                Spacer()
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("clearErrorHistoryButton")
                    }
                }
            }
            .settingsGroup()
        }
    }

    private static func errorRelativeTime(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    private var settingsFooter: some View {
        VStack(spacing: 5) {
            Text("Logos · v0.4.2")
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(Color.logosLabel3)
            Text("plugin · loaded into hermes gateway")
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(Color.logosLabel4)
            if let route = notifications.lastRoute {
                Text("last route · \(route.kind) → \(route.projectKey)")
                    .font(.system(size: 11, weight: .regular, design: .monospaced))
                    .foregroundStyle(Color.logosLabel4)
                    .accessibilityIdentifier("notificationRouteLabel")
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 2)
    }

    private func configureRuntime() {
        // App-lifecycle orchestration now lives in AppCoordinator (WS1 P6). ContentView keeps
        // only the dependency-wiring seam plus the closures that write back into its @State.
        appCoordinator.attach(
            client: client,
            voiceInput: voiceInput,
            notifications: notifications,
            onVoiceFinal: { text, inputID, partialSeq, startedAt in
                handleFinalVoiceTranscript(text: text, inputID: inputID, partialSeq: partialSeq, startedAt: startedAt)
            },
            onDerivedFlags: { speechEnabled, pushAllowed in
                onDeviceSpeech = speechEnabled
                pushEnabled = pushAllowed
            }
        )
        appCoordinator.start()
        client.updateSceneActivationForPlayback(isActive: scenePhase == .active)
        notifications.onRoute = { route in
            client.handleNotificationRoute(route)
        }
        appCoordinator.activateInputs()
    }

    private func handleScenePhaseChange(_ newPhase: ScenePhase) {
        appCoordinator.handleScenePhaseChange(
            isActive: newPhase == .active,
            isBackgroundOrInactive: newPhase == .inactive || newPhase == .background
        )
    }

    private func handleConnectionStateChange(_ newState: LogosConnectionState) {
        appCoordinator.handleConnectionStateChange(newState) { pushEnabled = $0 }
    }

    private func handleFinalVoiceTranscript(text: String, inputID: String, partialSeq: Int, startedAt: Int64) -> Bool {
        let sent = client.sendSpeech(
            text: text,
            isFinal: true,
            inputID: inputID,
            partialSeq: partialSeq,
            startedAtMilliseconds: startedAt
        )
        if sent == false {
            draft = text
            focusedField = .composer
            withAnimation(.easeOut(duration: 0.18)) {
                composerMode = .text
            }
        } else {
            handleThreadContentChanged(forceFollow: true)
        }
        return sent
    }

    private func restoreUndeliveredSpeechDraft() {
        guard let failedDraft = client.undeliveredSpeechDraft else { return }
        let restoredText = failedDraft.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard restoredText.isEmpty == false else {
            client.clearUndeliveredSpeechDraft(id: failedDraft.id)
            return
        }
        let existingDraft = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if existingDraft.isEmpty {
            draft = restoredText
        } else {
            let existingLines = existingDraft
                .split(whereSeparator: \.isNewline)
                .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            if existingLines.contains(restoredText) == false {
                draft = "\(draft)\n\(restoredText)"
            }
        }
        focusedField = .composer
        withAnimation(.easeOut(duration: 0.18)) {
            composerMode = .text
        }
        client.clearUndeliveredSpeechDraft(id: failedDraft.id)
    }

    private func handleThreadContentChanged(forceFollow: Bool = false) {
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
                force: true
            )
        } else if let focus = client.threadFocusRequest, handleThreadFocusRequest(focus) {
            return
        } else if shouldFollowThread && isThreadUserDetached == false {
            let followedFingerprint = threadContentFingerprint
            scrollThreadToBottomAfterLayout(
                animated: true,
                recordFollowedSnapshot: true,
                followedFingerprint: followedFingerprint
            )
        } else {
            withAnimation(.easeOut(duration: 0.18)) {
                hasUnseenThreadUpdates = true
            }
        }
    }

    private func handleThreadFocusRequest(_ focus: ThreadFocusRequest) -> Bool {
        guard focus.projectKey == client.activeProjectKey else { return false }
        guard client.messages.contains(where: { $0.id == focus.targetMessageID }) else { return false }
        guard lastHandledThreadFocusRequestID != focus.id else { return true }
        lastHandledThreadFocusRequestID = focus.id
        lastForceFollowedThreadContentFingerprint = threadMessageFingerprint
        suppressNextThreadContentChangeForFocusClear = true
        // Finished-notification taps are explicit route focus events; generic bottom scrolling is insufficient for notification replay.
        scrollThreadToTargetAfterLayout(targetID: focus.targetMessageID, anchor: .bottom, animated: true, force: true)
        ThreadFocusLog.logger.info("Thread focus scheduled focus_id=\(focus.id, privacy: .public) project_key=\(focus.projectKey, privacy: .public) target_message_id=\(focus.targetMessageID, privacy: .public) visible=true")
        client.completeThreadFocusRequest(id: focus.id)
        return true
    }

    private func detachThreadFromAutoFollow() {
        if isThreadNearBottom == false || userInitiatedThreadScrollObserved {
            cancelPendingThreadFollow()
            shouldFollowThread = false
            isThreadUserDetached = true
            recordDetachedThreadContentIfNeeded()
        }
    }

    private func recordDetachedThreadContentIfNeeded() {
        if detachedThreadContentFingerprint == nil {
            detachedThreadContentFingerprint = threadContentFingerprint
            detachedThreadMaxServerSeq = client.messages.map(\.serverSeq).max() ?? 0
        }
    }

    /// Number of server-delivered messages that arrived since the user detached from the bottom.
    /// Gated on the detachment fingerprint so it resets to 0 whenever the thread re-attaches.
    private var unseenThreadUpdateCount: Int {
        guard detachedThreadContentFingerprint != nil, let base = detachedThreadMaxServerSeq else { return 0 }
        return ThreadUnseenPolicy.unseenCount(serverSeqs: client.messages.map(\.serverSeq), since: base)
    }

    private func handleThreadBottomProximityChangedAfterLayout(_ isNearBottom: Bool) {
        threadScrollProximityScheduler.schedule(isNearBottom) { coalescedValue in
            handleThreadBottomProximityChanged(coalescedValue)
        }
    }

    private func handleThreadBottomProximityChanged(_ isNearBottom: Bool) {
        if isThreadNearBottom == isNearBottom {
            if isNearBottom {
                markThreadContentSeenAtBottom(resetUserScrollObservation: isUserDrivenThreadScrollPhase(threadScrollPhase) == false)
            }
            return
        }
        isThreadNearBottom = isNearBottom
        if isNearBottom {
            markThreadContentSeenAtBottom(resetUserScrollObservation: isUserDrivenThreadScrollPhase(threadScrollPhase) == false)
        } else {
            recordDetachedThreadContentIfNeeded()
            if isUserDrivenThreadScrollPhase(threadScrollPhase) || userInitiatedThreadScrollObserved {
                detachThreadFromAutoFollow()
            }
        }
    }

    private func handleThreadScrollPhaseChanged(_ phase: ScrollPhase) {
        if isUserDrivenThreadScrollPhase(phase) {
            userInitiatedThreadScrollObserved = true
            if isThreadNearBottom == false {
                detachThreadFromAutoFollow()
            }
            return
        }

        if phase == .idle, isThreadNearBottom {
            markThreadContentSeenAtBottom(resetUserScrollObservation: true)
        } else if phase == .idle, userInitiatedThreadScrollObserved {
            detachThreadFromAutoFollow()
        }
    }

    private func handleThreadScrollPositionChanged(_ position: ScrollPosition) {
        guard position.isPositionedByUser else { return }
        userInitiatedThreadScrollObserved = true
        if isThreadNearBottom == false {
            detachThreadFromAutoFollow()
        }
    }

    private func markThreadContentSeenAtBottom(resetUserScrollObservation: Bool) {
        shouldFollowThread = true
        hasUnseenThreadUpdates = false
        isThreadUserDetached = false
        detachedThreadContentFingerprint = nil
        lastFollowedThreadContentFingerprint = threadContentFingerprint
        if resetUserScrollObservation {
            userInitiatedThreadScrollObserved = false
        }
    }

    private func isUserDrivenThreadScrollPhase(_ phase: ScrollPhase) -> Bool {
        switch phase {
        case .tracking, .interacting, .decelerating:
            return true
        case .idle, .animating:
            return false
        }
    }

    private func scrollThreadToBottom(
        animated: Bool,
        recordFollowedSnapshot: Bool = true,
        followedFingerprint: String? = nil
    ) {
        let action = {
            threadScrollPosition.scrollTo(id: "thread-bottom", anchor: .bottom)
            shouldFollowThread = true
            hasUnseenThreadUpdates = false
            isThreadUserDetached = false
            userInitiatedThreadScrollObserved = false
            detachedThreadContentFingerprint = nil
            if recordFollowedSnapshot {
                lastFollowedThreadContentFingerprint = followedFingerprint ?? threadContentFingerprint
            }
        }
        if animated {
            withAnimation(.easeOut(duration: 0.18), action)
        } else {
            action()
        }
    }

    private func scrollThreadToTarget(
        targetID: String,
        anchor: UnitPoint,
        animated: Bool,
        recordFollowedSnapshot: Bool = true,
        followedFingerprint: String? = nil
    ) {
        let action = {
            threadScrollPosition.scrollTo(id: targetID, anchor: anchor)
            shouldFollowThread = true
            hasUnseenThreadUpdates = false
            isThreadUserDetached = false
            userInitiatedThreadScrollObserved = false
            detachedThreadContentFingerprint = nil
            if recordFollowedSnapshot {
                lastFollowedThreadContentFingerprint = followedFingerprint ?? threadContentFingerprint
            }
        }
        if animated {
            withAnimation(.easeOut(duration: 0.18), action)
        } else {
            action()
        }
    }

    private func scrollThreadToBottomAfterLayout(
        animated: Bool,
        recordFollowedSnapshot: Bool = true,
        followedFingerprint: String? = nil,
        force: Bool = false
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
            guard shouldApplyScheduledThreadFollow(epoch: scheduledEpoch, projectKey: scheduledProjectKey, force: force, scheduledCanFollow: scheduledCanFollow) else { return }
            scrollThreadToBottom(
                animated: animated,
                recordFollowedSnapshot: recordFollowedSnapshot,
                followedFingerprint: followedFingerprint
            )
            try? await Task.sleep(nanoseconds: 180_000_000)
            guard shouldApplyScheduledThreadFollow(epoch: scheduledEpoch, projectKey: scheduledProjectKey, force: false, scheduledCanFollow: scheduledCanFollow) else { return }
            scrollThreadToBottom(
                animated: false,
                recordFollowedSnapshot: recordFollowedSnapshot,
                followedFingerprint: followedFingerprint
            )
            confirmPassiveThreadFollowIfStillAtBottom()
            if recordFollowedSnapshot == false {
                try? await Task.sleep(nanoseconds: 600_000_000)
                guard shouldApplyScheduledThreadFollow(epoch: scheduledEpoch, projectKey: scheduledProjectKey, force: false, scheduledCanFollow: scheduledCanFollow) else { return }
                refreshForceFollowedThreadSnapshotIfStillAtBottom()
            }
        }
    }

    private func scrollThreadToTargetAfterLayout(
        targetID: String,
        anchor: UnitPoint,
        animated: Bool,
        force: Bool = false
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
            guard shouldApplyScheduledThreadTargetFollow(epoch: scheduledEpoch, projectKey: scheduledProjectKey, targetID: targetID, force: force, scheduledCanFollow: scheduledCanFollow) else { return }
            scrollThreadToTarget(targetID: targetID, anchor: anchor, animated: animated, followedFingerprint: followedFingerprint)
            ThreadFocusLog.logger.info("Thread focus applied pass=1 target_message_id=\(targetID, privacy: .public) project_key=\(scheduledProjectKey, privacy: .public)")

            try? await Task.sleep(nanoseconds: 180_000_000)
            guard shouldApplyScheduledThreadTargetFollow(epoch: scheduledEpoch, projectKey: scheduledProjectKey, targetID: targetID, force: force, scheduledCanFollow: scheduledCanFollow) else { return }
            scrollThreadToTarget(targetID: targetID, anchor: anchor, animated: false, followedFingerprint: followedFingerprint)
            ThreadFocusLog.logger.info("Thread focus applied pass=2 target_message_id=\(targetID, privacy: .public) project_key=\(scheduledProjectKey, privacy: .public)")

            try? await Task.sleep(nanoseconds: 420_000_000)
            guard shouldApplyScheduledThreadTargetFollow(epoch: scheduledEpoch, projectKey: scheduledProjectKey, targetID: targetID, force: force, scheduledCanFollow: scheduledCanFollow) else { return }
            scrollThreadToTarget(targetID: targetID, anchor: anchor, animated: false, followedFingerprint: followedFingerprint)
            ThreadFocusLog.logger.info("Thread focus applied pass=3 target_message_id=\(targetID, privacy: .public) project_key=\(scheduledProjectKey, privacy: .public)")
        }
    }

    private func shouldApplyScheduledThreadFollow(epoch: Int, projectKey: String?, force: Bool, scheduledCanFollow: Bool) -> Bool {
        guard Task.isCancelled == false, epoch == threadFollowEpoch, client.activeProjectKey == projectKey else { return false }
        return ThreadAutoFollowPolicy.shouldApplyFollow(
            force: force,
            shouldFollowThread: scheduledCanFollow && shouldFollowThread,
            isThreadUserDetached: isThreadUserDetached
        )
    }

    private func shouldApplyScheduledThreadTargetFollow(epoch: Int, projectKey: String?, targetID: String, force: Bool, scheduledCanFollow: Bool) -> Bool {
        guard Task.isCancelled == false, epoch == threadFollowEpoch, client.activeProjectKey == projectKey else { return false }
        guard client.messages.contains(where: { $0.id == targetID }) else { return false }
        return ThreadAutoFollowPolicy.shouldApplyFollow(
            force: force,
            shouldFollowThread: scheduledCanFollow && shouldFollowThread,
            isThreadUserDetached: isThreadUserDetached
        )
    }

    private func cancelPendingThreadFollow() {
        threadFollowEpoch += 1
        threadFollowTask?.cancel()
        threadFollowTask = nil
    }

    private func confirmPassiveThreadFollowIfStillAtBottom() {
        guard isThreadNearBottom, isThreadUserDetached == false, threadScrollPosition.isPositionedByUser == false else { return }
        shouldFollowThread = true
        hasUnseenThreadUpdates = false
        detachedThreadContentFingerprint = nil
        lastFollowedThreadContentFingerprint = threadContentFingerprint
    }

    private func refreshForceFollowedThreadSnapshotIfStillAtBottom() {
        guard isThreadNearBottom, isThreadUserDetached == false, threadScrollPosition.isPositionedByUser == false else { return }
        lastForceFollowedThreadContentFingerprint = threadMessageFingerprint
    }

    private func initializeThreadScrollIfNeeded() {
        guard hasInitializedThreadScroll == false else { return }
        hasInitializedThreadScroll = true
        scrollThreadToBottomAfterLayout(animated: false)
    }

    private func resetThreadScrollForProjectChange() {
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
        scrollThreadToBottomAfterLayout(animated: false, force: true)
    }

    private func syncComposerWithVoiceState() {
        guard composerMode == .recording else { return }
        if voiceInput.mode == .idle, voiceInput.pendingMode == nil, voiceInput.isFinalizingTranscript == false {
            withAnimation(.easeOut(duration: 0.18)) {
                composerMode = ComposerModePolicy.modeAfterVoiceFinished(current: composerMode)
            }
        }
    }

    private func handleRecordPillTapped() {
        switch composerMode {
        case .paused:
            guard ComposerModePolicy.canStartRecordingFromPausedPill(
                voiceControlsDisabled: voiceControlsDisabled,
                isFinalizingTranscript: voiceInput.isFinalizingTranscript
            ) else { return }
            voiceInput.toggleTap()
            if voiceInput.pendingMode != nil || voiceInput.isRecording {
                withAnimation(.smooth(duration: 0.18)) {
                    composerMode = .recording
                }
            }
        case .recording:
            if voiceInput.mode == .hold || voiceInput.pendingMode == .hold {
                voiceInput.endHold()
            } else if voiceInput.isRecording || voiceInput.pendingMode != nil {
                voiceInput.toggleTap()
            }
            withAnimation(.smooth(duration: 0.18)) {
                composerMode = ComposerModePolicy.modeAfterRecordPillStopped(current: composerMode)
            }
        case .text:
            break
        }
    }

    private func handleComposerRightPillButton() {
        switch composerMode {
        case .text:
            focusedField = nil
            withAnimation(.smooth(duration: 0.18)) {
                composerMode = ComposerModePolicy.modeAfterRightPillTapped(current: composerMode)
            }
            closeTransientOverlays()
        case .recording:
            voiceInput.cancel()
            withAnimation(.smooth(duration: 0.18)) {
                composerMode = ComposerModePolicy.modeAfterRightPillTapped(current: composerMode)
            }
            focusedField = .composer
        case .paused:
            withAnimation(.smooth(duration: 0.18)) {
                composerMode = ComposerModePolicy.modeAfterRightPillTapped(current: composerMode)
            }
            focusedField = .composer
        }
    }

    private func recordPillDisabled(isRecording: Bool) -> Bool {
        if isRecording {
            return voiceControlsDisabled && !voiceInput.isVoiceInteractionActive
        }
        return !ComposerModePolicy.canStartRecordingFromPausedPill(
            voiceControlsDisabled: voiceControlsDisabled,
            isFinalizingTranscript: voiceInput.isFinalizingTranscript
        )
    }

    private func recordPillAccessibilityLabel(isRecording: Bool) -> String {
        if isRecording { return "Stop recording" }
        if voiceInput.isFinalizingTranscript { return "Finishing voice input" }
        return "Start recording"
    }

    private func recordPillAccessibilityValue(isRecording: Bool) -> String {
        if isRecording { return "Recording" }
        if voiceInput.isFinalizingTranscript { return "Finalizing transcript" }
        return "Voice mode paused"
    }

    private func recordPillAccessibilityHint(isRecording: Bool) -> String {
        if isRecording { return "Stops recording and stays ready to record again" }
        if voiceInput.isFinalizingTranscript { return "Wait until the transcript finishes sending" }
        return "Starts tap to record"
    }

    private func messageBubbleAccessibilityLabel(_ message: LogosMessage) -> String {
        let speaker = message.role == "user" ? "You" : "Hermes"
        return "\(speaker): \(message.content)"
    }

    private func submitDraft() {
        if client.sendText(draft) {
            rememberSlashCommandIfNeeded(draft)
            draft = ""
            focusedField = nil
            slashCommandDismissedDraft = nil
            handleThreadContentChanged(forceFollow: true)
        }
    }

    private func handleDraftChangedForSlashCommands(_ value: String) {
        if value.isEmpty || value.hasPrefix("/") == false {
            slashCommandDismissedDraft = nil
            return
        }
        if slashCommandDismissedDraft != nil, slashCommandDismissedDraft != value {
            slashCommandDismissedDraft = nil
        }
        if value.contains(" ") {
            client.requestSlashCommandCompletion(text: value)
        }
    }

    private func applySlashCommand(_ command: SlashCommandSpec) {
        guard command.available else { return }
        draft = client.slashCommandCatalog.replacementText(for: command)
        rememberSlashCommand(command.canonical)
        slashCommandDismissedDraft = nil
        focusedField = .composer
    }

    private func applySlashCompletion(_ item: SlashCommandCompletionItem) {
        guard item.replacementStart >= 0,
              item.replacementEnd >= item.replacementStart,
              item.replacementEnd <= draft.count,
              let start = draft.index(draft.startIndex, offsetBy: item.replacementStart, limitedBy: draft.endIndex),
              let end = draft.index(draft.startIndex, offsetBy: item.replacementEnd, limitedBy: draft.endIndex)
        else { return }
        draft.replaceSubrange(start..<end, with: item.replacementText)
        rememberSlashCommand(item.canonical)
        focusedField = .composer
    }

    private func rememberSlashCommandIfNeeded(_ text: String) {
        guard text.hasPrefix("/") else { return }
        let token = String(text.split(whereSeparator: \.isWhitespace).first ?? "")
        if let command = client.slashCommandCatalog.command(canonical: token) {
            rememberSlashCommand(command.canonical)
        }
    }

    private func rememberSlashCommand(_ canonical: String) {
        guard canonical.hasPrefix("/") else { return }
        var recents = slashCommandRecents.filter { $0 != canonical }
        recents.insert(canonical, at: 0)
        slashCommandRecentsStorage = recents.prefix(8).joined(separator: "\n")
    }

    private func submitClarificationAnswer() {
        if client.answerClarification(clarifyAnswer) {
            clarifyAnswer = ""
            focusedField = nil
            handleThreadContentChanged(forceFollow: true)
        }
    }

    private func createProjectFromTitleField() {
        if client.createProject(title: newProjectTitle) {
            let createdTitle = newProjectTitle
            newProjectTitle = ""
            isCreatingProject = false
            closeProjectSwitcher()
            justCreatedProject = true
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1_800_000_000)
                if justCreatedProject || activeProjectTitle == createdTitle {
                    justCreatedProject = false
                }
            }
        }
    }

    private func saveAdapterURL() {
        let trimmed = adapterURLDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return }
        client.settings.urlString = trimmed
        editingAdapterURL = false
        focusedField = nil
    }

    private func generateDeviceKey() {
        let key = (0..<32).map { _ in String(format: "%x", Int.random(in: 0..<16)) }.joined()
        client.settings.secret = key
        deviceKeyDraft = ""
        editingDeviceKey = false
        focusedField = nil
        generatedDeviceKey = key
        copiedDeviceKey = false
    }

    private func saveDeviceKeyDraft() {
        let trimmed = deviceKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return }
        client.settings.secret = trimmed
        deviceKeyDraft = ""
        generatedDeviceKey = nil
        copiedDeviceKey = false
        editingDeviceKey = false
        focusedField = nil
    }

    private func closeProjectSwitcher() {
        withAnimation(.timingCurve(0.2, 0.85, 0.25, 1, duration: 0.24)) {
            showProjectSwitcher = false
            isCreatingProject = false
            switcherSearch = ""
        }
        focusedField = nil
    }

    private func closeSettings() {
        withAnimation(.timingCurve(0.2, 0.85, 0.25, 1, duration: 0.26)) {
            showSettings = false
            expandedSettingsPicker = nil
            editingAdapterURL = false
            editingDeviceKey = false
            deviceKeyDraft = ""
            generatedDeviceKey = nil
            copiedDeviceKey = false
        }
        focusedField = nil
    }

    private func closeTransientOverlays(exceptProjectSwitcher: Bool = false, exceptAttachSheet: Bool = false) {
        if !exceptProjectSwitcher { showProjectSwitcher = false }
        if !exceptAttachSheet { showAttachSheet = false }
        if draft.hasPrefix("/") {
            slashCommandDismissedDraft = draft
        }
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

    private var hasComposerDraft: Bool {
        draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    private var composerRightPillSystemImage: String {
        switch composerMode {
        case .text:
            return "mic"
        case .paused, .recording:
            return "keyboard"
        }
    }

    private var composerRightPillAccessibilityID: String {
        switch composerMode {
        case .text:
            return "tapToTalkButton"
        case .paused, .recording:
            return "keyboardModeButton"
        }
    }

    private var composerRightPillAccessibilityLabel: String {
        switch composerMode {
        case .text:
            return "Switch to voice mode"
        case .paused:
            return "Switch to keyboard"
        case .recording:
            return "Cancel voice input and switch to keyboard"
        }
    }

    private var composerRightPillAccessibilityHint: String {
        switch composerMode {
        case .text:
            return "Shows tap to record controls"
        case .paused:
            return "Returns to text input"
        case .recording:
            return "Cancels voice input and returns to text input"
        }
    }

    private var composerRightPillDisabled: Bool {
        if client.runStatus == .cancelling, composerMode == .text {
            return true
        }
        return composerMode == .text && defaultInput == "text"
    }

    private var voiceControlsDisabled: Bool {
        VoiceControlPolicy.controlsDisabled(
            voiceEnabled: voiceInput.voiceEnabled,
            connected: client.connectionState == .connected && client.runStatus != .cancelling,
            isRecording: voiceInput.isRecording || voiceInput.pendingMode != nil,
            isFinalizing: voiceInput.isFinalizingTranscript
        )
    }

    private var activeProjectTitle: String {
        client.projects.first(where: { $0.projectKey == client.activeProjectKey })?.title
            ?? client.activeProjectKey
    }

    private var allProjects: [LogosProject] {
        if client.projects.isEmpty {
            return [LogosProject(projectKey: client.activeProjectKey, title: client.activeProjectKey, currentSessionID: nil, lastPreview: "Current session")]
        }
        if client.projects.contains(where: { $0.projectKey == client.activeProjectKey }) {
            return client.projects
        }
        return [LogosProject(projectKey: client.activeProjectKey, title: client.activeProjectKey, currentSessionID: nil, lastPreview: "Current session")] + client.projects
    }

    private var displayedProjects: [LogosProject] {
        let base = isCreatingProject ? Array(allProjects.prefix(3)) : allProjects
        let query = switcherSearch.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard query.isEmpty == false, isCreatingProject == false else { return base }
        return base.filter { project in
            project.title.lowercased().contains(query)
                || project.projectKey.lowercased().contains(query)
                || (project.lastPreview?.lowercased().contains(query) ?? false)
        }
    }

    private var statusChipText: String {
        if justCreatedProject { return "Project created · ready" }
        if client.connectionRetryState != nil {
            return "Reconnecting…"
        }
        if client.connectionState == .connecting {
            return "Connecting…"
        }
        if client.connectionState == .error, client.runStatus != .error {
            return "Connection error"
        }
        switch client.runStatus {
        case .idle:
            return client.connectionState == .connected ? "Idle · live" : "Idle · disconnected"
        case .running, .queued:
            return "Hermes is working…"
        case .awaitingApproval:
            return "Approval needed"
        case .awaitingClarification:
            return "Clarification needed"
        case .cancelling:
            return "Stopping run…"
        case .error:
            return "Run error"
        }
    }

    private var statusChipColor: Color {
        if justCreatedProject { return .logosGreen }
        if client.connectionRetryState != nil || client.connectionState == .connecting {
            return .logosAmber
        }
        if client.connectionState == .error, client.runStatus != .error {
            return .logosRed
        }
        switch client.runStatus {
        case .idle:
            return client.connectionState == .connected ? .logosGreen : .logosLabel3
        case .running, .queued, .cancelling:
            return .logosAmber
        case .awaitingApproval, .awaitingClarification:
            return .logosYellow
        case .error:
            return .logosRed
        }
    }

    private var connectionTitle: String {
        ConnectionStatusPresentation.title(for: client.connectionState)
    }

    private var connectionDetail: String {
        ConnectionStatusPresentation.transportDescription(
            urlString: client.settings.urlString,
            isPinned: client.settings.certSPKISHA256.isEmpty == false
        )
    }

    private var autoConnectDetail: String {
        client.settings.autoConnect ? "On launch and resume" : "Off"
    }

    private var connectionActionTitle: String {
        ConnectionStatusPresentation.actionTitle(for: client.connectionState)
    }

    private var connectionColor: Color {
        switch ConnectionStatusPresentation.indicator(for: client.connectionState) {
        case .ok: return .logosGreen
        case .pending: return .logosAmber
        case .idle: return .logosLabel3
        case .error: return .logosRed
        }
    }

    private var maskedDeviceKey: String {
        let suffix = String(client.settings.secret.suffix(4))
        let shownSuffix = suffix.isEmpty ? "none" : suffix
        return "\(client.settings.deviceID) · ••••••\(shownSuffix)"
    }

    private func groupedSecret(_ secret: String) -> String {
        stride(from: 0, to: secret.count, by: 4).map { index in
            let start = secret.index(secret.startIndex, offsetBy: index)
            let end = secret.index(start, offsetBy: min(4, secret.distance(from: start, to: secret.endIndex)), limitedBy: secret.endIndex) ?? secret.endIndex
            return String(secret[start..<end])
        }.joined(separator: " ")
    }

    private func selectedLabel(for value: String, in options: [PickerOption]) -> String {
        options.first(where: { $0.value == value })?.label ?? value
    }

    private var hermesProfileOptions: [PickerOption] {
        [
            PickerOption(value: "default", label: "default", subtitle: "Balanced · safe defaults"),
            PickerOption(value: "focused-coding", label: "focused-coding", subtitle: "Long-running tasks · less chatter"),
            PickerOption(value: "planner", label: "planner", subtitle: "Thinks before acting · proposes plans"),
            PickerOption(value: "ops", label: "ops", subtitle: "Shell + infra · extra approvals"),
            PickerOption(value: "research", label: "research", subtitle: "Reads widely · cites sources")
        ]
    }

    private var defaultInputOptions: [PickerOption] {
        [
            PickerOption(value: "tap", label: "Tap to talk", subtitle: "Tap mic, tap Record, tap Stop"),
            PickerOption(value: "hold", label: "Hold to talk", subtitle: "Press and hold the mic to record"),
            PickerOption(value: "always", label: "Always listening", subtitle: "Wake word · \"Hey Logos\""),
            PickerOption(value: "text", label: "Text only", subtitle: "Hide the mic from the composer")
        ]
    }

    private var speakModeOptions: [PickerOption] {
        [
            PickerOption(value: "off", label: "Off", subtitle: "Silent · text only"),
            PickerOption(value: "summary", label: "Short summary only", subtitle: "One-line spoken recap"),
            PickerOption(value: "full", label: "Full response", subtitle: "Read every assistant turn aloud"),
            PickerOption(value: "urgent", label: "Only approvals", subtitle: "Speak when Hermes needs you")
        ]
    }
}

enum FocusedField: Hashable {
    case composer
    case switcherSearch
    case newProjectTitle
    case adapterURL
    case deviceKey
    case clarifyAnswer
}

private enum SlashCommandMenuState: String {
    case inactive
    case loadingCatalog
    case browsing
    case argumentHelp
    case emptyResults
    case dismissed
    case errorFallback
}

enum ComposerMode: Equatable {
    case text
    case paused
    case recording
}

enum ComposerModePolicy {
    static func modeAfterVoiceFinished(current: ComposerMode) -> ComposerMode {
        .paused
    }

    static func modeAfterRecordPillStopped(current: ComposerMode) -> ComposerMode {
        .paused
    }

    static func modeAfterRightPillTapped(current: ComposerMode) -> ComposerMode {
        switch current {
        case .text:
            return .paused
        case .paused, .recording:
            return .text
        }
    }

    static func canStartRecordingFromPausedPill(
        voiceControlsDisabled: Bool,
        isFinalizingTranscript: Bool
    ) -> Bool {
        voiceControlsDisabled == false && isFinalizingTranscript == false
    }
}

private enum ProjectCreateSource: String, CaseIterable, Identifiable {
    case blank
    case resume
    case lastDesktop

    var id: String { rawValue }

    var title: String {
        switch self {
        case .blank: return "Blank"
        case .resume: return "Resume by title"
        case .lastDesktop: return "Last desktop session"
        }
    }
}

enum SettingsPickerKind: Hashable {
    case hermesProfile
    case defaultInput
    case speakResponses
}

struct PickerOption: Identifiable, Hashable {
    var id: String { value }
    let value: String
    let label: String
    let subtitle: String
}



#Preview {
    ContentView()
        .environmentObject(LogosClient())
        .environmentObject(NotificationCoordinator.shared)
}
