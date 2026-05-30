import SwiftUI
import UIKit
import Foundation
import OSLog

struct SectionHead: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.system(size: 11, weight: .bold))
            .tracking(0.4)
            .foregroundStyle(Color.logosLabel3)
            .textCase(.uppercase)
            .padding(.horizontal, 2)
    }
}

struct SettingsSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHead(title: title)
            content
        }
    }
}

struct SettingRowChrome<Content: View>: View {
    var isLast: Bool
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .bottom) {
                if !isLast {
                    Rectangle()
                        .fill(Color.logosHairline)
                        .frame(height: 0.5)
                        .padding(.leading, 14)
                }
            }
    }
}

struct ExpandableSelectRow: View {
    let kind: SettingsPickerKind
    let title: String
    let detail: String
    @Binding var selectedValue: String
    @Binding var expanded: SettingsPickerKind?
    let options: [PickerOption]
    let monoLabels: Bool
    let isLast: Bool

    private var isExpanded: Bool { expanded == kind }

    var body: some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(.easeOut(duration: 0.18)) {
                    expanded = isExpanded ? nil : kind
                }
            } label: {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Color.logosLabel)
                        Text(detail)
                            .font(.system(size: 13))
                            .foregroundStyle(isExpanded ? Color.logosAmber : Color.logosLabel3)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.logosLabel3)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(isExpanded ? Color.logosAmberSoft2.opacity(0.55) : Color.clear)
            }
            .buttonStyle(.plain)

            if isExpanded {
                VStack(spacing: 2) {
                    ForEach(options) { option in
                        Button {
                            selectedValue = option.value
                            withAnimation(.easeOut(duration: 0.18)) { expanded = nil }
                        } label: {
                            HStack(spacing: 10) {
                                RadioMark(isSelected: selectedValue == option.value)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(option.label)
                                        .font(.system(size: 14, weight: selectedValue == option.value ? .semibold : .medium, design: monoLabels ? .monospaced : .default))
                                        .foregroundStyle(Color.logosLabel)
                                    Text(option.subtitle)
                                        .font(.system(size: 12))
                                        .foregroundStyle(Color.logosLabel3)
                                }
                                Spacer()
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 10)
                            .background(selectedValue == option.value ? Color.logosAmberSoft : Color.logosBG1.opacity(0.72), in: RoundedRectangle(cornerRadius: 12))
                            .overlay(RoundedRectangle(cornerRadius: 12).stroke(selectedValue == option.value ? Color.logosAmber.opacity(0.55) : Color.logosHairline, lineWidth: 0.5))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .overlay(alignment: .bottom) {
            if !isLast && !isExpanded {
                Rectangle()
                    .fill(Color.logosHairline)
                    .frame(height: 0.5)
                    .padding(.leading, 14)
            }
        }
    }
}

struct NotificationToggleRow: View {
    let title: String
    let detail: String?
    @Binding var isOn: Bool
    let enabled: Bool
    let isLast: Bool

    var body: some View {
        SettingRowChrome(isLast: isLast) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.logosLabel)
                    if let detail {
                        Text(detail)
                            .font(.system(size: 13))
                            .foregroundStyle(Color.logosLabel3)
                    }
                }
                Spacer()
                LogosToggle(isOn: $isOn, label: title)
                    .disabled(!enabled)
            }
            .opacity(enabled ? 1 : 0.45)
        }
    }
}

struct LogosToggle: View {
    @Binding var isOn: Bool
    var label: String = "Toggle"
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button {
            guard isEnabled else { return }
            withAnimation(.linear(duration: 0.2)) { isOn.toggle() }
        } label: {
            RoundedRectangle(cornerRadius: 999)
                .fill(isOn ? Color.logosGreen : Color.logosBG4)
                .frame(width: 51, height: 31)
                .overlay(alignment: isOn ? .trailing : .leading) {
                    Circle()
                        .fill(Color.white)
                        .frame(width: 27, height: 27)
                        .padding(2)
                        .shadow(color: .black.opacity(0.25), radius: 2, x: 0, y: 1)
                }
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(isOn ? "On" : "Off")
        .accessibilityHint(isEnabled ? "Double-tap to toggle" : "Unavailable")
        .accessibilityAddTraits(.isButton)
        .opacity(isEnabled ? 1 : 0.7)
    }
}

/// The full settings panel, extracted from `ContentView` (WS1 PR4a). Owns the editor-draft and
/// preference-mirror `@State` whose reads/writes are entirely contained in the settings UI, and
/// takes `@Binding`s for the cross-cutting mirrors that are also written from outside the panel:
/// `defaultInput` (read by the composer's right-pill gating), and `onDeviceSpeech`/`pushEnabled`
/// (pushed in by `AppCoordinator`'s derived-flags callback / connection-state handler).
struct SettingsOverlay: View {
    @Environment(LogosClient.self) private var client
    @Environment(NotificationCoordinator.self) private var notifications
    let voiceInput: VoiceInputController

    @Binding var defaultInput: String
    @Binding var onDeviceSpeech: Bool
    @Binding var pushEnabled: Bool
    let onClose: () -> Void

    @State private var editingAdapterURL = false
    @State private var adapterURLDraft = ""
    @State private var editingDeviceKey = false
    @State private var deviceKeyDraft = ""
    @State private var generatedDeviceKey: String?
    @State private var copiedDeviceKey = false
    @State private var expandedSettingsPicker: SettingsPickerKind?
    @State private var hermesProfile = "default"
    @State private var speakMode = "summary"
    @State private var notifyDone = true
    @State private var notifyApproval = true
    @State private var notifySummary = false

    @FocusState private var focusedField: FocusedField?

    var body: some View {
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
            .glassEffect(.regular, in: .rect)
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
                                        try? await Task.sleep(for: .milliseconds(1600))
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

    private func closeSettings() {
        editingAdapterURL = false
        editingDeviceKey = false
        deviceKeyDraft = ""
        generatedDeviceKey = nil
        copiedDeviceKey = false
        expandedSettingsPicker = nil
        focusedField = nil
        onClose()
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
