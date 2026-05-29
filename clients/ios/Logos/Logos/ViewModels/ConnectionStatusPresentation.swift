import Foundation

/// View-layer projection of the connection state for the status UI (WS1 P6).
///
/// A pure, testable view-model: it keeps the switch-on-`LogosConnectionState` derivation out of
/// the ContentView body. It deliberately stays UI-framework-free — it returns a semantic
/// `Indicator` that the view maps to a SwiftUI `Color`, so the mapping is testable without
/// importing SwiftUI.
enum ConnectionStatusPresentation {
    /// Semantic status light, mapped to a concrete color by the view layer.
    enum Indicator: Equatable {
        case ok
        case pending
        case idle
        case error
    }

    static func title(for state: LogosConnectionState) -> String {
        switch state {
        case .connected: return "Connected"
        case .connecting: return "Connecting…"
        case .disconnected: return "Disconnected"
        case .error: return "Error"
        }
    }

    /// Label for the connect/disconnect action button.
    static func actionTitle(for state: LogosConnectionState) -> String {
        switch state {
        case .connected: return "Disconnect"
        case .connecting: return "Connecting…"
        case .disconnected, .error: return "Connect"
        }
    }

    static func indicator(for state: LogosConnectionState) -> Indicator {
        switch state {
        case .connected: return .ok
        case .connecting: return .pending
        case .disconnected: return .idle
        case .error: return .error
        }
    }
}
