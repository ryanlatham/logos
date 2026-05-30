import Foundation
import Observation

/// Client-side dependencies the audio-playback subsystem needs from its owner (WS1 P5). The
/// `AudioCoordinator` reaches back through this narrow seam instead of holding the whole
/// `LogosClient`, so the audio domain stays decoupled from connection/notification state. The host
/// is held `weak`; every member is a no-op-safe call the coordinator routes non-audio work through.
@MainActor
protocol AudioCoordinatorHost: AnyObject {
    /// The device id stamped onto outbound playback frames and matched on inbound audio frames.
    var audioDeviceID: String { get }
    /// The active project key audio frames are scoped to.
    var audioActiveProjectKey: String { get }
    /// Gate a user-facing playback action on the connection being live (mirrors the client's
    /// `ensureConnectedForUserAction`, including its error side effect when not connected).
    @discardableResult func ensureAudioConnected(_ action: String) -> Bool
    /// Send a playback frame over the socket (mirrors `LogosClient.sendFrame`'s default-auth path).
    @discardableResult func sendAudioFrame(_ frame: [String: Any], onCompletion: (@MainActor @Sendable (Result<Void, Error>) -> Void)?) async -> Bool
    /// Extract a non-empty `project_key` from an inbound frame root.
    func audioFrameProjectKey(_ root: [String: Any]) -> String?
    /// Surface a playback error: the client clears the transient ack and records it under `.audio`.
    func recordAudioPlaybackError(_ message: String)
    /// Release a notification auto-play key the client owns (`autoPlayedMessageKeys.remove`).
    func clearAutoPlayedMessageKey(_ key: String)
    /// Release a fulfilled notification-route key the client owns (`fulfilledNotificationRouteKeys.remove`).
    func clearFulfilledNotificationRouteKey(_ key: String)
}

/// Owns the audio-playback subsystem lifted out of `LogosClient` (WS1 P5): the published overlay +
/// status, the in-flight/stopped/active id bookkeeping, the spectrum-animation and stream-timeout
/// collaborators, and the injected playback engine. `LogosClient` keeps a reference and re-exposes
/// `audioPlaybackOverlay`/`playbackStatus` via computed forwarding so views/tests are unchanged.
/// All client-side dependencies are routed through `host` (held `weak`).
@MainActor
@Observable
final class AudioCoordinator {
    private(set) var audioPlaybackOverlay: AudioPlaybackOverlayState?
    var playbackStatus: String?

    @ObservationIgnored weak var host: AudioCoordinatorHost?

    private let audioPlayback: AudioPlaybackController
    private var requestedAudioIDs = Set<String>()
    private var stoppedAudioIDs = Set<String>()
    private var activeAudioID: String?
    private let spectrumAnimator = SpectrumAnimator()
    private var playbackAutoPlayKeysByAudioID: [String: String] = [:]
    private var playbackNotificationRouteKeysByAudioID: [String: String] = [:]
    private let streamTimeout = PlaybackStreamTimeout()

    private static let stoppedAudioIDRetentionLimit = 128

    init(audioPlayback: AudioPlaybackController) {
        self.audioPlayback = audioPlayback
        audioPlayback.onPlaybackFinished = { [weak self] audioID, succeeded in
            Task { @MainActor in
                guard let self, self.activeAudioID == audioID else { return }
                self.stopSpectrumUpdates(audioID: audioID)
                self.activeAudioID = nil
                self.requestedAudioIDs.remove(audioID)
                self.rememberStoppedAudioID(audioID)
                self.cancelAudioPlaybackStreamTimeout(audioID: audioID)
                if succeeded {
                    self.clearPlaybackRetryKeys(audioID: audioID, allowRetry: false)
                    self.updateAudioOverlay(
                        audioID: audioID,
                        phase: .finished,
                        detail: "Audio finished",
                        canPause: false,
                        canStop: false,
                        spectrumBins: Array(repeating: 0.12, count: 12)
                    )
                    self.playbackStatus = "Audio finished"
                    Task { @MainActor [weak self] in
                        try? await Task.sleep(nanoseconds: 3_000_000_000)
                        guard let self else { return }
                        if self.audioPlaybackOverlay?.audioID == audioID,
                           self.audioPlaybackOverlay?.phase == .finished {
                            self.audioPlaybackOverlay = nil
                            self.playbackStatus = nil
                        }
                    }
                } else {
                    self.failAudioPlayback(
                        audioID: audioID,
                        message: "Audio playback ended unexpectedly. Check device volume and output route."
                    )
                }
            }
        }
    }

