import SwiftUI
import Foundation
import OSLog

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

