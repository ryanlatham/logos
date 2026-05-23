import XCTest
import AVFoundation
@testable import Logos

final class LogosModelTests: XCTestCase {
    func testProjectSwitcherLayoutCapsDropdownAndMakesOverflowScrollable() throws {
        let metrics = ProjectSwitcherLayout.metrics(
            screenHeight: 812,
            projectCount: 30,
            isCreatingProject: false
        )

        XCTAssertLessThanOrEqual(metrics.dropdownMaxHeight, 812 * 0.75)
        XCTAssertLessThan(metrics.projectListMaxHeight, metrics.projectListContentHeight)
        XCTAssertTrue(metrics.isProjectListScrollable)
    }

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

    func testSettingsDefaultAdapterURLUsesTailscaleMagicDNS() throws {
        let suiteName = "LogosSettingsDefaultAdapterURL-\(UUID().uuidString)"
        let userDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { userDefaults.removePersistentDomain(forName: suiteName) }

        let settings = LogosSettings(environment: [:], userDefaults: userDefaults)

        XCTAssertEqual(settings.urlString, "wss://studio.tail752253.ts.net/")
    }

    @MainActor
    func testConnectWaitsForWebSocketOpenBeforeStartupFrames() async throws {
        let socket = RecordingWebSocketTask()
        let client = LogosClient(
            store: SQLiteMessageStore(filename: "LogosTests-\(UUID().uuidString).sqlite3"),
            socketFactory: RecordingWebSocketTaskFactory(socket: socket)
        )
        client.settings.urlString = "wss://studio.tail752253.ts.net/"
        client.settings.secret = "test-secret"

        client.connect()

        XCTAssertEqual(client.connectionState, .connecting)
        XCTAssertTrue(socket.sentMessages.isEmpty)

        socket.open()
        await Task.yield()

        XCTAssertEqual(try socket.sentMessages.map { try frameType(from: $0) }, ["hello"])
        XCTAssertEqual(client.connectionState, .connecting)

        client.handleFrameString(#"{"type":"hello","request_id":"hello-1","payload":{"authenticated":true}}"#)

        XCTAssertEqual(client.connectionState, .connected)
        XCTAssertEqual(try socket.sentMessages.map { try frameType(from: $0) }, [
            "hello",
            "register_device",
            "list_projects"
        ])
    }

    @MainActor
    func testRegisterDeviceBeforeSocketOpenQueuesTokenWithoutSending() async throws {
        let socket = RecordingWebSocketTask()
        let client = LogosClient(
            store: SQLiteMessageStore(filename: "LogosTests-\(UUID().uuidString).sqlite3"),
            socketFactory: RecordingWebSocketTaskFactory(socket: socket)
        )
        client.settings.urlString = "wss://studio.tail752253.ts.net/"
        client.settings.secret = "test-secret"

        client.connect()
        client.registerDevice(apnsToken: "apns-token")

        XCTAssertEqual(client.connectionState, .connecting)
        XCTAssertNil(client.lastError)
        XCTAssertTrue(socket.sentMessages.isEmpty)

        socket.open()
        await Task.yield()

        XCTAssertEqual(try socket.sentMessages.map { try frameType(from: $0) }, ["hello"])

        client.handleFrameString(#"{"type":"hello","request_id":"hello-1","payload":{"authenticated":true}}"#)

        XCTAssertEqual(try socket.sentMessages.map { try frameType(from: $0) }, [
            "hello",
            "register_device",
            "list_projects"
        ])
        let registerFrame = try frameRoot(from: socket.sentMessages[1])
        let registerPayload = try XCTUnwrap(registerFrame["payload"] as? [String: Any])
        XCTAssertEqual(registerPayload["apns_token"] as? String, "apns-token")

        client.handleFrameString(#"{"type":"registered","request_id":"register-1","payload":{"device":{"device_id":"iphone-a","apns_registered":true}}}"#)
        client.registerDevice(apnsToken: nil)

        XCTAssertEqual(try socket.sentMessages.map { try frameType(from: $0) }, [
            "hello",
            "register_device",
            "list_projects",
            "register_device"
        ])
        let postAckRegisterFrame = try frameRoot(from: socket.sentMessages[3])
        let postAckRegisterPayload = try XCTUnwrap(postAckRegisterFrame["payload"] as? [String: Any])
        XCTAssertNil(postAckRegisterPayload["apns_token"])
    }

    @MainActor
    func testAuthErrorDuringHandshakeDoesNotMarkConnectedOrSendStartupFrames() async throws {
        let socket = RecordingWebSocketTask()
        let client = LogosClient(
            store: SQLiteMessageStore(filename: "LogosTests-\(UUID().uuidString).sqlite3"),
            socketFactory: RecordingWebSocketTaskFactory(socket: socket)
        )
        client.settings.urlString = "wss://studio.tail752253.ts.net/"
        client.settings.secret = "wrong-secret"

        client.connect()
        socket.open()
        await Task.yield()

        XCTAssertEqual(try socket.sentMessages.map { try frameType(from: $0) }, ["hello"])

        socket.receiveString(#"{"type":"error","request_id":"hello-1","project_key":"default","payload":{"code":"auth_failed","reason":"invalid_signature","message":"invalid Logos signed hello: signature mismatch"}}"#)
        await Task.yield()

        XCTAssertEqual(client.connectionState, .error)
        XCTAssertEqual(client.lastError, "Logos authentication failed: signature mismatch. Check that the iOS Device key matches LOGOS_DEVICE_SECRET on the Logos adapter.")
        XCTAssertEqual(try socket.sentMessages.map { try frameType(from: $0) }, ["hello"])
    }

    @MainActor
    func testSocketFailureBeforeOpenReportsErrorWithoutStartupFrames() async throws {
        let socket = RecordingWebSocketTask()
        let client = LogosClient(
            store: SQLiteMessageStore(filename: "LogosTests-\(UUID().uuidString).sqlite3"),
            socketFactory: RecordingWebSocketTaskFactory(socket: socket)
        )
        client.settings.urlString = "wss://studio.tail752253.ts.net/"
        client.settings.secret = "test-secret"

        client.connect()
        socket.fail(message: "Socket is not connected")
        await Task.yield()

        XCTAssertEqual(client.connectionState, .error)
        XCTAssertEqual(client.lastError, "Socket is not connected")
        XCTAssertTrue(socket.sentMessages.isEmpty)
    }

    func testAutoConnectDefaultsOnButWaitsForFirstSuccessfulConnection() throws {
        let suiteName = "LogosSettingsAutoConnectDefault-\(UUID().uuidString)"
        let userDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { userDefaults.removePersistentDomain(forName: suiteName) }

        let settings = LogosSettings(environment: [:], userDefaults: userDefaults)

        XCTAssertTrue(settings.autoConnect)
        XCTAssertFalse(settings.hasCompletedFirstConnection)
        XCTAssertFalse(LogosAutoConnectPolicy.shouldAttempt(
            autoConnect: settings.autoConnect,
            hasCompletedFirstConnection: settings.hasCompletedFirstConnection,
            connectionState: .disconnected
        ))
    }

    func testAutoConnectPolicyAttemptsOnlyAfterFirstConnectionWhenDisconnected() throws {
        XCTAssertTrue(LogosAutoConnectPolicy.shouldAttempt(
            autoConnect: true,
            hasCompletedFirstConnection: true,
            connectionState: .disconnected
        ))
        XCTAssertTrue(LogosAutoConnectPolicy.shouldAttempt(
            autoConnect: true,
            hasCompletedFirstConnection: true,
            connectionState: .error
        ))
        XCTAssertFalse(LogosAutoConnectPolicy.shouldAttempt(
            autoConnect: true,
            hasCompletedFirstConnection: true,
            connectionState: .connecting
        ))
        XCTAssertFalse(LogosAutoConnectPolicy.shouldAttempt(
            autoConnect: false,
            hasCompletedFirstConnection: true,
            connectionState: .disconnected
        ))
    }

    func testEnvironmentAutoConnectBypassesFirstConnectionGateForUITests() throws {
        let suiteName = "LogosSettingsAutoConnectEnvironment-\(UUID().uuidString)"
        let userDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { userDefaults.removePersistentDomain(forName: suiteName) }

        let settings = LogosSettings(environment: ["LOGOS_AUTOCONNECT": "1"], userDefaults: userDefaults)

        XCTAssertTrue(settings.autoConnect)
        XCTAssertTrue(settings.hasCompletedFirstConnection)
    }

    func testSettingsTrimsDeviceSecretFromEnvironment() throws {
        let suiteName = "LogosSettingsSecretTrim-\(UUID().uuidString)"
        let userDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { userDefaults.removePersistentDomain(forName: suiteName) }

        let settings = LogosSettings(
            environment: ["LOGOS_DEVICE_SECRET": "  configured-secret\n"],
            userDefaults: userDefaults
        )

        XCTAssertEqual(settings.secret, "configured-secret")
    }

    func testMessageStoreFilenameCanBeIsolatedByLaunchEnvironment() throws {
        XCTAssertEqual(
            SQLiteMessageStore.resolvedFilename(environment: ["LOGOS_MESSAGE_STORE_FILENAME": "LogosUITests-one.sqlite3"]),
            "LogosUITests-one.sqlite3"
        )
        XCTAssertEqual(
            SQLiteMessageStore.resolvedFilename(environment: ["LOGOS_MESSAGE_STORE_FILENAME": "../escape.sqlite3"]),
            "escape.sqlite3"
        )
        XCTAssertEqual(SQLiteMessageStore.resolvedFilename(environment: [:]), "LogosMessages.sqlite3")
    }

    func testPairingRouteParsesVersionedBase64URLFragment() throws {
        let payload: [String: Any] = [
            "v": 1,
            "adapter_url": "wss://studio.tail752253.ts.net/",
            "device_id": "iphone-17-pro",
            "pair_token": "one-time-token",
            "expires_at": 1_778_760_000.0,
            "autoconnect": true
        ]
        let url = try XCTUnwrap(URL(string: "logos://pair#\(base64URLPayload(payload))"))

        let route = try XCTUnwrap(LogosPairingRoute.from(url: url))

        XCTAssertEqual(route.adapterURL, "wss://studio.tail752253.ts.net/")
        XCTAssertEqual(route.deviceID, "iphone-17-pro")
        XCTAssertEqual(route.pairToken, "one-time-token")
        XCTAssertEqual(route.expiresAt, Date(timeIntervalSince1970: 1_778_760_000.0))
        XCTAssertTrue(route.autoConnect)
        XCTAssertNil(route.deviceSecret)
    }

    func testPairingRouteRejectsPayloadWithoutTokenOrSecret() throws {
        let payload: [String: Any] = [
            "v": 1,
            "adapter_url": "wss://studio.tail752253.ts.net/",
            "device_id": "iphone-17-pro"
        ]
        let url = try XCTUnwrap(URL(string: "logos://pair#\(base64URLPayload(payload))"))

        XCTAssertNil(LogosPairingRoute.from(url: url))
        XCTAssertNil(LogosPairingRoute.from(url: URL(string: "logos://notification?kind=approval")!))
    }

    func testPairingRouteRejectsDirectDeviceSecretPayload() throws {
        let payload: [String: Any] = [
            "v": 1,
            "adapter_url": "wss://studio.tail752253.ts.net/",
            "device_id": "iphone-17-pro",
            "device_secret": "do-not-accept-secrets-in-qr"
        ]
        let url = try XCTUnwrap(URL(string: "logos://pair#\(base64URLPayload(payload))"))

        XCTAssertNil(LogosPairingRoute.from(url: url))
    }

    func testPairingRouteRequiresSecureTransportExceptLoopback() throws {
        let secure = LogosPairingRoute(
            adapterURL: "wss://studio.tail752253.ts.net/",
            deviceID: "iphone-17-pro",
            pairToken: "one-time-token",
            deviceSecret: nil,
            expiresAt: Date().addingTimeInterval(120),
            autoConnect: true
        )
        let simulatorLoopback = LogosPairingRoute(
            adapterURL: "ws://127.0.0.1:8766",
            deviceID: "iphone-17-pro",
            pairToken: "one-time-token",
            deviceSecret: nil,
            expiresAt: Date().addingTimeInterval(120),
            autoConnect: true
        )
        let lanPlaintext = LogosPairingRoute(
            adapterURL: "ws://192.168.1.44:8765",
            deviceID: "iphone-17-pro",
            pairToken: "one-time-token",
            deviceSecret: nil,
            expiresAt: Date().addingTimeInterval(120),
            autoConnect: true
        )

        XCTAssertTrue(secure.allowsPairingTransport)
        XCTAssertTrue(simulatorLoopback.allowsPairingTransport)
        XCTAssertFalse(lanPlaintext.allowsPairingTransport)
    }

    @MainActor
    func testApplyPairingRouteExchangesTokenPersistsCredentialAndConnects() async throws {
        let socket = RecordingWebSocketTask()
        let exchanger = RecordingPairingCredentialExchanger()
        exchanger.credential = LogosPairingCredential(
            adapterURL: "wss://studio.tail752253.ts.net/",
            deviceID: "iphone-17-pro",
            deviceSecret: "per-device-secret"
        )
        let client = LogosClient(
            store: SQLiteMessageStore(filename: "LogosTests-\(UUID().uuidString).sqlite3"),
            socketFactory: RecordingWebSocketTaskFactory(socket: socket),
            pairingExchanger: exchanger
        )
        let route = LogosPairingRoute(
            adapterURL: "wss://studio.tail752253.ts.net/",
            deviceID: "iphone-17-pro",
            pairToken: "one-time-token",
            deviceSecret: nil,
            expiresAt: Date().addingTimeInterval(120),
            autoConnect: true
        )

        await client.applyPairingRoute(route)

        XCTAssertEqual(exchanger.routes, [route])
        XCTAssertEqual(client.settings.urlString, "wss://studio.tail752253.ts.net/")
        XCTAssertEqual(client.settings.deviceID, "iphone-17-pro")
        XCTAssertEqual(client.settings.secret, "per-device-secret")
        XCTAssertTrue(client.settings.autoConnect)
        XCTAssertTrue(client.settings.hasCompletedFirstConnection)
        XCTAssertEqual(client.connectionState, .connecting)
        XCTAssertNil(client.lastError)
        XCTAssertTrue(socket.sentMessages.isEmpty)
    }

    @MainActor
    func testFailedPairingWhileConnectedKeepsExistingConnectionUsable() async throws {
        let socket = RecordingWebSocketTask()
        let exchanger = RecordingPairingCredentialExchanger()
        exchanger.error = LogosPairingExchangeError.adapterRejected("Pairing token expired")
        let client = LogosClient(
            store: SQLiteMessageStore(filename: "LogosTests-\(UUID().uuidString).sqlite3"),
            socketFactory: RecordingWebSocketTaskFactory(socket: socket),
            pairingExchanger: exchanger
        )
        client.settings.urlString = "wss://old-adapter.tail752253.ts.net/"
        client.settings.deviceID = "old-device"
        client.settings.secret = "old-secret"
        client.connect()
        socket.open()
        await Task.yield()
        client.handleFrameString(#"{"type":"hello","request_id":"hello-1","payload":{"authenticated":true}}"#)
        XCTAssertEqual(client.connectionState, .connected)

        let route = LogosPairingRoute(
            adapterURL: "wss://studio.tail752253.ts.net/",
            deviceID: "iphone-17-pro",
            pairToken: "one-time-token",
            deviceSecret: nil,
            expiresAt: Date().addingTimeInterval(120),
            autoConnect: true
        )
        await client.applyPairingRoute(route)

        XCTAssertEqual(exchanger.routes, [route])
        XCTAssertEqual(client.connectionState, .connected)
        XCTAssertEqual(client.settings.urlString, "wss://old-adapter.tail752253.ts.net/")
        XCTAssertEqual(client.settings.deviceID, "old-device")
        XCTAssertEqual(client.settings.secret, "old-secret")
        XCTAssertTrue(client.lastError?.contains("Logos pairing failed") == true)
        XCTAssertTrue(client.createProject(title: "Still usable"))
    }

    @MainActor
    func testExpiredPairingRouteFailsBeforeExchange() async throws {
        let socket = RecordingWebSocketTask()
        let exchanger = RecordingPairingCredentialExchanger()
        exchanger.credential = LogosPairingCredential(
            adapterURL: "wss://studio.tail752253.ts.net/",
            deviceID: "iphone-17-pro",
            deviceSecret: "per-device-secret"
        )
        let client = LogosClient(
            store: SQLiteMessageStore(filename: "LogosTests-\(UUID().uuidString).sqlite3"),
            socketFactory: RecordingWebSocketTaskFactory(socket: socket),
            pairingExchanger: exchanger
        )
        let route = LogosPairingRoute(
            adapterURL: "wss://studio.tail752253.ts.net/",
            deviceID: "iphone-17-pro",
            pairToken: "one-time-token",
            deviceSecret: nil,
            expiresAt: Date().addingTimeInterval(-1),
            autoConnect: true
        )

        await client.applyPairingRoute(route)

        XCTAssertTrue(exchanger.routes.isEmpty)
        XCTAssertEqual(client.connectionState, .error)
        XCTAssertTrue(client.lastError?.contains("expired") == true)
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

    func testTapToTalkDefaultAllowsNaturalMidSentencePause() throws {
        var detector = TapToTalkSilenceDetector()
        detector.start(at: 30.0)

        XCTAssertEqual(detector.observe(energy: 0.12, at: 30.1), .continueListening)
        XCTAssertEqual(detector.observe(energy: 0.001, at: 31.4), .continueListening)
    }

    func testTapToTalkDefaultStopsAfterLongTrailingSilence() throws {
        var detector = TapToTalkSilenceDetector()
        detector.start(at: 40.0)

        XCTAssertEqual(detector.observe(energy: 0.12, at: 40.1), .continueListening)
        XCTAssertEqual(detector.observe(energy: 0.001, at: 42.7), .autoStop(reason: .trailingSilence))
    }

    func testTapToTalkDefaultTreatsQuietSpeechAsActivity() throws {
        var detector = TapToTalkSilenceDetector()
        detector.start(at: 50.0)

        XCTAssertEqual(detector.observe(energy: 0.12, at: 50.1), .continueListening)
        XCTAssertEqual(detector.observe(energy: 0.018, at: 51.4), .continueListening)
        XCTAssertEqual(detector.observe(energy: 0.001, at: 52.8), .continueListening)
    }

    func testTapToTalkASRProgressExtendsSilenceWindow() throws {
        var detector = TapToTalkSilenceDetector(
            energyThreshold: 0.05,
            trailingSilenceSeconds: 1.0,
            initialSilenceSeconds: 2.0
        )
        detector.start(at: 60.0)

        XCTAssertEqual(detector.observe(energy: 0.12, at: 60.1), .continueListening)
        XCTAssertEqual(detector.observe(energy: 0.001, at: 61.0), .continueListening)
        detector.markSpeech(at: 61.05)
        XCTAssertEqual(detector.observe(energy: 0.001, at: 61.9), .continueListening)
        XCTAssertEqual(detector.observe(energy: 0.001, at: 62.2), .autoStop(reason: .trailingSilence))
    }

    func testTapToTalkStopsAfterInitialSilenceWithoutSpeech() throws {
        var detector = TapToTalkSilenceDetector(
            energyThreshold: 0.05,
            trailingSilenceSeconds: 0.8,
            initialSilenceSeconds: 1.2,
            maximumRecordingSeconds: 10.0
        )
        detector.start(at: 20.0)
        XCTAssertEqual(detector.observe(energy: 0.01, at: 21.0), .continueListening)
        XCTAssertEqual(detector.observe(energy: 0.01, at: 21.3), .autoStop(reason: .initialSilence))
    }

    func testTapToTalkStopsAtMaximumDurationDuringContinuousAudio() throws {
        var detector = TapToTalkSilenceDetector(
            energyThreshold: 0.05,
            trailingSilenceSeconds: 0.8,
            initialSilenceSeconds: 1.2,
            maximumRecordingSeconds: 3.0
        )
        detector.start(at: 70.0)

        XCTAssertEqual(detector.observe(energy: 0.12, at: 70.5), .continueListening)
        XCTAssertEqual(detector.observe(energy: 0.12, at: 72.5), .continueListening)
        XCTAssertEqual(detector.observe(energy: 0.12, at: 73.1), .autoStop(reason: .maximumDuration))
    }

    func testSpeechRecognitionPolicyDoesNotSilentlyUseNetworkRecognition() throws {
        let disabled = VoiceRecognitionPolicy.resolve(supportsOnDeviceRecognition: false)
        XCTAssertFalse(disabled.voiceEnabled)
        XCTAssertFalse(disabled.requiresOnDeviceRecognition)
        XCTAssertTrue(disabled.message.contains("On-device speech recognition is unavailable"))

        let enabled = VoiceRecognitionPolicy.resolve(supportsOnDeviceRecognition: true)
        XCTAssertTrue(enabled.voiceEnabled)
        XCTAssertTrue(enabled.requiresOnDeviceRecognition)

        let temporarilyUnavailable = VoiceRecognitionPolicy.resolve(
            supportsOnDeviceRecognition: true,
            isRecognizerAvailable: false
        )
        XCTAssertFalse(temporarilyUnavailable.voiceEnabled)
        XCTAssertTrue(temporarilyUnavailable.requiresOnDeviceRecognition)
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

    func testComposerReturnsToPausedAudioModeAfterVoiceTurnFinishes() throws {
        XCTAssertEqual(ComposerModePolicy.modeAfterVoiceFinished(current: .recording), .paused)
    }

    func testFinalizingSpeechErrorWithoutInterimTranscriptKeepsWaitingForBufferedFinal() throws {
        XCTAssertEqual(
            VoiceFinalizationPolicy.actionForRecognitionError(isFinalizing: true, hasBufferedTranscript: false),
            .waitForFinalResult
        )
    }

    func testFinalizingSpeechErrorWithBufferedTranscriptSendsBestTranscript() throws {
        XCTAssertEqual(
            VoiceFinalizationPolicy.actionForRecognitionError(isFinalizing: true, hasBufferedTranscript: true),
            .finishWithBestTranscript
        )
    }

    func testActiveSpeechErrorOutsideFinalizationCancelsRecognition() throws {
        XCTAssertEqual(
            VoiceFinalizationPolicy.actionForRecognitionError(isFinalizing: false, hasBufferedTranscript: true),
            .cancelRecognition
        )
    }

    func testFinalizationFallbackSendsBufferedPartialAfterAutoStopWithoutASRFinal() throws {
        var finalization = VoiceFinalizationState()

        XCTAssertEqual(finalization.noteTranscript("hello Hermes", isFinal: false), .keepWaiting)
        XCTAssertEqual(finalization.begin(sendFinal: true, transcript: "hello Hermes"), .scheduleBestTranscriptFallback)
        XCTAssertEqual(finalization.timerFired(.bestTranscriptGrace), .sendFinal)
        XCTAssertEqual(finalization.timerFired(.hardTimeout), .keepWaiting)
    }

    func testFinalASRResultBeatsBestTranscriptFallback() throws {
        var finalization = VoiceFinalizationState()

        XCTAssertEqual(finalization.noteTranscript("hello Her", isFinal: false), .keepWaiting)
        XCTAssertEqual(finalization.begin(sendFinal: true, transcript: "hello Her"), .scheduleBestTranscriptFallback)
        XCTAssertEqual(finalization.noteTranscript("hello Hermes", isFinal: true), .sendFinal)
        XCTAssertEqual(finalization.timerFired(.bestTranscriptGrace), .keepWaiting)
    }

    func testFinalizingRecognitionErrorWithBufferedTranscriptSendsOnce() throws {
        var finalization = VoiceFinalizationState()

        XCTAssertEqual(finalization.noteTranscript("ship it", isFinal: false), .keepWaiting)
        XCTAssertEqual(finalization.begin(sendFinal: true, transcript: "ship it"), .scheduleBestTranscriptFallback)
        XCTAssertEqual(finalization.recognitionError(), .sendFinal)
        XCTAssertEqual(finalization.timerFired(.bestTranscriptGrace), .keepWaiting)
    }

    func testEmptyFinalizationFinishesWithoutSending() throws {
        var finalization = VoiceFinalizationState()

        XCTAssertEqual(finalization.begin(sendFinal: true, transcript: "   "), .keepWaiting)
        XCTAssertEqual(finalization.timerFired(.hardTimeout), .finishWithoutSending)
        XCTAssertEqual(finalization.recognitionError(), .keepWaiting)
    }

    func testDuplicateFinalizationCallbacksDoNotDoubleSend() throws {
        var finalization = VoiceFinalizationState()

        XCTAssertEqual(finalization.noteTranscript("only once", isFinal: false), .keepWaiting)
        XCTAssertEqual(finalization.begin(sendFinal: true, transcript: "only once"), .scheduleBestTranscriptFallback)
        XCTAssertEqual(finalization.timerFired(.bestTranscriptGrace), .sendFinal)
        XCTAssertEqual(finalization.recognitionError(), .keepWaiting)
        XCTAssertEqual(finalization.noteTranscript("only once", isFinal: true), .keepWaiting)
    }

    func testActiveFinalizationErrorOutsideStopCancelsRecognition() throws {
        var finalization = VoiceFinalizationState()

        XCTAssertEqual(finalization.recognitionError(), .cancelRecognition)
    }

    @MainActor
    func testDisconnectedFinalSpeechReturnsFalseWithoutAppendingPendingMessage() throws {
        let client = LogosClient()
        client.disconnect()
        let before = client.messages

        let sent = client.sendSpeech(
            text: "hello Hermes",
            isFinal: true,
            inputID: "voice-turn-1",
            partialSeq: 2,
            startedAtMilliseconds: 123
        )

        XCTAssertFalse(sent)
        XCTAssertEqual(client.messages, before)
    }

    func testPendingVoiceMessageUsesInputIDForReconciliation() throws {
        let pending = LogosMessage.pending(projectKey: "default", messageID: "voice-turn-1", content: "hello Hermes")
        let persisted = LogosMessage(
            projectKey: "default",
            sessionID: "session-1",
            messageID: "voice-turn-1",
            serverSeq: 7,
            role: "user",
            content: "hello Hermes!",
            timestamp: 123,
            status: "persisted"
        )

        XCTAssertEqual(pending.messageID, "voice-turn-1")
        XCTAssertTrue(PendingMessageReconciliation.shouldRemove(pending: pending, whenPersisted: persisted))
    }

    func testPendingMessageReconciliationKeepsRoleBoundaries() throws {
        let pending = LogosMessage.pending(projectKey: "default", messageID: "voice-turn-1", content: "same text")
        let assistant = LogosMessage(
            projectKey: "default",
            sessionID: "session-1",
            messageID: "voice-turn-1",
            serverSeq: 7,
            role: "assistant",
            content: "same text",
            timestamp: 123,
            status: "persisted"
        )

        XCTAssertFalse(PendingMessageReconciliation.shouldRemove(pending: pending, whenPersisted: assistant))
    }

    func testPendingMessageBufferKeepsPendingAcrossRefreshUntilPersistedEcho() throws {
        var buffer = PendingMessageBuffer()
        let pending = LogosMessage.pending(projectKey: "default", messageID: "voice-turn-1", content: "hello Hermes")

        buffer.add(pending)
        XCTAssertEqual(buffer.merged(with: [], projectKey: "default"), [pending])

        let persisted = LogosMessage(
            projectKey: "default",
            sessionID: "session-1",
            messageID: "voice-turn-1",
            serverSeq: 7,
            role: "user",
            content: "hello Hermes",
            timestamp: 123,
            status: "persisted"
        )
        buffer.reconcile(with: persisted)

        XCTAssertEqual(buffer.merged(with: [persisted], projectKey: "default"), [persisted])
    }

    @MainActor
    func testSuccessfulConnectionMarksFirstConnectionComplete() throws {
        let socket = RecordingWebSocketTask()
        let client = makeSocketBackedClient(socket: socket, autoConnect: false)

        XCTAssertTrue(client.settings.hasCompletedFirstConnection)
    }

    @MainActor
    func testFinalSpeechPendingAppearsOnlyAfterSocketSendCompletes() async throws {
        let socket = RecordingWebSocketTask()
        let client = makeSocketBackedClient(socket: socket)
        let sent = client.sendSpeech(
            text: "hello Hermes",
            isFinal: true,
            inputID: "voice-turn-queued",
            partialSeq: 2,
            startedAtMilliseconds: 123
        )

        XCTAssertTrue(sent)
        XCTAssertFalse(client.messages.contains { $0.messageID == "voice-turn-queued" })

        socket.completeLastSend(error: nil)
        await Task.yield()

        XCTAssertEqual(client.messages.last?.messageID, "voice-turn-queued")
        XCTAssertEqual(client.messages.last?.status, "pending")
        XCTAssertNil(client.undeliveredSpeechDraft)
    }

    @MainActor
    func testFinalSpeechSocketFailureRestoresUndeliveredDraftWithoutPendingMessage() async throws {
        let socket = RecordingWebSocketTask()
        let client = makeSocketBackedClient(socket: socket)
        let sent = client.sendSpeech(
            text: "restore this transcript",
            isFinal: true,
            inputID: "voice-turn-failed",
            partialSeq: 2,
            startedAtMilliseconds: 123
        )

        XCTAssertTrue(sent)

        socket.completeLastSend(error: RecordingSocketError())
        await Task.yield()

        XCTAssertEqual(client.undeliveredSpeechDraft?.id, "voice-turn-failed")
        XCTAssertEqual(client.undeliveredSpeechDraft?.text, "restore this transcript")
        XCTAssertFalse(client.messages.contains { $0.messageID == "voice-turn-failed" })
        XCTAssertEqual(client.connectionState, .error)
    }

    @MainActor
    func testDisconnectRestoresInFlightFinalSpeechDraftBeforeSendCompletion() async throws {
        let socket = RecordingWebSocketTask()
        let client = makeSocketBackedClient(socket: socket)
        let sent = client.sendSpeech(
            text: "save this before disconnect",
            isFinal: true,
            inputID: "voice-turn-disconnect",
            partialSeq: 2,
            startedAtMilliseconds: 123
        )

        XCTAssertTrue(sent)

        client.disconnect()
        await Task.yield()

        XCTAssertEqual(client.undeliveredSpeechDraft?.id, "voice-turn-disconnect")
        XCTAssertEqual(client.undeliveredSpeechDraft?.text, "save this before disconnect")
        XCTAssertFalse(client.messages.contains { $0.messageID == "voice-turn-disconnect" })
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
        let info = Bundle.main.infoDictionary ?? [:]
        let modes = try XCTUnwrap(info["UIBackgroundModes"] as? [String])
        XCTAssertTrue(modes.contains("remote-notification"))
        XCTAssertNotNil(info["NSLocalNetworkUsageDescription"] as? String)
        let urlTypes = try XCTUnwrap(info["CFBundleURLTypes"] as? [[String: Any]])
        let schemes = urlTypes.flatMap { ($0["CFBundleURLSchemes"] as? [String]) ?? [] }
        XCTAssertTrue(schemes.contains("logos"))
    }

    func testPushNotificationEntitlementAndProjectSettingConfigured() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let projectDirectory = testsDirectory.deletingLastPathComponent()
        let entitlementsURL = projectDirectory.appendingPathComponent("Logos/Logos.entitlements")
        let entitlementsData = try Data(contentsOf: entitlementsURL)
        let entitlements = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: entitlementsData, options: [], format: nil) as? [String: Any]
        )
        XCTAssertEqual(entitlements["aps-environment"] as? String, "development")

        let projectYAML = try String(contentsOf: projectDirectory.appendingPathComponent("project.yml"), encoding: .utf8)
        XCTAssertTrue(projectYAML.contains("CODE_SIGN_ENTITLEMENTS: Logos/Logos.entitlements"))
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
    func testStateUpdateMessageUpdatedReplacesExistingMessageContent() throws {
        let client = LogosClient(store: SQLiteMessageStore(filename: "LogosTests-\(UUID().uuidString).sqlite3"))

        client.handleFrameString("""
        {"type":"state_update","project_key":"default","payload":{"op":"message_appended","message":{"project_key":"default","session_id":"project:default","message_id":"tool-progress-1","server_seq":10,"role":"assistant","content":"🔧 terminal…","timestamp":123.0}}}
        """)
        XCTAssertEqual(client.messages.count, 1)
        XCTAssertEqual(client.messages.first?.content, "🔧 terminal…")

        client.handleFrameString(#"""
        {"type":"state_update","project_key":"default","payload":{"op":"message_updated","message":{"project_key":"default","session_id":"project:default","message_id":"tool-progress-1","server_seq":11,"role":"assistant","content":"🔧 terminal…\n✅ terminal done","timestamp":124.0}}}
        """#)

        XCTAssertEqual(client.messages.count, 1)
        XCTAssertEqual(client.messages.first?.content, "🔧 terminal…\n✅ terminal done")
        XCTAssertEqual(client.messages.first?.serverSeq, 11)
    }

    @MainActor
    func testManualPlaybackRequestsFullMessageAudio() throws {
        let socket = RecordingWebSocketTask()
        let client = makeSocketBackedClient(socket: socket)
        let baselineCount = socket.sentMessages.count
        let message = LogosMessage(
            projectKey: "default",
            sessionID: "session-full",
            messageID: "assistant-full-1",
            serverSeq: 42,
            role: "assistant",
            content: "First sentence. Second sentence should also be spoken, not silently dropped into a summary.",
            timestamp: 123,
            status: "persisted"
        )

        client.playback(message: message)

        XCTAssertEqual(socket.sentMessages.count, baselineCount + 1)
        let root = try frameRoot(from: try XCTUnwrap(socket.sentMessages.last))
        XCTAssertEqual(root["type"] as? String, "playback_audio")
        XCTAssertEqual(root["project_key"] as? String, "default")
        XCTAssertEqual(root["session_id"] as? String, "session-full")
        let payload = try XCTUnwrap(root["payload"] as? [String: Any])
        XCTAssertEqual(payload["message_id"] as? String, "assistant-full-1")
        XCTAssertEqual(payload["mode"] as? String, "full")
        XCTAssertEqual(payload["text"] as? String, message.content)
    }

    @MainActor
    func testLiveAssistantMessageAutoplaysFullAudioOnce() throws {
        let socket = RecordingWebSocketTask()
        let client = makeSocketBackedClient(socket: socket)
        let baselineCount = socket.sentMessages.count

        client.handleFrameString(#"""
        {"type":"state_update","project_key":"default","session_id":"session-live","server_seq":50,"payload":{"op":"message_appended","message":{"project_key":"default","session_id":"session-live","message_id":"assistant-live-1","server_seq":50,"role":"assistant","content":"Hello. Ada here. What are we tackling?","timestamp":123.0}}}
        """#)

        let newFrames = try socket.sentMessages.dropFirst(baselineCount).map { try frameRoot(from: $0) }
        let playbackFrames = newFrames.filter { $0["type"] as? String == "playback_audio" }
        XCTAssertEqual(playbackFrames.count, 1)
        let payload = try XCTUnwrap(playbackFrames.first?["payload"] as? [String: Any])
        XCTAssertEqual(playbackFrames.first?["project_key"] as? String, "default")
        XCTAssertEqual(playbackFrames.first?["session_id"] as? String, "session-live")
        XCTAssertEqual(payload["message_id"] as? String, "assistant-live-1")
        XCTAssertEqual(payload["mode"] as? String, "full")
        XCTAssertEqual(payload["text"] as? String, "Hello. Ada here. What are we tackling?")

        client.handleFrameString(#"""
        {"type":"state_update","project_key":"default","session_id":"session-live","server_seq":50,"payload":{"op":"message_appended","message":{"project_key":"default","session_id":"session-live","message_id":"assistant-live-1","server_seq":50,"role":"assistant","content":"Hello. Ada here. What are we tackling?","timestamp":123.0}}}
        """#)

        let framesAfterDuplicate = try socket.sentMessages.dropFirst(baselineCount).map { try frameRoot(from: $0) }
        XCTAssertEqual(framesAfterDuplicate.filter { $0["type"] as? String == "playback_audio" }.count, 1)
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

    private func base64URLPayload(_ payload: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        return data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func frameType(from message: URLSessionWebSocketTask.Message) throws -> String {
        let root = try frameRoot(from: message)
        return try XCTUnwrap(root["type"] as? String)
    }

    private func frameRoot(from message: URLSessionWebSocketTask.Message) throws -> [String: Any] {
        guard case .string(let string) = message else {
            XCTFail("Expected string websocket frame")
            return [:]
        }
        let data = try XCTUnwrap(string.data(using: .utf8))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}

private final class RecordingAudioSessionManager: AudioSessionManaging {
    private(set) var prepareRecordingCalls = 0
    private(set) var finishRecordingCalls = 0
    private(set) var prepareCalls = 0
    private(set) var finishCalls = 0

    func prepareForRecording() throws {
        prepareRecordingCalls += 1
    }

    func finishRecording() throws {
        finishRecordingCalls += 1
    }

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

private final class RecordingPairingCredentialExchanger: PairingCredentialExchanging {
    var credential: LogosPairingCredential?
    var error: Error?
    private(set) var routes: [LogosPairingRoute] = []

    func exchange(route: LogosPairingRoute) async throws -> LogosPairingCredential {
        routes.append(route)
        if let error { throw error }
        guard let credential else { throw RecordingSocketError() }
        return credential
    }
}

@MainActor
private func makeSocketBackedClient(socket: RecordingWebSocketTask, autoConnect: Bool = true) -> LogosClient {
    let client = LogosClient(
        store: SQLiteMessageStore(filename: "LogosTests-\(UUID().uuidString).sqlite3"),
        socketFactory: RecordingWebSocketTaskFactory(socket: socket)
    )
    client.settings.urlString = "ws://127.0.0.1:8765"
    client.settings.secret = "test-secret"
    client.settings.autoConnect = autoConnect
    client.connect()
    socket.open()
    client.handleFrameString(#"{"type":"hello","request_id":"hello-1","payload":{}}"#)
    return client
}

private final class RecordingWebSocketTaskFactory: WebSocketTaskMaking {
    private let socket: RecordingWebSocketTask

    init(socket: RecordingWebSocketTask) {
        self.socket = socket
    }

    func webSocketTask(with url: URL, lifecycleObserver: (any WebSocketLifecycleObserving)?) -> any WebSocketTasking {
        socket.lifecycleObserver = lifecycleObserver
        return socket
    }
}

private final class RecordingWebSocketTask: WebSocketTasking {
    private(set) var sentMessages: [URLSessionWebSocketTask.Message] = []
    private var sendCompletions: [@Sendable (Error?) -> Void] = []
    private var receiveCompletions: [@Sendable (Result<URLSessionWebSocketTask.Message, Error>) -> Void] = []
    weak var lifecycleObserver: (any WebSocketLifecycleObserving)?

    func resume() {}

    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {}

    func open() {
        lifecycleObserver?.webSocketDidOpen(taskID: ObjectIdentifier(self))
    }

    func fail(message: String = "Socket is not connected") {
        lifecycleObserver?.webSocketDidFail(taskID: ObjectIdentifier(self), message: message)
    }

    func send(_ message: URLSessionWebSocketTask.Message, completionHandler: @escaping @Sendable (Error?) -> Void) {
        sentMessages.append(message)
        sendCompletions.append(completionHandler)
    }

    func receive(completionHandler: @escaping @Sendable (Result<URLSessionWebSocketTask.Message, Error>) -> Void) {
        receiveCompletions.append(completionHandler)
    }

    func receiveString(_ string: String) {
        let completion = receiveCompletions.removeFirst()
        completion(.success(.string(string)))
    }

    func completeLastSend(error: Error?) {
        let completion = sendCompletions.removeLast()
        completion(error)
    }
}

private struct RecordingSocketError: LocalizedError {
    var errorDescription: String? {
        "socket send failed"
    }
}
