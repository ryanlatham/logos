import Foundation

public enum TapToTalkAutoStopReason: Equatable {
    case initialSilence
    case trailingSilence
}

public enum TapToTalkDecision: Equatable {
    case continueListening
    case autoStop(reason: TapToTalkAutoStopReason)
}

public struct TapToTalkSilenceDetector {
    public let energyThreshold: Double
    public let trailingSilenceSeconds: TimeInterval
    public let initialSilenceSeconds: TimeInterval

    private var startedAt: TimeInterval?
    private var lastSpeechAt: TimeInterval?
    private var heardSpeech = false
    private var stopped = false

    public init(energyThreshold: Double = 0.025, trailingSilenceSeconds: TimeInterval = 1.0, initialSilenceSeconds: TimeInterval = 4.0) {
        self.energyThreshold = energyThreshold
        self.trailingSilenceSeconds = trailingSilenceSeconds
        self.initialSilenceSeconds = initialSilenceSeconds
    }

    public mutating func start(at timestamp: TimeInterval) {
        startedAt = timestamp
        lastSpeechAt = nil
        heardSpeech = false
        stopped = false
    }

    public mutating func observe(energy: Double, at timestamp: TimeInterval) -> TapToTalkDecision {
        if stopped { return .continueListening }
        if startedAt == nil { start(at: timestamp) }

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
    public static func resolve(supportsOnDeviceRecognition: Bool) -> VoiceRecognitionAvailability {
        if supportsOnDeviceRecognition {
            return VoiceRecognitionAvailability(
                voiceEnabled: true,
                requiresOnDeviceRecognition: true,
                message: "On-device speech recognition is available."
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
