import SwiftUI
import Foundation
import OSLog

struct AudioPlaybackOverlayView: View {
    let overlay: AudioPlaybackOverlayState
    let onPauseResume: () -> Void
    let onStop: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            SpectrumAnalyzerView(bins: overlay.spectrumBins, isActive: overlay.phase == .playing)
                .frame(width: 92, height: 34)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.logosLabel)
                Text(overlay.detail)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color.logosLabel3)
                    .lineLimit(1)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(overlay.detail.isEmpty ? title : "\(title), \(overlay.detail)")

            Spacer(minLength: 8)

            Button(action: onPauseResume) {
                Image(systemName: overlay.phase == .paused ? "play.fill" : "pause.fill")
                    .font(.system(size: 13, weight: .bold))
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.logosAmberOn)
            .background(Color.logosAmber, in: Circle())
            .disabled(!overlay.canPause && overlay.phase != .paused)
            .opacity((overlay.canPause || overlay.phase == .paused) ? 1 : 0.45)
            .accessibilityIdentifier("audioOverlayPauseButton")
            .accessibilityLabel(overlay.phase == .paused ? "Resume audio" : "Pause audio")

            Button(action: onStop) {
                Image(systemName: "stop.fill")
                    .font(.system(size: 12, weight: .bold))
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.white)
            .background(Color.logosRed, in: Circle())
            .disabled(!overlay.canStop)
            .opacity(overlay.canStop ? 1 : 0.45)
            .accessibilityIdentifier("audioOverlayStopButton")
            .accessibilityLabel("Stop audio")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.logosGlass.opacity(0.96), in: RoundedRectangle(cornerRadius: 18))
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.logosHairline, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.28), radius: 16, x: 0, y: 8)
        .accessibilityIdentifier("audioPlaybackOverlay")
        // The overlay is a tightly packed horizontal pill (spectrum + status text +
        // two fixed circular controls). Let the status text scale for accessibility,
        // but clamp the largest sizes so the row does not break its fixed geometry.
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
    }

    private var title: String {
        switch overlay.phase {
        case .requesting:
            return "Preparing audio"
        case .receiving:
            return "Receiving audio"
        case .playing:
            return "Audio playing"
        case .paused:
            return "Audio paused"
        case .finished:
            return "Audio finished"
        case .failed:
            return "Audio failed"
        }
    }
}

/// Hosts the audio-playback overlay as its own observation scope: it is the only view that reads
/// `client.audioPlaybackOverlay`, so the ~20fps spectrum updates during playback invalidate just
/// this layer instead of re-evaluating all of `ContentView`'s body.
struct AudioOverlayLayer: View {
    @Environment(LogosClient.self) private var client

    var body: some View {
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
        }
    }
}

struct SpectrumAnalyzerView: View {
    let bins: [Double]
    let isActive: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 3) {
            ForEach(Array(bins.enumerated()), id: \.offset) { _, value in
                Capsule()
                    .fill(Color.logosAmber.opacity(isActive ? 0.95 : 0.45))
                    .frame(width: 4, height: max(4, CGFloat(value) * 28))
                    .animation(.easeOut(duration: 0.05), value: value)
            }
        }
        .frame(maxHeight: .infinity)
    }
}