    func playback(message: LogosMessage) async {
        _ = await requestPlayback(message: message, mode: "full")
    }

    func pausePlayback() {
        guard let audioID = audioPlaybackOverlay?.audioID ?? activeAudioID else { return }
        guard audioPlayback.pause(audioID: audioID) else { return }
        stopSpectrumUpdates(audioID: audioID)
        activeAudioID = audioID
        updateAudioOverlay(audioID: audioID, phase: .paused, detail: "Paused", canPause: false, canStop: true)
        playbackStatus = nil
    }

    func resumePlayback() {
        guard let audioID = audioPlaybackOverlay?.audioID ?? activeAudioID else { return }
        do {
            guard try audioPlayback.resume(audioID: audioID) else { return }
            activeAudioID = audioID
            updateAudioOverlay(audioID: audioID, phase: .playing, detail: "Playing", canPause: true, canStop: true)
            startSpectrumUpdates(audioID: audioID)
            playbackStatus = nil
        } catch {
            failAudioPlayback(audioID: audioID, message: error.localizedDescription)
        }
    }

    func stopPlayback() {
        guard let audioID = audioPlaybackOverlay?.audioID ?? activeAudioID else { return }
        stoppedAudioIDs.insert(audioID)
        requestedAudioIDs.remove(audioID)
        stopSpectrumUpdates(audioID: audioID)
        cancelAudioPlaybackStreamTimeout(audioID: audioID)
        clearPlaybackRetryKeys(audioID: audioID, allowRetry: false)
        _ = audioPlayback.stop(audioID: audioID)
        if activeAudioID == audioID { activeAudioID = nil }
        audioPlaybackOverlay = nil
        playbackStatus = nil
    }

    func pauseAudioForSceneBackground() {
        let snapshots = audioPlayback.pauseForLifecycle(reason: "scene_background")
        guard let snapshot = snapshots.first else { return }
        stopSpectrumUpdates(audioID: snapshot.audioID)
        activeAudioID = snapshot.audioID
        updateAudioOverlay(audioID: snapshot.audioID, phase: .paused, detail: "Paused", canPause: false, canStop: true)
        playbackStatus = nil
    }

    func resumeAudioForSceneActive() {
        do {
            let results = try audioPlayback.resumeAfterLifecycle()
            guard let result = results.first, result.started else { return }
            activeAudioID = result.audioID
            updateAudioOverlay(audioID: result.audioID, phase: .playing, detail: "Playing", canPause: true, canStop: true)
            startSpectrumUpdates(audioID: result.audioID)
            playbackStatus = nil
        } catch {
            if let audioID = activeAudioID ?? audioPlaybackOverlay?.audioID {
                failAudioPlayback(audioID: audioID, message: error.localizedDescription)
            } else {
                recordAudioPlaybackError(error.localizedDescription)
            }
        }
    }

    @discardableResult
    func requestPlayback(message: LogosMessage, mode: String, autoPlayKey: String? = nil, notificationRouteKey: String? = nil) async -> Bool {
        guard message.isProgressUpdate == false else { return false }
        guard host?.ensureAudioConnected("play audio") == true else { return false }
        let audioID = "ios-\(UUID().uuidString)"
        return await requestPlaybackAudio(
            audioID: audioID,
            projectKey: message.projectKey,
            sessionID: message.sessionID,
            messageID: message.messageID,
            mode: mode,
            text: message.content,
            autoPlayKey: autoPlayKey,
            notificationRouteKey: notificationRouteKey
        )
    }

