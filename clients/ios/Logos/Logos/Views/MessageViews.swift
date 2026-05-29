import SwiftUI
import UIKit
import Foundation
import OSLog

struct ThinkingBubble: View {
    let text: String
    @State private var shimmerPhase = false

    var body: some View {
        HStack {
            Text(text)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.logosLabel3)
                .overlay {
                    LinearGradient(
                        colors: [Color.logosLabel3, Color.logosLabel, Color.logosLabel3],
                        startPoint: shimmerPhase ? .trailing : .leading,
                        endPoint: shimmerPhase ? .leading : .trailing
                    )
                    .mask(Text(text).font(.system(size: 13, weight: .medium)))
                }
                .onAppear {
                    withAnimation(.linear(duration: 2.4).repeatForever(autoreverses: false)) { shimmerPhase.toggle() }
                }
            Spacer(minLength: 48)
        }
        .padding(.horizontal, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Hermes: \(text)")
    }
}

struct ToolStrip: View {
    let label: String
    let detail: String

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(Color.logosLabel2)
            Text("·")
                .foregroundStyle(Color.logosLabel3)
            Text(detail)
                .font(.system(size: 12, weight: .regular, design: .monospaced))
                .foregroundStyle(Color.logosLabel3)
                .lineLimit(1)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.clear)
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.logosHairline, lineWidth: 0.5))
    }
}

struct ErrorStrip: View {
    let text: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(Color.logosRed)
            Text(text)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.logosRed)
                .lineLimit(3)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(Color.logosRed.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.logosRed.opacity(0.25), lineWidth: 0.5))
    }
}

struct ApprovalCardView: View {
    let approval: ApprovalCard
    let isPending: Bool
    let isConnected: Bool
    let onApprove: () -> Void
    let onDeny: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 7) {
                Image(systemName: "lock.shield")
                    .font(.system(size: 14, weight: .semibold))
                    .accessibilityHidden(true)
                Text("Hermes needs approval")
                    .font(.system(size: 12, weight: .bold))
                    .textCase(.uppercase)
            }
            .foregroundStyle(Color.logosAmber)
            .accessibilityElement(children: .combine)

            VStack(alignment: .leading, spacing: 5) {
                Text(approval.title)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Color.logosLabel)
                Text(approval.summary)
                    .font(.system(size: 14))
                    .foregroundStyle(Color.logosLabel2)
                Text("Project: \(approval.projectKey)")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color.logosLabel3)
            }

            if approval.commandPreview.isEmpty == false {
                CommandPreview(command: approval.commandPreview)
            }

            if approval.risk.isEmpty == false {
                HStack(spacing: 7) {
                    Image(systemName: "exclamationmark.triangle")
                    Text(approval.risk)
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.logosYellow)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.logosYellow.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
            }

            HStack(spacing: 10) {
                Button(isPending ? "Sent" : "Deny") { onDeny() }
                    .buttonStyle(SecondaryPillButtonStyle())
                    .disabled(!isConnected || isPending)
                Button(isPending ? "Waiting…" : "Approve") { onApprove() }
                    .buttonStyle(AmberPillButtonStyle())
                    .disabled(!isConnected || isPending)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.logosBG2, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22).stroke(Color.logosAmber.opacity(0.28), lineWidth: 0.7))
        .shadow(color: .black.opacity(0.25), radius: 18, x: 0, y: 8)
    }
}

struct ClarifyCardView: View {
    let clarify: ClarifyCard
    @Binding var answer: String
    let isPending: Bool
    let isConnected: Bool
    var focused: FocusState<FocusedField?>.Binding
    let onChoice: (String) -> Void
    let onFreeText: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 7) {
                Image(systemName: "questionmark.circle")
                    .font(.system(size: 14, weight: .semibold))
                    .accessibilityHidden(true)
                Text("Clarification")
                    .font(.system(size: 12, weight: .bold))
                    .textCase(.uppercase)
            }
            .foregroundStyle(Color.logosTeal)
            .accessibilityElement(children: .combine)

            Text(clarify.question)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Color.logosLabel)
            Text("Project: \(clarify.projectKey)")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(Color.logosLabel3)

            VStack(spacing: 6) {
                ForEach(clarify.choices, id: \.self) { choice in
                    Button {
                        onChoice(choice)
                    } label: {
                        HStack {
                            Text(choice)
                                .font(.system(size: 14, weight: .semibold, design: .monospaced))
                            Spacer()
                        }
                        .foregroundStyle(Color.logosLabel)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(Color.logosBG3.opacity(0.55), in: RoundedRectangle(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.logosHairline, lineWidth: 0.5))
                    }
                    .buttonStyle(.plain)
                    .disabled(!isConnected || isPending)
                }
            }

            if clarify.allowFreeText {
                HStack(spacing: 8) {
                    TextField("Answer", text: $answer)
                        .accessibilityIdentifier("clarifyAnswerField")
                        .focused(focused, equals: .clarifyAnswer)
                        .font(.system(size: 14))
                        .foregroundStyle(Color.logosLabel)
                        .submitLabel(.send)
                        .onSubmit(onFreeText)
                        .padding(.horizontal, 12)
                        .frame(height: 40)
                        .background(Color.logosBG1, in: RoundedRectangle(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.logosHairline, lineWidth: 0.5))
                        .disabled(!isConnected || isPending)
                    Button(isPending ? "Sent" : "Send") { onFreeText() }
                        .buttonStyle(AmberChipButtonStyle())
                        .disabled(!isConnected || isPending || answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.logosBG2, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22).stroke(Color.logosTeal.opacity(0.28), lineWidth: 0.7))
        .shadow(color: .black.opacity(0.25), radius: 18, x: 0, y: 8)
    }
}

struct CommandPreview: View {
    let command: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("cwd · current project")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(Color.logosLabel3)
            Text(command)
                .font(.system(size: 12.5, weight: .medium, design: .monospaced))
                .foregroundStyle(Color.logosLabel)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .background(Color.black, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.logosHairline, lineWidth: 0.5))
    }
}

