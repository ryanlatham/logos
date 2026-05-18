import Foundation

public enum TapToTalkAutoStopReason: Equatable {
    case initialSilence
    case trailingSilence
    case maximumDuration
}

public enum TapToTalkDecision: Equatable {
    case continueListening
    case autoStop(reason: TapToTalkAutoStopReason)
}

public struct TapToTalkSilenceDetector {
    public static let defaultEnergyThreshold = 0.015
    public static let defaultTrailingSilenceSeconds: TimeInterval = 2.2
    public static let defaultInitialSilenceSeconds: TimeInterval = 4.0
    public static let defaultMaximumRecordingSeconds: TimeInterval = 45.0

    public let energyThreshold: Double
    public let trailingSilenceSeconds: TimeInterval
    public let initialSilenceSeconds: TimeInterval
    public let maximumRecordingSeconds: TimeInterval

    private var startedAt: TimeInterval?
    private var lastSpeechAt: TimeInterval?
    private var heardSpeech = false
    private var stopped = false

    public init(
        energyThreshold: Double = Self.defaultEnergyThreshold,
        trailingSilenceSeconds: TimeInterval = Self.defaultTrailingSilenceSeconds,
        initialSilenceSeconds: TimeInterval = Self.defaultInitialSilenceSeconds,
        maximumRecordingSeconds: TimeInterval = Self.defaultMaximumRecordingSeconds
    ) {
        self.energyThreshold = energyThreshold
        self.trailingSilenceSeconds = trailingSilenceSeconds
        self.initialSilenceSeconds = initialSilenceSeconds
        self.maximumRecordingSeconds = maximumRecordingSeconds
    }

    public mutating func start(at timestamp: TimeInterval) {
        startedAt = timestamp
        lastSpeechAt = nil
        heardSpeech = false
        stopped = false
    }

    public mutating func markSpeech(at timestamp: TimeInterval) {
        if stopped { return }
        if startedAt == nil { start(at: timestamp) }
        heardSpeech = true
        lastSpeechAt = timestamp
    }

    public mutating func observe(energy: Double, at timestamp: TimeInterval) -> TapToTalkDecision {
        if stopped { return .continueListening }
        if startedAt == nil { start(at: timestamp) }

        if let startedAt, timestamp - startedAt >= maximumRecordingSeconds {
            stopped = true
            return .autoStop(reason: .maximumDuration)
        }

        if energy >= energyThreshold {
            heardSpeech = true
            lastSpeechAt = timestamp
            return .continueListening
        }

        if heardSpeech {
            let speechTime = lastSpeechAt ?? startedAt ?? timestamp
            if timestamp - speechTime >= trailingSilenceSeconds {
                stopped = true
                return .autoStop(reason: .trailingSilence)
            }
        } else if let startedAt, timestamp - startedAt >= initialSilenceSeconds {
            stopped = true
            return .autoStop(reason: .initialSilence)
        }

        return .continueListening
    }
}

public struct VoiceRecognitionAvailability: Equatable {
    public let voiceEnabled: Bool
    public let requiresOnDeviceRecognition: Bool
    public let message: String
}

public enum VoiceRecognitionPolicy {
    public static func resolve(supportsOnDeviceRecognition: Bool, isRecognizerAvailable: Bool = true) -> VoiceRecognitionAvailability {
        if supportsOnDeviceRecognition, isRecognizerAvailable {
            return VoiceRecognitionAvailability(
                voiceEnabled: true,
                requiresOnDeviceRecognition: true,
                message: "On-device speech recognition is available."
            )
        }
        if supportsOnDeviceRecognition, isRecognizerAvailable == false {
            return VoiceRecognitionAvailability(
                voiceEnabled: false,
                requiresOnDeviceRecognition: true,
                message: "Speech recognition is temporarily unavailable."
            )
        }
        return VoiceRecognitionAvailability(
            voiceEnabled: false,
            requiresOnDeviceRecognition: false,
            message: "On-device speech recognition is unavailable for this locale/device. Logos will not silently use network speech recognition."
        )
    }
}

public enum VoiceControlPolicy {
    public static func controlsDisabled(
        voiceEnabled: Bool,
        connected: Bool,
        isRecording: Bool,
        isFinalizing: Bool = false
    ) -> Bool {
        if isFinalizing { return true }
        if isRecording { return false }
        return voiceEnabled == false || connected == false
    }
}

public enum VoiceRecognitionErrorAction: Equatable {
    case waitForFinalResult
    case finishWithBestTranscript
    case cancelRecognition
}

public enum VoiceFinalizationTimer: Equatable {
    case bestTranscriptGrace
    case hardTimeout
}

