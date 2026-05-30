import SwiftUI
import UIKit
import OSLog

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

    /// A cheap change signature for the hot follow / "new updates" path (read on every `body` pass via
    /// `threadContentFingerprint`). Mirrors `contentFingerprint`'s change-sensitivity but hashes only
    /// per-message *metadata* plus the *last* message's content — history is append-only (the streaming
    /// tail is the only message whose content mutates; `MessageManager.refreshMessages` upserts it), so
    /// this is behavior-equivalent without the O(total-content) string build. `contentFingerprint` is
    /// retained for the on-change diff in `handleThreadTimelineSnapshotChanged`.
    var threadContentSignature: Int {
        var hasher = Hasher()
        hasher.combine(activeProjectKey)
        hasher.combine(messages.count)
        for message in messages {
            hasher.combine(message.id)
            hasher.combine(message.role)
            hasher.combine(message.status)
            hasher.combine(message.isFinal)
            hasher.combine(message.isProgressUpdate)
        }
        hasher.combine(messages.last?.content ?? "no-last-content")
        if let progress {
            hasher.combine(progress.id)
            hasher.combine(progress.updateCount)
            hasher.combine(progress.adapterUpdateCount)
            hasher.combine(progress.isExpanded)
            hasher.combine(progress.isComplete)
            hasher.combine(progress.timedOut)
            hasher.combine(progress.finalStatus)
            hasher.combine(progress.canRetry)
            hasher.combine(progress.completedFinalMessageID)
        } else {
            hasher.combine("no-progress")
        }
        if let connectionRetry {
            hasher.combine(connectionRetry.id)
            hasher.combine(connectionRetry.attemptCount)
            hasher.combine(connectionRetry.eventCount)
            hasher.combine(connectionRetry.nextRetryAt)
        } else {
            hasher.combine("no-connection-retry")
        }
        hasher.combine(isRunControlVisible)
        hasher.combine(approvalCardID)
        hasher.combine(clarifyCardID)
        hasher.combine(pendingInteractionResponseID)
        hasher.combine(ackText)
        hasher.combine(errorText)
        hasher.combine(voiceDraftText)
        hasher.combine(composerMode)
        hasher.combine(composerBottomPadding)
        hasher.combine(connectionState)
        hasher.combine(runStatus)
        hasher.combine(focusRequest?.id)
        hasher.combine(focusRequest?.targetMessageID)
        return hasher.finalize()
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
    @Environment(LogosClient.self) private var client
    @Environment(NotificationCoordinator.self) private var notifications

    @State private var draft = ""
    @State private var clarifyAnswer = ""
    @State private var voiceInput = VoiceInputController()
    @State private var appCoordinator = AppCoordinator()
    @AppStorage("logos.slashCommandRecents") private var slashCommandRecentsStorage = ""

    @State private var composerMode: ComposerMode = .paused
    @State private var showProjectSwitcher = false
    @State private var showAttachSheet = false
    @State private var showSettings = false
    // `justCreatedProject` stays here (not in ProjectSwitcherOverlay): it is read by the nav-bar
    // status chip (`statusChipText`/`statusChipColor`) and its delayed reset must outlive the
    // switcher's dismissal. The overlay reports a successful create via `onProjectCreated`.
    @State private var justCreatedProject = false

    // Settings preference mirrors that are also written from outside the settings panel, so they
    // stay here as the source of truth and are handed to `SettingsOverlay` as bindings:
    // `defaultInput` is read by the composer's right-pill gating; `onDeviceSpeech`/`pushEnabled`
    // are pushed in by `AppCoordinator`'s derived-flags callback / connection-state handler.
    @State private var defaultInput = "tap"
    @State private var onDeviceSpeech = true
    @State private var pushEnabled = false
    @State private var pendingPairingRoute: LogosPairingRoute?
    // Owns the thread auto-follow / scroll / unseen-updates state machine (WS1 PR4c). Created once
    // and kept across project switches — `resetThreadScrollForProjectChange` handles the reset.
    @State private var threadFollow = ThreadFollowModel()
    @State private var slashCommandDismissedDraft: String?

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

            AudioOverlayLayer()
                .zIndex(6)

            if showProjectSwitcher {
                ProjectSwitcherOverlay(
                    isPresented: $showProjectSwitcher,
                    onProjectCreated: { title in handleProjectCreated(title) }
                )
                .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
                .zIndex(10)
            }

            if showAttachSheet {
                AttachSheetOverlay(
                    isPresented: $showAttachSheet,
                    onSelectCommands: { openCommandsFromAttachSheet() }
                )
                .transition(.opacity)
                .zIndex(20)
            }

            if showSettings {
                SettingsOverlay(
                    voiceInput: voiceInput,
                    defaultInput: $defaultInput,
                    onDeviceSpeech: $onDeviceSpeech,
                    pushEnabled: $pushEnabled,
                    onClose: { closeSettings() }
                )
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
        ThreadView(
            threadFollow: threadFollow,
            composerMode: composerMode,
            voiceDraftText: voiceDraftText,
            slashCommandMenuStateRawValue: slashCommandMenuState.rawValue,
            slashCommandMenuHeight: slashCommandMenuHeight,
            clarifyAnswer: $clarifyAnswer,
            clarifyFocus: $focusedField,
            onApprove: {
                Task { @MainActor in
                    await client.approveCurrentRequest()
                    forceFollowThreadContent()
                }
            },
            onDeny: {
                Task { @MainActor in
                    await client.denyCurrentRequest()
                    forceFollowThreadContent()
                }
            },
            onClarifyChoice: { choice in
                Task { @MainActor in
                    if await client.answerClarification(choice) {
                        forceFollowThreadContent()
                    }
                }
            },
            onClarifySubmit: submitClarificationAnswer,
            onForceFollow: { forceFollowThreadContent() }
        )
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

    private var threadMessageFingerprint: String {
        threadTimelineSnapshot.messageFingerprint
    }

    private var threadContentFingerprint: Int {
        threadTimelineSnapshot.threadContentSignature
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
        Task { @MainActor in
            await client.updateSceneActivationForPlayback(isActive: scenePhase == .active)
        }
        notifications.onRoute = { route in
            Task { @MainActor in
                await client.handleNotificationRoute(route)
            }
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

    @discardableResult
    private func handleFinalVoiceTranscript(text: String, inputID: String, partialSeq: Int, startedAt: Int64) -> Bool {
        // The socket send is now async; kick it off and apply the optimistic-follow / text-composer
        // fallback once it resolves. The voice state machine only uses the synchronous return for an
        // idle status string, so we report that the transcript was accepted for delivery here.
        Task { @MainActor in
            let sent = await client.sendSpeech(
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
                forceFollowThreadContent()
            }
        }
        return true
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

    /// Thin call-site forwarder into `ThreadFollowModel.handleThreadContentChanged` for the
    /// post-send / post-interaction "force-follow to bottom" path. The view supplies the
    /// `client` and the current `threadContentFingerprint`/`threadMessageFingerprint`; the
    /// state machine itself lives on `threadFollow` (WS1 PR4c).
    private func forceFollowThreadContent() {
        threadFollow.handleThreadContentChanged(
            forceFollow: true,
            client: client,
            threadContentFingerprint: threadContentFingerprint,
            threadMessageFingerprint: threadMessageFingerprint
        )
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

    private func submitDraft() {
        let pendingDraft = draft
        Task { @MainActor in
            if await client.sendText(pendingDraft) {
                rememberSlashCommandIfNeeded(pendingDraft)
                draft = ""
                focusedField = nil
                slashCommandDismissedDraft = nil
                forceFollowThreadContent()
            }
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
            Task { @MainActor in await client.requestSlashCommandCompletion(text: value) }
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
        let pendingAnswer = clarifyAnswer
        Task { @MainActor in
            if await client.answerClarification(pendingAnswer) {
                clarifyAnswer = ""
                focusedField = nil
                forceFollowThreadContent()
            }
        }
    }

    private func handleProjectCreated(_ createdTitle: String) {
        // ProjectSwitcherOverlay has already dismissed itself; ContentView owns the nav-bar
        // "project created" status flag and its delayed reset, which must outlive that dismissal.
        justCreatedProject = true
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(1800))
            if justCreatedProject || activeProjectTitle == createdTitle {
                justCreatedProject = false
            }
        }
    }

    private func openCommandsFromAttachSheet() {
        showAttachSheet = false
        composerMode = .text
        draft = "/"
        slashCommandDismissedDraft = nil
        focusedField = .composer
    }

    private func closeSettings() {
        // SettingsOverlay resets its own editor drafts before invoking this; ContentView only
        // owns the panel-visibility flag and the dismiss animation.
        withAnimation(.timingCurve(0.2, 0.85, 0.25, 1, duration: 0.26)) {
            showSettings = false
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

    // `shouldShowRunControl` and `canRetryProgressRun` stay here: the timeline snapshot (still
    // computed in ContentView for `forceFollowThreadContent`) reads them. `isProgressWorking` /
    // `canStopProgressRun` moved to `ThreadView` with the `ProgressActivityCard` that used them.
    private var shouldShowRunControl: Bool {
        switch client.runStatus {
        case .running, .queued, .awaitingApproval, .awaitingClarification, .cancelling:
            return true
        case .idle, .error:
            return false
        }
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

enum ProjectCreateSource: String, CaseIterable, Identifiable {
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
        .environment(LogosClient())
        .environment(NotificationCoordinator.shared)
}
