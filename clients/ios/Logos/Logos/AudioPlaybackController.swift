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

struct DecodedAudioSamples: Equatable {
    let samples: [Float]
    let sampleRate: Double
}

protocol AudioSampleDecoding {
    func decodeSamples(from data: Data) throws -> DecodedAudioSamples
}

struct AVAudioFileSampleDecoder: AudioSampleDecoding {
    private static let temporaryFilePrefix = "logos-spectrum-"

    private let fileManager: FileManager
    private let temporaryDirectory: URL
    private let maxDecodedDuration: TimeInterval
    private let maxDecodedFrames: AVAudioFramePosition
    private let maxSampleRate: Double
    private let maxChannelCount: Int

    init(
        fileManager: FileManager = .default,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory.appendingPathComponent("logos-spectrum-analysis", isDirectory: true),
        maxDecodedDuration: TimeInterval = 300,
        maxDecodedFrames: Int = 8_640_000,
        maxSampleRate: Double = 48_000,
        maxChannelCount: Int = 2
    ) {
        self.fileManager = fileManager
        self.temporaryDirectory = temporaryDirectory
        self.maxDecodedDuration = max(0.1, maxDecodedDuration)
        self.maxDecodedFrames = AVAudioFramePosition(max(1, maxDecodedFrames))
        self.maxSampleRate = max(1, maxSampleRate)
        self.maxChannelCount = max(1, maxChannelCount)
        prepareTemporaryDirectory()
        cleanupStaleTemporaryFiles()
    }

    func decodeSamples(from data: Data) throws -> DecodedAudioSamples {
        let fileExtension = temporaryFileExtension(for: data)
        let url = temporaryDirectory
            .appendingPathComponent("\(Self.temporaryFilePrefix)\(UUID().uuidString)")
            .appendingPathExtension(fileExtension)
        defer { try? fileManager.removeItem(at: url) }

        try data.write(to: url, options: .atomic)
        try? fileManager.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)

        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let sampleRate = file.processingFormat.sampleRate
        guard sampleRate.isFinite, sampleRate > 0, sampleRate <= maxSampleRate else {
            throw AudioSampleDecodingError.invalidSampleRate
        }
        let channelCount = Int(file.processingFormat.channelCount)
        guard channelCount > 0 else {
            throw AudioSampleDecodingError.noSamples
        }
        guard channelCount <= maxChannelCount else {
            throw AudioSampleDecodingError.tooManyChannels
        }
        let durationFrameCount = AVAudioFramePosition((sampleRate * maxDecodedDuration).rounded(.down))
        let maxFrameCount = max(1, min(durationFrameCount, maxDecodedFrames))
        guard file.length > 0 else {
            throw AudioSampleDecodingError.noSamples
        }
        guard file.length <= maxFrameCount, file.length <= AVAudioFramePosition(Int32.max) else {
            throw AudioSampleDecodingError.tooManyDecodedFrames
        }
        let frameCapacity = AVAudioFrameCount(file.length)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frameCapacity) else {
            throw AudioSampleDecodingError.noSamples
        }
        try file.read(into: buffer)
        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0, let channelData = buffer.floatChannelData else {
            throw AudioSampleDecodingError.noSamples
        }

        var monoSamples = Array(repeating: Float(0), count: frameLength)
        for channel in 0..<channelCount {
            let samples = channelData[channel]
            for frame in 0..<frameLength {
                monoSamples[frame] += samples[frame] / Float(channelCount)
            }
        }
        return DecodedAudioSamples(samples: monoSamples, sampleRate: sampleRate)
    }

    private func prepareTemporaryDirectory() {
        try? fileManager.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var directory = temporaryDirectory
        try? directory.setResourceValues(values)
        try? fileManager.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: temporaryDirectory.path)
    }

    private func cleanupStaleTemporaryFiles() {
        guard let files = try? fileManager.contentsOfDirectory(at: temporaryDirectory, includingPropertiesForKeys: nil) else { return }
        for file in files where file.lastPathComponent.hasPrefix(Self.temporaryFilePrefix) {
            try? fileManager.removeItem(at: file)
        }
    }

    private func temporaryFileExtension(for data: Data) -> String {
        let bytes = Array(data.prefix(12))
        if bytes.count >= 4, bytes[0] == 0x52, bytes[1] == 0x49, bytes[2] == 0x46, bytes[3] == 0x46 {
            return "wav"
        }
        if bytes.count >= 3, bytes[0] == 0x49, bytes[1] == 0x44, bytes[2] == 0x33 {
            return "mp3"
        }
        if bytes.count >= 2, bytes[0] == 0xFF, (bytes[1] & 0xE0) == 0xE0 {
            return "mp3"
        }
        if bytes.count >= 12,
           bytes[4] == 0x66,
           bytes[5] == 0x74,
           bytes[6] == 0x79,
           bytes[7] == 0x70 {
            return "m4a"
        }
        return "mp3"
    }
}

