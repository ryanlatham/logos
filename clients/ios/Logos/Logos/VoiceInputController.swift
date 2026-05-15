import AVFoundation
import Foundation
import Speech

@MainActor
final class VoiceInputController: ObservableObject {
    enum Mode: String {
        case idle
        case hold
        case tap
    }

    @Published private(set) var mode: Mode = .idle
    @Published private(set) var statusText: String = "Voice idle"
    @Published private(set) var partialTranscript: String = ""
    @Published private(set) var availabilityMessage: String = "Checking speech support"
    @Published private(set) var voiceEnabled: Bool = false
    @Published private(set) var transportAvailable: Bool = false
    @Published private(set) var permissionDenied: Bool = false
    @Published private(set) var isFinalizingTranscript: Bool = false

    var onPartialTranscript: ((String, String, Int, Int64) -> Void)?
    var onFinalTranscript: ((String, String, Int, Int64) -> Void)?

    private let recognizer: SFSpeechRecognizer?
    private let audioEngine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var inputID = UUID().uuidString
    private var partialSeq = 0
    private var startedAtMilliseconds: Int64 = 0
    private var silenceDetector = TapToTalkSilenceDetector()
    private var startIntent = VoiceStartIntentTracker<Mode>()
    private var didInstallTap = false
    private var shouldSendFinalAfterRecognition = false
    private var finalizationTask: Task<Void, Never>?
    private var recognitionGeneration = UUID()
    private static let finalizationTimeoutNanoseconds: UInt64 = 2_000_000_000

    init(locale: Locale = Locale(identifier: "en-US")) {
        recognizer = SFSpeechRecognizer(locale: locale)
        refreshAvailability()
    }

    var isRecording: Bool { mode != .idle }
    var pendingMode: Mode? { startIntent.pendingMode }
    var isVoiceInteractionActive: Bool { isRecording || isFinalizingTranscript || pendingMode != nil }

    func configureCallbacks(
        partial: @escaping (String, String, Int, Int64) -> Void,
        final: @escaping (String, String, Int, Int64) -> Void
    ) {
        onPartialTranscript = partial
        onFinalTranscript = final
    }

    func refreshAvailability() {
        let supportsOnDevice = recognizer?.supportsOnDeviceRecognition ?? false
        let policy = VoiceRecognitionPolicy.resolve(supportsOnDeviceRecognition: supportsOnDevice)
        voiceEnabled = policy.voiceEnabled
        availabilityMessage = policy.message
        refreshIdleStatusText()
    }

    func updateTransportAvailable(_ available: Bool) {
        transportAvailable = available
        if available == false, isVoiceInteractionActive {
            startIntent.cancel()
            stop(sendFinal: false)
            statusText = "Voice cancelled — Logos disconnected"
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
            if #available(iOS 17.0, *) {
                AVAudioApplication.requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            } else {
                AVAudioSession.sharedInstance().requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
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

        inputID = UUID().uuidString
        partialSeq = 0
        partialTranscript = ""
        shouldSendFinalAfterRecognition = false
        isFinalizingTranscript = false
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

        let audioSession = AVAudioSession.sharedInstance()
        do {
            try audioSession.setCategory(.record, mode: .measurement, options: [.duckOthers])
            try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            statusText = "Audio session failed: \(error.localizedDescription)"
            return
        }

        let inputNode = audioEngine.inputNode
        if didInstallTap {
            inputNode.removeTap(onBus: 0)
            didInstallTap = false
        }
        let recordingFormat = inputNode.outputFormat(forBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { [weak self] buffer, _ in
            request.append(buffer)
            Task { @MainActor in
                self?.observeAudioBuffer(buffer)
            }
        }
        didInstallTap = true

        audioEngine.prepare()
        do {
            try audioEngine.start()
        } catch {
            statusText = "Microphone failed: \(error.localizedDescription)"
            inputNode.removeTap(onBus: 0)
            didInstallTap = false
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

    private func observeAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        guard mode == .tap else { return }
        let decision = silenceDetector.observe(
            energy: Self.rootMeanSquareEnergy(buffer),
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
            partialTranscript = text
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !result.isFinal, !trimmed.isEmpty {
                partialSeq += 1
                onPartialTranscript?(text, inputID, partialSeq, startedAtMilliseconds)
            }
            if result.isFinal {
                if mode != .idle {
                    stopAudioCapture(endAudio: false, deactivateSession: false)
                }
                finishRecognition(sendFinal: shouldSendFinalAfterRecognition || !trimmed.isEmpty, cancelTask: false)
                return
            }
        }
        if let error, mode != .idle || isFinalizingTranscript {
            if isFinalizingTranscript, partialTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
                finishRecognition(sendFinal: shouldSendFinalAfterRecognition, cancelTask: true)
            } else {
                statusText = "Speech failed: \(error.localizedDescription)"
                cancelRecognition(status: "Speech failed: \(error.localizedDescription)")
            }
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
        statusText = partialTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Finishing speech recognition…"
            : "Finishing transcript…"
        finalizationTask?.cancel()
        finalizationTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.finalizationTimeoutNanoseconds)
            guard let self, self.isFinalizingTranscript else { return }
            self.finishRecognition(sendFinal: self.shouldSendFinalAfterRecognition, cancelTask: true)
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
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
        mode = .idle
    }

    private func finishRecognition(sendFinal: Bool, cancelTask: Bool) {
        finalizationTask?.cancel()
        finalizationTask = nil
        let finalText = partialTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        if cancelTask {
            recognitionTask?.cancel()
        }
        recognitionTask = nil
        request = nil
        recognitionGeneration = UUID()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        isFinalizingTranscript = false
        shouldSendFinalAfterRecognition = false
        mode = .idle
        statusText = finalText.isEmpty ? "Voice idle — no speech captured" : "Voice idle"
        if sendFinal, !finalText.isEmpty {
            partialSeq += 1
            onFinalTranscript?(finalText, inputID, partialSeq, startedAtMilliseconds)
        }
    }

    private func cancelRecognition(status: String) {
        finalizationTask?.cancel()
        finalizationTask = nil
        stopAudioCapture(endAudio: true)
        recognitionTask?.cancel()
        recognitionTask = nil
        request = nil
        recognitionGeneration = UUID()
        isFinalizingTranscript = false
        shouldSendFinalAfterRecognition = false
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
