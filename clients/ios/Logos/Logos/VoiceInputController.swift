import AVFoundation
import Foundation
import Observation
import Speech

@MainActor
@Observable
final class VoiceInputController: NSObject, SFSpeechRecognizerDelegate {
    enum Mode: String {
        case idle
        case hold
        case tap
    }

    private(set) var mode: Mode = .idle
    private(set) var statusText: String = "Voice idle"
    private(set) var partialTranscript: String = ""
    private(set) var availabilityMessage: String = "Checking speech support"
    private(set) var voiceEnabled: Bool = false
    private(set) var transportAvailable: Bool = false
    private(set) var permissionDenied: Bool = false
    private(set) var isFinalizingTranscript: Bool = false

    @ObservationIgnored var onPartialTranscript: ((String, String, Int, Int64) -> Void)?
    @ObservationIgnored var onFinalTranscript: ((String, String, Int, Int64) -> Bool)?

    private let recognizer: SFSpeechRecognizer?
    private let audioEngine = AVAudioEngine()
    @ObservationIgnored private var request: SFSpeechAudioBufferRecognitionRequest?
    @ObservationIgnored private var recognitionTask: SFSpeechRecognitionTask?
    @ObservationIgnored private var inputID = UUID().uuidString
    @ObservationIgnored private var partialSeq = 0
    @ObservationIgnored private var startedAtMilliseconds: Int64 = 0
    @ObservationIgnored private var lastSentPartialTranscript = ""
    @ObservationIgnored private var bestTranscript = ""
    @ObservationIgnored private var silenceDetector = TapToTalkSilenceDetector()
    @ObservationIgnored private var startIntent = VoiceStartIntentTracker<Mode>()
    @ObservationIgnored private var didInstallTap = false
    @ObservationIgnored private var shouldSendFinalAfterRecognition = false
    @ObservationIgnored private var finalizationState = VoiceFinalizationState()
    @ObservationIgnored private var bestTranscriptFallbackTask: Task<Void, Never>?
    @ObservationIgnored private var finalizationTask: Task<Void, Never>?
    @ObservationIgnored private var recognitionGeneration = UUID()
    private let audioSessionManager: any AudioSessionManaging
    private static let bestTranscriptGraceNanoseconds = VoiceFinalizationPolicy.bestTranscriptGraceNanoseconds
    private static let finalizationTimeoutNanoseconds = VoiceFinalizationPolicy.hardTimeoutNanoseconds

    init(locale: Locale = Locale(identifier: "en-US"), audioSessionManager: any AudioSessionManaging = SystemAudioSessionManager()) {
        recognizer = SFSpeechRecognizer(locale: locale)
        self.audioSessionManager = audioSessionManager
        super.init()
        recognizer?.delegate = self
        observeAudioSessionNotifications()
        refreshAvailability()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        finalizationTask?.cancel()
        bestTranscriptFallbackTask?.cancel()
        recognitionTask?.cancel()
        audioEngine.stop()
        if didInstallTap {
            audioEngine.inputNode.removeTap(onBus: 0)
        }
        recognizer?.delegate = nil
    }

    var isRecording: Bool { mode != .idle }
    var pendingMode: Mode? { startIntent.pendingMode }
    var isVoiceInteractionActive: Bool { isRecording || isFinalizingTranscript || pendingMode != nil }

    func configureCallbacks(
        partial: @escaping (String, String, Int, Int64) -> Void,
        final: @escaping (String, String, Int, Int64) -> Bool
    ) {
        onPartialTranscript = partial
        onFinalTranscript = final
    }

    func refreshAvailability() {
        let supportsOnDevice = recognizer?.supportsOnDeviceRecognition ?? false
        let isAvailable = recognizer?.isAvailable ?? false
        let policy = VoiceRecognitionPolicy.resolve(
            supportsOnDeviceRecognition: supportsOnDevice,
            isRecognizerAvailable: isAvailable
        )
        voiceEnabled = policy.voiceEnabled
        availabilityMessage = policy.message
        refreshIdleStatusText()
    }

