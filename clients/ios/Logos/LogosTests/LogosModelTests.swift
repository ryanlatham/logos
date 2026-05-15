import XCTest
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
}
