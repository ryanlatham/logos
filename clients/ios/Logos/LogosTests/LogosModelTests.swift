import XCTest
import AVFoundation
@testable import Logos

final class LogosModelTests: XCTestCase {
    func testProjectDecodesFromAdapterDictionary() throws {
        let project = LogosProject.from(dictionary: [
            "project_key": "alpha",
            "title": "Alpha",
            "current_session_id": "sess-alpha",
            "last_preview": "Recent work"
        ])
        XCTAssertEqual(project?.projectKey, "alpha")
        XCTAssertEqual(project?.title, "Alpha")
        XCTAssertEqual(project?.currentSessionID, "sess-alpha")
    }

    func testMessageDecodesFromAdapterDictionary() throws {
        let message = LogosMessage.from(dictionary: [
            "project_key": "alpha",
            "session_id": "sess-alpha",
            "message_id": "m1",
            "server_seq": 7,
            "role": "assistant",
            "content": "Done",
            "timestamp": 123.0
        ])
        XCTAssertEqual(message?.id, "sess-alpha:m1")
        XCTAssertEqual(message?.serverSeq, 7)
        XCTAssertEqual(message?.status, "persisted")
    }

    func testSettingsReadSimulatorLaunchEnvironment() throws {
        let settings = LogosSettings(environment: [
            "LOGOS_WS_URL": "ws://127.0.0.1:9999",
            "LOGOS_DEVICE_ID": "test-device",
            "LOGOS_DEVICE_SECRET": "secret",
            "LOGOS_AUTOCONNECT": "1"
        ])
        XCTAssertEqual(settings.urlString, "ws://127.0.0.1:9999")
        XCTAssertEqual(settings.deviceID, "test-device")
        XCTAssertEqual(settings.secret, "secret")
        XCTAssertTrue(settings.autoConnect)
    }

    func testHelloSignatureMatchesServerCanonicalHMAC() throws {
        let signature = LogosAuthentication.signHello(
            secret: "dev-secret",
            deviceID: "iphone",
            requestID: "hello-1",
            projectKey: "default",
            timestampMilliseconds: 1_778_760_000_000,
            nonce: "nonce-for-test-123"
        )
        XCTAssertEqual(signature, "8e759986cbf64221407462255218bb440f72c338ffa5753fec9c526211f2f5e3")
    }

    func testTapToTalkStopsAfterTrailingSilenceOnlyAfterSpeech() throws {
        var detector = TapToTalkSilenceDetector(
            energyThreshold: 0.05,
            trailingSilenceSeconds: 0.8,
            initialSilenceSeconds: 2.0
        )
        detector.start(at: 10.0)
        XCTAssertEqual(detector.observe(energy: 0.12, at: 10.1), .continueListening)
        XCTAssertEqual(detector.observe(energy: 0.01, at: 10.7), .continueListening)
        XCTAssertEqual(detector.observe(energy: 0.01, at: 11.0), .autoStop(reason: .trailingSilence))
    }

    func testTapToTalkStopsAfterInitialSilenceWithoutSpeech() throws {
        var detector = TapToTalkSilenceDetector(
            energyThreshold: 0.05,
            trailingSilenceSeconds: 0.8,
            initialSilenceSeconds: 1.2
        )
        detector.start(at: 20.0)
        XCTAssertEqual(detector.observe(energy: 0.01, at: 21.0), .continueListening)
        XCTAssertEqual(detector.observe(energy: 0.01, at: 21.3), .autoStop(reason: .initialSilence))
    }

    func testSpeechRecognitionPolicyDoesNotSilentlyUseNetworkRecognition() throws {
        let disabled = VoiceRecognitionPolicy.resolve(supportsOnDeviceRecognition: false)
        XCTAssertFalse(disabled.voiceEnabled)
        XCTAssertFalse(disabled.requiresOnDeviceRecognition)
        XCTAssertTrue(disabled.message.contains("On-device speech recognition is unavailable"))

        let enabled = VoiceRecognitionPolicy.resolve(supportsOnDeviceRecognition: true)
        XCTAssertTrue(enabled.voiceEnabled)
        XCTAssertTrue(enabled.requiresOnDeviceRecognition)
    }

    func testVoiceControlsStayEnabledToStopActiveRecordingAfterDisconnect() throws {
        XCTAssertTrue(VoiceControlPolicy.controlsDisabled(voiceEnabled: true, connected: false, isRecording: false))
        XCTAssertFalse(VoiceControlPolicy.controlsDisabled(voiceEnabled: true, connected: false, isRecording: true))
        XCTAssertFalse(VoiceControlPolicy.controlsDisabled(voiceEnabled: true, connected: true, isRecording: false))
        XCTAssertTrue(VoiceControlPolicy.controlsDisabled(
            voiceEnabled: true,
            connected: true,
            isRecording: false,
            isFinalizing: true
        ))
    }