    func updateTransportAvailable(_ available: Bool) {
        transportAvailable = available
        if available == false, isVoiceInteractionActive {
            finishOrCancelAfterExternalStop(status: "Voice cancelled — Logos disconnected")
            return
        }
        refreshIdleStatusText()
    }

    func startHold() {
        begin(mode: .hold)
    }

    func endHold() {
        if pendingMode == .hold {
            cancelPendingStart(status: "Voice idle")
            return
        }
        stop(sendFinal: true)
    }

    func toggleTap() {
        if mode == .tap {
            stop(sendFinal: true)
        } else if pendingMode == .tap {
            cancelPendingStart(status: "Voice idle")
        } else {
            begin(mode: .tap)
        }
    }

    func cancel() {
        if pendingMode != nil {
            cancelPendingStart(status: "Voice cancelled")
            return
        }
        stop(sendFinal: false)
    }

    private func begin(mode targetMode: Mode) {
        guard mode == .idle, pendingMode == nil, isFinalizingTranscript == false else { return }
        refreshAvailability()
        guard voiceEnabled else { return }
        guard transportAvailable else {
            statusText = "Connect to Logos before using voice"
            return
        }
        guard let startID = startIntent.begin(mode: targetMode) else { return }
        statusText = "Preparing microphone…"

        Task { @MainActor in
            let authorized = await requestPermissions()
            guard startIntent.accepts(id: startID, mode: targetMode) else { return }
            guard authorized else {
                startIntent.cancel(mode: targetMode)
                permissionDenied = true
                statusText = "Speech or microphone permission denied"
                return
            }
            guard transportAvailable else {
                startIntent.cancel(mode: targetMode)
                statusText = "Voice cancelled — Logos disconnected"
                return
            }
            startIntent.cancel(mode: targetMode)
            startRecognition(mode: targetMode)
        }
    }

    private func requestPermissions() async -> Bool {
        let speechAuthorized = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
        guard speechAuthorized else { return false }

        return await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    private func startRecognition(mode targetMode: Mode) {
        guard let recognizer else {
            voiceEnabled = false
            availabilityMessage = "Speech recognizer could not be created."
            statusText = "Voice unavailable"
            return
        }
        guard recognizer.supportsOnDeviceRecognition else {
            refreshAvailability()
            return
        }
        guard recognizer.isAvailable else {
            refreshAvailability()
            statusText = "Voice unavailable"
            return
        }

        inputID = UUID().uuidString
        partialSeq = 0
        partialTranscript = ""
        lastSentPartialTranscript = ""
        bestTranscript = ""
        shouldSendFinalAfterRecognition = false
        finalizationState.reset()
        isFinalizingTranscript = false
        bestTranscriptFallbackTask?.cancel()
        bestTranscriptFallbackTask = nil
        finalizationTask?.cancel()
        finalizationTask = nil
        startedAtMilliseconds = Int64(Date().timeIntervalSince1970 * 1000)
        recognitionGeneration = UUID()
        let generation = recognitionGeneration
        silenceDetector.start(at: Date().timeIntervalSinceReferenceDate)

        recognitionTask?.cancel()
        recognitionTask = nil
        request = SFSpeechAudioBufferRecognitionRequest()
        guard let request else { return }
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = true

        do {
            try audioSessionManager.prepareForRecording()
        } catch {
            cleanupFailedRecognitionStart(status: "Audio session failed: \(error.localizedDescription)", endAudio: true)
            return
        }

        let inputNode = audioEngine.inputNode
        if didInstallTap {
            inputNode.removeTap(onBus: 0)
            didInstallTap = false
        }
        let recordingFormat = inputNode.outputFormat(forBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { [weak self] buffer, _ in
            let energy = Self.rootMeanSquareEnergy(buffer)
            request.append(buffer)
            Task { @MainActor in
                self?.observeAudioEnergy(energy)
            }
        }
        didInstallTap = true

        audioEngine.prepare()
        do {
            try audioEngine.start()
        } catch {
            cleanupFailedRecognitionStart(status: "Microphone failed: \(error.localizedDescription)", endAudio: true)
            return
        }

        mode = targetMode
        statusText = targetMode == .hold ? "Hold to talk listening" : "Tap to talk listening"

        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in
                self?.handleRecognition(result: result, error: error, generation: generation)
            }
        }
    }

