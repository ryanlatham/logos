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
    @Published private(set) var permissionDenied: Bool = false

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
    private var didInstallTap = false

    init(locale: Locale = Locale(identifier: "en-US")) {
        recognizer = SFSpeechRecognizer(locale: locale)
        refreshAvailability()
    }

    var isRecording: Bool { mode != .idle }

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
        if voiceEnabled {
            statusText = "Voice ready"
        } else {
            statusText = "Voice unavailable"
        }
    }

    func startHold() {
        begin(mode: .hold)
    }

    func endHold() {
        stop(sendFinal: true)
    }

    func toggleTap() {
        if mode == .tap {
            stop(sendFinal: true)
        } else {
            begin(mode: .tap)
        }
    }

    func cancel() {
        stop(sendFinal: false)
    }

    private func begin(mode targetMode: Mode) {
        guard mode == .idle else { return }
        refreshAvailability()
        guard voiceEnabled else { return }

        Task { @MainActor in
            let authorized = await requestPermissions()
            guard authorized else {
                permissionDenied = true
                statusText = "Speech or microphone permission denied"
                return
            }
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
        startedAtMilliseconds = Int64(Date().timeIntervalSince1970 * 1000)
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
                self?.handleRecognition(result: result, error: error)
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

    private func handleRecognition(result: SFSpeechRecognitionResult?, error: Error?) {
        if let result {
            let text = result.bestTranscription.formattedString
            partialTranscript = text
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                partialSeq += 1
                onPartialTranscript?(text, inputID, partialSeq, startedAtMilliseconds)
            }
            if result.isFinal {
                stop(sendFinal: true)
            }
        }
        if let error, mode != .idle {
            statusText = "Speech failed: \(error.localizedDescription)"
            stop(sendFinal: true)
        }
    }

    private func stop(sendFinal: Bool) {
        guard mode != .idle else { return }
        let finalText = partialTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        audioEngine.stop()
        if didInstallTap {
            audioEngine.inputNode.removeTap(onBus: 0)
            didInstallTap = false
        }
        request?.endAudio()
        request = nil
        recognitionTask?.cancel()
        recognitionTask = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        mode = .idle
        statusText = finalText.isEmpty ? "Voice idle — no speech captured" : "Voice idle"
        if sendFinal, !finalText.isEmpty {
            partialSeq += 1
            onFinalTranscript?(finalText, inputID, partialSeq, startedAtMilliseconds)
        }
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