    func testVoiceStartIntentTrackerRejectsReleasedOrSupersededStarts() throws {
        var tracker = VoiceStartIntentTracker<String>()
        let first = try XCTUnwrap(tracker.begin(mode: "hold"))
        XCTAssertTrue(tracker.accepts(id: first, mode: "hold"))
        XCTAssertNil(tracker.begin(mode: "tap"))

        tracker.cancel(mode: "hold")
        XCTAssertFalse(tracker.accepts(id: first, mode: "hold"))

        let second = try XCTUnwrap(tracker.begin(mode: "tap"))
        XCTAssertTrue(tracker.accepts(id: second, mode: "tap"))
        XCTAssertFalse(tracker.accepts(id: first, mode: "hold"))
    }

    @MainActor
    func testVoiceTransportAvailabilityUpdatesIdleStatus() throws {
        let voice = VoiceInputController()
        voice.updateTransportAvailable(false)
        if voice.voiceEnabled {
            XCTAssertEqual(voice.statusText, "Connect to Logos before using voice")
        } else {
            XCTAssertEqual(voice.statusText, "Voice unavailable")
        }
    }

    func testSpeechFrameIncludesPartialAndFinalMetadata() throws {
        let partial = LogosSpeechFrame.make(
            text: "hello wor",
            isFinal: false,
            inputID: "turn-1",
            partialSeq: 3,
            startedAtMilliseconds: 123456,
            deviceID: "iphone",
            projectKey: "default"
        )
        XCTAssertEqual(partial["type"] as? String, "speech")
        let payload = try XCTUnwrap(partial["payload"] as? [String: Any])
        XCTAssertEqual(payload["text"] as? String, "hello wor")
        XCTAssertEqual(payload["is_final"] as? Bool, false)
        XCTAssertEqual(payload["client_msg_id"] as? String, "turn-1")
        XCTAssertEqual(payload["partial_seq"] as? Int, 3)

        let final = LogosSpeechFrame.make(
            text: "hello world",
            isFinal: true,
            inputID: "turn-1",
            partialSeq: 4,
            startedAtMilliseconds: 123456,
            deviceID: "iphone",
            projectKey: "default"
        )
        let finalPayload = try XCTUnwrap(final["payload"] as? [String: Any])
        XCTAssertEqual(finalPayload["is_final"] as? Bool, true)
        XCTAssertEqual(finalPayload["partial_seq"] as? Int, 4)
    }

    func testSpeechPermissionUsageDescriptionsAreConfigured() throws {
        let info = Bundle.main.infoDictionary ?? [:]
        let mic = try XCTUnwrap(info["NSMicrophoneUsageDescription"] as? String)
        let speech = try XCTUnwrap(info["NSSpeechRecognitionUsageDescription"] as? String)
        XCTAssertTrue(mic.contains("microphone"))
        XCTAssertTrue(speech.contains("On-device"))
    }

    func testNotificationRouteParsesPrivatePushPayload() throws {
        let route = try XCTUnwrap(LogosNotificationRoute.from(userInfo: [
            "kind": "finished",
            "project_key": "default",
            "session_id": "session-1",
            "message_id": "msg-1",
            "server_seq": "42"
        ]))
        XCTAssertEqual(route.kind, "finished")
        XCTAssertEqual(route.projectKey, "default")
        XCTAssertEqual(route.sessionID, "session-1")
        XCTAssertEqual(route.messageID, "msg-1")
        XCTAssertEqual(route.serverSeq, 42)
    }

    func testNotificationRouteParsesLogosDeepLink() throws {
        let url = try XCTUnwrap(URL(string: "logos://notification?kind=approval&project_key=default&request_id=appr-1&server_seq=12"))
        let route = try XCTUnwrap(LogosNotificationRoute.from(url: url))
        XCTAssertEqual(route.kind, "approval")
        XCTAssertEqual(route.projectKey, "default")
        XCTAssertEqual(route.requestID, "appr-1")
        XCTAssertEqual(route.serverSeq, 12)
    }

    func testRemoteNotificationBackgroundModeConfigured() throws {
        let modes = try XCTUnwrap(Bundle.main.infoDictionary?["UIBackgroundModes"] as? [String])
        XCTAssertTrue(modes.contains("remote-notification"))
        let urlTypes = try XCTUnwrap(Bundle.main.infoDictionary?["CFBundleURLTypes"] as? [[String: Any]])
        let schemes = urlTypes.flatMap { ($0["CFBundleURLSchemes"] as? [String]) ?? [] }
        XCTAssertTrue(schemes.contains("logos"))
    }