    private func observeAudioEnergy(_ energy: Double) {
        guard mode == .tap else { return }
        let decision = silenceDetector.observe(
            energy: energy,
            at: Date().timeIntervalSinceReferenceDate
        )
        if case .autoStop = decision {
            stop(sendFinal: true)
        }
    }

    private func handleRecognition(result: SFSpeechRecognitionResult?, error: Error?, generation: UUID) {
        guard generation == recognitionGeneration, mode != .idle || isFinalizingTranscript else { return }
        if let result {
            let text = result.bestTranscription.formattedString
            let previousNormalized = Self.normalizedTranscript(partialTranscript)
            partialTranscript = text
            let normalized = Self.normalizedTranscript(text)
            let transcriptChanged = normalized != previousNormalized
            if !normalized.isEmpty {
                bestTranscript = text
            }
            if mode == .tap, !normalized.isEmpty, transcriptChanged {
                silenceDetector.markSpeech(at: Date().timeIntervalSinceReferenceDate)
            }

            if result.isFinal {
                if mode != .idle {
                    stopAudioCapture(endAudio: false, deactivateSession: false)
                }
                if finalizationState.isFinalizing == false {
                    _ = finalizationState.begin(
                        sendFinal: shouldSendFinalAfterRecognition || !normalized.isEmpty,
                        transcript: text
                    )
                }
                applyFinalizationDecision(
                    finalizationState.noteTranscript(text, isFinal: true),
                    generation: generation,
                    cancelTask: false,
                    errorMessage: nil
                )
                return
            }

            if !normalized.isEmpty, transcriptChanged, normalized != lastSentPartialTranscript {
                lastSentPartialTranscript = normalized
                partialSeq += 1
                onPartialTranscript?(text, inputID, partialSeq, startedAtMilliseconds)
                applyFinalizationDecision(
                    finalizationState.noteTranscript(text, isFinal: false),
                    generation: generation,
                    cancelTask: true,
                    errorMessage: nil
                )
            }
        }
        if let error, mode != .idle || isFinalizingTranscript {
            applyFinalizationDecision(
                finalizationState.recognitionError(),
                generation: generation,
                cancelTask: true,
                errorMessage: "Speech failed: \(error.localizedDescription)"
            )
        }
    }

    private func stop(sendFinal: Bool) {
        if isFinalizingTranscript {
            if sendFinal { return }
            cancelRecognition(status: "Voice cancelled")
            return
        }
        guard mode != .idle else { return }
        if sendFinal {
            beginFinalizingRecognition()
        } else {
            cancelRecognition(status: "Voice cancelled")
        }
    }

    private func beginFinalizingRecognition() {
        shouldSendFinalAfterRecognition = true
        isFinalizingTranscript = true
        stopAudioCapture(endAudio: true, deactivateSession: false)
        statusText = bestAvailableTranscript().isEmpty
            ? "Finishing speech recognition…"
            : "Finishing transcript…"
        let generation = recognitionGeneration
        applyFinalizationDecision(
            finalizationState.begin(sendFinal: true, transcript: bestAvailableTranscript()),
            generation: generation,
            cancelTask: true,
            errorMessage: nil
        )
        scheduleHardFinalizationTimeout(generation: generation)
    }