    @discardableResult
    private func requestPlaybackAudio(audioID: String, projectKey: String, sessionID: String?, messageID: String?, mode: String, text: String, autoPlayKey: String? = nil, notificationRouteKey: String? = nil) async -> Bool {
        prepareForNewPlaybackRequest(audioID: audioID)
        requestedAudioIDs.insert(audioID)
        stoppedAudioIDs.remove(audioID)
        audioPlaybackOverlay = AudioPlaybackOverlayState(
            audioID: audioID,
            messageID: messageID,
            projectKey: projectKey,
            phase: .requesting,
            detail: "Requesting audio",
            spectrumBins: idleSpectrumBins(),
            canPause: false,
            canStop: true
        )
        playbackStatus = "Requesting audio"
        var payload: [String: Any] = [
            "audio_id": audioID,
            "mode": mode,
            "text": text
        ]
        if let messageID { payload["message_id"] = messageID }
        // Record the retry-key bookkeeping + stream watchdog *before* awaiting the send: the inline
        // send/failure callback now resolves within `await sendAudioFrame`, and the failure handler
        // tears these down (releasing the auto-play / route keys for retry), so they must already be
        // in place. A pre-send validation failure (`sent == false`) rolls them back below.
        if let autoPlayKey {
            playbackAutoPlayKeysByAudioID[audioID] = autoPlayKey
        }
        if let notificationRouteKey {
            playbackNotificationRouteKeysByAudioID[audioID] = notificationRouteKey
        }
        scheduleAudioPlaybackStreamTimeout(audioID: audioID)
        let sent = await host?.sendAudioFrame([
            "type": "playback_audio",
            "request_id": UUID().uuidString,
            "device_id": host?.audioDeviceID ?? "",
            "project_key": projectKey,
            "session_id": sessionID ?? "project:\(projectKey)",
            "payload": payload
        ]) { [weak self] result in
            guard case .failure = result else { return }
            if let autoPlayKey {
                self?.host?.clearAutoPlayedMessageKey(autoPlayKey)
            }
            if let notificationRouteKey {
                self?.host?.clearFulfilledNotificationRouteKey(notificationRouteKey)
            }
            self?.clearFailedPlaybackRequest(audioID: audioID)
        } ?? false
        if sent == false {
            // Pre-send validation failed (the inline failure callback never ran): roll back.
            if let autoPlayKey {
                host?.clearAutoPlayedMessageKey(autoPlayKey)
            }
            if let notificationRouteKey {
                host?.clearFulfilledNotificationRouteKey(notificationRouteKey)
            }
            clearPlaybackRetryKeys(audioID: audioID, allowRetry: false)
            cancelAudioPlaybackStreamTimeout(audioID: audioID)
            stoppedAudioIDs.insert(audioID)
            requestedAudioIDs.remove(audioID)
            if audioPlaybackOverlay?.audioID == audioID {
                audioPlaybackOverlay = nil
            }
            playbackStatus = nil
        }
        return sent
    }

    private func markStopped(_ audioID: String?) {
        guard let audioID, audioID.isEmpty == false else { return }
        stoppedAudioIDs.insert(audioID)
    }

    private func clearFailedPlaybackRequest(audioID: String) {
        stoppedAudioIDs.insert(audioID)
        requestedAudioIDs.remove(audioID)
        stopSpectrumUpdates(audioID: audioID)
        cancelAudioPlaybackStreamTimeout(audioID: audioID)
        clearPlaybackRetryKeys(audioID: audioID, allowRetry: true)
        if activeAudioID == audioID {
            activeAudioID = nil
        }
        if audioPlaybackOverlay?.audioID == audioID {
            audioPlaybackOverlay = nil
        }
        playbackStatus = nil
    }