    func testConnectionLifecycleRejectsStaleCallbacksAfterDisconnectOrReconnect() throws {
        var lifecycle = LogosConnectionLifecycle()
        let first = lifecycle.startConnection()
        XCTAssertTrue(lifecycle.accepts(first))

        lifecycle.invalidate()
        XCTAssertFalse(lifecycle.accepts(first))

        let second = lifecycle.startConnection()
        XCTAssertFalse(lifecycle.accepts(first))
        XCTAssertTrue(lifecycle.accepts(second))
    }

    @MainActor
    func testDisconnectClearsVisibleErrorAndReportsDisconnected() throws {
        let client = LogosClient()
        client.lastError = "The socket is not connected."

        client.disconnect()

        XCTAssertNil(client.lastError)
        XCTAssertEqual(client.connectionState, .disconnected)
    }

    @MainActor
    func testSuccessfulInboundFrameClearsVisibleErrorAndMarksConnected() throws {
        let client = LogosClient()
        client.lastError = "Cannot reconnect: stale socket failure."

        client.handleFrameString("""
        {"type":"hello","request_id":"hello-1","payload":{}}
        """)

        XCTAssertNil(client.lastError)
        XCTAssertEqual(client.connectionState, .connected)
    }

    @MainActor
    func testSuccessfulOperationFrameClearsPriorAdapterError() throws {
        let client = LogosClient()
        client.lastError = "Cannot send a message: Logos is not connected."

        client.handleFrameString("""
        {"type":"projects_list","payload":{"projects":[],"active_project_key":"default"}}
        """)

        XCTAssertNil(client.lastError)
    }

    @MainActor
    func testAudioFramesForOtherDevicesAreIgnored() throws {
        let client = LogosClient()
        client.settings.deviceID = "iphone-a"

        client.handleFrameString("""
        {"type":"audio_chunk","device_id":"iphone-b","payload":{"audio_id":"foreign-audio","chunk_index":0,"data":"not-base64"}}
        """)

        XCTAssertNil(client.lastError)
        XCTAssertNil(client.playbackStatus)
    }

    func testAudioPlaybackPreparesPlaybackSessionBeforeStartingPlayer() throws {
        let session = RecordingAudioSessionManager()
        let factory = RecordingAudioPlayerFactory()
        let controller = AudioPlaybackController(sessionManager: session, playerFactory: factory)
        try controller.appendChunk(audioID: "audio-1", chunkIndex: 1, base64: Data([3, 4]).base64EncodedString())
        try controller.appendChunk(audioID: "audio-1", chunkIndex: 0, base64: Data([1, 2]).base64EncodedString())

        let result = try controller.finish(audioID: "audio-1", expectedChunkCount: 2)

        XCTAssertEqual(session.prepareCalls, 1)
        XCTAssertEqual(factory.receivedData, Data([1, 2, 3, 4]))
        XCTAssertEqual(factory.player.prepareCalls, 1)
        XCTAssertEqual(factory.player.playCalls, 1)
        XCTAssertNotNil(factory.player.delegate)
        XCTAssertEqual(session.finishCalls, 0)
        XCTAssertEqual(result, AudioPlaybackResult(byteCount: 4, started: true))
    }

    func testAudioPlaybackReportsPlayerStartFailure() throws {
        let factory = RecordingAudioPlayerFactory()
        factory.player.playResult = false
        let session = RecordingAudioSessionManager()
        let controller = AudioPlaybackController(
            sessionManager: session,
            playerFactory: factory
        )
        try controller.appendChunk(audioID: "audio-1", chunkIndex: 0, base64: Data([1, 2]).base64EncodedString())

        XCTAssertThrowsError(try controller.finish(audioID: "audio-1", expectedChunkCount: 1)) { error in
            guard case AudioPlaybackError.playbackDidNotStart = error else {
                XCTFail("Expected playbackDidNotStart, got \(error)")
                return
            }
        }
        XCTAssertEqual(session.finishCalls, 1)
    }
}

private final class RecordingAudioSessionManager: AudioSessionManaging {
    private(set) var prepareCalls = 0
    private(set) var finishCalls = 0

    func prepareForPlayback() throws {
        prepareCalls += 1
    }

    func finishPlayback() throws {
        finishCalls += 1
    }
}

private final class RecordingAudioPlayer: AudioPlaying {
    weak var delegate: AVAudioPlayerDelegate?
    var prepareResult = true
    var playResult = true
    private(set) var prepareCalls = 0
    private(set) var playCalls = 0

    func prepareToPlay() -> Bool {
        prepareCalls += 1
        return prepareResult
    }

    func play() -> Bool {
        playCalls += 1
        return playResult
    }
}

private final class RecordingAudioPlayerFactory: AudioPlayerMaking {
    let player = RecordingAudioPlayer()
    private(set) var receivedData = Data()

    func makePlayer(data: Data) throws -> any AudioPlaying {
        receivedData = data
        return player
    }
}