    private func scheduleBestTranscriptFallback(generation: UUID) {
        bestTranscriptFallbackTask?.cancel()
        bestTranscriptFallbackTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: Self.bestTranscriptGraceNanoseconds)
            } catch {
                return
            }
            guard let self, Task.isCancelled == false, self.isFinalizingTranscript else { return }
            self.applyFinalizationDecision(
                self.finalizationState.timerFired(.bestTranscriptGrace),
                generation: generation,
                cancelTask: true,
                errorMessage: nil
            )
        }
    }

    private func scheduleHardFinalizationTimeout(generation: UUID) {
        finalizationTask?.cancel()
        finalizationTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: Self.finalizationTimeoutNanoseconds)
            } catch {
                return
            }
            guard let self, Task.isCancelled == false, self.isFinalizingTranscript else { return }
            self.applyFinalizationDecision(
                self.finalizationState.timerFired(.hardTimeout),
                generation: generation,
                cancelTask: true,
                errorMessage: nil
            )
        }
    }

    private func applyFinalizationDecision(
        _ decision: VoiceFinalizationDecision,
        generation: UUID,
        cancelTask: Bool,
        errorMessage: String?
    ) {
        guard generation == recognitionGeneration else { return }
        switch decision {
        case .keepWaiting:
            if let errorMessage {
                statusText = bestAvailableTranscript().isEmpty ? "Finishing speech recognition…" : "Finishing transcript…"
                _ = errorMessage
            }
        case .scheduleBestTranscriptFallback:
            scheduleBestTranscriptFallback(generation: generation)
        case .sendFinal:
            finishRecognition(sendFinal: true, cancelTask: cancelTask)
        case .finishWithoutSending:
            finishRecognition(sendFinal: false, cancelTask: cancelTask)
        case .cancelRecognition:
            cancelRecognition(status: errorMessage ?? "Speech failed")
        }
    }

    private func stopAudioCapture(endAudio: Bool, deactivateSession: Bool = true) {
        audioEngine.stop()
        if didInstallTap {
            audioEngine.inputNode.removeTap(onBus: 0)
            didInstallTap = false
        }
        if endAudio {
            request?.endAudio()
        }
        if deactivateSession {
            try? audioSessionManager.finishRecording()
        }
        mode = .idle
    }

    private func finishRecognition(sendFinal: Bool, cancelTask: Bool) {
        guard recognitionTask != nil || request != nil || isFinalizingTranscript || mode != .idle else { return }
        bestTranscriptFallbackTask?.cancel()
        bestTranscriptFallbackTask = nil
        finalizationTask?.cancel()
        finalizationTask = nil
        let finalText = bestAvailableTranscript()
        if cancelTask {
            recognitionTask?.cancel()
        }
        recognitionTask = nil
        request = nil
        recognitionGeneration = UUID()
        try? audioSessionManager.finishRecording()
        isFinalizingTranscript = false
        shouldSendFinalAfterRecognition = false
        finalizationState.reset()
        mode = .idle
        var didDeliverFinal = true
        if sendFinal, !finalText.isEmpty {
            partialSeq += 1
            didDeliverFinal = onFinalTranscript?(finalText, inputID, partialSeq, startedAtMilliseconds) ?? false
        }
        if finalText.isEmpty || sendFinal == false {
            statusText = "Voice idle — no speech captured"
        } else {
            statusText = didDeliverFinal ? "Voice idle" : "Voice idle — transcript not sent"
        }
    }

    private func cancelRecognition(status: String) {
        bestTranscriptFallbackTask?.cancel()
        bestTranscriptFallbackTask = nil
        finalizationTask?.cancel()
        finalizationTask = nil
        stopAudioCapture(endAudio: true)
        recognitionTask?.cancel()
        recognitionTask = nil
        request = nil
        recognitionGeneration = UUID()
        isFinalizingTranscript = false
        shouldSendFinalAfterRecognition = false
        finalizationState.reset()
        statusText = status
    }

    private func cleanupFailedRecognitionStart(status: String, endAudio: Bool) {
        stopAudioCapture(endAudio: endAudio)
        recognitionTask?.cancel()
        recognitionTask = nil
        request = nil
        recognitionGeneration = UUID()
        isFinalizingTranscript = false
        shouldSendFinalAfterRecognition = false
        finalizationState.reset()
        statusText = status
    }

    private func refreshIdleStatusText() {
        guard mode == .idle, isFinalizingTranscript == false else { return }
        if voiceEnabled == false {
            statusText = "Voice unavailable"
        } else if transportAvailable == false {
            statusText = "Connect to Logos before using voice"
        } else {
            statusText = "Voice ready"
        }
    }

    private func cancelPendingStart(status: String) {
        startIntent.cancel()
        statusText = status
    }

    private func observeAudioSessionNotifications() {
        let center = NotificationCenter.default
        let session = AVAudioSession.sharedInstance()
        center.addObserver(
            self,
            selector: #selector(handleAudioSessionInterruptionNotification(_:)),
            name: AVAudioSession.interruptionNotification,
            object: session
        )
        center.addObserver(
            self,
            selector: #selector(handleAudioRouteChangeNotification(_:)),
            name: AVAudioSession.routeChangeNotification,
            object: session
        )
        center.addObserver(
            self,
            selector: #selector(handleMediaServicesResetNotification(_:)),
            name: AVAudioSession.mediaServicesWereResetNotification,
            object: session
        )
    }

    nonisolated func speechRecognizer(_ speechRecognizer: SFSpeechRecognizer, availabilityDidChange available: Bool) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.refreshAvailability()
            if available == false {
                self.finishOrCancelAfterExternalStop(status: "Voice cancelled — speech recognition unavailable")
            }
        }
    }

    @objc private nonisolated func handleAudioSessionInterruptionNotification(_ notification: Notification) {
        Task { @MainActor [weak self] in
            self?.handleAudioSessionInterruption(notification)
        }
    }

    @objc private nonisolated func handleAudioRouteChangeNotification(_ notification: Notification) {
        Task { @MainActor [weak self] in
            self?.handleAudioRouteChange(notification)
        }
    }

    @objc private nonisolated func handleMediaServicesResetNotification(_ notification: Notification) {
        Task { @MainActor [weak self] in
            self?.handleMediaServicesReset()
        }
    }

    private func handleAudioSessionInterruption(_ notification: Notification) {
        guard
            let rawType = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
            let type = AVAudioSession.InterruptionType(rawValue: rawType)
        else { return }

        switch type {
        case .began:
            finishOrCancelAfterExternalStop(status: "Voice cancelled — audio interrupted")
        case .ended:
            refreshAvailability()
        @unknown default:
            break
        }
    }

    private func handleAudioRouteChange(_ notification: Notification) {
        guard
            let rawReason = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
            let reason = AVAudioSession.RouteChangeReason(rawValue: rawReason)
        else { return }
        if reason == .oldDeviceUnavailable {
            finishOrCancelAfterExternalStop(status: "Voice cancelled — audio route changed")
        }
    }

    private func handleMediaServicesReset() {
        finishOrCancelAfterExternalStop(status: "Voice cancelled — audio services reset")
        audioEngine.reset()
        refreshAvailability()
    }

    private func finishOrCancelAfterExternalStop(status: String) {
        if pendingMode != nil, mode == .idle, isFinalizingTranscript == false {
            cancelPendingStart(status: status)
            return
        }
        guard mode != .idle || isFinalizingTranscript else { return }
        if isFinalizingTranscript {
            applyFinalizationDecision(
                finalizationState.timerFired(.bestTranscriptGrace),
                generation: recognitionGeneration,
                cancelTask: true,
                errorMessage: nil
            )
            return
        }
        if bestAvailableTranscript().isEmpty {
            cancelRecognition(status: status)
        } else {
            beginFinalizingRecognition()
        }
    }

    private func bestAvailableTranscript() -> String {
        let current = Self.normalizedTranscript(partialTranscript)
        if !current.isEmpty { return current }
        return Self.normalizedTranscript(bestTranscript)
    }

    private static func normalizedTranscript(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func rootMeanSquareEnergy(_ buffer: AVAudioPCMBuffer) -> Double {
        guard let channel = buffer.floatChannelData?[0] else { return 0 }
        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0 else { return 0 }
        var total: Float = 0
        for index in 0..<frameLength {
            let sample = channel[index]
            total += sample * sample
        }
        return Double(sqrt(total / Float(frameLength)))
    }
}
