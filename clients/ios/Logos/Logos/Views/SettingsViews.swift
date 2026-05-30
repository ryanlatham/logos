import SwiftUI
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