    private func failAudioPlayback(audioID: String, message: String, exposeError: Bool = true) {
        rememberStoppedAudioID(audioID)
        requestedAudioIDs.remove(audioID)
        stopSpectrumUpdates(audioID: audioID)
        cancelAudioPlaybackStreamTimeout(audioID: audioID)
        clearPlaybackRetryKeys(audioID: audioID, allowRetry: true)
        _ = audioPlayback.stop(audioID: audioID)
        if activeAudioID == audioID {
            activeAudioID = nil
        }
        if audioPlaybackOverlay?.audioID == audioID {
            updateAudioOverlay(audioID: audioID, phase: .failed, detail: message, canPause: false, canStop: false, spectrumBins: idleSpectrumBins())
            scheduleFailedAudioOverlayDismissal(audioID: audioID)
        }
        playbackStatus = nil
        if exposeError {
            recordAudioPlaybackError(message)
        }
    }

    private func clearPlaybackRetryKeys(audioID: String, allowRetry: Bool) {
        let autoPlayKey = playbackAutoPlayKeysByAudioID.removeValue(forKey: audioID)
        let notificationRouteKey = playbackNotificationRouteKeysByAudioID.removeValue(forKey: audioID)
        guard allowRetry else { return }
        if let autoPlayKey {
            host?.clearAutoPlayedMessageKey(autoPlayKey)
        }
        if let notificationRouteKey {
            host?.clearFulfilledNotificationRouteKey(notificationRouteKey)
        }
    }

