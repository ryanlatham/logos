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

    func testMessageDecodesFinalAndProgressMetadata() throws {
        let progress = try XCTUnwrap(LogosMessage.from(dictionary: [
            "project_key": "alpha",
            "session_id": "sess-alpha",
            "message_id": "m-progress",
            "server_seq": 8,
            "role": "assistant",
            "content": "🔧 terminal…",
            "timestamp": 124.0,
            "metadata": [
                "finalized": false,
                "source": "tool_progress",
                "progress_kind": "terminal"
            ]
        ]))
        XCTAssertFalse(progress.isFinal)
        XCTAssertTrue(progress.hasFinalizedMetadata)
        XCTAssertEqual(progress.metadataSource, "tool_progress")
        XCTAssertEqual(progress.progressKind, "terminal")

        let final = try XCTUnwrap(LogosMessage.from(dictionary: [
            "project_key": "alpha",
            "session_id": "sess-alpha",
            "message_id": "m-final",
            "server_seq": 9,
            "role": "assistant",
            "content": "Done.",
            "timestamp": 125.0,
            "metadata": [
                "finalized": true,
                "source": "hermes"
            ]
        ]))
        XCTAssertTrue(final.isFinal)
        XCTAssertTrue(final.hasFinalizedMetadata)
        XCTAssertEqual(final.metadataSource, "hermes")
        XCTAssertNil(final.progressKind)
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

    func testPendingMessageReconciliationKeepsProjectBoundaries() throws {
        let pending = LogosMessage.pending(projectKey: "default", messageID: "shared-id", content: "same text")
        let otherProjectEcho = LogosMessage(
            projectKey: "other",
            sessionID: "session-other",
            messageID: "shared-id",
            serverSeq: 7,
            role: "user",
            content: "same text",
            timestamp: 123,
            status: "persisted"
        )

        XCTAssertFalse(PendingMessageReconciliation.shouldRemove(pending: pending, whenPersisted: otherProjectEcho))
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
    func testTextSendFailureRemovesPendingMessage() async throws {
        let socket = RecordingWebSocketTask()
        let client = makeSocketBackedClient(socket: socket)

        XCTAssertTrue(client.sendText("this text send will fail"))
        XCTAssertTrue(client.messages.contains { $0.content == "this text send will fail" && $0.status == "pending" })

        socket.completeLastSend(error: RecordingSocketError())
        await Task.yield()

        XCTAssertFalse(client.messages.contains { $0.content == "this text send will fail" && $0.status == "pending" })
        XCTAssertEqual(client.connectionState, .error)
        XCTAssertNotNil(client.lastError)
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

    @MainActor
    func testLateFinalSpeechSendCompletionAfterDisconnectIsIgnored() async throws {
        let socket = RecordingWebSocketTask()
        let client = makeSocketBackedClient(socket: socket)
        let sent = client.sendSpeech(
            text: "do not resurrect error after disconnect",
            isFinal: true,
            inputID: "voice-turn-late-completion",
            partialSeq: 2,
            startedAtMilliseconds: 123
        )

        XCTAssertTrue(sent)
        client.disconnect()
        await Task.yield()
        let restoredReason = client.undeliveredSpeechDraft?.reason

        socket.completeLastSend(error: RecordingSocketError())
        await Task.yield()

        XCTAssertEqual(client.connectionState, .disconnected)
        XCTAssertNil(client.lastError)
        XCTAssertEqual(client.undeliveredSpeechDraft?.id, "voice-turn-late-completion")
        XCTAssertEqual(client.undeliveredSpeechDraft?.text, "do not resurrect error after disconnect")
        XCTAssertEqual(client.undeliveredSpeechDraft?.reason, restoredReason)
        XCTAssertFalse(client.messages.contains { $0.messageID == "voice-turn-late-completion" })
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

    func testProgressActivityCardLivesInActiveBottomFlowAndScrollsOnProgressUpdates() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let projectDirectory = testsDirectory.deletingLastPathComponent()
        let contentViewSource = try String(contentsOf: projectDirectory.appendingPathComponent("Logos/ContentView.swift"), encoding: .utf8)
        let messagesRange = try XCTUnwrap(contentViewSource.range(of: "ForEach(client.messages)"))
        let progressRange = try XCTUnwrap(contentViewSource.range(of: "ProgressActivityCard("))

        XCTAssertGreaterThan(progressRange.lowerBound, messagesRange.lowerBound)
        XCTAssertTrue(contentViewSource.contains(".onChange(of: client.progressActivity?.events.count) { _, _ in scrollToBottom(proxy) }"))
        XCTAssertTrue(contentViewSource.contains("proxy.scrollTo(\"progress-activity\", anchor: .bottom)"))
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
        {"type":"state_update","project_key":"default","payload":{"op":"message_updated","message":{"project_key":"default","session_id":"project:default","message_id":"tool-progress-1","server_seq":11,"role":"assistant","content":"🔧 terminal…\n✅ terminal done","timestamp":124.0,"metadata":{"finalized":true}}}}
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
    func testLiveFinalAssistantMessageAutoplaysFinalAutoAudioOnce() throws {
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
        XCTAssertEqual(payload["mode"] as? String, "final_auto")
        XCTAssertEqual(payload["text"] as? String, "Hello. Ada here. What are we tackling?")

        client.handleFrameString(#"""
        {"type":"state_update","project_key":"default","session_id":"session-live","server_seq":50,"payload":{"op":"message_appended","message":{"project_key":"default","session_id":"session-live","message_id":"assistant-live-1","server_seq":50,"role":"assistant","content":"Hello. Ada here. What are we tackling?","timestamp":123.0}}}
        """#)

        let framesAfterDuplicate = try socket.sentMessages.dropFirst(baselineCount).map { try frameRoot(from: $0) }
        XCTAssertEqual(framesAfterDuplicate.filter { $0["type"] as? String == "playback_audio" }.count, 1)
    }

    @MainActor
    func testNonFinalProgressAggregatesOutsideMessagesAndNeverAutoplays() throws {
        let socket = RecordingWebSocketTask()
        let client = makeSocketBackedClient(socket: socket)
        let baselineCount = socket.sentMessages.count

        client.handleFrameString(#"""
        {"type":"state_update","request_id":"req-progress","project_key":"default","session_id":"session-progress","server_seq":70,"payload":{"op":"message_updated","message":{"project_key":"default","session_id":"session-progress","message_id":"assistant-progress-1","server_seq":70,"role":"assistant","content":"🔧 terminal…","timestamp":123.0,"metadata":{"finalized":false,"source":"tool_progress","progress_kind":"terminal"}}}}
        """#)

        XCTAssertTrue(client.messages.isEmpty)
        XCTAssertEqual(client.progressActivity?.requestID, "req-progress")
        XCTAssertEqual(client.progressActivity?.events.count, 1)
        XCTAssertEqual(client.progressActivity?.events.first?.text, "🔧 terminal…")
        XCTAssertEqual(client.runStatus, .running)

        client.handleFrameString(#"""
        {"type":"tool_progress","request_id":"req-progress","project_key":"default","session_id":"session-progress","payload":{"kind":"terminal","text":"✅ terminal done"}}
        """#)

        XCTAssertTrue(client.messages.isEmpty)
        XCTAssertEqual(client.progressActivity?.events.count, 2)
        let newFrames = try socket.sentMessages.dropFirst(baselineCount).map { try frameRoot(from: $0) }
        XCTAssertTrue(newFrames.filter { $0["type"] as? String == "playback_audio" }.isEmpty)

        client.handleFrameString(#"""
        {"type":"run_status","project_key":"default","payload":{"status":"idle"}}
        """#)
        XCTAssertEqual(client.runStatus, .running)
    }

    @MainActor
    func testLegacyGatewayStillWorkingMessageAggregatesOutsideMessagesAndNeverAutoplays() throws {
        let socket = RecordingWebSocketTask()
        let client = makeSocketBackedClient(socket: socket)
        let baselineCount = socket.sentMessages.count
        let progressText = "⏳ Still working... (3 min elapsed — iteration 1/1000, API call #1 completed)"

        client.handleFrameString(#"""
        {"type":"state_update","request_id":"req-still-working","project_key":"default","session_id":"session-still-working","server_seq":71,"payload":{"op":"message_appended","message":{"project_key":"default","session_id":"session-still-working","message_id":"assistant-still-working-1","server_seq":71,"role":"assistant","content":"⏳ Still working... (3 min elapsed — iteration 1/1000, API call #1 completed)","timestamp":123.0}}}
        """#)

        XCTAssertTrue(client.messages.isEmpty)
        XCTAssertEqual(client.progressActivity?.requestID, "req-still-working")
        XCTAssertEqual(client.progressActivity?.events.count, 1)
        XCTAssertEqual(client.progressActivity?.events.first?.kind, "gateway_status")
        XCTAssertEqual(client.progressActivity?.events.first?.text, progressText)
        XCTAssertEqual(client.runStatus, .running)
        let newFrames = try socket.sentMessages.dropFirst(baselineCount).map { try frameRoot(from: $0) }
        XCTAssertTrue(newFrames.filter { $0["type"] as? String == "playback_audio" }.isEmpty)

        client.handleFrameString(#"""
        {"type":"run_status","project_key":"default","payload":{"status":"idle"}}
        """#)
        XCTAssertEqual(client.runStatus, .running)
    }

    @MainActor
    func testGatewayStatusProgressDoesNotTimeoutOrAutoplayTimeoutAudio() async throws {
        let socket = RecordingWebSocketTask()
        let client = makeSocketBackedClient(socket: socket, progressTimeoutInterval: 0.05)
        let baselineCount = socket.sentMessages.count

        client.handleFrameString(#"""
        {"type":"tool_progress","request_id":"req-gateway-status","project_key":"default","session_id":"session-gateway-status","payload":{"kind":"gateway_status","progress_kind":"gateway_status","text":"⏳ Still working... (3 min elapsed — iteration 1/1000, API call #1 completed)"}}
        """#)
        try await Task.sleep(nanoseconds: 90_000_000)

        XCTAssertEqual(client.runStatus, .running)
        XCTAssertEqual(client.progressActivity?.timedOut, false)
        XCTAssertEqual(client.progressActivity?.events.filter { $0.kind == "timeout" }.count, 0)
        let newFrames = try socket.sentMessages.dropFirst(baselineCount).map { try frameRoot(from: $0) }
        XCTAssertTrue(newFrames.filter { $0["type"] as? String == "playback_audio" }.isEmpty)
    }

    func testExplicitFinalizedMessageIsNotClassifiedAsProgressEvenWithLegacyProgressMetadata() throws {
        let message = try XCTUnwrap(LogosMessage.from(dictionary: [
            "project_key": "default",
            "session_id": "session-final-progress-metadata",
            "message_id": "assistant-final-progress-metadata",
            "server_seq": 73,
            "role": "assistant",
            "content": "Final answer after progress.",
            "timestamp": 124.0,
            "metadata": [
                "finalized": true,
                "source": "tool_progress",
                "progress_kind": "terminal"
            ]
        ]))

        XCTAssertTrue(message.isFinal)
        XCTAssertFalse(message.isProgressUpdate)
    }

    @MainActor
    func testStoredLegacyGatewayProgressMessagesAreFilteredAndPlaybackGuarded() throws {
        let store = SQLiteMessageStore(filename: "LogosTests-\(UUID().uuidString).sqlite3")
        let legacyProgress = LogosMessage(
            projectKey: "default",
            sessionID: "session-stored-progress",
            messageID: "stored-still-working",
            serverSeq: 72,
            role: "assistant",
            content: "⏳ Still working... (3 min elapsed — iteration 1/1000, API call #1 completed)",
            timestamp: 123.0,
            status: "persisted"
        )
        store.upsert(legacyProgress)
        let socket = RecordingWebSocketTask()
        let client = makeSocketBackedClient(socket: socket, store: store)
        let baselineCount = socket.sentMessages.count

        XCTAssertTrue(client.messages.isEmpty)
        client.playback(message: legacyProgress)

        let newFrames = try socket.sentMessages.dropFirst(baselineCount).map { try frameRoot(from: $0) }
        XCTAssertTrue(newFrames.filter { $0["type"] as? String == "playback_audio" }.isEmpty)
    }

    @MainActor
    func testMessagesBatchClearsProgressWhenFinalResponseArrivesInSameBatch() throws {
        let socket = RecordingWebSocketTask()
        let client = makeSocketBackedClient(socket: socket)

        client.handleFrameString(#"""
        {"type":"messages_batch","request_id":"req-batch-final","project_key":"default","session_id":"session-batch-final","payload":{"messages":[{"project_key":"default","session_id":"session-batch-final","message_id":"legacy-progress-in-batch","server_seq":81,"role":"assistant","content":"⏳ Still working... (3 min elapsed — iteration 1/1000, API call #1 completed)","timestamp":123.0},{"project_key":"default","session_id":"session-batch-final","message_id":"assistant-batch-final","server_seq":82,"role":"assistant","content":"Final response after progress.","timestamp":124.0,"metadata":{"finalized":true}}]}}
        """#)

        XCTAssertNil(client.progressActivity)
        XCTAssertEqual(client.runStatus, .idle)
        XCTAssertEqual(client.messages.count, 1)
        XCTAssertEqual(client.messages.first?.messageID, "assistant-batch-final")
    }

    @MainActor
    func testMessagesBatchFinalOnlyClearsExistingProgressActivity() throws {
        let socket = RecordingWebSocketTask()
        let client = makeSocketBackedClient(socket: socket)

        client.handleFrameString(#"""
        {"type":"tool_progress","request_id":"req-final-only-replay","project_key":"default","session_id":"session-final-only-replay","payload":{"kind":"gateway_status","progress_kind":"gateway_status","text":"⏳ Still working... (3 min elapsed — iteration 1/1000, API call #1 completed)"}}
        """#)
        XCTAssertNotNil(client.progressActivity)
        XCTAssertEqual(client.runStatus, .running)

        client.handleFrameString(#"""
        {"type":"messages_batch","request_id":"req-final-only-replay","project_key":"default","session_id":"session-final-only-replay","payload":{"messages":[{"project_key":"default","session_id":"session-final-only-replay","message_id":"assistant-final-only","server_seq":83,"role":"assistant","content":"Final response replayed without transient progress.","timestamp":125.0,"metadata":{"finalized":true}}]}}
        """#)

        XCTAssertNil(client.progressActivity)
        XCTAssertEqual(client.runStatus, .idle)
        XCTAssertEqual(client.messages.count, 1)
        XCTAssertEqual(client.messages.first?.messageID, "assistant-final-only")
    }

    @MainActor
    func testMessagesBatchFinalDuringCancelDoesNotClearCancelLatch() throws {
        let socket = RecordingWebSocketTask()
        let client = makeSocketBackedClient(socket: socket)

        client.handleFrameString(#"""
        {"type":"tool_progress","request_id":"req-cancel-batch","project_key":"default","session_id":"session-cancel-batch","payload":{"kind":"terminal","text":"Still running before cancel"}}
        """#)
        client.cancelRun()
        XCTAssertEqual(client.runStatus, .cancelling)
        XCTAssertEqual(client.progressActivity?.requestID, "req-cancel-batch")

        client.handleFrameString(#"""
        {"type":"messages_batch","request_id":"req-cancel-batch","project_key":"default","session_id":"session-cancel-batch","payload":{"messages":[{"project_key":"default","session_id":"session-cancel-batch","message_id":"assistant-cancelled-final-replay","server_seq":84,"role":"assistant","content":"Late final replay after local cancel.","timestamp":126.0,"metadata":{"finalized":true,"source":"hermes"}}]}}
        """#)

        XCTAssertEqual(client.runStatus, .cancelling)
        XCTAssertEqual(client.progressActivity?.requestID, "req-cancel-batch")
        XCTAssertEqual(client.progressActivity?.sessionID, "session-cancel-batch")
    }

    @MainActor
    func testMessagesBatchFinalForDifferentRequestDoesNotClearCurrentProgress() throws {
        let socket = RecordingWebSocketTask()
        let client = makeSocketBackedClient(socket: socket)

        client.handleFrameString(#"""
        {"type":"tool_progress","request_id":"req-current-batch","project_key":"default","session_id":"session-shared-batch","payload":{"kind":"terminal","text":"Current request still running"}}
        """#)
        XCTAssertEqual(client.runStatus, .running)
        XCTAssertEqual(client.progressActivity?.requestID, "req-current-batch")

        client.handleFrameString(#"""
        {"type":"messages_batch","request_id":"req-old-batch","project_key":"default","session_id":"session-shared-batch","payload":{"messages":[{"project_key":"default","session_id":"session-shared-batch","message_id":"assistant-old-batch-final","server_seq":85,"role":"assistant","content":"Old same-session final replay.","timestamp":127.0,"metadata":{"finalized":true,"source":"hermes"}}]}}
        """#)

        XCTAssertEqual(client.runStatus, .running)
        XCTAssertEqual(client.progressActivity?.requestID, "req-current-batch")
        XCTAssertEqual(client.progressActivity?.sessionID, "session-shared-batch")
    }

    @MainActor
    func testFinalizedMessageUpdatedClearsProgressAndAutoplaysFinalAutoOnce() throws {
        let socket = RecordingWebSocketTask()
        let client = makeSocketBackedClient(socket: socket)

        client.handleFrameString(#"""
        {"type":"state_update","request_id":"req-finalize","project_key":"default","session_id":"session-finalize","server_seq":80,"payload":{"op":"message_updated","message":{"project_key":"default","session_id":"session-finalize","message_id":"assistant-finalize-1","server_seq":80,"role":"assistant","content":"🔧 terminal…","timestamp":123.0,"metadata":{"finalized":false,"progress_kind":"terminal"}}}}
        """#)
        XCTAssertEqual(client.progressActivity?.events.count, 1)
        XCTAssertTrue(client.messages.isEmpty)
        let baselineCount = socket.sentMessages.count

        client.handleFrameString(#"""
        {"type":"state_update","request_id":"req-finalize","project_key":"default","session_id":"session-finalize","server_seq":81,"payload":{"op":"message_updated","message":{"project_key":"default","session_id":"session-finalize","message_id":"assistant-finalize-1","server_seq":81,"role":"assistant","content":"Done with the terminal work.","timestamp":124.0,"metadata":{"finalized":true,"source":"hermes"}}}}
        """#)

        XCTAssertNil(client.progressActivity)
        XCTAssertEqual(client.messages.count, 1)
        XCTAssertEqual(client.messages.first?.messageID, "assistant-finalize-1")
        XCTAssertTrue(client.messages.first?.isFinal == true)
        let newFrames = try socket.sentMessages.dropFirst(baselineCount).map { try frameRoot(from: $0) }
        let playbackFrames = newFrames.filter { $0["type"] as? String == "playback_audio" }
        XCTAssertEqual(playbackFrames.count, 1)
        let payload = try XCTUnwrap(playbackFrames.first?["payload"] as? [String: Any])
        XCTAssertEqual(payload["message_id"] as? String, "assistant-finalize-1")
        XCTAssertEqual(payload["mode"] as? String, "final_auto")

        client.handleFrameString(#"""
        {"type":"state_update","request_id":"req-finalize","project_key":"default","session_id":"session-finalize","server_seq":81,"payload":{"op":"message_updated","message":{"project_key":"default","session_id":"session-finalize","message_id":"assistant-finalize-1","server_seq":81,"role":"assistant","content":"Done with the terminal work.","timestamp":124.0,"metadata":{"finalized":true,"source":"hermes"}}}}
        """#)
        let framesAfterDuplicate = try socket.sentMessages.dropFirst(baselineCount).map { try frameRoot(from: $0) }
        XCTAssertEqual(framesAfterDuplicate.filter { $0["type"] as? String == "playback_audio" }.count, 1)
    }

    @MainActor
    func testFinalStateUpdateForDifferentSessionDoesNotClearCurrentProgressOrAutoplay() throws {
        let socket = RecordingWebSocketTask()
        let client = makeSocketBackedClient(socket: socket)
        client.handleFrameString(#"""
        {"type":"tool_progress","request_id":"req-current","project_key":"default","session_id":"session-current","payload":{"kind":"terminal","text":"Current request is still running"}}
        """#)
        let baselineCount = socket.sentMessages.count

        client.handleFrameString(#"""
        {"type":"state_update","project_key":"default","session_id":"session-old","server_seq":91,"payload":{"op":"message_appended","message":{"project_key":"default","session_id":"session-old","message_id":"assistant-old-final","server_seq":91,"role":"assistant","content":"Old final response arrived late.","timestamp":126.0,"metadata":{"finalized":true,"source":"hermes"}}}}
        """#)

        XCTAssertEqual(client.progressActivity?.requestID, "req-current")
        XCTAssertEqual(client.progressActivity?.sessionID, "session-current")
        XCTAssertEqual(client.runStatus, .running)
        let newFrames = try socket.sentMessages.dropFirst(baselineCount).map { try frameRoot(from: $0) }
        XCTAssertTrue(newFrames.filter { $0["type"] as? String == "playback_audio" }.isEmpty)
    }

    @MainActor
    func testProgressSilenceTimeoutIsVisualOnlyAndFinalCancelsTimeout() async throws {
        let socket = RecordingWebSocketTask()
        let client = makeSocketBackedClient(socket: socket, progressTimeoutInterval: 0.05)
        let baselineCount = socket.sentMessages.count

        client.handleFrameString(#"""
        {"type":"tool_progress","request_id":"req-timeout","project_key":"default","session_id":"session-timeout","payload":{"kind":"terminal","text":"Still running"}}
        """#)
        try await Task.sleep(nanoseconds: 90_000_000)

        XCTAssertEqual(client.progressActivity?.timedOut, true)
        var newFrames = try socket.sentMessages.dropFirst(baselineCount).map { try frameRoot(from: $0) }
        var playbackFrames = newFrames.filter { $0["type"] as? String == "playback_audio" }
        XCTAssertTrue(playbackFrames.isEmpty)

        try await Task.sleep(nanoseconds: 90_000_000)
        newFrames = try socket.sentMessages.dropFirst(baselineCount).map { try frameRoot(from: $0) }
        playbackFrames = newFrames.filter { $0["type"] as? String == "playback_audio" }
        XCTAssertTrue(playbackFrames.isEmpty)

        let socket2 = RecordingWebSocketTask()
        let client2 = makeSocketBackedClient(socket: socket2, progressTimeoutInterval: 0.05)
        let baselineCount2 = socket2.sentMessages.count
        client2.handleFrameString(#"""
        {"type":"tool_progress","request_id":"req-cancel-timeout","project_key":"default","session_id":"session-cancel-timeout","payload":{"kind":"terminal","text":"Almost done"}}
        """#)
        client2.handleFrameString(#"""
        {"type":"state_update","request_id":"req-cancel-timeout","project_key":"default","session_id":"session-cancel-timeout","server_seq":90,"payload":{"op":"message_updated","message":{"project_key":"default","session_id":"session-cancel-timeout","message_id":"assistant-cancel-timeout","server_seq":90,"role":"assistant","content":"Finished before timeout.","timestamp":125.0,"metadata":{"finalized":true}}}}
        """#)
        try await Task.sleep(nanoseconds: 90_000_000)

        XCTAssertNil(client2.progressActivity)
        let finalFrames = try socket2.sentMessages.dropFirst(baselineCount2).map { try frameRoot(from: $0) }
        let finalPlaybackFrames = finalFrames.filter { $0["type"] as? String == "playback_audio" }
        XCTAssertEqual(finalPlaybackFrames.count, 1)
        let payload = try XCTUnwrap(finalPlaybackFrames.first?["payload"] as? [String: Any])
        XCTAssertEqual(payload["mode"] as? String, "final_auto")
    }

    @MainActor
    func testProgressTimeoutSuspendsWhileAwaitingApproval() async throws {
        let socket = RecordingWebSocketTask()
        let client = makeSocketBackedClient(socket: socket, progressTimeoutInterval: 0.05)
        let baselineCount = socket.sentMessages.count

        client.handleFrameString(#"""
        {"type":"tool_progress","request_id":"req-approval-wait","project_key":"default","session_id":"session-approval-wait","payload":{"kind":"terminal","text":"🔧 terminal running"}}
        """#)
        client.handleFrameString(#"""
        {"type":"approval_request","request_id":"req-approval-wait","project_key":"default","session_id":"session-approval-wait","payload":{"approval_id":"approval-wait","title":"Approve?","summary":"Needs confirmation","command_preview":"echo ok","risk":"fixture"}}
        """#)
        try await Task.sleep(nanoseconds: 90_000_000)

        XCTAssertEqual(client.runStatus, .awaitingApproval)
        XCTAssertEqual(client.progressActivity?.timedOut, false)
        XCTAssertEqual(client.progressActivity?.events.filter { $0.kind == "timeout" }.count, 0)
        let newFrames = try socket.sentMessages.dropFirst(baselineCount).map { try frameRoot(from: $0) }
        XCTAssertTrue(newFrames.filter { $0["type"] as? String == "playback_audio" }.isEmpty)
    }

    @MainActor
    func testCancelRunDedupeSuspendsProgressTimeoutAndAcceptsIdle() async throws {
        let socket = RecordingWebSocketTask()
        let client = makeSocketBackedClient(socket: socket, progressTimeoutInterval: 0.05)
        client.handleFrameString(#"""
        {"type":"tool_progress","request_id":"req-cancel","project_key":"default","session_id":"session-cancel","payload":{"kind":"terminal","text":"Long task running"}}
        """#)
        let baselineCount = socket.sentMessages.count

        client.cancelRun()
        client.cancelRun()

        XCTAssertEqual(client.runStatus, .cancelling)
        let cancelFrames = try socket.sentMessages.dropFirst(baselineCount)
            .map { try frameRoot(from: $0) }
            .filter { $0["type"] as? String == "run_cancel" }
        XCTAssertEqual(cancelFrames.count, 1)
        XCTAssertEqual(cancelFrames.first?["project_key"] as? String, "default")
        let payload = try XCTUnwrap(cancelFrames.first?["payload"] as? [String: Any])
        XCTAssertTrue(payload.isEmpty)

        client.handleFrameString(#"""
        {"type":"run_status","project_key":"default","payload":{"status":"cancelling"}}
        """#)
        try await Task.sleep(nanoseconds: 90_000_000)

        XCTAssertEqual(client.runStatus, .cancelling)
        XCTAssertEqual(client.progressActivity?.events.filter { $0.kind == "timeout" }.count, 0)

        client.handleFrameString(#"""
        {"type":"run_status","request_id":"stale-idle","project_key":"default","payload":{"status":"idle"}}
        """#)

        XCTAssertEqual(client.runStatus, .cancelling)
        XCTAssertNotNil(client.progressActivity)

        let cancelRequestID = try XCTUnwrap(cancelFrames.first?["request_id"] as? String)
        client.handleFrameString("""
        {"type":"run_status","request_id":"\(cancelRequestID)","project_key":"default","payload":{"status":"idle","cancelled":true}}
        """)

        XCTAssertEqual(client.runStatus, .idle)
        XCTAssertNil(client.progressActivity)
    }

    @MainActor
    func testCancelRunClearsInteractionCardsAndIgnoresLateRequests() throws {
        let socket = RecordingWebSocketTask()
        let client = makeSocketBackedClient(socket: socket)

        client.handleFrameString(#"""
        {"type":"approval_request","request_id":"approval-before-cancel","project_key":"default","session_id":"session-cancel-interaction","payload":{"approval_id":"approval-before-cancel","title":"Approve?","summary":"Needs confirmation","command_preview":"echo ok","risk":"fixture"}}
        """#)
        XCTAssertEqual(client.runStatus, .awaitingApproval)
        XCTAssertEqual(client.approvalCard?.id, "approval-before-cancel")

        client.cancelRun()

        XCTAssertEqual(client.runStatus, .cancelling)
        XCTAssertNil(client.approvalCard)
        XCTAssertNil(client.clarifyCard)
        XCTAssertNil(client.pendingInteractionResponseID)

        client.handleFrameString(#"""
        {"type":"approval_request","request_id":"approval-late","project_key":"default","session_id":"session-cancel-interaction","payload":{"approval_id":"approval-late","title":"Approve late?","summary":"Late approval","command_preview":"echo late","risk":"fixture"}}
        """#)
        client.handleFrameString(#"""
        {"type":"clarify_request","request_id":"clarify-late","project_key":"default","session_id":"session-cancel-interaction","payload":{"clarify_id":"clarify-late","question":"Late question?","choices":["yes"],"allow_free_text":true}}
        """#)

        XCTAssertEqual(client.runStatus, .cancelling)
        XCTAssertNil(client.approvalCard)
        XCTAssertNil(client.clarifyCard)
    }

    @MainActor
    func testProjectSwitchClearsRunStatusAndIgnoresStaleProjectFrames() throws {
        let socket = RecordingWebSocketTask()
        let client = makeSocketBackedClient(socket: socket)
        client.handleFrameString(#"""
        {"type":"tool_progress","request_id":"req-alpha","project_key":"default","session_id":"session-alpha","payload":{"kind":"terminal","text":"Alpha is running"}}
        """#)
        XCTAssertEqual(client.runStatus, .running)

        client.switchProject("beta")

        XCTAssertEqual(client.activeProjectKey, "beta")
        XCTAssertEqual(client.runStatus, .idle)
        XCTAssertNil(client.progressActivity)

        client.handleFrameString(#"""
        {"type":"state_update","request_id":"switch-alpha-old","project_key":"default","server_seq":130,"payload":{"op":"active_project_changed","project":{"project_key":"default","title":"Default"}}}
        """#)
        XCTAssertEqual(client.activeProjectKey, "beta")

        client.handleFrameString(#"""
        {"type":"projects_list","request_id":"list-stale","project_key":"default","payload":{"active_project_key":"default","projects":[{"project_key":"default","title":"Default"},{"project_key":"beta","title":"Beta"}]}}
        """#)
        XCTAssertEqual(client.activeProjectKey, "beta")
    }

    @MainActor
    func testAdapterErrorsClearPendingInteractionAndCancelState() async throws {
        let socket = RecordingWebSocketTask()
        let client = makeSocketBackedClient(socket: socket)
        await Task.yield()

        client.handleFrameString(#"""
        {"type":"approval_request","request_id":"approval-not-pending","project_key":"default","session_id":"session-approval-error","payload":{"approval_id":"approval-not-pending","title":"Approve?","summary":"Needs confirmation","command_preview":"echo ok","risk":"fixture"}}
        """#)
        client.approveCurrentRequest()
        XCTAssertEqual(client.pendingInteractionResponseID, "approval-not-pending")

        client.handleFrameString(#"""
        {"type":"error","request_id":"approval-not-pending","project_key":"default","payload":{"code":"approval_not_pending","message":"approval_response requires a matching pending approval for this project"}}
        """#)

        XCTAssertNil(client.pendingInteractionResponseID)
        XCTAssertNil(client.approvalCard)
        XCTAssertNil(client.ackText)

        client.handleFrameString(#"""
        {"type":"tool_progress","request_id":"req-cancel-error","project_key":"default","session_id":"session-cancel-error","payload":{"kind":"terminal","text":"Long task running"}}
        """#)
        client.cancelRun()
        let cancelRoot = try frameRoot(from: try XCTUnwrap(socket.sentMessages.last))
        let cancelRequestID = try XCTUnwrap(cancelRoot["request_id"] as? String)
        XCTAssertEqual(client.runStatus, .cancelling)

        client.handleFrameString("""
        {"type":"error","request_id":"\(cancelRequestID)","project_key":"default","payload":{"code":"run_cancel_failed","message":"cancel failed"}}
        """)

        XCTAssertEqual(client.runStatus, .error)
        XCTAssertNil(client.progressActivity)
    }

    @MainActor
    func testCancelRunSendFailureClearsProgressAndReportsError() async throws {
        let socket = RecordingWebSocketTask()
        let client = makeSocketBackedClient(socket: socket)
        await Task.yield()
        client.handleFrameString(#"""
        {"type":"tool_progress","request_id":"req-cancel-send-fail","project_key":"default","session_id":"session-cancel-send-fail","payload":{"kind":"terminal","text":"Long task running"}}
        """#)

        client.cancelRun()
        XCTAssertEqual(client.runStatus, .cancelling)

        socket.completeLastSend(error: RecordingSocketError())
        await Task.yield()

        XCTAssertEqual(client.runStatus, .error)
        XCTAssertNil(client.progressActivity)
        XCTAssertEqual(client.connectionState, .error)
    }

    @MainActor
    func testSameSessionDifferentRequestFinalDoesNotClearProgressOrAutoplay() throws {
        let socket = RecordingWebSocketTask()
        let client = makeSocketBackedClient(socket: socket)
        client.handleFrameString(#"""
        {"type":"tool_progress","request_id":"req-current-shared","project_key":"default","session_id":"session-shared","payload":{"kind":"terminal","text":"Current request is still running"}}
        """#)
        let baselineCount = socket.sentMessages.count

        client.handleFrameString(#"""
        {"type":"state_update","request_id":"req-old-shared","project_key":"default","session_id":"session-shared","server_seq":131,"payload":{"op":"message_appended","message":{"project_key":"default","session_id":"session-shared","message_id":"assistant-old-shared-final","server_seq":131,"role":"assistant","content":"Old final response arrived late.","timestamp":126.0,"metadata":{"finalized":true,"source":"hermes"}}}}
        """#)

        XCTAssertEqual(client.progressActivity?.requestID, "req-current-shared")
        XCTAssertEqual(client.progressActivity?.sessionID, "session-shared")
        XCTAssertEqual(client.runStatus, .running)
        let newFrames = try socket.sentMessages.dropFirst(baselineCount).map { try frameRoot(from: $0) }
        XCTAssertTrue(newFrames.filter { $0["type"] as? String == "playback_audio" }.isEmpty)
    }

    @MainActor
    func testUnsolicitedSameDeviceAudioIsIgnoredButFastAckAudioIsAuthorized() throws {
        let socket = RecordingWebSocketTask()
        let session = RecordingAudioSessionManager()
        let factory = RecordingAudioPlayerFactory()
        let controller = AudioPlaybackController(sessionManager: session, playerFactory: factory)
        let client = makeSocketBackedClient(socket: socket, audioPlayback: controller)
        let unsolicited = Data([4, 5, 6]).base64EncodedString()

        client.handleFrameString("""
        {"type":"audio_chunk","device_id":"ios-simulator","project_key":"default","session_id":"session-audio","payload":{"audio_id":"unsolicited-audio","message_id":"assistant-audio","chunk_index":0,"data":"\(unsolicited)"}}
        """)
        client.handleFrameString(#"""
        {"type":"audio_end","device_id":"ios-simulator","project_key":"default","session_id":"session-audio","payload":{"audio_id":"unsolicited-audio","message_id":"assistant-audio","chunk_count":1}}
        """#)
        XCTAssertEqual(factory.player.playCalls, 0)

        client.handleFrameString(#"""
        {"type":"state_update","request_id":"ack-req","project_key":"default","session_id":"session-audio","payload":{"op":"fast_ack","ack_text":"On it.","audio_id":"ack-audio","transient":true}}
        """#)
        client.handleFrameString("""
        {"type":"audio_chunk","device_id":"ios-simulator","project_key":"default","session_id":"session-audio","payload":{"audio_id":"ack-audio","chunk_index":0,"data":"\(unsolicited)"}}
        """)
        client.handleFrameString(#"""
        {"type":"audio_end","device_id":"ios-simulator","project_key":"default","session_id":"session-audio","payload":{"audio_id":"ack-audio","chunk_count":1}}
        """#)

        XCTAssertEqual(factory.player.playCalls, 1)
    }

    @MainActor
    func testStaleTextSendCompletionAfterDisconnectRemovesPendingBubble() async throws {
        let socket = RecordingWebSocketTask()
        let client = makeSocketBackedClient(socket: socket)
        await Task.yield()

        XCTAssertTrue(client.sendText("pending then disconnect"))
        XCTAssertEqual(client.messages.last?.content, "pending then disconnect")
        XCTAssertEqual(client.messages.last?.status, "pending")

        client.disconnect()
        socket.completeLastSend(error: nil)
        await Task.yield()

        XCTAssertTrue(client.messages.allSatisfy { $0.content != "pending then disconnect" })
    }

    @MainActor
    func testLateRunStatusCannotOverrideCancellingUntilIdle() throws {
        let socket = RecordingWebSocketTask()
        let client = makeSocketBackedClient(socket: socket)
        client.handleFrameString(#"""
        {"type":"tool_progress","request_id":"req-cancel-latch","project_key":"default","session_id":"session-cancel-latch","payload":{"kind":"terminal","text":"Still running"}}
        """#)
        client.cancelRun()
        XCTAssertEqual(client.runStatus, .cancelling)

        client.handleFrameString(#"""
        {"type":"run_status","request_id":"late-running","project_key":"default","payload":{"status":"running"}}
        """#)
        client.handleFrameString(#"""
        {"type":"run_status","request_id":"late-approval","project_key":"default","payload":{"status":"awaiting_approval"}}
        """#)

        XCTAssertEqual(client.runStatus, .cancelling)
        XCTAssertNil(client.approvalCard)
        XCTAssertNil(client.clarifyCard)

        let cancelRoot = try frameRoot(from: try XCTUnwrap(socket.sentMessages.last))
        let cancelRequestID = try XCTUnwrap(cancelRoot["request_id"] as? String)
        client.handleFrameString(#"""
        {"type":"run_status","request_id":"stale-cancel-complete","project_key":"default","payload":{"status":"idle"}}
        """#)
        XCTAssertEqual(client.runStatus, .cancelling)

        client.handleFrameString("""
        {"type":"run_status","request_id":"\(cancelRequestID)","project_key":"default","payload":{"status":"idle","cancelled":true}}
        """)
        XCTAssertEqual(client.runStatus, .idle)
        XCTAssertNil(client.progressActivity)
    }

    @MainActor
    func testLateUnscopedFinalDuringCancelDoesNotClearProgressOrAutoplay() throws {
        let socket = RecordingWebSocketTask()
        let client = makeSocketBackedClient(socket: socket)
        client.handleFrameString(#"""
        {"type":"tool_progress","request_id":"req-cancel-current","project_key":"default","session_id":"session-shared-cancel","payload":{"kind":"terminal","text":"Current request is running"}}
        """#)
        client.cancelRun()
        let baselineCount = socket.sentMessages.count

        client.handleFrameString(#"""
        {"type":"state_update","project_key":"default","session_id":"session-shared-cancel","server_seq":132,"payload":{"op":"message_appended","message":{"project_key":"default","session_id":"session-shared-cancel","message_id":"assistant-unscoped-late-final","server_seq":132,"role":"assistant","content":"Late final after cancel.","timestamp":127.0,"metadata":{"finalized":true,"source":"hermes"}}}}
        """#)

        XCTAssertEqual(client.runStatus, .cancelling)
        XCTAssertEqual(client.progressActivity?.requestID, "req-cancel-current")
        let newFrames = try socket.sentMessages.dropFirst(baselineCount).map { try frameRoot(from: $0) }
        XCTAssertTrue(newFrames.filter { $0["type"] as? String == "playback_audio" }.isEmpty)
    }

    @MainActor
    func testLateUnscopedFinalAfterCancelCompleteDoesNotClearNewSameSessionRunOrAutoplay() throws {
        let socket = RecordingWebSocketTask()
        let client = makeSocketBackedClient(socket: socket)
        client.handleFrameString(#"""
        {"type":"tool_progress","request_id":"req-old-before-cancel","project_key":"default","session_id":"session-shared-rerun","payload":{"kind":"terminal","text":"Old request is running"}}
        """#)
        client.cancelRun()
        let cancelRoot = try frameRoot(from: try XCTUnwrap(socket.sentMessages.last))
        let cancelRequestID = try XCTUnwrap(cancelRoot["request_id"] as? String)
        client.handleFrameString("""
        {"type":"run_status","request_id":"\(cancelRequestID)","project_key":"default","session_id":"session-shared-rerun","payload":{"status":"idle","cancelled":true}}
        """)
        XCTAssertEqual(client.runStatus, .idle)
        XCTAssertNil(client.progressActivity)

        client.handleFrameString(#"""
        {"type":"tool_progress","request_id":"req-new-after-cancel","project_key":"default","session_id":"session-shared-rerun","payload":{"kind":"terminal","text":"New request is running"}}
        """#)
        XCTAssertEqual(client.progressActivity?.requestID, "req-new-after-cancel")
        let baselineCount = socket.sentMessages.count

        client.handleFrameString(#"""
        {"type":"state_update","project_key":"default","session_id":"session-shared-rerun","server_seq":133,"payload":{"op":"message_appended","message":{"project_key":"default","session_id":"session-shared-rerun","message_id":"assistant-old-unscoped-after-cancel","server_seq":133,"role":"assistant","content":"Old final after the user started over.","timestamp":128.0,"metadata":{"finalized":true,"source":"hermes"}}}}
        """#)

        XCTAssertEqual(client.runStatus, .running)
        XCTAssertEqual(client.progressActivity?.requestID, "req-new-after-cancel")
        XCTAssertEqual(client.progressActivity?.sessionID, "session-shared-rerun")
        let newFrames = try socket.sentMessages.dropFirst(baselineCount).map { try frameRoot(from: $0) }
        XCTAssertTrue(newFrames.filter { $0["type"] as? String == "playback_audio" }.isEmpty)
    }

    @MainActor
    func testOutboundTextAndSpeechAreRejectedWhileCancelling() throws {
        let socket = RecordingWebSocketTask()
        let client = makeSocketBackedClient(socket: socket)
        client.handleFrameString(#"""
        {"type":"tool_progress","request_id":"req-cancel-outbound","project_key":"default","session_id":"session-cancel-outbound","payload":{"kind":"terminal","text":"Current request is running"}}
        """#)
        client.cancelRun()
        let baselineCount = socket.sentMessages.count

        XCTAssertFalse(client.sendText("new text while stopping"))
        XCTAssertFalse(client.sendSpeech(text: "new final speech while stopping", isFinal: true, inputID: "voice-during-cancel", partialSeq: 0, startedAtMilliseconds: 1))
        XCTAssertFalse(client.sendSpeech(text: "new partial speech while stopping", isFinal: false, inputID: "voice-partial-during-cancel", partialSeq: 1, startedAtMilliseconds: 1))

        let newFrames = try socket.sentMessages.dropFirst(baselineCount).map { try frameRoot(from: $0) }
        XCTAssertTrue(newFrames.isEmpty)
        XCTAssertTrue(client.messages.allSatisfy { $0.content != "new text while stopping" && $0.content != "new final speech while stopping" })
    }

    @MainActor
    func testReceiveLoopFailureClearsPendingInteractionState() async throws {
        let socket = RecordingWebSocketTask()
        let client = makeSocketBackedClient(socket: socket)
        await Task.yield()
        client.handleFrameString(#"""
        {"type":"approval_request","request_id":"approval-before-receive-failure","project_key":"default","session_id":"session-receive-failure","payload":{"approval_id":"approval-before-receive-failure","title":"Approve?","summary":"Needs confirmation","command_preview":"echo ok","risk":"fixture"}}
        """#)
        client.approveCurrentRequest()
        XCTAssertEqual(client.approvalCard?.id, "approval-before-receive-failure")
        XCTAssertEqual(client.pendingInteractionResponseID, "approval-before-receive-failure")

        socket.receiveFailure(RecordingSocketError())
        await Task.yield()

        XCTAssertEqual(client.connectionState, .error)
        XCTAssertEqual(client.runStatus, .error)
        XCTAssertNil(client.approvalCard)
        XCTAssertNil(client.clarifyCard)
        XCTAssertNil(client.pendingInteractionResponseID)
        XCTAssertNil(client.ackText)
    }

    @MainActor
    func testApprovalResponseSendFailureClearsPendingStateForRetry() async throws {
        let socket = RecordingWebSocketTask()
        let client = makeSocketBackedClient(socket: socket)
        await Task.yield()

        client.handleFrameString(#"""
        {"type":"approval_request","request_id":"approval-send-fail","project_key":"default","session_id":"session-approval-fail","payload":{"approval_id":"approval-send-fail","title":"Approve?","summary":"Needs confirmation","command_preview":"echo ok","risk":"fixture"}}
        """#)
        client.approveCurrentRequest()

        XCTAssertEqual(client.pendingInteractionResponseID, "approval-send-fail")
        XCTAssertEqual(client.ackText, "Approved. Waiting for Hermes…")

        socket.completeLastSend(error: RecordingSocketError())
        await Task.yield()

        XCTAssertNil(client.pendingInteractionResponseID)
        XCTAssertNil(client.ackText)
        XCTAssertEqual(client.approvalCard?.id, "approval-send-fail")
        XCTAssertEqual(client.connectionState, .error)
    }

    @MainActor
    func testPlaybackRequestSendFailureClearsRequestingOverlay() async throws {
        let socket = RecordingWebSocketTask()
        let session = RecordingAudioSessionManager()
        let factory = RecordingAudioPlayerFactory()
        let controller = AudioPlaybackController(sessionManager: session, playerFactory: factory)
        let client = makeSocketBackedClient(socket: socket, audioPlayback: controller)
        await Task.yield()
        let message = LogosMessage(
            projectKey: "default",
            sessionID: "session-playback-fail",
            messageID: "assistant-playback-fail",
            serverSeq: 120,
            role: "assistant",
            content: "Play this if the socket stays alive.",
            timestamp: 123,
            status: "persisted"
        )

        client.playback(message: message)
        XCTAssertEqual(client.audioPlaybackOverlay?.phase, .requesting)
        let requestRoot = try frameRoot(from: try XCTUnwrap(socket.sentMessages.last))
        let requestPayload = try XCTUnwrap(requestRoot["payload"] as? [String: Any])
        let audioID = try XCTUnwrap(requestPayload["audio_id"] as? String)

        socket.completeLastSend(error: RecordingSocketError())
        await Task.yield()

        XCTAssertNil(client.audioPlaybackOverlay)
        XCTAssertNil(client.playbackStatus)
        XCTAssertEqual(client.connectionState, .error)

        client.handleFrameString("""
        {"type":"audio_chunk","device_id":"ios-simulator","project_key":"default","session_id":"session-playback-fail","payload":{"audio_id":"\(audioID)","message_id":"assistant-playback-fail","chunk_index":0,"data":"\(Data([1, 2]).base64EncodedString())"}}
        """)
        client.handleFrameString("""
        {"type":"audio_end","device_id":"ios-simulator","project_key":"default","session_id":"session-playback-fail","payload":{"audio_id":"\(audioID)","message_id":"assistant-playback-fail","chunk_count":1}}
        """)
        XCTAssertEqual(factory.player.playCalls, 0)
    }

    @MainActor
    func testPlaybackOverlayControlsAudioLifecycleAndSuppressesStoppedFrames() throws {
        let socket = RecordingWebSocketTask()
        let session = RecordingAudioSessionManager()
        let factory = RecordingAudioPlayerFactory()
        let controller = AudioPlaybackController(sessionManager: session, playerFactory: factory)
        let client = makeSocketBackedClient(socket: socket, audioPlayback: controller)
        let message = LogosMessage(
            projectKey: "default",
            sessionID: "session-overlay",
            messageID: "assistant-overlay-1",
            serverSeq: 100,
            role: "assistant",
            content: "Play this response.",
            timestamp: 123,
            status: "persisted"
        )

        client.playback(message: message)
        let requestRoot = try frameRoot(from: try XCTUnwrap(socket.sentMessages.last))
        let requestPayload = try XCTUnwrap(requestRoot["payload"] as? [String: Any])
        let audioID = try XCTUnwrap(requestPayload["audio_id"] as? String)
        XCTAssertEqual(requestPayload["mode"] as? String, "full")
        XCTAssertEqual(client.audioPlaybackOverlay?.audioID, audioID)
        XCTAssertEqual(client.audioPlaybackOverlay?.messageID, "assistant-overlay-1")
        XCTAssertEqual(client.audioPlaybackOverlay?.phase, .requesting)
        XCTAssertEqual(client.audioPlaybackOverlay?.canStop, true)

        let chunk = Data([1, 2, 3, 4]).base64EncodedString()
        client.handleFrameString("""
        {"type":"audio_chunk","device_id":"ios-simulator","project_key":"default","session_id":"session-overlay","payload":{"audio_id":"\(audioID)","message_id":"assistant-overlay-1","chunk_index":0,"data":"\(chunk)"}}
        """)
        XCTAssertEqual(client.audioPlaybackOverlay?.phase, .receiving)
        XCTAssertEqual(client.audioPlaybackOverlay?.spectrumBins.count, 12)

        client.handleFrameString("""
        {"type":"audio_end","device_id":"ios-simulator","project_key":"default","session_id":"session-overlay","payload":{"audio_id":"\(audioID)","message_id":"assistant-overlay-1","chunk_count":1}}
        """)
        XCTAssertEqual(factory.receivedData, Data([1, 2, 3, 4]))
        XCTAssertEqual(factory.player.playCalls, 1)
        XCTAssertEqual(client.audioPlaybackOverlay?.phase, .playing)
        XCTAssertEqual(client.audioPlaybackOverlay?.canPause, true)

        client.pausePlayback()
        XCTAssertEqual(factory.player.pauseCalls, 1)
        XCTAssertEqual(client.audioPlaybackOverlay?.phase, .paused)

        client.resumePlayback()
        XCTAssertEqual(factory.player.playCalls, 2)
        XCTAssertEqual(client.audioPlaybackOverlay?.phase, .playing)

        client.stopPlayback()
        XCTAssertEqual(factory.player.stopCalls, 1)
        XCTAssertNil(client.audioPlaybackOverlay)
        XCTAssertNil(client.playbackStatus)

        let playCallsAfterStop = factory.player.playCalls
        client.handleFrameString("""
        {"type":"audio_chunk","device_id":"ios-simulator","project_key":"default","session_id":"session-overlay","payload":{"audio_id":"\(audioID)","message_id":"assistant-overlay-1","chunk_index":1,"data":"\(chunk)"}}
        """)
        client.handleFrameString("""
        {"type":"audio_end","device_id":"ios-simulator","project_key":"default","session_id":"session-overlay","payload":{"audio_id":"\(audioID)","message_id":"assistant-overlay-1","chunk_count":2}}
        """)
        XCTAssertEqual(factory.player.playCalls, playCallsAfterStop)
        XCTAssertNil(client.lastError)
    }

    @MainActor
    func testFinishedPlaybackLeavesOverlayVisibleTemporarily() async throws {
        let socket = RecordingWebSocketTask()
        let session = RecordingAudioSessionManager()
        let factory = RecordingAudioPlayerFactory()
        let controller = AudioPlaybackController(sessionManager: session, playerFactory: factory)
        let client = makeSocketBackedClient(socket: socket, audioPlayback: controller)
        let message = LogosMessage(
            projectKey: "default",
            sessionID: "session-overlay-finished",
            messageID: "assistant-overlay-finished-1",
            serverSeq: 102,
            role: "assistant",
            content: "Play this short response.",
            timestamp: 123,
            status: "persisted"
        )

        client.playback(message: message)
        let requestRoot = try frameRoot(from: try XCTUnwrap(socket.sentMessages.last))
        let requestPayload = try XCTUnwrap(requestRoot["payload"] as? [String: Any])
        let audioID = try XCTUnwrap(requestPayload["audio_id"] as? String)
        let chunk = Data([9, 10, 11]).base64EncodedString()
        client.handleFrameString("""
        {"type":"audio_chunk","device_id":"ios-simulator","project_key":"default","session_id":"session-overlay-finished","payload":{"audio_id":"\(audioID)","message_id":"assistant-overlay-finished-1","chunk_index":0,"data":"\(chunk)"}}
        """)
        client.handleFrameString("""
        {"type":"audio_end","device_id":"ios-simulator","project_key":"default","session_id":"session-overlay-finished","payload":{"audio_id":"\(audioID)","message_id":"assistant-overlay-finished-1","chunk_count":1}}
        """)
        XCTAssertEqual(client.audioPlaybackOverlay?.phase, .playing)

        controller.onPlaybackFinished?(audioID, true)
        await Task.yield()

        XCTAssertEqual(client.audioPlaybackOverlay?.audioID, audioID)
        XCTAssertEqual(client.audioPlaybackOverlay?.phase, .finished)
        XCTAssertEqual(client.audioPlaybackOverlay?.detail, "Audio finished")
        XCTAssertEqual(client.audioPlaybackOverlay?.canPause, false)
        XCTAssertEqual(client.audioPlaybackOverlay?.canStop, false)
    }

    @MainActor
    func testSceneLifecyclePauseResumeIsLocalAndPreservesOffset() throws {
        let socket = RecordingWebSocketTask()
        let session = RecordingAudioSessionManager()
        let factory = RecordingAudioPlayerFactory()
        let controller = AudioPlaybackController(sessionManager: session, playerFactory: factory)
        let client = makeSocketBackedClient(socket: socket, audioPlayback: controller)
        let message = LogosMessage(
            projectKey: "default",
            sessionID: "session-lifecycle",
            messageID: "assistant-lifecycle-1",
            serverSeq: 101,
            role: "assistant",
            content: "Resume this response.",
            timestamp: 123,
            status: "persisted"
        )

        client.playback(message: message)
        let requestRoot = try frameRoot(from: try XCTUnwrap(socket.sentMessages.last))
        let requestPayload = try XCTUnwrap(requestRoot["payload"] as? [String: Any])
        let audioID = try XCTUnwrap(requestPayload["audio_id"] as? String)
        let chunk = Data([5, 6]).base64EncodedString()
        client.handleFrameString("""
        {"type":"audio_chunk","device_id":"ios-simulator","project_key":"default","session_id":"session-lifecycle","payload":{"audio_id":"\(audioID)","message_id":"assistant-lifecycle-1","chunk_index":0,"data":"\(chunk)"}}
        """)
        client.handleFrameString("""
        {"type":"audio_end","device_id":"ios-simulator","project_key":"default","session_id":"session-lifecycle","payload":{"audio_id":"\(audioID)","message_id":"assistant-lifecycle-1","chunk_count":1}}
        """)
        factory.player.currentTime = 8.25
        let socketFrameCountAfterStart = socket.sentMessages.count

        client.pauseAudioForSceneBackground()
        XCTAssertEqual(factory.player.pauseCalls, 1)
        XCTAssertEqual(client.audioPlaybackOverlay?.phase, .paused)
        factory.player.currentTime = 0

        client.resumeAudioForSceneActive()
        XCTAssertEqual(factory.player.playCalls, 2)
        XCTAssertEqual(factory.player.currentTime, 8.25, accuracy: 0.001)
        XCTAssertEqual(client.audioPlaybackOverlay?.phase, .playing)
        XCTAssertEqual(socket.sentMessages.count, socketFrameCountAfterStart)
        let playbackFrameCount = try socket.sentMessages.map { try frameRoot(from: $0) }
            .filter { $0["type"] as? String == "playback_audio" }
            .count
        XCTAssertEqual(playbackFrameCount, 1)
    }

    @MainActor
    func testManualPausedAudioDoesNotResumeOnSceneActive() throws {
        let socket = RecordingWebSocketTask()
        let session = RecordingAudioSessionManager()
        let factory = RecordingAudioPlayerFactory()
        let controller = AudioPlaybackController(sessionManager: session, playerFactory: factory)
        let client = makeSocketBackedClient(socket: socket, audioPlayback: controller)
        let message = LogosMessage(
            projectKey: "default",
            sessionID: "session-manual-pause",
            messageID: "assistant-manual-pause-1",
            serverSeq: 103,
            role: "assistant",
            content: "Do not resume this automatically.",
            timestamp: 123,
            status: "persisted"
        )

        client.playback(message: message)
        let requestRoot = try frameRoot(from: try XCTUnwrap(socket.sentMessages.last))
        let requestPayload = try XCTUnwrap(requestRoot["payload"] as? [String: Any])
        let audioID = try XCTUnwrap(requestPayload["audio_id"] as? String)
        let chunk = Data([7, 8]).base64EncodedString()
        client.handleFrameString("""
        {"type":"audio_chunk","device_id":"ios-simulator","project_key":"default","session_id":"session-manual-pause","payload":{"audio_id":"\(audioID)","message_id":"assistant-manual-pause-1","chunk_index":0,"data":"\(chunk)"}}
        """)
        client.handleFrameString("""
        {"type":"audio_end","device_id":"ios-simulator","project_key":"default","session_id":"session-manual-pause","payload":{"audio_id":"\(audioID)","message_id":"assistant-manual-pause-1","chunk_count":1}}
        """)
        XCTAssertEqual(factory.player.playCalls, 1)

        client.pausePlayback()
        XCTAssertEqual(factory.player.pauseCalls, 1)
        XCTAssertEqual(client.audioPlaybackOverlay?.phase, .paused)

        client.pauseAudioForSceneBackground()
        client.resumeAudioForSceneActive()

        XCTAssertEqual(factory.player.playCalls, 1)
        XCTAssertEqual(client.audioPlaybackOverlay?.phase, .paused)
    }

    @MainActor
    func testNewPlaybackRequestStopsPriorAudioAndSuppressesLateFrames() throws {
        let socket = RecordingWebSocketTask()
        let session = RecordingAudioSessionManager()
        let factory = RecordingAudioPlayerFactory()
        let controller = AudioPlaybackController(sessionManager: session, playerFactory: factory)
        let client = makeSocketBackedClient(socket: socket, audioPlayback: controller)
        let first = LogosMessage(
            projectKey: "default",
            sessionID: "session-replay-one",
            messageID: "assistant-replay-1",
            serverSeq: 105,
            role: "assistant",
            content: "First playback.",
            timestamp: 123,
            status: "persisted"
        )
        let second = LogosMessage(
            projectKey: "default",
            sessionID: "session-replay-two",
            messageID: "assistant-replay-2",
            serverSeq: 106,
            role: "assistant",
            content: "Second playback.",
            timestamp: 124,
            status: "persisted"
        )

        client.playback(message: first)
        let firstRoot = try frameRoot(from: try XCTUnwrap(socket.sentMessages.last))
        let firstPayload = try XCTUnwrap(firstRoot["payload"] as? [String: Any])
        let firstAudioID = try XCTUnwrap(firstPayload["audio_id"] as? String)
        let chunk = Data([3, 4]).base64EncodedString()
        client.handleFrameString("""
        {"type":"audio_chunk","device_id":"ios-simulator","project_key":"default","session_id":"session-replay-one","payload":{"audio_id":"\(firstAudioID)","message_id":"assistant-replay-1","chunk_index":0,"data":"\(chunk)"}}
        """)
        client.handleFrameString("""
        {"type":"audio_end","device_id":"ios-simulator","project_key":"default","session_id":"session-replay-one","payload":{"audio_id":"\(firstAudioID)","message_id":"assistant-replay-1","chunk_count":1}}
        """)
        XCTAssertEqual(factory.player.playCalls, 1)

        client.playback(message: second)
        let secondRoot = try frameRoot(from: try XCTUnwrap(socket.sentMessages.last))
        let secondPayload = try XCTUnwrap(secondRoot["payload"] as? [String: Any])
        XCTAssertNotEqual(secondPayload["audio_id"] as? String, firstAudioID)
        XCTAssertEqual(factory.player.stopCalls, 1)
        XCTAssertEqual(client.audioPlaybackOverlay?.messageID, "assistant-replay-2")

        client.handleFrameString("""
        {"type":"audio_chunk","device_id":"ios-simulator","project_key":"default","session_id":"session-replay-one","payload":{"audio_id":"\(firstAudioID)","message_id":"assistant-replay-1","chunk_index":1,"data":"\(chunk)"}}
        """)
        client.handleFrameString("""
        {"type":"audio_end","device_id":"ios-simulator","project_key":"default","session_id":"session-replay-one","payload":{"audio_id":"\(firstAudioID)","message_id":"assistant-replay-1","chunk_count":2}}
        """)
        XCTAssertEqual(factory.player.playCalls, 1)
        XCTAssertEqual(client.audioPlaybackOverlay?.messageID, "assistant-replay-2")
    }

    @MainActor
    func testProjectSwitchStopsAudioAndRejectsLateFrames() throws {
        let socket = RecordingWebSocketTask()
        let session = RecordingAudioSessionManager()
        let factory = RecordingAudioPlayerFactory()
        let controller = AudioPlaybackController(sessionManager: session, playerFactory: factory)
        let client = makeSocketBackedClient(socket: socket, audioPlayback: controller)
        let message = LogosMessage(
            projectKey: "default",
            sessionID: "session-project-audio",
            messageID: "assistant-project-audio-1",
            serverSeq: 104,
            role: "assistant",
            content: "Project scoped audio.",
            timestamp: 123,
            status: "persisted"
        )

        client.playback(message: message)
        let requestRoot = try frameRoot(from: try XCTUnwrap(socket.sentMessages.last))
        let requestPayload = try XCTUnwrap(requestRoot["payload"] as? [String: Any])
        let audioID = try XCTUnwrap(requestPayload["audio_id"] as? String)
        client.switchProject("beta")

        XCTAssertNil(client.audioPlaybackOverlay)
        XCTAssertNil(client.playbackStatus)
        client.handleFrameString("""
        {"type":"audio_chunk","device_id":"ios-simulator","project_key":"default","session_id":"session-project-audio","payload":{"audio_id":"\(audioID)","message_id":"assistant-project-audio-1","chunk_index":0,"data":"\(Data([1]).base64EncodedString())"}}
        """)
        client.handleFrameString("""
        {"type":"audio_end","device_id":"ios-simulator","project_key":"default","session_id":"session-project-audio","payload":{"audio_id":"\(audioID)","message_id":"assistant-project-audio-1","chunk_count":1}}
        """)

        XCTAssertEqual(factory.player.playCalls, 0)
        XCTAssertNil(client.audioPlaybackOverlay)
        XCTAssertNil(client.lastError)
    }

    func testAudioPlaybackControllerLifecycleIgnoresManualPausedPlayers() throws {
        let session = RecordingAudioSessionManager()
        let factory = RecordingAudioPlayerFactory()
        let controller = AudioPlaybackController(sessionManager: session, playerFactory: factory)
        try controller.appendChunk(audioID: "audio-manual-paused", chunkIndex: 0, base64: Data([1, 2]).base64EncodedString())
        try controller.finish(audioID: "audio-manual-paused", expectedChunkCount: 1)

        XCTAssertTrue(controller.pause(audioID: "audio-manual-paused"))
        let snapshots = controller.pauseForLifecycle(reason: "scene_background")
        let resumed = try controller.resumeAfterLifecycle()

        XCTAssertTrue(snapshots.isEmpty)
        XCTAssertTrue(resumed.isEmpty)
        XCTAssertEqual(factory.player.playCalls, 1)
    }

    @MainActor
    func testFastAckClearsWhenAssistantMessageArrives() throws {
        let client = LogosClient(store: SQLiteMessageStore(filename: "LogosTests-\(UUID().uuidString).sqlite3"))

        client.handleFrameString(#"""
        {"type":"state_update","request_id":"req-ack","project_key":"default","payload":{"op":"fast_ack","ack_text":"I'll check.","transient":true,"ttl_ms":5000}}
        """#)
        XCTAssertEqual(client.ackText, "I'll check.")

        client.handleFrameString(#"""
        {"type":"state_update","project_key":"default","session_id":"session-ack","server_seq":51,"payload":{"op":"message_appended","message":{"project_key":"default","session_id":"session-ack","message_id":"assistant-ack-1","server_seq":51,"role":"assistant","content":"Checked. Clean.","timestamp":123.0}}}
        """#)

        XCTAssertNil(client.ackText)
    }

    @MainActor
    func testFastAckClearsWhenRunStatusBecomesTerminal() throws {
        let client = LogosClient(store: SQLiteMessageStore(filename: "LogosTests-\(UUID().uuidString).sqlite3"))

        client.handleFrameString(#"""
        {"type":"state_update","request_id":"req-ack","project_key":"default","payload":{"op":"fast_ack","ack_text":"Working on it.","transient":true,"ttl_ms":5000}}
        """#)
        XCTAssertEqual(client.ackText, "Working on it.")

        client.handleFrameString(#"""
        {"type":"run_status","project_key":"default","payload":{"status":"idle"}}
        """#)

        XCTAssertNil(client.ackText)
    }

    @MainActor
    func testFastAckTTLExpiresWithoutClearingNewerAckEarly() async throws {
        let client = LogosClient(store: SQLiteMessageStore(filename: "LogosTests-\(UUID().uuidString).sqlite3"))

        client.handleFrameString(#"""
        {"type":"state_update","request_id":"old-ack","project_key":"default","payload":{"op":"fast_ack","ack_text":"Old ack.","transient":true,"ttl_ms":40}}
        """#)
        XCTAssertEqual(client.ackText, "Old ack.")

        client.handleFrameString(#"""
        {"type":"state_update","request_id":"new-ack","project_key":"default","payload":{"op":"fast_ack","ack_text":"New ack.","transient":true,"ttl_ms":220}}
        """#)
        XCTAssertEqual(client.ackText, "New ack.")

        try await Task.sleep(nanoseconds: 90_000_000)
        XCTAssertEqual(client.ackText, "New ack.")

        try await Task.sleep(nanoseconds: 220_000_000)
        XCTAssertNil(client.ackText)
    }

    @MainActor
    func testFastAckIgnoresInactiveProject() throws {
        let client = LogosClient(store: SQLiteMessageStore(filename: "LogosTests-\(UUID().uuidString).sqlite3"))
        client.activeProjectKey = "default"

        client.handleFrameString(#"""
        {"type":"state_update","request_id":"req-ack","project_key":"other","payload":{"op":"fast_ack","ack_text":"Wrong project.","transient":true,"ttl_ms":5000}}
        """#)

        XCTAssertNil(client.ackText)
    }

    @MainActor
    func testFastAckSurvivesSameActiveProjectRefresh() throws {
        let client = LogosClient(store: SQLiteMessageStore(filename: "LogosTests-\(UUID().uuidString).sqlite3"))

        client.handleFrameString(#"""
        {"type":"state_update","request_id":"req-ack","project_key":"default","payload":{"op":"fast_ack","ack_text":"I'll check.","transient":true,"ttl_ms":5000}}
        """#)
        XCTAssertEqual(client.ackText, "I'll check.")

        client.handleFrameString(#"""
        {"type":"projects_list","payload":{"active_project_key":"default","projects":[{"project_key":"default","title":"Default","current_session_id":"project:default","last_preview":""}]}}
        """#)

        XCTAssertEqual(client.ackText, "I'll check.")
    }

    @MainActor
    func testAdapterErrorClearsFastAck() throws {
        let client = LogosClient(store: SQLiteMessageStore(filename: "LogosTests-\(UUID().uuidString).sqlite3"))

        client.handleFrameString(#"""
        {"type":"state_update","request_id":"req-ack","project_key":"default","payload":{"op":"fast_ack","ack_text":"I'll check.","transient":true,"ttl_ms":5000}}
        """#)
        XCTAssertEqual(client.ackText, "I'll check.")

        client.handleFrameString(#"""
        {"type":"error","request_id":"req-ack","project_key":"default","payload":{"code":"server_error","message":"Hermes failed."}}
        """#)

        XCTAssertNil(client.ackText)
        XCTAssertEqual(client.lastError, "Hermes failed.")
    }

    @MainActor
    func testInteractionReconciliationClearsResponseAck() throws {
        let socket = RecordingWebSocketTask()
        let client = makeSocketBackedClient(socket: socket)

        client.handleFrameString(#"""
        {"type":"approval_request","request_id":"appr-1","project_key":"default","payload":{"title":"Approve command?","summary":"Hermes needs approval.","command_preview":"python test.py","risk":"low"}}
        """#)
        client.approveCurrentRequest()
        XCTAssertEqual(client.ackText, "Approved. Waiting for Hermes…")

        client.handleFrameString(#"""
        {"type":"messages_batch","project_key":"default","payload":{"messages":[],"pending_interactions":[]}}
        """#)

        XCTAssertNil(client.approvalCard)
        XCTAssertNil(client.pendingInteractionResponseID)
        XCTAssertNil(client.ackText)
    }

    @MainActor
    func testFastDirectResponseClearsAckAndAutoplaysOnce() throws {
        let socket = RecordingWebSocketTask()
        let client = makeSocketBackedClient(socket: socket)
        client.handleFrameString(#"""
        {"type":"state_update","request_id":"req-ack","project_key":"default","payload":{"op":"fast_ack","ack_text":"I'll check.","transient":true,"ttl_ms":5000}}
        """#)
        XCTAssertEqual(client.ackText, "I'll check.")
        let baselineCount = socket.sentMessages.count

        client.handleFrameString(#"""
        {"type":"state_update","project_key":"default","session_id":"session-fast","server_seq":60,"payload":{"op":"message_appended","message":{"project_key":"default","session_id":"session-fast","message_id":"fast-req-hi","server_seq":60,"role":"assistant","content":"I'm here.","timestamp":123.0,"metadata":{"source":"fast_response"}}}}
        """#)

        XCTAssertNil(client.ackText)
        XCTAssertEqual(client.messages.last?.messageID, "fast-req-hi")
        XCTAssertEqual(client.messages.last?.content, "I'm here.")
        let newFrames = try socket.sentMessages.dropFirst(baselineCount).map { try frameRoot(from: $0) }
        XCTAssertEqual(newFrames.filter { $0["type"] as? String == "playback_audio" }.count, 1)
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

    func testAudioPlaybackControllerLifecyclePauseDoesNotFinishAndResumesOffset() throws {
        let session = RecordingAudioSessionManager()
        let factory = RecordingAudioPlayerFactory()
        let controller = AudioPlaybackController(sessionManager: session, playerFactory: factory)
        var finished: [(String, Bool)] = []
        controller.onPlaybackFinished = { audioID, succeeded in
            finished.append((audioID, succeeded))
        }
        try controller.appendChunk(audioID: "audio-lifecycle", chunkIndex: 0, base64: Data([1, 2]).base64EncodedString())
        try controller.finish(audioID: "audio-lifecycle", expectedChunkCount: 1)
        factory.player.currentTime = 6.5

        let snapshots = controller.pauseForLifecycle(reason: "scene_background")

        let snapshot = try XCTUnwrap(snapshots.first)
        XCTAssertEqual(snapshot.audioID, "audio-lifecycle")
        XCTAssertEqual(snapshot.currentTime, 6.5, accuracy: 0.001)
        XCTAssertEqual(factory.player.pauseCalls, 1)
        XCTAssertEqual(session.finishCalls, 0)
        XCTAssertTrue(finished.isEmpty)

        factory.player.currentTime = 0
        let resumed = try controller.resumeAfterLifecycle()

        XCTAssertEqual(resumed.map(\.audioID), ["audio-lifecycle"])
        XCTAssertEqual(factory.player.currentTime, 6.5, accuracy: 0.001)
        XCTAssertEqual(factory.player.playCalls, 2)
    }

    func testAudioPlaybackControllerPauseResumeStopAndSpectrumBins() throws {
        let session = RecordingAudioSessionManager()
        let factory = RecordingAudioPlayerFactory()
        let controller = AudioPlaybackController(sessionManager: session, playerFactory: factory)
        try controller.appendChunk(audioID: "audio-spectrum", chunkIndex: 0, base64: Data([1, 2, 3]).base64EncodedString())
        try controller.finish(audioID: "audio-spectrum", expectedChunkCount: 1)

        let bins = controller.spectrumBins(audioID: "audio-spectrum", count: 12)

        XCTAssertEqual(bins.count, 12)
        XCTAssertTrue(bins.allSatisfy { $0 >= 0 && $0 <= 1 })
        XCTAssertTrue(controller.pause(audioID: "audio-spectrum"))
        XCTAssertEqual(factory.player.pauseCalls, 1)
        XCTAssertTrue(try controller.resume(audioID: "audio-spectrum"))
        XCTAssertEqual(factory.player.playCalls, 2)
        XCTAssertTrue(controller.stop(audioID: "audio-spectrum"))
        XCTAssertEqual(factory.player.stopCalls, 1)
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
    var isPlaying = false
    var currentTime: TimeInterval = 0
    var duration: TimeInterval = 30
    var isMeteringEnabled = false
    var averagePowerValue: Float = -18
    private(set) var prepareCalls = 0
    private(set) var playCalls = 0
    private(set) var pauseCalls = 0
    private(set) var stopCalls = 0
    private(set) var updateMetersCalls = 0
    private(set) var averagePowerCalls = 0

    func prepareToPlay() -> Bool {
        prepareCalls += 1
        return prepareResult
    }

    func play() -> Bool {
        playCalls += 1
        isPlaying = playResult
        return playResult
    }

    func pause() {
        pauseCalls += 1
        isPlaying = false
    }

    func stop() {
        stopCalls += 1
        isPlaying = false
        currentTime = 0
    }

    func updateMeters() {
        updateMetersCalls += 1
    }

    func averagePower(forChannel channelNumber: Int) -> Float {
        averagePowerCalls += 1
        return averagePowerValue
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
private func makeSocketBackedClient(
    socket: RecordingWebSocketTask,
    autoConnect: Bool = true,
    store: SQLiteMessageStore? = nil,
    audioPlayback: AudioPlaybackController = AudioPlaybackController(),
    progressTimeoutInterval: TimeInterval = 45
) -> LogosClient {
    let client = LogosClient(
        store: store ?? SQLiteMessageStore(filename: "LogosTests-\(UUID().uuidString).sqlite3"),
        socketFactory: RecordingWebSocketTaskFactory(socket: socket),
        audioPlayback: audioPlayback,
        progressTimeoutInterval: progressTimeoutInterval
    )
    client.settings.urlString = "ws://127.0.0.1:8765"
    client.settings.deviceID = "ios-simulator"
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

    func receiveFailure(_ error: Error) {
        let completion = receiveCompletions.removeFirst()
        completion(.failure(error))
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
