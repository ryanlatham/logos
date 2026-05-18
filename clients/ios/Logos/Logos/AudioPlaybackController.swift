import AVFoundation
import Foundation

protocol AudioSessionManaging {
    func prepareForRecording() throws
    func finishRecording() throws
    func prepareForPlayback() throws
    func finishPlayback() throws
}

struct SystemAudioSessionManager: AudioSessionManaging {
    func prepareForRecording() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .measurement, options: [.duckOthers, .allowBluetoothHFP])
        try session.setActive(true, options: .notifyOthersOnDeactivation)
    }

    func finishRecording() throws {
        try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    func prepareForPlayback() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try session.setActive(true)
    }

    func finishPlayback() throws {
        try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}

protocol AudioPlaying: AnyObject {
    var delegate: AVAudioPlayerDelegate? { get set }

    @discardableResult
    func prepareToPlay() -> Bool

    @discardableResult
    func play() -> Bool
}

extension AVAudioPlayer: AudioPlaying {}

protocol AudioPlayerMaking {
    func makePlayer(data: Data) throws -> any AudioPlaying
}

struct SystemAudioPlayerFactory: AudioPlayerMaking {
    func makePlayer(data: Data) throws -> any AudioPlaying {
        try AVAudioPlayer(data: data)
    }
}

struct AudioPlaybackResult: Equatable {
    let byteCount: Int
    let started: Bool
}

final class AudioPlaybackController: NSObject, AVAudioPlayerDelegate {
    var onPlaybackFinished: ((String, Bool) -> Void)?

    private var chunksByAudioID: [String: [Int: Data]] = [:]
    private var playersByAudioID: [String: any AudioPlaying] = [:]
    private var audioIDByPlayerID: [ObjectIdentifier: String] = [:]
    private let sessionManager: any AudioSessionManaging
    private let playerFactory: any AudioPlayerMaking

    init(
        sessionManager: any AudioSessionManaging = SystemAudioSessionManager(),
        playerFactory: any AudioPlayerMaking = SystemAudioPlayerFactory()
    ) {
        self.sessionManager = sessionManager
        self.playerFactory = playerFactory
        super.init()
    }

    func appendChunk(audioID: String, chunkIndex: Int, base64: String) throws {
        guard let data = Data(base64Encoded: base64) else {
            throw AudioPlaybackError.invalidBase64
        }
        var chunks = chunksByAudioID[audioID, default: [:]]
        chunks[chunkIndex] = data
        chunksByAudioID[audioID] = chunks
    }

    @discardableResult
    func finish(audioID: String, expectedChunkCount: Int? = nil) throws -> AudioPlaybackResult {
        guard let chunks = chunksByAudioID[audioID], chunks.isEmpty == false else {
            throw AudioPlaybackError.noChunks
        }
        if let expectedChunkCount, chunks.count < expectedChunkCount {
            throw AudioPlaybackError.missingChunks
        }
        let ordered = chunks.keys.sorted().compactMap { chunks[$0] }
        let data = ordered.reduce(into: Data()) { partial, chunk in
            partial.append(chunk)
        }

        do {
            try sessionManager.prepareForPlayback()
            let player = try playerFactory.makePlayer(data: data)
            player.delegate = self
            let prepared = player.prepareToPlay()
            let started = player.play()
            guard prepared, started else {
                try? sessionManager.finishPlayback()
                throw AudioPlaybackError.playbackDidNotStart
            }
            playersByAudioID[audioID] = player
            audioIDByPlayerID[ObjectIdentifier(player)] = audioID
            chunksByAudioID.removeValue(forKey: audioID)
            return AudioPlaybackResult(byteCount: data.count, started: started)
        } catch {
            if !(error is AudioPlaybackError) {
                try? sessionManager.finishPlayback()
            }
            throw error
        }
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        let playerID = ObjectIdentifier(player)
        guard let audioID = audioIDByPlayerID.removeValue(forKey: playerID) else { return }
        playersByAudioID.removeValue(forKey: audioID)
        try? sessionManager.finishPlayback()
        onPlaybackFinished?(audioID, flag)
    }

    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        let playerID = ObjectIdentifier(player)
        guard let audioID = audioIDByPlayerID.removeValue(forKey: playerID) else { return }
        playersByAudioID.removeValue(forKey: audioID)
        try? sessionManager.finishPlayback()
        onPlaybackFinished?(audioID, false)
    }
}

enum AudioPlaybackError: LocalizedError {
    case invalidBase64
    case noChunks
    case missingChunks
    case playbackDidNotStart

    var errorDescription: String? {
        switch self {
        case .invalidBase64:
            return "Audio chunk was not valid base64."
        case .noChunks:
            return "No audio chunks were received."
        case .missingChunks:
            return "Audio stream ended before all chunks arrived."
        case .playbackDidNotStart:
            return "Audio playback could not start. Check device volume and output route."
        }
    }
}