enum AudioSampleDecodingError: LocalizedError, Equatable {
    case invalidSampleRate
    case noSamples
    case tooManyChannels
    case tooManyDecodedFrames

    var errorDescription: String? {
        switch self {
        case .invalidSampleRate:
            "Decoded audio sample rate was invalid."
        case .noSamples:
            "No decoded PCM samples were available for spectrum analysis."
        case .tooManyChannels:
            "Decoded audio had too many channels for spectrum analysis."
        case .tooManyDecodedFrames:
            "Decoded audio was too long for spectrum analysis."
        }
    }
}

struct AudioPlaybackLimits: Equatable {
    var maxChunkCount: Int = 256
    var maxChunkBytes: Int = 1_000_000
    var maxEncodedBytes: Int = 12_000_000
    var maxBase64ChunkCharacters: Int {
        ((maxChunkBytes + 2) / 3) * 4 + 4
    }

    init(maxChunkCount: Int = 256, maxChunkBytes: Int = 1_000_000, maxEncodedBytes: Int = 12_000_000) {
        self.maxChunkCount = max(1, maxChunkCount)
        self.maxChunkBytes = max(1, maxChunkBytes)
        self.maxEncodedBytes = max(1, maxEncodedBytes)
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
    private var spectrumSamplesByAudioID: [String: DecodedAudioSamples] = [:]
    private var spectrumDecodeTokensByAudioID: [String: UUID] = [:]
    private var lifecycleSnapshotsByAudioID: [String: AudioPlaybackLifecycleSnapshot] = [:]
    private let sessionManager: any AudioSessionManaging
    private let playerFactory: any AudioPlayerMaking
    private let sampleDecoder: any AudioSampleDecoding
    private let spectrumAnalyzer: AudioSpectrumAnalyzer
    private let limits: AudioPlaybackLimits
    private let spectrumDecodeQueue: DispatchQueue

    init(
        sessionManager: any AudioSessionManaging = SystemAudioSessionManager(),
        playerFactory: any AudioPlayerMaking = SystemAudioPlayerFactory(),
        sampleDecoder: any AudioSampleDecoding = AVAudioFileSampleDecoder(),
        spectrumAnalyzer: AudioSpectrumAnalyzer = AudioSpectrumAnalyzer(),
        limits: AudioPlaybackLimits = AudioPlaybackLimits(),
        spectrumDecodeQueue: DispatchQueue = DispatchQueue(label: "dev.logos.audio-spectrum-decode", qos: .utility)
    ) {
        self.sessionManager = sessionManager
        self.playerFactory = playerFactory
        self.sampleDecoder = sampleDecoder
        self.spectrumAnalyzer = spectrumAnalyzer
        self.limits = limits
        self.spectrumDecodeQueue = spectrumDecodeQueue
        super.init()
    }

    func appendChunk(audioID: String, chunkIndex: Int, base64: String) throws {
        guard chunkIndex >= 0, chunkIndex < limits.maxChunkCount else {
            throw AudioPlaybackError.invalidChunkIndex
        }
        guard base64.utf8.count <= limits.maxBase64ChunkCharacters else {
            throw AudioPlaybackError.chunkTooLarge
        }
        guard let data = Data(base64Encoded: base64) else {
            throw AudioPlaybackError.invalidBase64
        }
        guard data.count <= limits.maxChunkBytes else {
            throw AudioPlaybackError.chunkTooLarge
        }
        var chunks = chunksByAudioID[audioID, default: [:]]
        if chunks[chunkIndex] == nil, chunks.count >= limits.maxChunkCount {
            throw AudioPlaybackError.tooManyChunks
        }
        let currentBytes = chunks.reduce(0) { total, item in
            item.key == chunkIndex ? total : total + item.value.count
        }
        guard currentBytes + data.count <= limits.maxEncodedBytes else {
            throw AudioPlaybackError.audioTooLarge
        }
        chunks[chunkIndex] = data
        chunksByAudioID[audioID] = chunks
    }

    @discardableResult
    func finish(audioID: String, expectedChunkCount: Int? = nil) throws -> AudioPlaybackResult {
        guard let chunks = chunksByAudioID[audioID], chunks.isEmpty == false else {
            throw AudioPlaybackError.noChunks
        }
        if let expectedChunkCount {
            guard expectedChunkCount > 0, expectedChunkCount <= limits.maxChunkCount else {
                throw AudioPlaybackError.missingChunks
            }
            guard Set(chunks.keys) == Set(0..<expectedChunkCount) else {
                throw AudioPlaybackError.missingChunks
            }
        } else {
            guard Set(chunks.keys) == Set(0..<chunks.count) else {
                throw AudioPlaybackError.missingChunks
            }
        }
        guard chunks.count <= limits.maxChunkCount else {
            throw AudioPlaybackError.tooManyChunks
        }
        let ordered = chunks.keys.sorted().compactMap { chunks[$0] }
        let totalBytes = ordered.reduce(0) { $0 + $1.count }
        guard totalBytes <= limits.maxEncodedBytes else {
            throw AudioPlaybackError.audioTooLarge
        }
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
            scheduleSpectrumDecode(audioID: audioID, data: data)
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
        cancelSpectrumDecode(audioID: audioID)
        lifecycleSnapshotsByAudioID.removeValue(forKey: audioID)
        try? sessionManager.finishPlayback()
        onPlaybackFinished?(audioID, flag)
    }

    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        let playerID = ObjectIdentifier(player)
        guard let audioID = audioIDByPlayerID.removeValue(forKey: playerID) else { return }
        playersByAudioID.removeValue(forKey: audioID)
        cancelSpectrumDecode(audioID: audioID)
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
        cancelSpectrumDecode(audioID: audioID)
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
        guard let player = playersByAudioID[audioID], let decodedSamples = spectrumSamplesByAudioID[audioID] else {
            return floorSpectrumBins(count: binCount)
        }
        let bins = spectrumAnalyzer.analyze(
            samples: decodedSamples.samples,
            sampleRate: decodedSamples.sampleRate,
            playheadTime: player.currentTime,
            configuration: AudioSpectrumAnalyzer.Configuration(
                fftSize: 1024,
                binCount: binCount,
                minimumFrequency: 80,
                maximumFrequency: 8_000,
                floorDB: -80
            ),
            previousBins: nil
        )
        return bins
    }

