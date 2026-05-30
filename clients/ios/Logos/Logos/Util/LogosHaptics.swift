import UIKit

/// Thin, no-op-safe wrapper around `UIImpactFeedbackGenerator` for the small set
/// of tactile moments Logos cares about. Each call prepares and fires a fresh
/// generator so callers never have to manage generator lifetime, and the
/// feedback gracefully does nothing on devices without a Taptic Engine.
/// `@MainActor` because `UIImpactFeedbackGenerator` is main-actor-isolated (UIKit).
@MainActor
enum LogosHaptics {
    /// Fired on the idle → recording transition when voice capture begins.
    static func recordStart() {
        impact(.medium)
    }

    /// Fired on the recording → idle transition when voice capture ends.
    static func recordStop() {
        impact(.light)
    }

    private static func impact(_ style: UIImpactFeedbackGenerator.FeedbackStyle) {
        let generator = UIImpactFeedbackGenerator(style: style)
        generator.prepare()
        generator.impactOccurred()
    }
}
