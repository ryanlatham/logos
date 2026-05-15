import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var client: LogosClient
    @EnvironmentObject private var notifications: NotificationCoordinator
    @State private var draft = ""
    @State private var newProjectTitle = ""
    @State private var clarifyAnswer = ""
    @StateObject private var voiceInput = VoiceInputController()
    @FocusState private var composerFocused: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                ScrollView {
                    VStack(spacing: 12) {
                        connectionPanel
                        projectPanel
                        statusPanel
                        notificationPanel
                        voicePanel
                        interactionCards
                        messageList
                    }
                }
                composer
            }
            .padding()
            .navigationTitle("Logos")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(client.connectionState == .connected ? "Reconnect" : "Connect") {
                        client.connect()
                    }
                }
            }
            .onAppear {
                client.connectIfRequestedByEnvironment()
                voiceInput.configureCallbacks(
                    partial: { text, inputID, partialSeq, startedAt in
                        client.sendSpeech(text: text, isFinal: false, inputID: inputID, partialSeq: partialSeq, startedAtMilliseconds: startedAt)
                    },
                    final: { text, inputID, partialSeq, startedAt in
                        client.sendSpeech(text: text, isFinal: true, inputID: inputID, partialSeq: partialSeq, startedAtMilliseconds: startedAt)
                    }
                )
                notifications.onDeviceToken = { token in
                    client.registerDevice(apnsToken: token)
                }
                notifications.onRoute = { route in
                    client.handleNotificationRoute(route)
                }
                voiceInput.refreshAvailability()
                voiceInput.updateTransportAvailable(client.connectionState == .connected)
            }
            .onChange(of: client.connectionState) { _, newState in
                voiceInput.updateTransportAvailable(newState == .connected)
            }
            .onOpenURL { url in
                if let route = LogosNotificationRoute.from(url: url) {
                    notifications.route(route)
                }
            }
        }
    }

    private var connectionPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Adapter")
                .font(.headline)
            TextField("ws://127.0.0.1:8765", text: Binding(
                get: { client.settings.urlString },
                set: { client.settings.urlString = $0 }
            ))
            .accessibilityIdentifier("adapterURLField")
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .textFieldStyle(.roundedBorder)
            SecureField("Development shared secret", text: Binding(
                get: { client.settings.secret },
                set: { client.settings.secret = $0 }
            ))
            .accessibilityIdentifier("secretField")
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .textFieldStyle(.roundedBorder)
            HStack {
                Circle()
                    .fill(connectionColor)
                    .frame(width: 10, height: 10)
                Text(client.connectionState.rawValue.capitalized)
                    .font(.caption)
                    .accessibilityIdentifier("connectionStatusLabel")
                Spacer()
                Button("Disconnect") { client.disconnect() }
                    .disabled(client.connectionState == .disconnected)
            }
            if let error = client.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }
        }
        .padding(12)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    private var projectPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Project")
                    .font(.headline)
                Spacer()
                Button("Refresh") { client.requestProjects() }
            }
            Picker("Active project", selection: Binding(
                get: { client.activeProjectKey },
                set: { client.switchProject($0) }
            )) {
                if client.projects.isEmpty {
                    Text("default").tag("default")
                }
                ForEach(client.projects) { project in
                    Text(project.title).tag(project.projectKey)
                }
            }
            .pickerStyle(.menu)
            .accessibilityIdentifier("projectPicker")
            HStack {
                TextField("New project title", text: $newProjectTitle)
                    .accessibilityIdentifier("newProjectTitleField")
                    .textFieldStyle(.roundedBorder)
                Button("New") {
                    if client.createProject(title: newProjectTitle) {
                        newProjectTitle = ""
                    }
                }
                .disabled(client.connectionState != .connected || newProjectTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(12)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    private var statusPanel: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Label(client.runStatus.rawValue.replacingOccurrences(of: "_", with: " ").capitalized, systemImage: statusIcon)
                    .font(.subheadline)
                Spacer()
                Button("Stop") { client.cancelRun() }
                    .disabled(client.connectionState != .connected || client.runStatus == .idle || client.runStatus == .cancelling)
            }
            if let playbackStatus = client.playbackStatus {
                Label(playbackStatus, systemImage: "speaker.wave.2")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("playbackStatusLabel")
            }
            if let ackText = client.ackText {
                Label(ackText, systemImage: "bolt.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("ackStatusLabel")
            }
        }
    }

    private var notificationPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Notifications")
                    .font(.headline)
                Spacer()
                Button("Enable") { notifications.requestAuthorizationAndRegister() }
                    .accessibilityIdentifier("enableNotificationsButton")
            }
            Text(notifications.authorizationStatus)
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("notificationStatusLabel")
            if let route = notifications.lastRoute {
                Text("Last route: \(route.kind) → \(route.projectKey)")
                    .font(.caption)
                    .accessibilityIdentifier("notificationRouteLabel")
            }
        }
        .padding(12)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    private var voicePanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Voice")
                .font(.headline)
            Text(voiceInput.availabilityMessage)
                .font(.caption)
                .foregroundStyle(voiceInput.voiceEnabled ? Color.secondary : Color.orange)
                .accessibilityIdentifier("voiceAvailabilityLabel")
            Label(voiceInput.statusText, systemImage: voiceInput.isRecording ? "waveform" : "mic")
                .font(.caption)
                .accessibilityIdentifier("voiceStatusLabel")
            if voiceInput.partialTranscript.isEmpty == false {
                Text(voiceInput.partialTranscript)
                    .font(.caption)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
                    .accessibilityIdentifier("partialTranscriptLabel")
            }
            HStack {
                Text("Hold to Talk")
                    .font(.callout.weight(.semibold))
                    .padding(.vertical, 8)
                    .padding(.horizontal, 12)
                    .frame(maxWidth: .infinity)
                    .background(voiceInput.mode == .hold ? Color.red.opacity(0.22) : Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                    .accessibilityIdentifier("holdToTalkButton")
                    .accessibilityAddTraits(.isButton)
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { _ in voiceInput.startHold() }
                            .onEnded { _ in voiceInput.endHold() }
                    )
                    .allowsHitTesting(VoiceControlPolicy.controlsDisabled(
                        voiceEnabled: voiceInput.voiceEnabled,
                        connected: client.connectionState == .connected,
                        isRecording: voiceInput.isVoiceInteractionActive
                    ) == false)
                    .opacity(VoiceControlPolicy.controlsDisabled(
                        voiceEnabled: voiceInput.voiceEnabled,
                        connected: client.connectionState == .connected,
                        isRecording: voiceInput.isVoiceInteractionActive
                    ) ? 0.45 : 1.0)
                Button((voiceInput.mode == .tap || voiceInput.pendingMode == .tap) ? "Stop Tap" : "Tap to Talk") {
                    voiceInput.toggleTap()
                }
                .accessibilityIdentifier("tapToTalkButton")
                .buttonStyle(.borderedProminent)
                .disabled(VoiceControlPolicy.controlsDisabled(
                    voiceEnabled: voiceInput.voiceEnabled,
                    connected: client.connectionState == .connected,
                    isRecording: voiceInput.isVoiceInteractionActive
                ))
            }
        }
        .padding(12)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    @ViewBuilder
    private var interactionCards: some View {
        if let approval = client.approvalCard {
            VStack(alignment: .leading, spacing: 8) {
                Text(approval.title).font(.headline)
                Text(approval.summary).font(.subheadline)
                Text("Project: \(approval.projectKey)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if approval.commandPreview.isEmpty == false {
                    Text(approval.commandPreview)
                        .font(.system(.caption, design: .monospaced))
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.orange.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
                }
                if approval.risk.isEmpty == false {
                    Text(approval.risk).font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    let responsePending = client.pendingInteractionResponseID == approval.id
                    Button("Deny", role: .destructive) { client.denyCurrentRequest() }
                        .disabled(client.connectionState != .connected || responsePending)
                    Spacer()
                    Button(responsePending ? "Sent" : "Approve") { client.approveCurrentRequest() }
                        .buttonStyle(.borderedProminent)
                        .disabled(client.connectionState != .connected || responsePending)
                }
            }
            .padding(12)
            .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 14))
        }
        if let clarify = client.clarifyCard {
            VStack(alignment: .leading, spacing: 8) {
                Text("Hermes needs clarification").font(.headline)
                Text("Project: \(clarify.projectKey)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(clarify.question).font(.subheadline)
                let responsePending = client.pendingInteractionResponseID == clarify.id
                ForEach(clarify.choices, id: \.self) { choice in
                    Button(choice) { client.answerClarification(choice) }
                        .buttonStyle(.bordered)
                        .disabled(client.connectionState != .connected || responsePending)
                }
                if clarify.allowFreeText {
                    HStack {
                        TextField("Answer", text: $clarifyAnswer)
                            .textFieldStyle(.roundedBorder)
                            .disabled(responsePending)
                        Button(responsePending ? "Sent" : "Send") {
                            if client.answerClarification(clarifyAnswer) {
                                clarifyAnswer = ""
                            }
                        }
                        .disabled(client.connectionState != .connected || responsePending || clarifyAnswer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
            .padding(12)
            .background(Color.blue.opacity(0.1), in: RoundedRectangle(cornerRadius: 14))
        }
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(client.messages) { message in
                        messageBubble(message)
                            .id(message.id)
                    }
                }
            }
            .onChange(of: client.messages.count) { _, _ in
                if let last = client.messages.last {
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
    }

    private func messageBubble(_ message: LogosMessage) -> some View {
        HStack {
            if message.role == "user" { Spacer(minLength: 40) }
            VStack(alignment: .leading, spacing: 4) {
                Text(message.role.capitalized)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(message.content)
                    .font(.body)
                if message.role != "user" && message.status == "persisted" {
                    Button {
                        client.playback(message: message)
                    } label: {
                        Label("Play", systemImage: "play.circle")
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("playMessageButton")
                    .disabled(client.connectionState != .connected)
                }
                if message.status != "persisted" {
                    Text(message.status)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(10)
            .background(message.role == "user" ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
            if message.role != "user" { Spacer(minLength: 40) }
        }
    }

    private var composer: some View {
        HStack {
            TextField("Ask Hermes", text: $draft, axis: .vertical)
                .accessibilityIdentifier("composerTextField")
                .focused($composerFocused)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...4)
                .onSubmit { submitDraft() }
            Button("Send") {
                submitDraft()
            }
            .accessibilityIdentifier("sendButton")
            .disabled(client.connectionState != .connected || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private func submitDraft() {
        if client.sendText(draft) {
            draft = ""
            composerFocused = false
        }
    }

    private var connectionColor: Color {
        switch client.connectionState {
        case .connected: return .green
        case .connecting: return .orange
        case .error: return .red
        case .disconnected: return .gray
        }
    }

    private var statusIcon: String {
        switch client.runStatus {
        case .idle: return "checkmark.circle"
        case .running, .queued: return "hourglass"
        case .awaitingApproval: return "exclamationmark.triangle"
        case .awaitingClarification: return "questionmark.circle"
        case .cancelling: return "xmark.circle"
        case .error: return "exclamationmark.octagon"
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(LogosClient())
}
