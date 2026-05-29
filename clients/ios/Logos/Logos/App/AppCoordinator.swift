import SwiftUI

/// Owns the app-lifecycle orchestration that used to live as glue inside `ContentView`
/// (WS1 P6). This is intentionally *not* a view-state holder: the 46 `@State` props that
/// drive the composer/thread UI stay on `ContentView`. `AppCoordinator` only holds the
/// long-lived collaborators (`LogosClient`, `VoiceInputController`, `NotificationCoordinator`)
/// and runs the reactive lifecycle reactions — scene-phase changes, incoming URLs, and the
/// connection-state transition — that are primarily collaborator calls.
///
/// The few places this orchestration must touch `ContentView` state (e.g. the derived
/// `onDeviceSpeech`/`pushEnabled` flags, or handing a final voice transcript back to the
/// composer) are expressed as closures injected via `attach`, so the @State stays in the view.
@MainActor
final class AppCoordinator: ObservableObject {
    private var client: LogosClient?
    private var voiceInput: VoiceInputController?
    private var notifications: NotificationCoordinator?

    /// Forwards a finalized voice transcript to `ContentView`, which decides whether it was
    /// sent or needs to fall back into the text composer. Mirrors the old
    /// `handleFinalVoiceTranscript(text:inputID:partialSeq:startedAt:)` callback.
    private var onVoiceFinal: ((String, String, Int, Int64) -> Bool)?

    /// Pushes runtime-derived flags (`onDeviceSpeech`, `pushEnabled`) back into `ContentView`
    /// @State so the settings UI reflects voice availability / push authorization.
    private var onDerivedFlags: ((_ onDeviceSpeech: Bool, _ pushEnabled: Bool) -> Void)?

    /// Captures the collaborators and the `ContentView` write-back closures. No side effects:
    /// the actual runtime wiring is performed by `start()` / `activateInputs()` so the call
    /// site can preserve the exact original `configureRuntime` ordering.
    func attach(
        client: LogosClient,
        voiceInput: VoiceInputController,
        notifications: NotificationCoordinator,
        onVoiceFinal: @escaping (String, String, Int, Int64) -> Bool,
        onDerivedFlags: @escaping (_ onDeviceSpeech: Bool, _ pushEnabled: Bool) -> Void
    ) {
        self.client = client
        self.voiceInput = voiceInput
        self.notifications = notifications
        self.onVoiceFinal = onVoiceFinal
        self.onDerivedFlags = onDerivedFlags
    }

    /// First half of the launch wiring (matches the head of the old `configureRuntime`):
    /// environment-driven connect, voice transcript callbacks, and APNS device-token routing
    /// including replay of an already-known token.
    func start() {
        guard let client, let voiceInput, let notifications else { return }
        client.connectIfRequestedByEnvironment()
        voiceInput.configureCallbacks(
            partial: { [weak self] text, inputID, partialSeq, startedAt in
                self?.client?.sendSpeech(text: text, isFinal: false, inputID: inputID, partialSeq: partialSeq, startedAtMilliseconds: startedAt)
            },
            final: { [weak self] text, inputID, partialSeq, startedAt in
                self?.onVoiceFinal?(text, inputID, partialSeq, startedAt) ?? false
            }
        )
        notifications.onDeviceToken = { [weak self] token in
            self?.client?.registerDevice(apnsToken: token)
        }
        if let token = notifications.deviceToken {
            client.registerDevice(apnsToken: token)
        }
    }

    /// Second half of the launch wiring (matches the tail of the old `configureRuntime`):
    /// voice availability refresh, transport availability seed, and the derived UI flags.
    /// Called after `ContentView` seeds scene activation and wires `notifications.onRoute`,
    /// so the original ordering is preserved end to end.
    func activateInputs() {
        guard let client, let voiceInput, let notifications else { return }
        voiceInput.refreshAvailability()
        voiceInput.updateTransportAvailable(client.connectionState == .connected)
        onDerivedFlags?(voiceInput.voiceEnabled, notifications.authorizationStatus.contains("allowed"))
    }

    /// Scene-phase reaction (was the `.onChange(of: scenePhase)` body). Keeps playback scene
    /// activation in sync and pauses/resumes audio for background/active transitions, plus the
    /// auto-connect + command-catalog refresh on resume.
    func handleScenePhaseChange(isActive: Bool, isBackgroundOrInactive: Bool) {
        guard let client else { return }
        client.updateSceneActivationForPlayback(isActive: isActive)
        if isActive {
            client.resumeAudioForSceneActive()
            client.connectIfAutoConnectEnabled()
            client.requestCommandCatalog()
        } else if isBackgroundOrInactive {
            client.pauseAudioForSceneBackground()
        }
    }

    /// Connection-state reaction (was the `.onChange(of: client.connectionState)` body).
    /// Updates voice transport availability and, on connect, refreshes the command catalog.
    /// The derived push flag is reported through `onPushEnabled` so it lands in `ContentView`
    /// @State.
    func handleConnectionStateChange(_ newState: LogosConnectionState, onPushEnabled: (Bool) -> Void) {
        guard let client, let voiceInput, let notifications else { return }
        voiceInput.updateTransportAvailable(newState == .connected)
        if newState == .connected {
            onPushEnabled(notifications.authorizationStatus.contains("allowed"))
            client.requestCommandCatalog()
        }
    }

    /// URL-open reaction (was the `.onOpenURL` body). Pairing routes are returned to the caller
    /// so `ContentView` can stage the confirmation alert via its `pendingPairingRoute` @State;
    /// notification routes are dispatched straight through the notification coordinator.
    @discardableResult
    func handleURL(_ url: URL) -> LogosPairingRoute? {
        if let route = LogosPairingRoute.from(url: url) {
            return route
        }
        if let route = LogosNotificationRoute.from(url: url) {
            notifications?.route(route)
        }
        return nil
    }
}
