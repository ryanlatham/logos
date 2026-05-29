import Foundation

enum AudioPlaybackPhase: String, Hashable {
    case requesting
    case receiving
    case playing
    case paused
    case finished
    case failed
}

struct AudioPlaybackOverlayState: Identifiable, Hashable {
    var id: String { audioID }
    let audioID: String
    let messageID: String?
    let projectKey: String
    var phase: AudioPlaybackPhase
    var detail: String
    var spectrumBins: [Double]
    var canPause: Bool
    var canStop: Bool
}