public enum VoiceFinalizationDecision: Equatable {
    case keepWaiting
    case scheduleBestTranscriptFallback
    case sendFinal
    case finishWithoutSending
    case cancelRecognition
}

public enum VoiceFinalizationPolicy {
    public static let bestTranscriptGraceNanoseconds: UInt64 = 900_000_000
    public static let hardTimeoutNanoseconds: UInt64 = 4_000_000_000
    public static let timeoutNanoseconds = hardTimeoutNanoseconds

    public static func actionForRecognitionError(isFinalizing: Bool, hasBufferedTranscript: Bool) -> VoiceRecognitionErrorAction {
        guard isFinalizing else { return .cancelRecognition }
        return hasBufferedTranscript ? .finishWithBestTranscript : .waitForFinalResult
    }
}

public struct VoiceFinalizationState {
    public private(set) var isFinalizing = false
    public private(set) var wantsFinal = false
    public private(set) var hasBufferedTranscript = false
    public private(set) var hasResolved = false

    public init() {}

    public mutating func reset() {
        isFinalizing = false
        wantsFinal = false
        hasBufferedTranscript = false
        hasResolved = false
    }

    @discardableResult
    public mutating func noteTranscript(_ text: String, isFinal: Bool) -> VoiceFinalizationDecision {
        guard hasResolved == false else { return .keepWaiting }
        let hasTranscript = Self.hasTranscript(text)
        if hasTranscript {
            hasBufferedTranscript = true
        }
        if isFinal {
            if isFinalizing == false {
                isFinalizing = true
                wantsFinal = hasTranscript
            }
            return resolve(sendFinal: wantsFinal || hasTranscript)
        }
        guard isFinalizing, wantsFinal, hasTranscript else { return .keepWaiting }
        return .scheduleBestTranscriptFallback
    }

    public mutating func begin(sendFinal: Bool, transcript: String) -> VoiceFinalizationDecision {
        guard hasResolved == false else { return .keepWaiting }
        isFinalizing = true
        wantsFinal = sendFinal
        if Self.hasTranscript(transcript) {
            hasBufferedTranscript = true
        }
        return wantsFinal && hasBufferedTranscript ? .scheduleBestTranscriptFallback : .keepWaiting
    }

    public mutating func recognitionError() -> VoiceFinalizationDecision {
        guard hasResolved == false else { return .keepWaiting }
        guard isFinalizing else { return .cancelRecognition }
        return hasBufferedTranscript ? resolve(sendFinal: wantsFinal) : .keepWaiting
    }

    public mutating func timerFired(_ timer: VoiceFinalizationTimer) -> VoiceFinalizationDecision {
        guard hasResolved == false else { return .keepWaiting }
        guard isFinalizing else { return .keepWaiting }
        switch timer {
        case .bestTranscriptGrace:
            return hasBufferedTranscript ? resolve(sendFinal: wantsFinal) : .keepWaiting
        case .hardTimeout:
            return hasBufferedTranscript ? resolve(sendFinal: wantsFinal) : resolve(sendFinal: false)
        }
    }

    public mutating func cancel() {
        reset()
        hasResolved = true
    }

    private mutating func resolve(sendFinal: Bool) -> VoiceFinalizationDecision {
        guard hasResolved == false else { return .keepWaiting }
        hasResolved = true
        isFinalizing = false
        return sendFinal && wantsFinal && hasBufferedTranscript ? .sendFinal : .finishWithoutSending
    }

    private static func hasTranscript(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }
}

struct VoiceStartIntentTracker<Mode: Equatable> {
    private(set) var pendingID: UUID?
    private(set) var pendingMode: Mode?

    mutating func begin(mode: Mode) -> UUID? {
        guard pendingID == nil else { return nil }
        let id = UUID()
        pendingID = id
        pendingMode = mode
        return id
    }

    mutating func cancel(mode: Mode? = nil) {
        guard mode == nil || pendingMode == mode else { return }
        pendingID = nil
        pendingMode = nil
    }

    func accepts(id: UUID, mode: Mode) -> Bool {
        pendingID == id && pendingMode == mode
    }
}

public enum LogosSpeechFrame {
    public static func make(
        text: String,
        isFinal: Bool,
        inputID: String,
        partialSeq: Int,
        startedAtMilliseconds: Int64,
        deviceID: String,
        projectKey: String,
        requestID: String = UUID().uuidString
    ) -> [String: Any] {
        [
            "type": "speech",
            "request_id": requestID,
            "device_id": deviceID,
            "project_key": projectKey,
            "payload": [
                "text": text,
                "is_final": isFinal,
                "client_msg_id": inputID,
                "partial_seq": partialSeq,
                "started_at_ms": startedAtMilliseconds
            ]
        ]
    }
}