    private func scheduleSpectrumDecode(audioID: String, data: Data) {
        let token = UUID()
        spectrumDecodeTokensByAudioID[audioID] = token
        spectrumSamplesByAudioID.removeValue(forKey: audioID)
        let decoder = sampleDecoder
        spectrumDecodeQueue.async { [weak self] in
            let decodedSamples = try? decoder.decodeSamples(from: data)
            DispatchQueue.main.async { [weak self] in
                guard let self,
                      self.spectrumDecodeTokensByAudioID[audioID] == token else { return }
                self.spectrumDecodeTokensByAudioID.removeValue(forKey: audioID)
                guard self.playersByAudioID[audioID] != nil else {
                    self.spectrumSamplesByAudioID.removeValue(forKey: audioID)
                    return
                }
                if let decodedSamples, decodedSamples.samples.isEmpty == false {
                    self.spectrumSamplesByAudioID[audioID] = decodedSamples
                } else {
                    self.spectrumSamplesByAudioID.removeValue(forKey: audioID)
                }
            }
        }
    }

    private func cancelSpectrumDecode(audioID: String) {
        spectrumDecodeTokensByAudioID.removeValue(forKey: audioID)
        spectrumSamplesByAudioID.removeValue(forKey: audioID)
    }

    func waitForSpectrumDecodeForTesting(audioID: String, timeout: TimeInterval = 5.0) async -> Bool {
        // The decode runs on a background utility queue; it normally completes in well under a
        // second, and the loop returns the instant its token clears. The ceiling exists only to
        // avoid hanging if the decode never runs — keep it generous so a loaded CI runner doesn't
        // time out a decode that is merely slow to be scheduled (was 1.0s; flaked on CI).
        let deadline = Date().addingTimeInterval(timeout)
        while spectrumDecodeTokensByAudioID[audioID] != nil {
            if Date() >= deadline { return false }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return true
    }

    private func floorSpectrumBins(count: Int) -> [Double] {
        Array(repeating: 0.04, count: max(1, count))
    }
}

enum AudioPlaybackError: LocalizedError, Equatable {
    case invalidBase64
    case invalidChunkIndex
    case chunkTooLarge
    case tooManyChunks
    case audioTooLarge
    case noChunks
    case missingChunks
    case playbackDidNotStart

    var errorDescription: String? {
        switch self {
        case .invalidBase64:
            return "Audio chunk was not valid base64."
        case .invalidChunkIndex:
            return "Audio chunk index was invalid."
        case .chunkTooLarge:
            return "Audio chunk was too large."
        case .tooManyChunks:
            return "Audio stream contained too many chunks."
        case .audioTooLarge:
            return "Audio stream was too large."
        case .noChunks:
            return "No audio chunks were received."
        case .missingChunks:
            return "Audio stream ended before all chunks arrived."
        case .playbackDidNotStart:
            return "Audio playback could not start. Check device volume and output route."
        }
    }
}
