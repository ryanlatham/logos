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
    var isPlaying: Bool { get }
    var currentTime: TimeInterval { get set }
    var duration: TimeInterval { get }
    var isMeteringEnabled: Bool { get set }

    @discardableResult
    func prepareToPlay() -> Bool

    @discardableResult
    func play() -> Bool

    func pause()
    func stop()
    func updateMeters()
    func averagePower(forChannel channelNumber: Int) -> Float
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

struct AudioPlaybackLifecycleSnapshot: Equatable {
    let audioID: String
    let currentTime: TimeInterval
    let duration: TimeInterval
    let reason: String
}

struct AudioPlaybackResumeResult: Equatable {
    let audioID: String
    let currentTime: TimeInterval
    let started: Bool
}

final class AudioPlaybackController: NSObject, AVAudioPlayerDelegate {
    var onPlaybackFinished: ((String, Bool) -> Void)?

    private var chunksByAudioID: [String: [Int: Data]] = [:]
    private var playersByAudioID: [String: any AudioPlaying] = [:]
    private var audioIDByPlayerID: [ObjectIdentifier: String] = [:]
    private var dataByAudioID: [String: Data] = [:]
    private var lifecycleSnapshotsByAudioID: [String: AudioPlaybackLifecycleSnapshot] = [:]
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
            player.isMeteringEnabled = true
            playersByAudioID[audioID] = player
            audioIDByPlayerID[ObjectIdentifier(player)] = audioID
            dataByAudioID[audioID] = data
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
        dataByAudioID.removeValue(forKey: audioID)
        lifecycleSnapshotsByAudioID.removeValue(forKey: audioID)
        try? sessionManager.finishPlayback()
        onPlaybackFinished?(audioID, flag)
    }

    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        let playerID = ObjectIdentifier(player)
        guard let audioID = audioIDByPlayerID.removeValue(forKey: playerID) else { return }
        playersByAudioID.removeValue(forKey: audioID)
        dataByAudioID.removeValue(forKey: audioID)
        lifecycleSnapshotsByAudioID.removeValue(forKey: audioID)
        try? sessionManager.finishPlayback()
        onPlaybackFinished?(audioID, false)
    }

    @discardableResult
    func pause(audioID: String) -> Bool {
        guard let player = playersByAudioID[audioID] else { return false }
        player.pause()
        lifecycleSnapshotsByAudioID.removeValue(forKey: audioID)
        return true
    }

    @discardableResult
    func resume(audioID: String) throws -> Bool {
        guard let player = playersByAudioID[audioID] else { return false }
        try sessionManager.prepareForPlayback()
        return player.play()
    }

    @discardableResult
    func stop(audioID: String) -> Bool {
        let player = playersByAudioID.removeValue(forKey: audioID)
        chunksByAudioID.removeValue(forKey: audioID)
        dataByAudioID.removeValue(forKey: audioID)
        lifecycleSnapshotsByAudioID.removeValue(forKey: audioID)
        if let player {
            audioIDByPlayerID.removeValue(forKey: ObjectIdentifier(player))
            player.stop()
            try? sessionManager.finishPlayback()
            return true
        }
        return false
    }

    func stopAll() {
        for audioID in Array(Set(playersByAudioID.keys).union(chunksByAudioID.keys)) {
            _ = stop(audioID: audioID)
        }
    }

    func pauseForLifecycle(reason: String) -> [AudioPlaybackLifecycleSnapshot] {
        var snapshots: [AudioPlaybackLifecycleSnapshot] = []
        for (audioID, player) in playersByAudioID where player.isPlaying {
            let snapshot = AudioPlaybackLifecycleSnapshot(
                audioID: audioID,
                currentTime: player.currentTime,
                duration: player.duration,
                reason: reason
            )
            player.pause()
            lifecycleSnapshotsByAudioID[audioID] = snapshot
            snapshots.append(snapshot)
        }
        return snapshots.sorted { $0.audioID < $1.audioID }
    }

    func resumeAfterLifecycle() throws -> [AudioPlaybackResumeResult] {
        var results: [AudioPlaybackResumeResult] = []
        for snapshot in lifecycleSnapshotsByAudioID.values.sorted(by: { $0.audioID < $1.audioID }) where snapshot.reason != "manual_pause" {
            guard let player = playersByAudioID[snapshot.audioID] else { continue }
            try sessionManager.prepareForPlayback()
            player.currentTime = snapshot.currentTime
            let started = player.play()
            if started {
                lifecycleSnapshotsByAudioID.removeValue(forKey: snapshot.audioID)
            }
            results.append(AudioPlaybackResumeResult(audioID: snapshot.audioID, currentTime: player.currentTime, started: started))
        }
        return results
    }

    func spectrumBins(audioID: String, count: Int = 12) -> [Double] {
        let binCount = max(1, count)
        if let player = playersByAudioID[audioID] {
            player.updateMeters()
            let power = player.averagePower(forChannel: 0)
            let normalized = max(0.05, min(1.0, Double((power + 60) / 60)))
            return (0..<binCount).map { index in
                let wave = 0.65 + 0.35 * sin(Double(index) * 0.9 + player.currentTime)
                return max(0.05, min(1.0, normalized * wave))
            }
        }
        guard let data = dataByAudioID[audioID], data.isEmpty == false else {
            return Array(repeating: 0.12, count: binCount)
        }
        return (0..<binCount).map { index in
            let byte = data[index % data.count]
            return max(0.05, Double(byte) / 255.0)
        }
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
