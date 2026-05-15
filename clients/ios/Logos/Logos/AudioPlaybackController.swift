import AVFoundation
import Foundation

final class AudioPlaybackController {
    private var chunksByAudioID: [String: [Int: Data]] = [:]
    private var playersByAudioID: [String: AVAudioPlayer] = [:]

    func appendChunk(audioID: String, chunkIndex: Int, base64: String) throws {
        guard let data = Data(base64Encoded: base64) else {
            throw AudioPlaybackError.invalidBase64
        }
        var chunks = chunksByAudioID[audioID, default: [:]]
        chunks[chunkIndex] = data
        chunksByAudioID[audioID] = chunks
    }

    @discardableResult
    func finish(audioID: String, expectedChunkCount: Int? = nil) throws -> Int {
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
        let player = try AVAudioPlayer(data: data)
        player.prepareToPlay()
        player.play()
        playersByAudioID[audioID] = player
        chunksByAudioID.removeValue(forKey: audioID)
        return data.count
    }
}

enum AudioPlaybackError: LocalizedError {
    case invalidBase64
    case noChunks
    case missingChunks

    var errorDescription: String? {
        switch self {
        case .invalidBase64:
            return "Audio chunk was not valid base64."
        case .noChunks:
            return "No audio chunks were received."
        case .missingChunks:
            return "Audio stream ended before all chunks arrived."
        }
    }
}
