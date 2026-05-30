import SwiftUI
import Foundation
import OSLog

struct ProjectRowView: View {
    let project: LogosProject
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(project.title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.logosLabel)
                    .lineLimit(1)
                Text(project.lastPreview ?? project.projectKey)
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(Color.logosLabel3)
                    .lineLimit(1)
            }
            Spacer()
            if isSelected {
                Image(systemName: "checkmark")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Color.logosAmber)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(isSelected ? Color.logosAmberSoft2 : Color.logosBG2.opacity(0.56), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(isSelected ? Color.logosAmber.opacity(0.55) : Color.logosHairline, lineWidth: 0.7))
    }
}

struct AttachRow: View {
    let icon: String
    let title: String
    let detail: String
    var isLast = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .settingsIcon()
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.logosLabel)
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.logosLabel3)
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .opacity(0.62)
        .overlay(alignment: .bottom) {
            if !isLast {
                Rectangle().fill(Color.logosHairline).frame(height: 0.5).padding(.leading, 44)
            }
        }
    }
}

struct SlashCommandRow: View {
    let command: SlashCommandSpec
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: command.available ? "terminal" : "lock.slash")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(command.available ? Color.logosAmber : Color.logosLabel3)
                    .frame(width: 24, height: 24)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(command.canonical)
                            .font(.system(size: 14, weight: .semibold, design: .monospaced))
                            .foregroundStyle(command.available ? Color.logosLabel : Color.logosLabel3)
                            .lineLimit(1)
                        Text(command.description)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Color.logosLabel2)
                            .lineLimit(1)
                    }
                    Text(secondaryText)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(command.available ? Color.logosLabel3 : Color.logosAmber)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(isSelected ? Color.logosAmberSoft2 : Color.logosBG2.opacity(0.58), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(isSelected ? Color.logosAmber.opacity(0.5) : Color.logosHairline, lineWidth: 0.6))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("slashCommandRow.\(command.canonical)")
        .accessibilityLabel("\(command.canonical), \(command.description)")
        .accessibilityHint(command.available ? "Completes this slash command" : command.unavailableReason)
    }

    private var secondaryText: String {
        if command.available == false, command.unavailableReason.isEmpty == false {
            return command.unavailableReason
        }
        let usage = command.argsHint.isEmpty ? command.category : "\(command.argsHint) · \(command.category)"
        let aliases = command.aliases.isEmpty ? "" : " · \(command.aliases.joined(separator: ", "))"
        return "\(usage) · \(command.source)\(aliases)"
    }
}

struct SlashCommandCompletionRow: View {
    let item: SlashCommandCompletionItem
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: "arrow.turn.down.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.logosAmber)
                    .frame(width: 24, height: 24)
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.display)
                        .font(.system(size: 14, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Color.logosLabel)
                        .lineLimit(1)
                    Text(item.detail.isEmpty ? item.canonical : item.detail)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.logosLabel3)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Color.logosBG2.opacity(0.58), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.logosHairline, lineWidth: 0.6))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("slashCompletionRow.\(item.display)")
        .accessibilityLabel(item.display)
        .accessibilityHint("Completes this slash command argument")
    }
}