    private func scheduleFailedAudioOverlayDismissal(audioID: String) {
        Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: 6_000_000_000)
            } catch {
                return
            }
            guard let self,
                  self.audioPlaybackOverlay?.audioID == audioID,
                  self.audioPlaybackOverlay?.phase == .failed
            else { return }
            self.audioPlaybackOverlay = nil
            self.playbackStatus = nil
        }
    }

    private func scheduleAudioPlaybackStreamTimeout(audioID: String) {
        streamTimeout.schedule(audioID: audioID) { [weak self] id in
            self?.handleStreamTimeoutFired(audioID: id)
        }
    }

    private func cancelAudioPlaybackStreamTimeout(audioID: String? = nil) {
        streamTimeout.cancel(audioID: audioID)
    }

    /// Watchdog fired: fail the stream only if it's still mid-request/receive for this id.
    private func handleStreamTimeoutFired(audioID: String) {
        guard requestedAudioIDs.contains(audioID),
              audioPlaybackOverlay?.audioID == audioID
        else { return }
        switch audioPlaybackOverlay?.phase {
        case .requesting, .receiving:
            failAudioPlayback(audioID: audioID, message: "Audio stream timed out.")
        default:
            break
        }
    }

    private func recordAudioPlaybackError(_ message: String) {
        host?.recordAudioPlaybackError(message)
    }

    private func prepareForNewPlaybackRequest(audioID: String) {
        stopSpectrumUpdates()
        for requestedID in requestedAudioIDs where requestedID != audioID {
            stoppedAudioIDs.insert(requestedID)
            clearPlaybackRetryKeys(audioID: requestedID, allowRetry: false)
        }
        if audioPlaybackOverlay?.audioID != audioID {
            markStopped(audioPlaybackOverlay?.audioID)
            if let overlayAudioID = audioPlaybackOverlay?.audioID {
                clearPlaybackRetryKeys(audioID: overlayAudioID, allowRetry: false)
            }
        }
        if activeAudioID != audioID {
            markStopped(activeAudioID)
            if let activeAudioID {
                clearPlaybackRetryKeys(audioID: activeAudioID, allowRetry: false)
            }
        }
        audioPlayback.stopAll()
        requestedAudioIDs.removeAll()
        activeAudioID = nil
        cancelAudioPlaybackStreamTimeout()
    }

    func clearAudioPlaybackForProjectSwitch() {
        stopSpectrumUpdates()
        for requestedID in requestedAudioIDs {
            stoppedAudioIDs.insert(requestedID)
            clearPlaybackRetryKeys(audioID: requestedID, allowRetry: false)
        }
        markStopped(audioPlaybackOverlay?.audioID)
        if let overlayAudioID = audioPlaybackOverlay?.audioID {
            clearPlaybackRetryKeys(audioID: overlayAudioID, allowRetry: false)
        }
        markStopped(activeAudioID)
        if let activeAudioID {
            clearPlaybackRetryKeys(audioID: activeAudioID, allowRetry: false)
        }
        audioPlayback.stopAll()
        requestedAudioIDs.removeAll()
        activeAudioID = nil
        cancelAudioPlaybackStreamTimeout()
        audioPlaybackOverlay = nil
        playbackStatus = nil
    }

    private func updateAudioOverlay(audioID: String, phase: AudioPlaybackPhase, detail: String, canPause: Bool, canStop: Bool, spectrumBins: [Double]? = nil) {
        guard var overlay = audioPlaybackOverlay, overlay.audioID == audioID else { return }
        overlay.phase = phase
        overlay.detail = detail
        overlay.canPause = canPause
        overlay.canStop = canStop
        overlay.spectrumBins = spectrumBins ?? audioPlayback.spectrumBins(audioID: audioID, count: 12)
        audioPlaybackOverlay = overlay
    }

    private func idleSpectrumBins(count: Int = 12) -> [Double] {
        Array(repeating: 0.04, count: max(1, count))
    }

    private func startSpectrumUpdates(audioID: String) {
        spectrumAnimator.start(audioID: audioID) { [weak self] id in
            self?.refreshPlaybackSpectrum(audioID: id)
        }
    }

    private func stopSpectrumUpdates(audioID: String? = nil) {
        spectrumAnimator.stop(audioID: audioID)
    }

    func refreshPlaybackSpectrumForTesting(audioID: String) {
        refreshPlaybackSpectrum(audioID: audioID)
    }

    private func refreshPlaybackSpectrum(audioID: String) {
        guard activeAudioID == audioID,
              stoppedAudioIDs.contains(audioID) == false,
              var overlay = audioPlaybackOverlay,
              overlay.audioID == audioID,
              overlay.phase == .playing
        else { return }
        overlay.spectrumBins = audioPlayback.spectrumBins(audioID: audioID, count: 12)
        audioPlaybackOverlay = overlay
    }

    /// Fail or quietly retire any in-flight remote audio when the socket drops (called from the
    /// client's socket-failure path). Mirrors the former `LogosClient.failInterruptedRemoteAudioStream`.
    func failInterruptedRemoteAudioStream() {
        if let overlay = audioPlaybackOverlay {
            switch overlay.phase {
            case .requesting, .receiving:
                failAudioPlayback(
                    audioID: overlay.audioID,
                    message: "Audio stream interrupted. Reconnect and try again.",
                    exposeError: false
                )
                return
            default:
                break
            }
        }
        let interruptedAudioIDs = requestedAudioIDs.filter { $0 != activeAudioID }
        for audioID in interruptedAudioIDs {
            rememberStoppedAudioID(audioID)
            clearPlaybackRetryKeys(audioID: audioID, allowRetry: true)
            requestedAudioIDs.remove(audioID)
        }
        cancelAudioPlaybackStreamTimeout()
    }

    /// A `fast_ack` carried an `audio_id`: the stream is live again, so un-stop and re-arm it
    /// (called from the client's `state_update` handling).
    func noteFastAckAudioID(_ audioID: String) {
        guard audioID.isEmpty == false else { return }
        stoppedAudioIDs.remove(audioID)
        requestedAudioIDs.insert(audioID)
    }

    func handleAudioChunk(_ root: [String: Any]) {
        guard
            let payload = root["payload"] as? [String: Any],
            let audioID = payload["audio_id"] as? String,
            let data = payload["data"] as? String
        else { return }
        guard shouldAcceptAudioFrame(root, audioID: audioID) else {
            guard stoppedAudioIDs.contains(audioID) == false else { return }
            if audioPlaybackOverlay?.audioID == audioID {
                failAudioPlayback(audioID: audioID, message: "Audio stream no longer matches this conversation.")
            }
            return
        }
        guard let chunkIndex = audioChunkIndex(from: payload) else {
            failAudioPlayback(audioID: audioID, message: AudioPlaybackError.invalidChunkIndex.localizedDescription)
            return
        }
        do {
            requestedAudioIDs.insert(audioID)
            try audioPlayback.appendChunk(audioID: audioID, chunkIndex: chunkIndex, base64: data)
            updateAudioOverlay(audioID: audioID, phase: .receiving, detail: "Receiving audio", canPause: false, canStop: true, spectrumBins: idleSpectrumBins())
            scheduleAudioPlaybackStreamTimeout(audioID: audioID)
            playbackStatus = "Receiving audio"
        } catch {
            requestedAudioIDs.remove(audioID)
            failAudioPlayback(audioID: audioID, message: error.localizedDescription)
        }
    }

    private func audioChunkIndex(from payload: [String: Any]) -> Int? {
        if let index = payload["chunk_index"] as? Int {
            return index
        }
        if let rawIndex = payload["chunk_index"] as? String {
            return Int(rawIndex)
        }
        return nil
    }

    func handleAudioEnd(_ root: [String: Any]) {
        guard
            let payload = root["payload"] as? [String: Any],
            let audioID = payload["audio_id"] as? String
        else { return }
        guard shouldAcceptAudioFrame(root, audioID: audioID) else {
            guard stoppedAudioIDs.contains(audioID) == false else { return }
            if audioPlaybackOverlay?.audioID == audioID {
                failAudioPlayback(audioID: audioID, message: "Audio stream ended for a different conversation.")
            }
            return
        }
        let chunkCount = payload["chunk_count"] as? Int ?? Int(payload["chunk_count"] as? String ?? "")
        do {
            let result = try audioPlayback.finish(audioID: audioID, expectedChunkCount: chunkCount)
            requestedAudioIDs.remove(audioID)
            cancelAudioPlaybackStreamTimeout(audioID: audioID)
            activeAudioID = audioID
            updateAudioOverlay(audioID: audioID, phase: .playing, detail: "Playing", canPause: true, canStop: true)
            startSpectrumUpdates(audioID: audioID)
            playbackStatus = result.started ? "Playing audio" : "Audio did not start"
        } catch {
            requestedAudioIDs.remove(audioID)
            failAudioPlayback(audioID: audioID, message: error.localizedDescription)
        }
    }

    private func rememberStoppedAudioID(_ audioID: String) {
        stoppedAudioIDs.insert(audioID)
        if stoppedAudioIDs.count > Self.stoppedAudioIDRetentionLimit {
            stoppedAudioIDs.subtract(stoppedAudioIDs.sorted().prefix(stoppedAudioIDs.count - Self.stoppedAudioIDRetentionLimit))
        }
    }

    private func shouldAcceptAudioFrame(_ root: [String: Any], audioID: String) -> Bool {
        guard stoppedAudioIDs.contains(audioID) == false else { return false }
        if let frameDeviceID = root["device_id"] as? String, frameDeviceID.isEmpty == false {
            guard frameDeviceID == host?.audioDeviceID else { return false }
        }
        if let projectKey = host?.audioFrameProjectKey(root), projectKey != host?.audioActiveProjectKey {
            return false
        }
        if let overlay = audioPlaybackOverlay, overlay.audioID == audioID {
            guard overlay.projectKey == host?.audioActiveProjectKey else { return false }
            if let projectKey = host?.audioFrameProjectKey(root), projectKey != overlay.projectKey {
                return false
            }
            return true
        }
        if requestedAudioIDs.contains(audioID) {
            return true
        }
        return false
    }
}
