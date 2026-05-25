import XCTest
import AVFoundation
@testable import Logos

final class LogosModelTests: XCTestCase {
    func testThreadAutoFollowPolicyUsesViewportBasedDetachThreshold() {
        XCTAssertEqual(ThreadAutoFollowPolicy.detachThreshold(visibleHeight: 400), 160)
        XCTAssertEqual(ThreadAutoFollowPolicy.detachThreshold(visibleHeight: 1000), 250)
        XCTAssertTrue(ThreadAutoFollowPolicy.isNearBottom(distanceFromBottom: 160, visibleHeight: 400))
        XCTAssertFalse(ThreadAutoFollowPolicy.isNearBottom(distanceFromBottom: 161, visibleHeight: 400))
        XCTAssertFalse(ThreadAutoFollowPolicy.shouldDetachForUserScroll(distanceFromBottom: 120, visibleHeight: 400))
        XCTAssertTrue(ThreadAutoFollowPolicy.shouldDetachForUserScroll(distanceFromBottom: 220, visibleHeight: 400))
        XCTAssertFalse(ThreadAutoFollowPolicy.shouldDetachForProgrammaticScroll(distanceFromBottom: 800, visibleHeight: 400))
        XCTAssertTrue(ThreadAutoFollowPolicy.shouldApplyFollow(force: true, shouldFollowThread: false, isThreadUserDetached: true))
    }

    func testThreadTimelineSnapshotChangesForEveryVisibleThreadSignal() {
        let base = makeThreadTimelineSnapshot()

        XCTAssertNotEqual(base, makeThreadTimelineSnapshot(messages: [.init(id: "m2", status: "persisted", isFinal: true, content: "New")]))
        XCTAssertNotEqual(base, makeThreadTimelineSnapshot(messages: [.init(id: "m1", status: "persisted", isFinal: true, content: "Hello", role: "user")]))
        XCTAssertNotEqual(base, makeThreadTimelineSnapshot(messages: [.init(id: "m1", status: "persisted", isFinal: false, content: "Hello", isProgressUpdate: true)]))
        XCTAssertNotEqual(base, makeThreadTimelineSnapshot(progress: .init(id: "progress", updateCount: 2, adapterUpdateCount: 1, isExpanded: false, isComplete: false, timedOut: false, finalStatus: nil, canRetry: false, completedFinalMessageID: nil)))
        XCTAssertNotEqual(base, makeThreadTimelineSnapshot(progress: .init(id: "progress", updateCount: 1, adapterUpdateCount: 2, isExpanded: false, isComplete: false, timedOut: false, finalStatus: nil, canRetry: false, completedFinalMessageID: nil)))
        XCTAssertNotEqual(base, makeThreadTimelineSnapshot(progress: .init(id: "progress", updateCount: 1, adapterUpdateCount: 1, isExpanded: true, isComplete: false, timedOut: false, finalStatus: nil, canRetry: false, completedFinalMessageID: nil)))
        XCTAssertNotEqual(base, makeThreadTimelineSnapshot(progress: .init(id: "progress", updateCount: 1, adapterUpdateCount: 1, isExpanded: false, isComplete: true, timedOut: false, finalStatus: "complete", canRetry: false, completedFinalMessageID: "session:final")))
        XCTAssertNotEqual(base, makeThreadTimelineSnapshot(progress: .init(id: "progress", updateCount: 1, adapterUpdateCount: 1, isExpanded: false, isComplete: true, timedOut: false, finalStatus: "failed", canRetry: true, completedFinalMessageID: nil)))
        XCTAssertNotEqual(base, makeThreadTimelineSnapshot(progress: .init(id: "progress", updateCount: 1, adapterUpdateCount: 1, isExpanded: false, isComplete: false, timedOut: true, finalStatus: nil, canRetry: false, completedFinalMessageID: nil)))
        XCTAssertNotEqual(base, makeThreadTimelineSnapshot(isRunControlVisible: true))
        XCTAssertNotEqual(base, makeThreadTimelineSnapshot(approvalCardID: "approval-1"))
        XCTAssertNotEqual(base, makeThreadTimelineSnapshot(clarifyCardID: "clarify-1"))
        XCTAssertNotEqual(base, makeThreadTimelineSnapshot(pendingInteractionResponseID: "approval-1"))
        XCTAssertNotEqual(base, makeThreadTimelineSnapshot(ackText: "Thinking"))
        XCTAssertNotEqual(base, makeThreadTimelineSnapshot(errorText: "Error"))
        XCTAssertNotEqual(base, makeThreadTimelineSnapshot(connectionRetry: .init(id: "retry", attemptCount: 1, eventCount: 1, nextRetryAt: 100)))
        XCTAssertNotEqual(base, makeThreadTimelineSnapshot(voiceDraftText: "Listening"))
        XCTAssertNotEqual(base, makeThreadTimelineSnapshot(composerMode: "text"))
        XCTAssertNotEqual(base, makeThreadTimelineSnapshot(composerBottomPadding: 16))
        XCTAssertNotEqual(base, makeThreadTimelineSnapshot(connectionState: "disconnected"))
        XCTAssertNotEqual(base, makeThreadTimelineSnapshot(runStatus: "cancelling"))
    }

    private func makeThreadTimelineSnapshot(
        activeProjectKey: String = "default",
        messages: [ThreadTimelineSnapshot.Message] = [.init(id: "m1", status: "persisted", isFinal: true, content: "Hello")],
        progress: ThreadTimelineSnapshot.Progress? = .init(id: "progress", updateCount: 1, adapterUpdateCount: 1, isExpanded: false, isComplete: false, timedOut: false, finalStatus: nil, canRetry: false, completedFinalMessageID: nil),
        isRunControlVisible: Bool = false,
        approvalCardID: String? = nil,
        clarifyCardID: String? = nil,
        pendingInteractionResponseID: String? = nil,
        ackText: String? = nil,
        errorText: String? = nil,
        connectionRetry: ThreadTimelineSnapshot.ConnectionRetry? = nil,
        voiceDraftText: String? = nil,
        composerMode: String = "paused",
        composerBottomPadding: CGFloat = 28,
        connectionState: String = "connected",
        runStatus: String = "running"
    ) -> ThreadTimelineSnapshot {
        ThreadTimelineSnapshot(
            activeProjectKey: activeProjectKey,
            messages: messages,
            progress: progress,
            connectionRetry: connectionRetry,
            isRunControlVisible: isRunControlVisible,
            approvalCardID: approvalCardID,
            clarifyCardID: clarifyCardID,
            pendingInteractionResponseID: pendingInteractionResponseID,
            ackText: ackText,
            errorText: errorText,
            voiceDraftText: voiceDraftText,
            composerMode: composerMode,
            composerBottomPadding: composerBottomPadding,
            connectionState: connectionState,
            runStatus: runStatus
        )
    }

    func testThreadProgressPlacementUsesMatchedFinalMessageIdentity() {
        let messages = [
            LogosMessage(
                projectKey: "default",
                sessionID: "session-placement",
                messageID: "user-1",
                serverSeq: 1,
                role: "user",
                content: "Question",
                timestamp: 1,
                status: "persisted"
            ),
            LogosMessage(
                projectKey: "default",
                sessionID: "session-placement",
                messageID: "assistant-final-1",
                serverSeq: 2,
                role: "assistant",
                content: "First final",
                timestamp: 2,
                status: "persisted"
            ),
            LogosMessage(
                projectKey: "default",
                sessionID: "session-placement",
                messageID: "assistant-final-2",
                serverSeq: 3,
                role: "assistant",
                content: "Later assistant message",
                timestamp: 3,
                status: "persisted"
            )
        ]

        XCTAssertEqual(
            ThreadProgressPlacement.insertionIndex(
                messages: messages,
                completedFinalMessageID: "session-placement:assistant-final-1"
            ),
            1
        )
        XCTAssertNil(ThreadProgressPlacement.insertionIndex(messages: messages, completedFinalMessageID: nil))
        XCTAssertNil(
            ThreadProgressPlacement.insertionIndex(
                messages: messages,
                completedFinalMessageID: "session-placement:missing"
            )
        )
    }

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
                "progress_kind": "terminal",
                "request_id": "req-progress",
                "transient": false
            ]
        ]))
        XCTAssertFalse(progress.isFinal)
        XCTAssertTrue(progress.hasFinalizedMetadata)
        XCTAssertEqual(progress.metadataSource, "tool_progress")
        XCTAssertEqual(progress.progressKind, "terminal")
        XCTAssertEqual(progress.metadataRequestID, "req-progress")
        XCTAssertEqual(progress.metadataTransient, false)

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

    func testSQLiteMessageStorePersistsProgressMetadata() throws {
        let filename = "LogosTests-\(UUID().uuidString).sqlite3"
        let store = SQLiteMessageStore(filename: filename)
        let progress = LogosMessage(
            projectKey: "default",
            sessionID: "session-progress",
            messageID: "progress-1",
            serverSeq: 12,
            role: "assistant",
            content: "🔧 terminal: \"pytest\"",
            timestamp: 123.0,
            status: "persisted",
            isFinal: false,
            hasFinalizedMetadata: true,
            metadataSource: "tool_progress",
            progressKind: "terminal",
            metadataRequestID: "req-progress",
            metadataTransient: false
        )

        store.upsert(progress)

        let reloaded = SQLiteMessageStore(filename: filename)
        let loaded = try XCTUnwrap(reloaded.loadMessages(projectKey: "default").first)
        XCTAssertTrue(loaded.isProgressUpdate)
        XCTAssertFalse(loaded.isFinal)
        XCTAssertTrue(loaded.hasFinalizedMetadata)
        XCTAssertEqual(loaded.metadataSource, "tool_progress")
        XCTAssertEqual(loaded.progressKind, "terminal")
        XCTAssertEqual(loaded.metadataRequestID, "req-progress")
        XCTAssertEqual(loaded.metadataTransient, false)
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

        XCTAssertEqual(settings.urlString, "wss://your-mac.your-tailnet.ts.net/")
    }

    @MainActor
    func testConnectWaitsForWebSocketOpenBeforeStartupFrames() async throws {
        let socket = RecordingWebSocketTask()
        let client = LogosClient(
            store: SQLiteMessageStore(filename: "LogosTests-\(UUID().uuidString).sqlite3"),
            socketFactory: RecordingWebSocketTaskFactory(socket: socket)
        )
        client.settings.urlString = "wss://your-mac.your-tailnet.ts.net/"
        client.settings.secret = "test-secret"
        client.settings.autoConnect = true

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
        client.settings.urlString = "wss://your-mac.your-tailnet.ts.net/"
        client.settings.secret = "test-secret"
        client.settings.autoConnect = true

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
        client.settings.urlString = "wss://your-mac.your-tailnet.ts.net/"
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
        client.settings.urlString = "wss://your-mac.your-tailnet.ts.net/"
        client.settings.secret = "test-secret"
        client.settings.autoConnect = true

        client.connect()
        socket.fail(message: "Socket is not connected")
        await Task.yield()

        XCTAssertEqual(client.connectionState, .error)
        XCTAssertEqual(client.lastError, "Socket is not connected")
        XCTAssertEqual(client.runStatus, .idle)
        XCTAssertEqual(client.connectionRetryState?.attemptCount, 1)
        XCTAssertEqual(client.connectionRetryState?.latestError, "Socket is not connected")
        XCTAssertEqual(client.connectionRetryState?.events.last?.text, "Connection attempt 1 failed: Socket is not connected")
        XCTAssertNotNil(client.connectionRetryState?.nextRetryAt)
        XCTAssertTrue(socket.sentMessages.isEmpty)
    }

    func testAutoConnectDefaultsOnAndAttemptsBeforeFirstSuccessfulConnection() throws {
        let suiteName = "LogosSettingsAutoConnectDefault-\(UUID().uuidString)"
        let userDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { userDefaults.removePersistentDomain(forName: suiteName) }

        let settings = LogosSettings(environment: [:], userDefaults: userDefaults)

        XCTAssertTrue(settings.autoConnect)
        XCTAssertFalse(settings.hasCompletedFirstConnection)
        XCTAssertTrue(LogosAutoConnectPolicy.shouldAttempt(
            autoConnect: settings.autoConnect,
            hasCompletedFirstConnection: settings.hasCompletedFirstConnection,
            connectionState: .disconnected
        ))
    }

    func testReconnectBackoffUsesDeterministicSchedule() {
        XCTAssertEqual(LogosReconnectBackoff.delay(afterFailedAttempt: 1), 1)
        XCTAssertEqual(LogosReconnectBackoff.delay(afterFailedAttempt: 2), 2)
        XCTAssertEqual(LogosReconnectBackoff.delay(afterFailedAttempt: 3), 4)
        XCTAssertEqual(LogosReconnectBackoff.delay(afterFailedAttempt: 4), 8)
        XCTAssertEqual(LogosReconnectBackoff.delay(afterFailedAttempt: 5), 15)
        XCTAssertEqual(LogosReconnectBackoff.delay(afterFailedAttempt: 6), 30)
        XCTAssertEqual(LogosReconnectBackoff.delay(afterFailedAttempt: 7), 60)
        XCTAssertEqual(LogosReconnectBackoff.delay(afterFailedAttempt: 12), 60)
    }

    @MainActor
    func testManualReconnectClearsRetryStateAndDoesNotLeaveRunError() async throws {
        let socket = RecordingWebSocketTask()
        let client = LogosClient(
            store: SQLiteMessageStore(filename: "LogosTests-\(UUID().uuidString).sqlite3"),
            socketFactory: RecordingWebSocketTaskFactory(socket: socket)
        )
        client.settings.urlString = "wss://your-mac.your-tailnet.ts.net/"
        client.settings.secret = "test-secret"
        client.settings.autoConnect = true

        client.connect()
        socket.fail(message: "Gateway unreachable")
        await Task.yield()

        XCTAssertNotNil(client.connectionRetryState)
        XCTAssertEqual(client.runStatus, .idle)

        client.connect()

        XCTAssertNil(client.connectionRetryState)
        XCTAssertNil(client.lastError)
        XCTAssertEqual(client.connectionState, .connecting)
        XCTAssertEqual(client.runStatus, .idle)
    }

    @MainActor
    func testSuccessfulReconnectClearsRetryState() async throws {
        let socket = RecordingWebSocketTask()
        let client = LogosClient(
            store: SQLiteMessageStore(filename: "LogosTests-\(UUID().uuidString).sqlite3"),
            socketFactory: RecordingWebSocketTaskFactory(socket: socket)
        )
        client.settings.urlString = "wss://your-mac.your-tailnet.ts.net/"
        client.settings.secret = "test-secret"
        client.settings.autoConnect = true

        client.connect()
        socket.fail(message: "Gateway unreachable")
        await Task.yield()
        XCTAssertNotNil(client.connectionRetryState)

        client.connect()
        socket.open()
        await Task.yield()
        client.handleFrameString(#"{"type":"hello","request_id":"hello-1","payload":{"authenticated":true}}"#)

        XCTAssertNil(client.connectionRetryState)
        XCTAssertEqual(client.connectionState, .connected)
        XCTAssertNil(client.lastError)
    }

    func testAutoConnectPolicyAttemptsWheneverEnabledAndDisconnected() throws {
        XCTAssertTrue(LogosAutoConnectPolicy.shouldAttempt(
            autoConnect: true,
            hasCompletedFirstConnection: false,
            connectionState: .disconnected
        ))
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
            "adapter_url": "wss://your-mac.your-tailnet.ts.net/",
            "device_id": "iphone-17-pro",
            "pair_token": "one-time-token",
            "expires_at": 1_778_760_000.0,
            "autoconnect": true
        ]
        let url = try XCTUnwrap(URL(string: "logos://pair#\(base64URLPayload(payload))"))

        let route = try XCTUnwrap(LogosPairingRoute.from(url: url))

        XCTAssertEqual(route.adapterURL, "wss://your-mac.your-tailnet.ts.net/")
        XCTAssertEqual(route.deviceID, "iphone-17-pro")
        XCTAssertEqual(route.pairToken, "one-time-token")
        XCTAssertEqual(route.expiresAt, Date(timeIntervalSince1970: 1_778_760_000.0))
        XCTAssertTrue(route.autoConnect)
        XCTAssertNil(route.deviceSecret)
    }

    func testPairingRouteRejectsPayloadWithoutTokenOrSecret() throws {
        let payload: [String: Any] = [
            "v": 1,
            "adapter_url": "wss://your-mac.your-tailnet.ts.net/",
            "device_id": "iphone-17-pro"
        ]
        let url = try XCTUnwrap(URL(string: "logos://pair#\(base64URLPayload(payload))"))

        XCTAssertNil(LogosPairingRoute.from(url: url))
        XCTAssertNil(LogosPairingRoute.from(url: URL(string: "logos://notification?kind=approval")!))
    }

    func testPairingRouteRejectsDirectDeviceSecretPayload() throws {
        let payload: [String: Any] = [
            "v": 1,
            "adapter_url": "wss://your-mac.your-tailnet.ts.net/",
            "device_id": "iphone-17-pro",
            "device_secret": "do-not-accept-secrets-in-qr"
        ]
        let url = try XCTUnwrap(URL(string: "logos://pair#\(base64URLPayload(payload))"))

        XCTAssertNil(LogosPairingRoute.from(url: url))
    }

    func testPairingRouteRequiresSecureTransportExceptLoopback() throws {
        let secure = LogosPairingRoute(
            adapterURL: "wss://your-mac.your-tailnet.ts.net/",
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
            adapterURL: "wss://your-mac.your-tailnet.ts.net/",
            deviceID: "iphone-17-pro",
            deviceSecret: "per-device-secret"
        )
        let client = LogosClient(
            store: SQLiteMessageStore(filename: "LogosTests-\(UUID().uuidString).sqlite3"),
            socketFactory: RecordingWebSocketTaskFactory(socket: socket),
            pairingExchanger: exchanger
        )
        let route = LogosPairingRoute(
            adapterURL: "wss://your-mac.your-tailnet.ts.net/",
            deviceID: "iphone-17-pro",
            pairToken: "one-time-token",
            deviceSecret: nil,
            expiresAt: Date().addingTimeInterval(120),
            autoConnect: true
        )

        await client.applyPairingRoute(route)

        XCTAssertEqual(exchanger.routes, [route])
        XCTAssertEqual(client.settings.urlString, "wss://your-mac.your-tailnet.ts.net/")
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
        client.settings.urlString = "wss://old-adapter.your-tailnet.ts.net/"
        client.settings.deviceID = "old-device"
        client.settings.secret = "old-secret"
        client.connect()
        socket.open()
        await Task.yield()
        client.handleFrameString(#"{"type":"hello","request_id":"hello-1","payload":{"authenticated":true}}"#)
        XCTAssertEqual(client.connectionState, .connected)

        let route = LogosPairingRoute(
            adapterURL: "wss://your-mac.your-tailnet.ts.net/",
            deviceID: "iphone-17-pro",
            pairToken: "one-time-token",
            deviceSecret: nil,
            expiresAt: Date().addingTimeInterval(120),
            autoConnect: true
        )
        await client.applyPairingRoute(route)

        XCTAssertEqual(exchanger.routes, [route])
        XCTAssertEqual(client.connectionState, .connected)
        XCTAssertEqual(client.settings.urlString, "wss://old-adapter.your-tailnet.ts.net/")
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
            adapterURL: "wss://your-mac.your-tailnet.ts.net/",
            deviceID: "iphone-17-pro",
            deviceSecret: "per-device-secret"
        )
        let client = LogosClient(
            store: SQLiteMessageStore(filename: "LogosTests-\(UUID().uuidString).sqlite3"),
            socketFactory: RecordingWebSocketTaskFactory(socket: socket),
            pairingExchanger: exchanger
        )
        let route = LogosPairingRoute(
            adapterURL: "wss://your-mac.your-tailnet.ts.net/",
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

    func testComposerStopKeepsVoiceModePausedForImmediateRerecord() throws {
        XCTAssertEqual(ComposerModePolicy.modeAfterRecordPillStopped(current: .recording), .paused)
    }

    func testComposerRightPillIsOnlyModeSwitchBetweenKeyboardAndVoice() throws {
        XCTAssertEqual(ComposerModePolicy.modeAfterRightPillTapped(current: .text), .paused)
        XCTAssertEqual(ComposerModePolicy.modeAfterRightPillTapped(current: .paused), .text)
        XCTAssertEqual(ComposerModePolicy.modeAfterRightPillTapped(current: .recording), .text)
    }

    func testComposerPausedRecordPillWaitsForVoiceFinalizationBeforeRestarting() throws {
        XCTAssertFalse(ComposerModePolicy.canStartRecordingFromPausedPill(
            voiceControlsDisabled: false,
            isFinalizingTranscript: true
        ))
        XCTAssertFalse(ComposerModePolicy.canStartRecordingFromPausedPill(
            voiceControlsDisabled: true,
            isFinalizingTranscript: false
        ))
        XCTAssertTrue(ComposerModePolicy.canStartRecordingFromPausedPill(
            voiceControlsDisabled: false,
            isFinalizingTranscript: false
        ))
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

    func testPendingMessageReconciliationKeepsDistinctRepeatedUserText() throws {
        let pending = LogosMessage(
            projectKey: "default",
            sessionID: "pending",
            messageID: "voice-turn-2",
            serverSeq: 0,
            role: "user",
            content: "yes",
            timestamp: 200,
            status: "pending"
        )
        let olderPersisted = LogosMessage(
            projectKey: "default",
            sessionID: "session-1",
            messageID: "voice-turn-1",
            serverSeq: 7,
            role: "user",
            content: "yes",
            timestamp: 123,
            status: "persisted"
        )

        XCTAssertFalse(PendingMessageReconciliation.shouldRemove(pending: pending, whenPersisted: olderPersisted))
    }

    func testPendingMessageReconciliationRemovesNewerSameContentEchoWithoutClientID() throws {
        let pending = LogosMessage(
            projectKey: "default",
            sessionID: "pending",
            messageID: "local-client-id",
            serverSeq: 0,
            role: "user",
            content: "hello Hermes",
            timestamp: 200,
            status: "pending"
        )
        let newerPersistedEcho = LogosMessage(
            projectKey: "default",
            sessionID: "session-1",
            messageID: "server-generated-id",
            serverSeq: 8,
            role: "user",
            content: "hello Hermes",
            timestamp: 201,
            status: "persisted"
        )

        XCTAssertTrue(PendingMessageReconciliation.shouldRemove(pending: pending, whenPersisted: newerPersistedEcho))
    }

    @MainActor
    func testFinalSpeechPendingAppearsForRepeatedTranscriptTextBeforeSocketSendCompletes() async throws {
        let socket = RecordingWebSocketTask()
        let store = SQLiteMessageStore(filename: "LogosTests-\(UUID().uuidString).sqlite3")
        store.upsert(LogosMessage(
            projectKey: "default",
            sessionID: "session-1",
            messageID: "voice-turn-previous",
            serverSeq: 7,
            role: "user",
            content: "yes",
            timestamp: 123,
            status: "persisted"
        ))
        let client = makeSocketBackedClient(socket: socket, store: store)
        let sent = client.sendSpeech(
            text: "yes",
            isFinal: true,
            inputID: "voice-turn-current",
            partialSeq: 2,
            startedAtMilliseconds: 456
        )

        XCTAssertTrue(sent)
        XCTAssertTrue(client.messages.contains { $0.messageID == "voice-turn-current" && $0.status == "pending" })
    }

    @MainActor
    func testSuccessfulConnectionMarksFirstConnectionComplete() throws {
        let socket = RecordingWebSocketTask()
        let client = makeSocketBackedClient(socket: socket, autoConnect: false)

        XCTAssertTrue(client.settings.hasCompletedFirstConnection)
    }

    @MainActor
    func testFinalSpeechPendingAppearsImmediatelyAfterASRFinalBeforeSocketSendCompletes() async throws {
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
        XCTAssertEqual(client.messages.last?.messageID, "voice-turn-queued")
        XCTAssertEqual(client.messages.last?.content, "hello Hermes")
        XCTAssertEqual(client.messages.last?.role, "user")
        XCTAssertEqual(client.messages.last?.status, "pending")

        socket.completeLastSend(error: nil)
        await Task.yield()

        XCTAssertEqual(client.messages.filter { $0.messageID == "voice-turn-queued" }.count, 1)
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
        let messagesRange = try XCTUnwrap(contentViewSource.range(of: "ForEach(threadMessagesBeforeProgress)"))
        let progressRange = try XCTUnwrap(contentViewSource.range(of: "ProgressActivityCard("))
        let afterProgressRange = try XCTUnwrap(contentViewSource.range(of: "ForEach(threadMessagesAfterProgress)"))

        XCTAssertGreaterThan(progressRange.lowerBound, messagesRange.lowerBound)
        XCTAssertGreaterThan(afterProgressRange.lowerBound, progressRange.lowerBound)
        XCTAssertFalse(contentViewSource.contains(".onChange(of: client.progressActivity?.events.count) { _, _ in handleThreadContentChanged() }"))
        XCTAssertFalse(contentViewSource.contains(".onChange(of: client.progressActivity?.updateCount) { _, _ in handleThreadContentChanged() }"))
        XCTAssertFalse(contentViewSource.contains(".onChange(of: client.progressActivity?.isExpanded) { _, _ in handleThreadContentChanged() }"))
        XCTAssertFalse(contentViewSource.contains(".onChange(of: client.progressActivity?.isComplete) { _, _ in handleThreadContentChanged() }"))
        XCTAssertFalse(contentViewSource.contains(".onChange(of: client.runStatus) { _, _ in handleThreadContentChanged() }"))
        XCTAssertTrue(contentViewSource.contains(".onChange(of: threadTimelineSnapshot) { _, _ in handleThreadContentChanged() }"))
        XCTAssertTrue(contentViewSource.contains("threadScrollPosition.scrollTo(id: \"thread-bottom\", anchor: .bottom)"))
        XCTAssertTrue(contentViewSource.contains(".defaultScrollAnchor(.bottom, for: .alignment)"))
        XCTAssertTrue(contentViewSource.contains("ThreadAutoFollowPolicy.isNearBottom"))
        XCTAssertTrue(contentViewSource.contains("Only detach"))
        XCTAssertTrue(contentViewSource.contains("ThreadTimelineSnapshot"))
        XCTAssertTrue(contentViewSource.contains("runStatus: client.runStatus.rawValue"))
        XCTAssertTrue(contentViewSource.contains("threadMessagesBeforeProgress"))
        XCTAssertTrue(contentViewSource.contains("threadMessagesAfterProgress"))
        XCTAssertFalse(contentViewSource.contains("RunControlStrip("))
        XCTAssertFalse(contentViewSource.contains("private struct RunControlStrip"))
        XCTAssertTrue(contentViewSource.contains("SpinningHourglassIcon("))
        XCTAssertTrue(contentViewSource.contains("ConnectionRetryCard("))
        XCTAssertTrue(contentViewSource.contains("TimelineView(.periodic"))
        XCTAssertTrue(contentViewSource.contains("elapsedTimeText"))
        XCTAssertFalse(contentViewSource.contains("Starts after first connection"))
        XCTAssertTrue(contentViewSource.contains("@Environment(\\.accessibilityReduceMotion)"))
        XCTAssertTrue(contentViewSource.contains("Text(progressTitleText)"))
        XCTAssertTrue(contentViewSource.contains("case .complete: return \"Complete\""))
        XCTAssertTrue(contentViewSource.contains("case .failed: return \"Failed\""))
        XCTAssertTrue(contentViewSource.contains("case .stopped: return \"Stopped\""))
        XCTAssertTrue(contentViewSource.contains("Text(\"Duration\")"))
        XCTAssertTrue(contentViewSource.contains("retryProgressActivity"))
        XCTAssertTrue(contentViewSource.contains("hasAdapterUpdates"))
        XCTAssertTrue(contentViewSource.contains("adapterUpdateCount > 0"))
        XCTAssertTrue(contentViewSource.contains("accessibilityReduceMotion ? AnyTransition.opacity"))
        XCTAssertTrue(contentViewSource.contains("stopRunButton"))
        XCTAssertTrue(contentViewSource.contains("retryRunButton"))
        XCTAssertFalse(contentViewSource.contains("action: { _, newValue in\n                handleThreadBottomProximityChanged(newValue)"))
        XCTAssertFalse(contentViewSource.contains("Text(event.kind)"))
        XCTAssertFalse(contentViewSource.contains(".lineLimit(4)"))
        XCTAssertFalse(contentViewSource.contains("Text(latestEvent.text)"))
        XCTAssertTrue(contentViewSource.contains("event.count > 1"))
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
    func testNonFinalProgressPersistsInProgressCardOnlyAndNeverAutoplays() throws {
        let socket = RecordingWebSocketTask()
        let client = makeSocketBackedClient(socket: socket)
        let baselineCount = socket.sentMessages.count

        client.handleFrameString(#"""
        {"type":"state_update","request_id":"req-progress","project_key":"default","session_id":"session-progress","server_seq":70,"payload":{"op":"message_updated","message":{"project_key":"default","session_id":"session-progress","message_id":"assistant-progress-1","server_seq":70,"role":"assistant","content":"🔧 terminal…","timestamp":123.0,"metadata":{"finalized":false,"source":"tool_progress","progress_kind":"terminal"}}}}
        """#)

        XCTAssertTrue(client.messages.isEmpty)
        XCTAssertEqual(client.progressActivity?.requestID, "req-progress")
        XCTAssertEqual(client.progressActivity?.updateCount, 1)
        XCTAssertEqual(client.progressActivity?.events.count, 1)
        XCTAssertEqual(client.progressActivity?.events.first?.text, "🔧 terminal…")
        XCTAssertEqual(client.runStatus, .running)

        client.handleFrameString(#"""
        {"type":"tool_progress","request_id":"req-progress","project_key":"default","session_id":"session-progress","server_seq":71,"payload":{"kind":"tool_progress","progress_kind":"terminal","message_id":"assistant-progress-1","text":"✅ terminal done","transient":false,"finalized":false,"message":{"project_key":"default","session_id":"session-progress","message_id":"assistant-progress-1","server_seq":71,"role":"assistant","content":"✅ terminal done","timestamp":124.0,"metadata":{"finalized":false,"source":"tool_progress","progress_kind":"terminal","transient":false}}}}
        """#)

        XCTAssertTrue(client.messages.isEmpty)
        XCTAssertEqual(client.progressActivity?.updateCount, 2)
        XCTAssertEqual(client.progressActivity?.events.count, 1)
        XCTAssertEqual(client.progressActivity?.events.first?.text, "✅ terminal done")

        client.handleFrameString(#"""
        {"type":"tool_progress","request_id":"req-progress","project_key":"default","session_id":"session-progress","server_seq":72,"payload":{"kind":"tool_progress","progress_kind":"terminal","message_id":"assistant-progress-2","text":"✅ terminal done","transient":false,"finalized":false,"message":{"project_key":"default","session_id":"session-progress","message_id":"assistant-progress-2","server_seq":72,"role":"assistant","content":"✅ terminal done","timestamp":125.0,"metadata":{"finalized":false,"source":"tool_progress","progress_kind":"terminal","transient":false}}}}
        """#)

        XCTAssertEqual(client.progressActivity?.updateCount, 3)
        XCTAssertEqual(client.progressActivity?.events.count, 1)
        XCTAssertEqual(client.progressActivity?.events.first?.count, 2)
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
    func testGatewayStatusProgressCanBecomeLocalStaleNoticeWithoutAutoplay() async throws {
        let socket = RecordingWebSocketTask()
        let client = makeSocketBackedClient(socket: socket, staleTimeoutInterval: 0.05)
        let baselineCount = socket.sentMessages.count

        client.handleFrameString(#"""
        {"type":"tool_progress","request_id":"req-gateway-status","project_key":"default","session_id":"session-gateway-status","payload":{"kind":"gateway_status","progress_kind":"gateway_status","text":"⏳ Still working... (3 min elapsed — iteration 1/1000, API call #1 completed)"}}
        """#)
        try await Task.sleep(nanoseconds: 90_000_000)

        XCTAssertEqual(client.runStatus, .running)
        XCTAssertEqual(client.progressActivity?.timedOut, true)
        XCTAssertEqual(client.messages.filter { $0.status == "local_notice" }.count, 1)
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

    func testRetryStatusMessageIsClassifiedAsGatewayProgress() throws {
        let retry = try XCTUnwrap(LogosMessage.from(dictionary: [
            "project_key": "default",
            "session_id": "session-retry-status",
            "message_id": "assistant-retry-status",
            "server_seq": 74,
            "role": "assistant",
            "content": "⏳ Retrying in 2.6s (attempt 1/3)...",
            "timestamp": 123.0
        ]))

        XCTAssertTrue(retry.isProgressUpdate)
        XCTAssertTrue(retry.isGatewayStatusUpdate)
        XCTAssertEqual(retry.progressEventKind, "gateway_status")
    }

    func testProviderAbortStatusMessageIsClassifiedAsGatewayProgress() throws {
        let providerStatus = try XCTUnwrap(LogosMessage.from(dictionary: [
            "project_key": "default",
            "session_id": "session-provider-status",
            "message_id": "assistant-provider-status",
            "server_seq": 77,
            "role": "assistant",
            "content": "⚠️ No response from provider for 300s (non-streaming, model: gpt-5.5). Aborting call.",
            "timestamp": 125.0
        ]))

        XCTAssertTrue(providerStatus.isProgressUpdate)
        XCTAssertTrue(providerStatus.isGatewayStatusUpdate)
        XCTAssertEqual(providerStatus.progressEventKind, "gateway_status")
    }

    @MainActor
    func testRetryStatusStateUpdateAggregatesOutsideMessagesAndNeverAutoplays() throws {
        let socket = RecordingWebSocketTask()
        let client = makeSocketBackedClient(socket: socket)
        let baselineCount = socket.sentMessages.count

        client.handleFrameString(#"""
        {"type":"state_update","request_id":"req-retry-status","project_key":"default","session_id":"session-retry-status","server_seq":75,"payload":{"op":"message_appended","message":{"project_key":"default","session_id":"session-retry-status","message_id":"assistant-retry-status","server_seq":75,"role":"assistant","content":"⏳ Retrying in 2.6s (attempt 1/3)...","timestamp":123.0}}}
        """#)

        XCTAssertTrue(client.messages.isEmpty)
        XCTAssertEqual(client.progressActivity?.requestID, "req-retry-status")
        XCTAssertEqual(client.progressActivity?.events.count, 1)
        XCTAssertEqual(client.progressActivity?.events.first?.kind, "gateway_status")
        XCTAssertEqual(client.progressActivity?.events.first?.text, "⏳ Retrying in 2.6s (attempt 1/3)...")
        let newFrames = try socket.sentMessages.dropFirst(baselineCount).map { try frameRoot(from: $0) }
        XCTAssertTrue(newFrames.filter { $0["type"] as? String == "playback_audio" }.isEmpty)
    }

    @MainActor
    func testProviderAbortStateUpdateStaysInProgressAndAllowsLaterFinal() throws {
        let socket = RecordingWebSocketTask()
        let client = makeSocketBackedClient(socket: socket)
        XCTAssertTrue(client.sendText("trigger provider abort status"))
        let textFrame = try XCTUnwrap(try socket.sentMessages.map { try frameRoot(from: $0) }.last { $0["type"] as? String == "text_input" })
        let requestID = try XCTUnwrap(textFrame["request_id"] as? String)
        let providerStatusText = "⚠️ No response from provider for 300s (non-streaming, model: gpt-5.5). Aborting call."
        let baselineCount = socket.sentMessages.count

        client.handleFrameString("""
        {"type":"state_update","request_id":"\(requestID)","project_key":"default","session_id":"project:default","server_seq":78,"payload":{"op":"message_appended","message":{"project_key":"default","session_id":"project:default","message_id":"assistant-provider-status","server_seq":78,"role":"assistant","content":"\(providerStatusText)","timestamp":126.0}}}
        """)

        XCTAssertFalse(client.messages.contains { $0.messageID == "assistant-provider-status" })
        XCTAssertEqual(client.progressActivity?.requestID, requestID)
        XCTAssertEqual(client.progressActivity?.isComplete, false)
        XCTAssertEqual(client.progressActivity?.events.last?.kind, "gateway_status")
        XCTAssertEqual(client.progressActivity?.events.last?.text, providerStatusText)
        XCTAssertEqual(client.runStatus, .running)
        let providerFrames = try socket.sentMessages.dropFirst(baselineCount).map { try frameRoot(from: $0) }
        XCTAssertTrue(providerFrames.filter { $0["type"] as? String == "playback_audio" }.isEmpty)

        let finalBaselineCount = socket.sentMessages.count
        client.handleFrameString("""
        {"type":"state_update","request_id":"\(requestID)","project_key":"default","session_id":"project:default","server_seq":79,"payload":{"op":"message_appended","message":{"project_key":"default","session_id":"project:default","message_id":"assistant-provider-final","server_seq":79,"role":"assistant","content":"Final answer after provider retry.","timestamp":127.0,"metadata":{"finalized":true,"source":"hermes"}}}}
        """)

        XCTAssertEqual(client.progressActivity?.requestID, requestID)
        XCTAssertEqual(client.progressActivity?.isComplete, true)
        XCTAssertEqual(client.progressActivity?.completedFinalMessageID, "project:default:assistant-provider-final")
        XCTAssertEqual(client.runStatus, .idle)
        XCTAssertTrue(client.messages.contains { $0.messageID == "assistant-provider-final" })
        let finalFrames = try socket.sentMessages.dropFirst(finalBaselineCount).map { try frameRoot(from: $0) }
        let playbackFrames = finalFrames.filter { $0["type"] as? String == "playback_audio" }
        XCTAssertEqual(playbackFrames.count, 1)
        if playbackFrames.count == 1 {
            XCTAssertEqual((playbackFrames[0]["payload"] as? [String: Any])?["message_id"] as? String, "assistant-provider-final")
        }
    }

    @MainActor
    func testRetryStatusMessagesBatchAggregatesForActivePromptAndNeverAutoplays() throws {
        let socket = RecordingWebSocketTask()
        let client = makeSocketBackedClient(socket: socket)
        XCTAssertTrue(client.sendText("trigger retry status"))
        let textFrame = try XCTUnwrap(try socket.sentMessages.map { try frameRoot(from: $0) }.last { $0["type"] as? String == "text_input" })
        let requestID = try XCTUnwrap(textFrame["request_id"] as? String)
        let baselineCount = socket.sentMessages.count

        client.handleFrameString("""
        {"type":"messages_batch","request_id":"\(requestID)","project_key":"default","session_id":"project:default","payload":{"messages":[{"project_key":"default","session_id":"project:default","message_id":"assistant-retry-batch","server_seq":76,"role":"assistant","content":"⏳ Retrying in 2.6s (attempt 1/3)...","timestamp":124.0}]}}
        """)

        XCTAssertFalse(client.messages.contains { $0.messageID == "assistant-retry-batch" })
        XCTAssertEqual(client.progressActivity?.requestID, requestID)
        XCTAssertEqual(client.progressActivity?.events.last?.kind, "gateway_status")
        XCTAssertEqual(client.progressActivity?.events.last?.text, "⏳ Retrying in 2.6s (attempt 1/3)...")
        let newFrames = try socket.sentMessages.dropFirst(baselineCount).map { try frameRoot(from: $0) }
        XCTAssertTrue(newFrames.filter { $0["type"] as? String == "playback_audio" }.isEmpty)
    }

    @MainActor
    func testProviderAbortMessagesBatchAggregatesForActivePromptAndNeverAutoplays() throws {
        let socket = RecordingWebSocketTask()
        let client = makeSocketBackedClient(socket: socket)
        XCTAssertTrue(client.sendText("trigger provider abort batch status"))
        let textFrame = try XCTUnwrap(try socket.sentMessages.map { try frameRoot(from: $0) }.last { $0["type"] as? String == "text_input" })
        let requestID = try XCTUnwrap(textFrame["request_id"] as? String)
        let providerStatusText = "⚠️ No response from provider for 300s (non-streaming, model: gpt-5.5). Aborting call."
        let baselineCount = socket.sentMessages.count

        client.handleFrameString("""
        {"type":"messages_batch","request_id":"\(requestID)","project_key":"default","session_id":"project:default","payload":{"messages":[{"project_key":"default","session_id":"project:default","message_id":"assistant-provider-batch","server_seq":80,"role":"assistant","content":"\(providerStatusText)","timestamp":128.0}]}}
        """)

        XCTAssertFalse(client.messages.contains { $0.messageID == "assistant-provider-batch" })
        XCTAssertEqual(client.progressActivity?.requestID, requestID)
        XCTAssertEqual(client.progressActivity?.isComplete, false)
        XCTAssertEqual(client.progressActivity?.events.last?.kind, "gateway_status")
        XCTAssertEqual(client.progressActivity?.events.last?.text, providerStatusText)
        XCTAssertEqual(client.runStatus, .running)
        let newFrames = try socket.sentMessages.dropFirst(baselineCount).map { try frameRoot(from: $0) }
        XCTAssertTrue(newFrames.filter { $0["type"] as? String == "playback_audio" }.isEmpty)
    }

    @MainActor
    func testActiveRunAssistantStatusWithoutFinalMetadataStaysInProgressUntilExplicitFinal() throws {
        let socket = RecordingWebSocketTask()
        let client = makeSocketBackedClient(socket: socket)
        XCTAssertTrue(client.sendText("trigger nonterminal status"))
        let textFrame = try XCTUnwrap(try socket.sentMessages.map { try frameRoot(from: $0) }.last { $0["type"] as? String == "text_input" })
        let requestID = try XCTUnwrap(textFrame["request_id"] as? String)
        let statusText = "Preflight compression: compacting context before continuing."
        let baselineCount = socket.sentMessages.count

        client.handleFrameString("""
        {"type":"state_update","request_id":"\(requestID)","project_key":"default","session_id":"project:default","server_seq":89,"payload":{"op":"message_appended","message":{"project_key":"default","session_id":"project:default","message_id":"assistant-preflight-status","server_seq":89,"role":"assistant","content":"\(statusText)","timestamp":129.0}}}
        """)

        XCTAssertFalse(client.messages.contains { $0.messageID == "assistant-preflight-status" })
        XCTAssertEqual(client.progressActivity?.requestID, requestID)
        XCTAssertEqual(client.progressActivity?.isComplete, false)
        XCTAssertEqual(client.progressActivity?.events.last?.text, statusText)
        XCTAssertEqual(client.runStatus, .running)
        let statusFrames = try socket.sentMessages.dropFirst(baselineCount).map { try frameRoot(from: $0) }
        XCTAssertTrue(statusFrames.filter { $0["type"] as? String == "playback_audio" }.isEmpty)

        let finalBaselineCount = socket.sentMessages.count
        client.handleFrameString("""
        {"type":"state_update","request_id":"\(requestID)","project_key":"default","session_id":"project:default","server_seq":90,"payload":{"op":"message_appended","message":{"project_key":"default","session_id":"project:default","message_id":"assistant-explicit-final","server_seq":90,"role":"assistant","content":"Explicit final after status.","timestamp":130.0,"metadata":{"finalized":true,"source":"hermes"}}}}
        """)

        XCTAssertEqual(client.progressActivity?.isComplete, true)
        XCTAssertEqual(client.progressActivity?.completedFinalMessageID, "project:default:assistant-explicit-final")
        XCTAssertTrue(client.messages.contains { $0.messageID == "assistant-explicit-final" })
        XCTAssertEqual(client.runStatus, .idle)
        let finalFrames = try socket.sentMessages.dropFirst(finalBaselineCount).map { try frameRoot(from: $0) }
        XCTAssertEqual(finalFrames.filter { $0["type"] as? String == "playback_audio" }.count, 1)
    }

    @MainActor
    func testTextSendCreatesProgressActivityBeforeFirstAdapterUpdate() throws {
        let socket = RecordingWebSocketTask()
        let client = makeSocketBackedClient(socket: socket)

        XCTAssertTrue(client.sendText("start progress immediately"))
        let textFrame = try XCTUnwrap(try socket.sentMessages.map { try frameRoot(from: $0) }.last { $0["type"] as? String == "text_input" })
        let requestID = try XCTUnwrap(textFrame["request_id"] as? String)

        XCTAssertEqual(client.progressActivity?.requestID, requestID)
        XCTAssertEqual(client.progressActivity?.projectKey, "default")
        XCTAssertEqual(client.progressActivity?.events.count, 0)
        XCTAssertEqual(client.progressActivity?.updateCount, 0)
        XCTAssertEqual(client.progressActivity?.adapterUpdateCount, 0)
        XCTAssertEqual(client.progressActivity?.isComplete, false)
        XCTAssertNil(client.progressActivity?.finalStatus)
        XCTAssertEqual(client.progressActivity?.retryRequest, .text("start progress immediately"))
        XCTAssertNotNil(client.progressActivity?.startedAt)
        XCTAssertNil(client.progressActivity?.completedAt)

        client.handleFrameString("""
        {"type":"tool_progress","request_id":"\(requestID)","project_key":"default","session_id":"project:default","payload":{"kind":"terminal","text":"Adapter update arrived"}}
        """)
        XCTAssertEqual(client.progressActivity?.updateCount, 1)
        XCTAssertEqual(client.progressActivity?.adapterUpdateCount, 1)
    }

    @MainActor
    func testProgressActivityCompletionFreezesElapsedTime() throws {
        let socket = RecordingWebSocketTask()
        let client = makeSocketBackedClient(socket: socket)

        XCTAssertTrue(client.sendText("measure elapsed progress"))
        let textFrame = try XCTUnwrap(try socket.sentMessages.map { try frameRoot(from: $0) }.last { $0["type"] as? String == "text_input" })
        let requestID = try XCTUnwrap(textFrame["request_id"] as? String)
        let startedAt = try XCTUnwrap(client.progressActivity?.startedAt)
        XCTAssertNil(client.progressActivity?.completedAt)

        client.handleFrameString("""
        {"type":"state_update","request_id":"\(requestID)","project_key":"default","session_id":"project:default","server_seq":91,"payload":{"op":"message_appended","message":{"project_key":"default","session_id":"project:default","message_id":"assistant-elapsed-final","server_seq":91,"role":"assistant","content":"Done measuring.","timestamp":131.0,"metadata":{"finalized":true,"source":"hermes"}}}}
        """)

        let completedAt = try XCTUnwrap(client.progressActivity?.completedAt)
        XCTAssertGreaterThanOrEqual(completedAt, startedAt)
        XCTAssertEqual(client.progressActivity?.isComplete, true)
        XCTAssertEqual(client.progressActivity?.finalStatus, .complete)
        XCTAssertNil(client.progressActivity?.retryRequest)
    }

    @MainActor
    func testRunStatusErrorMarksProgressFailedAndTextRetryResendsOriginalPrompt() throws {
        let socket = RecordingWebSocketTask()
        let client = makeSocketBackedClient(socket: socket)

        XCTAssertTrue(client.sendText("retry this exact text"))
        let textFrame = try XCTUnwrap(try socket.sentMessages.map { try frameRoot(from: $0) }.last { $0["type"] as? String == "text_input" })
        let requestID = try XCTUnwrap(textFrame["request_id"] as? String)

        client.handleFrameString("""
        {"type":"run_status","request_id":"\(requestID)","project_key":"default","payload":{"status":"error","message":"Hermes failed the request"}}
        """)

        XCTAssertEqual(client.runStatus, .idle)
        XCTAssertEqual(client.progressActivity?.isComplete, true)
        XCTAssertEqual(client.progressActivity?.finalStatus, .failed)
        XCTAssertEqual(client.progressActivity?.failureMessage, "Hermes failed the request")
        XCTAssertEqual(client.progressActivity?.retryRequest, .text("retry this exact text"))

        let baselineCount = socket.sentMessages.count
        XCTAssertTrue(client.retryProgressActivity())

        let retryFrame = try XCTUnwrap(try socket.sentMessages.dropFirst(baselineCount).map { try frameRoot(from: $0) }.last { $0["type"] as? String == "text_input" })
        let retryPayload = try XCTUnwrap(retryFrame["payload"] as? [String: Any])
        XCTAssertEqual(retryPayload["text"] as? String, "retry this exact text")
        XCTAssertNotEqual(retryFrame["request_id"] as? String, requestID)
        XCTAssertEqual(client.progressActivity?.finalStatus, nil)
    }

    @MainActor
    func testVoiceRetryResendsOriginalTranscriptAsFreshFinalSpeech() throws {
        let socket = RecordingWebSocketTask()
        let client = makeSocketBackedClient(socket: socket)

        XCTAssertTrue(client.sendSpeech(
            text: "retry this voice transcript",
            isFinal: true,
            inputID: "voice-original-failed",
            partialSeq: 4,
            startedAtMilliseconds: 123
        ))
        let speechFrame = try XCTUnwrap(try socket.sentMessages.map { try frameRoot(from: $0) }.last { $0["type"] as? String == "speech" })
        let requestID = try XCTUnwrap(speechFrame["request_id"] as? String)

        client.handleFrameString("""
        {"type":"run_status","request_id":"\(requestID)","project_key":"default","payload":{"status":"error","message":"Voice request failed"}}
        """)

        XCTAssertEqual(client.progressActivity?.finalStatus, .failed)
        XCTAssertEqual(client.progressActivity?.retryRequest, .speech(text: "retry this voice transcript"))

        let baselineCount = socket.sentMessages.count
        XCTAssertTrue(client.retryProgressActivity())

        let retryFrame = try XCTUnwrap(try socket.sentMessages.dropFirst(baselineCount).map { try frameRoot(from: $0) }.last { $0["type"] as? String == "speech" })
        let retryPayload = try XCTUnwrap(retryFrame["payload"] as? [String: Any])
        XCTAssertEqual(retryPayload["text"] as? String, "retry this voice transcript")
        XCTAssertEqual(retryPayload["is_final"] as? Bool, true)
        XCTAssertEqual(retryPayload["partial_seq"] as? Int, 0)
        XCTAssertNotEqual(retryPayload["client_msg_id"] as? String, "voice-original-failed")
    }

    @MainActor
    func testFinalSpeechSendCreatesProgressActivityBeforeFirstAdapterUpdate() throws {
        let socket = RecordingWebSocketTask()
        let client = makeSocketBackedClient(socket: socket)

        XCTAssertTrue(client.sendSpeech(
            text: "voice request starts progress",
            isFinal: true,
            inputID: "voice-progress-start",
            partialSeq: 1,
            startedAtMilliseconds: 123
        ))
        let speechFrame = try XCTUnwrap(try socket.sentMessages.map { try frameRoot(from: $0) }.last { $0["type"] as? String == "speech" })
        let requestID = try XCTUnwrap(speechFrame["request_id"] as? String)

        XCTAssertEqual(client.progressActivity?.requestID, requestID)
        XCTAssertEqual(client.progressActivity?.events.count, 0)
        XCTAssertEqual(client.progressActivity?.updateCount, 0)
        XCTAssertEqual(client.progressActivity?.adapterUpdateCount, 0)
        XCTAssertEqual(client.progressActivity?.isComplete, false)
        XCTAssertNil(client.progressActivity?.finalStatus)
        XCTAssertEqual(client.progressActivity?.retryRequest, .speech(text: "voice request starts progress"))
        XCTAssertNotNil(client.progressActivity?.startedAt)
        XCTAssertNil(client.progressActivity?.completedAt)
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
    func testFinalMessageStartingWithGatewayWordsRemainsVisible() throws {
        let store = SQLiteMessageStore(filename: "LogosTests-\(UUID().uuidString).sqlite3")
        store.upsert(LogosMessage(
            projectKey: "default",
            sessionID: "session-final-still-working",
            messageID: "assistant-final-still-working",
            serverSeq: 73,
            role: "assistant",
            content: "Still working through the details, but here is the final answer.",
            timestamp: 123.0,
            status: "persisted",
            isFinal: true,
            hasFinalizedMetadata: true,
            metadataSource: "hermes"
        ))
        let client = LogosClient(store: store)

        XCTAssertEqual(client.messages.map(\.messageID), ["assistant-final-still-working"])
        XCTAssertTrue(client.messages.first?.isProgressUpdate == false)
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
    func testMessagesBatchKeepsDurableProgressOutOfConversationBubblesWhenFinalResponseArrivesInSameBatch() throws {
        let socket = RecordingWebSocketTask()
        let client = makeSocketBackedClient(socket: socket)
        let baselineCount = socket.sentMessages.count

        client.handleFrameString(#"""
        {"type":"messages_batch","request_id":"req-batch-durable-final","project_key":"default","session_id":"session-batch-durable-final","payload":{"messages":[{"project_key":"default","session_id":"session-batch-durable-final","message_id":"progress-batch","server_seq":81,"role":"assistant","content":"🔧 terminal: \"pytest\"","timestamp":123.0,"metadata":{"finalized":false,"source":"tool_progress","progress_kind":"terminal","transient":false}},{"project_key":"default","session_id":"session-batch-durable-final","message_id":"assistant-batch-final","server_seq":82,"role":"assistant","content":"Final response after progress.","timestamp":124.0,"metadata":{"finalized":true,"source":"hermes"}}]}}
        """#)

        XCTAssertNil(client.progressActivity)
        XCTAssertEqual(client.runStatus, .idle)
        XCTAssertEqual(client.messages.map(\.messageID), ["assistant-batch-final"])
        let newFrames = try socket.sentMessages.dropFirst(baselineCount).map { try frameRoot(from: $0) }
        XCTAssertTrue(newFrames.filter { $0["type"] as? String == "playback_audio" }.isEmpty)
    }

    @MainActor
    func testMessagesBatchFinalCompletesExistingProgressActivity() throws {
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

        XCTAssertEqual(client.progressActivity?.requestID, "req-final-only-replay")
        XCTAssertEqual(client.progressActivity?.isComplete, true)
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
    func testUnscopedMessagesBatchFinalAfterNewTextBeforeProgressDoesNotIdlePrompt() throws {
        let socket = RecordingWebSocketTask()
        let client = makeSocketBackedClient(socket: socket)
        XCTAssertTrue(client.sendText("new request before unscoped batch final"))
        let textRoot = try frameRoot(from: try XCTUnwrap(socket.sentMessages.last))
        let newRequestID = try XCTUnwrap(textRoot["request_id"] as? String)
        let baselineCount = socket.sentMessages.count

        client.handleFrameString(#"""
        {"type":"messages_batch","project_key":"default","session_id":"project:default","payload":{"messages":[{"project_key":"default","session_id":"project:default","message_id":"assistant-old-unscoped-batch-final","server_seq":86,"role":"assistant","content":"Old unscoped batch final replay.","timestamp":128.0,"metadata":{"finalized":true,"source":"hermes"}}]}}
        """#)

        let newFrames = try socket.sentMessages.dropFirst(baselineCount).map { try frameRoot(from: $0) }
        XCTAssertTrue(newFrames.filter { $0["type"] as? String == "playback_audio" }.isEmpty)
        XCTAssertEqual(client.runStatus, .running)
        XCTAssertEqual(client.progressActivity?.requestID, newRequestID)
        XCTAssertEqual(client.progressActivity?.isComplete, false)
        XCTAssertTrue(client.messages.contains { $0.content == "new request before unscoped batch final" && $0.status == "pending" })
    }

    @MainActor
    func testMessagesBatchFinalMetadataRequestIDCompletesProgressWithoutFrameRequestID() throws {
        let socket = RecordingWebSocketTask()
        let client = makeSocketBackedClient(socket: socket)

        client.handleFrameString(#"""
        {"type":"tool_progress","request_id":"req-batch-metadata-final","project_key":"default","session_id":"session-batch-metadata-final","payload":{"kind":"terminal","text":"Running before metadata final"}}
        """#)

        client.handleFrameString(#"""
        {"type":"messages_batch","project_key":"default","session_id":"session-batch-metadata-final","payload":{"messages":[{"project_key":"default","session_id":"session-batch-metadata-final","message_id":"assistant-batch-metadata-final","server_seq":87,"role":"assistant","content":"Final with metadata request id.","timestamp":129.0,"metadata":{"finalized":true,"source":"hermes","request_id":"req-batch-metadata-final"}}]}}
        """#)

        XCTAssertEqual(client.progressActivity?.isComplete, true)
        XCTAssertEqual(client.progressActivity?.completedFinalMessageID, "session-batch-metadata-final:assistant-batch-metadata-final")
        XCTAssertEqual(client.runStatus, .idle)
    }

    @MainActor
    func testStateUpdateFinalMetadataRequestIDCompletesProgressWithoutFrameRequestID() throws {
        let socket = RecordingWebSocketTask()
        let client = makeSocketBackedClient(socket: socket)

        client.handleFrameString(#"""
        {"type":"tool_progress","request_id":"req-state-metadata-final","project_key":"default","session_id":"session-state-metadata-final","payload":{"kind":"terminal","text":"Running before metadata state final"}}
        """#)

        client.handleFrameString(#"""
        {"type":"state_update","project_key":"default","session_id":"session-state-metadata-final","server_seq":88,"payload":{"op":"message_appended","message":{"project_key":"default","session_id":"session-state-metadata-final","message_id":"assistant-state-metadata-final","server_seq":88,"role":"assistant","content":"State final with metadata request id.","timestamp":130.0,"metadata":{"finalized":true,"source":"hermes","request_id":"req-state-metadata-final"}}}}
        """#)

        XCTAssertEqual(client.progressActivity?.isComplete, true)
        XCTAssertEqual(client.progressActivity?.completedFinalMessageID, "session-state-metadata-final:assistant-state-metadata-final")
        XCTAssertEqual(client.runStatus, .idle)
    }

    @MainActor
    func testFinalizedMessageUpdatedKeepsProgressCardAndAutoplaysFinalAutoOnce() throws {
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

        XCTAssertEqual(client.progressActivity?.requestID, "req-finalize")
        XCTAssertEqual(client.progressActivity?.isComplete, true)
        XCTAssertEqual(client.progressActivity?.completedFinalMessageID, "session-finalize:assistant-finalize-1")
        XCTAssertEqual(client.progressActivity?.events.count, 1)
        XCTAssertEqual(client.runStatus, .idle)
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
        {"type":"state_update","project_key":"default","session_id":"session-finalize","server_seq":82,"payload":{"op":"message_appended","message":{"project_key":"default","session_id":"session-finalize","message_id":"assistant-later-unrelated","server_seq":82,"role":"assistant","content":"Later unrelated assistant message.","timestamp":125.0,"metadata":{"finalized":true,"source":"hermes"}}}}
        """#)
        XCTAssertEqual(client.progressActivity?.completedFinalMessageID, "session-finalize:assistant-finalize-1")

        client.handleFrameString(#"""
        {"type":"state_update","request_id":"req-finalize","project_key":"default","session_id":"session-finalize","server_seq":83,"payload":{"op":"message_appended","message":{"project_key":"default","session_id":"session-finalize","message_id":"assistant-second-same-request","server_seq":83,"role":"assistant","content":"A later same-request final should not move progress.","timestamp":126.0,"metadata":{"finalized":true,"source":"hermes"}}}}
        """#)
        XCTAssertEqual(client.progressActivity?.completedFinalMessageID, "session-finalize:assistant-finalize-1")
        let framesAfterLaterSameRequest = try socket.sentMessages.dropFirst(baselineCount).map { try frameRoot(from: $0) }
        XCTAssertEqual(framesAfterLaterSameRequest.filter { $0["type"] as? String == "playback_audio" }.count, 1)

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
        let client = makeSocketBackedClient(socket: socket, staleTimeoutInterval: 0.05)
        let baselineCount = socket.sentMessages.count

        client.handleFrameString(#"""
        {"type":"tool_progress","request_id":"req-timeout","project_key":"default","session_id":"session-timeout","payload":{"kind":"terminal","text":"Still running"}}
        """#)
        try await Task.sleep(nanoseconds: 90_000_000)

        XCTAssertEqual(client.progressActivity?.timedOut, true)
        XCTAssertNotEqual(client.runStatus, .error)
        XCTAssertEqual(client.messages.filter { $0.status == "local_notice" }.count, 1)
        var newFrames = try socket.sentMessages.dropFirst(baselineCount).map { try frameRoot(from: $0) }
        var playbackFrames = newFrames.filter { $0["type"] as? String == "playback_audio" }
        XCTAssertTrue(playbackFrames.isEmpty)

        try await Task.sleep(nanoseconds: 90_000_000)
        newFrames = try socket.sentMessages.dropFirst(baselineCount).map { try frameRoot(from: $0) }
        playbackFrames = newFrames.filter { $0["type"] as? String == "playback_audio" }
        XCTAssertTrue(playbackFrames.isEmpty)

        let socket2 = RecordingWebSocketTask()
        let client2 = makeSocketBackedClient(socket: socket2, staleTimeoutInterval: 0.05)
        let baselineCount2 = socket2.sentMessages.count
        client2.handleFrameString(#"""
        {"type":"tool_progress","request_id":"req-cancel-timeout","project_key":"default","session_id":"session-cancel-timeout","payload":{"kind":"terminal","text":"Almost done"}}
        """#)
        client2.handleFrameString(#"""
        {"type":"state_update","request_id":"req-cancel-timeout","project_key":"default","session_id":"session-cancel-timeout","server_seq":90,"payload":{"op":"message_updated","message":{"project_key":"default","session_id":"session-cancel-timeout","message_id":"assistant-cancel-timeout","server_seq":90,"role":"assistant","content":"Finished before timeout.","timestamp":125.0,"metadata":{"finalized":true}}}}
        """#)
        try await Task.sleep(nanoseconds: 90_000_000)

        XCTAssertEqual(client2.progressActivity?.requestID, "req-cancel-timeout")
        XCTAssertEqual(client2.progressActivity?.isComplete, true)
        XCTAssertEqual(client2.progressActivity?.timedOut, false)
        XCTAssertTrue(client2.messages.filter { $0.status == "local_notice" }.isEmpty)
        let finalFrames = try socket2.sentMessages.dropFirst(baselineCount2).map { try frameRoot(from: $0) }
        let finalPlaybackFrames = finalFrames.filter { $0["type"] as? String == "playback_audio" }
        XCTAssertEqual(finalPlaybackFrames.count, 1)
        let payload = try XCTUnwrap(finalPlaybackFrames.first?["payload"] as? [String: Any])
        XCTAssertEqual(payload["mode"] as? String, "final_auto")
    }

    @MainActor
    func testServerClientConfigOverridesStaleTimeoutAndPromptSilenceAddsLocalNotice() async throws {
        let socket = RecordingWebSocketTask()
        let client = makeSocketBackedClient(socket: socket, staleTimeoutInterval: 30)

        client.handleFrameString(#"""
        {"type":"hello","request_id":"hello-config","payload":{"client_config":{"stale_timeout_seconds":0.05}}}
        """#)
        let baselineCount = socket.sentMessages.count
        XCTAssertTrue(client.sendText("Do something slow."))
        let sentCount = socket.sentMessages.count

        try await Task.sleep(nanoseconds: 90_000_000)

        XCTAssertNotEqual(client.runStatus, .error)
        XCTAssertEqual(client.messages.filter { $0.status == "local_notice" }.count, 1)
        let newFrames = try socket.sentMessages.dropFirst(baselineCount).map { try frameRoot(from: $0) }
        XCTAssertEqual(newFrames.filter { $0["type"] as? String == "text_input" }.count, 1)
        XCTAssertTrue(newFrames.filter { $0["type"] as? String == "playback_audio" }.isEmpty)
        let framesAfterSend = try socket.sentMessages.dropFirst(sentCount).map { try frameRoot(from: $0) }
        XCTAssertTrue(framesAfterSend.filter { $0["type"] as? String == "text_input" }.isEmpty)
    }

    @MainActor
    func testRunStatusKeepaliveResetsStaleNoticeTimer() async throws {
        let socket = RecordingWebSocketTask()
        let client = makeSocketBackedClient(socket: socket, staleTimeoutInterval: 0.08)
        XCTAssertTrue(client.sendText("Stay alive while working."))
        let textFrame = try XCTUnwrap(try socket.sentMessages.map { try frameRoot(from: $0) }.last { $0["type"] as? String == "text_input" })
        let requestID = try XCTUnwrap(textFrame["request_id"] as? String)

        try await Task.sleep(nanoseconds: 40_000_000)
        client.handleFrameString("""
        {"type":"run_status","request_id":"\(requestID)","project_key":"default","session_id":"project:default","payload":{"status":"running","keepalive":true,"source":"typing"}}
        """)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(client.messages.filter { $0.status == "local_notice" }.isEmpty)

        try await Task.sleep(nanoseconds: 60_000_000)
        XCTAssertEqual(client.messages.filter { $0.status == "local_notice" }.count, 1)
        XCTAssertNotEqual(client.runStatus, .error)
    }

    @MainActor
    func testMismatchedRunStatusKeepaliveDoesNotResetActiveStaleTimer() async throws {
        let socket = RecordingWebSocketTask()
        let client = makeSocketBackedClient(socket: socket, staleTimeoutInterval: 0.08)
        XCTAssertTrue(client.sendText("Active run should not be reset by old keepalive."))

        try await Task.sleep(nanoseconds: 40_000_000)
        client.handleFrameString(#"""
        {"type":"run_status","request_id":"req-old-keepalive","project_key":"default","session_id":"project:default","payload":{"status":"running","keepalive":true,"source":"typing"}}
        """#)
        try await Task.sleep(nanoseconds: 55_000_000)

        XCTAssertEqual(client.messages.filter { $0.status == "local_notice" }.count, 1)
        XCTAssertNotEqual(client.runStatus, .error)
    }

    @MainActor
    func testTerminalRunStatusAfterStaleNoticeStopsRepeatingNotices() async throws {
        let socket = RecordingWebSocketTask()
        let client = makeSocketBackedClient(socket: socket, staleTimeoutInterval: 0.05)
        XCTAssertTrue(client.sendText("This will become stale, then idle."))
        let textFrame = try XCTUnwrap(try socket.sentMessages.map { try frameRoot(from: $0) }.last { $0["type"] as? String == "text_input" })
        let requestID = try XCTUnwrap(textFrame["request_id"] as? String)

        try await Task.sleep(nanoseconds: 90_000_000)
        XCTAssertEqual(client.messages.filter { $0.status == "local_notice" }.count, 1)

        client.handleFrameString("""
        {"type":"run_status","request_id":"\(requestID)","project_key":"default","session_id":"project:default","payload":{"status":"idle"}}
        """)
        try await Task.sleep(nanoseconds: 90_000_000)

        XCTAssertEqual(client.runStatus, .idle)
        XCTAssertEqual(client.messages.filter { $0.status == "local_notice" }.count, 1)
    }

    @MainActor
    func testTimedOutProgressIgnoresUnrelatedLateProgress() async throws {
        let socket = RecordingWebSocketTask()
        let client = makeSocketBackedClient(socket: socket, staleTimeoutInterval: 0.05)

        client.handleFrameString(#"""
        {"type":"tool_progress","request_id":"req-timeout-current","project_key":"default","session_id":"session-timeout-current","payload":{"kind":"terminal","text":"Current request running"}}
        """#)
        try await Task.sleep(nanoseconds: 90_000_000)
        XCTAssertEqual(client.progressActivity?.requestID, "req-timeout-current")
        XCTAssertEqual(client.progressActivity?.timedOut, true)

        client.handleFrameString(#"""
        {"type":"tool_progress","request_id":"req-unrelated-late","project_key":"default","session_id":"session-timeout-current","payload":{"kind":"terminal","text":"Unrelated late progress"}}
        """#)

        XCTAssertEqual(client.progressActivity?.requestID, "req-timeout-current")
        XCTAssertTrue(client.progressActivity?.events.last?.text.contains("not heard from Hermes") == true)
    }

    @MainActor
    func testMessagesBatchDurableProgressDoesNotReviveLiveProgressOrStaleTimer() async throws {
        let socket = RecordingWebSocketTask()
        let client = makeSocketBackedClient(socket: socket, staleTimeoutInterval: 0.05)

        client.handleFrameString(#"""
        {"type":"messages_batch","request_id":"hello-replay","project_key":"default","session_id":"session-replay","payload":{"messages":[{"project_key":"default","session_id":"session-replay","message_id":"progress-replay","server_seq":91,"role":"assistant","content":"🔧 terminal: \"old\"","timestamp":123.0,"metadata":{"finalized":false,"source":"tool_progress","progress_kind":"terminal","request_id":"req-old-replay","transient":false}}]}}
        """#)
        try await Task.sleep(nanoseconds: 90_000_000)

        XCTAssertNil(client.progressActivity)
        XCTAssertTrue(client.messages.isEmpty)
        XCTAssertTrue(client.messages.filter { $0.status == "local_notice" }.isEmpty)
    }

    @MainActor
    func testLocalStaleNoticePersistsAcrossStoreReload() async throws {
        let socket = RecordingWebSocketTask()
        let store = SQLiteMessageStore(filename: "LogosTests-\(UUID().uuidString).sqlite3")
        let client = makeSocketBackedClient(socket: socket, store: store, staleTimeoutInterval: 0.05)
        XCTAssertTrue(client.sendText("Persist stale notice."))

        try await Task.sleep(nanoseconds: 90_000_000)

        let reloaded = LogosClient(store: store, staleTimeoutInterval: 0.05)
        XCTAssertEqual(reloaded.messages.filter { $0.status == "local_notice" }.count, 1)
        XCTAssertEqual(reloaded.messages.first(where: { $0.status == "local_notice" })?.metadataSource, "local_notice")
    }

    @MainActor
    func testProgressTimeoutSuspendsWhileAwaitingApproval() async throws {
        let socket = RecordingWebSocketTask()
        let client = makeSocketBackedClient(socket: socket, staleTimeoutInterval: 0.05)
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
        let client = makeSocketBackedClient(socket: socket, staleTimeoutInterval: 0.05)
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
        XCTAssertEqual(client.progressActivity?.isComplete, true)
        XCTAssertEqual(client.progressActivity?.finalStatus, .stopped)
        XCTAssertNil(client.progressActivity?.retryRequest)
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
        XCTAssertEqual(client.progressActivity?.isComplete, true)
        XCTAssertEqual(client.progressActivity?.finalStatus, .stopped)
        XCTAssertNil(client.progressActivity?.retryRequest)
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
        XCTAssertEqual(client.progressActivity?.isComplete, true)
        XCTAssertEqual(client.progressActivity?.finalStatus, .stopped)
        XCTAssertNil(client.progressActivity?.retryRequest)

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
    func testLateUnscopedFinalAfterNewTextBeforeProgressDoesNotAutoplay() throws {
        let socket = RecordingWebSocketTask()
        let client = makeSocketBackedClient(socket: socket)
        client.handleFrameString(#"""
        {"type":"tool_progress","request_id":"req-old-before-text-rerun","project_key":"default","session_id":"project:default","payload":{"kind":"terminal","text":"Old request is running"}}
        """#)
        client.cancelRun()
        let cancelRoot = try frameRoot(from: try XCTUnwrap(socket.sentMessages.last))
        let cancelRequestID = try XCTUnwrap(cancelRoot["request_id"] as? String)
        client.handleFrameString("""
        {"type":"run_status","request_id":"\(cancelRequestID)","project_key":"default","session_id":"project:default","payload":{"status":"idle","cancelled":true}}
        """)
        XCTAssertTrue(client.sendText("new request before progress"))
        let baselineCount = socket.sentMessages.count

        client.handleFrameString(#"""
        {"type":"state_update","project_key":"default","session_id":"project:default","server_seq":134,"payload":{"op":"message_appended","message":{"project_key":"default","session_id":"project:default","message_id":"assistant-old-unscoped-before-progress","server_seq":134,"role":"assistant","content":"Old final before new progress starts.","timestamp":129.0,"metadata":{"finalized":true,"source":"hermes"}}}}
        """#)

        let newFrames = try socket.sentMessages.dropFirst(baselineCount).map { try frameRoot(from: $0) }
        XCTAssertTrue(newFrames.filter { $0["type"] as? String == "playback_audio" }.isEmpty)
        XCTAssertTrue(client.messages.contains { $0.content == "new request before progress" && $0.status == "pending" })
    }

    @MainActor
    func testMatchingFinalAfterNewTextBeforeProgressAutoplays() throws {
        let socket = RecordingWebSocketTask()
        let client = makeSocketBackedClient(socket: socket)
        XCTAssertTrue(client.sendText("fast hello before progress"))
        let textRoot = try frameRoot(from: try XCTUnwrap(socket.sentMessages.last))
        let requestID = try XCTUnwrap(textRoot["request_id"] as? String)
        let baselineCount = socket.sentMessages.count

        client.handleFrameString("""
        {"type":"state_update","request_id":"\(requestID)","project_key":"default","session_id":"project:default","server_seq":135,"payload":{"op":"message_appended","message":{"project_key":"default","session_id":"project:default","message_id":"assistant-fast-final","server_seq":135,"role":"assistant","content":"Fast response before progress.","timestamp":130.0,"metadata":{"finalized":true,"source":"fast_response"}}}}
        """)

        let newFrames = try socket.sentMessages.dropFirst(baselineCount).map { try frameRoot(from: $0) }
        let playbackFrames = newFrames.filter { $0["type"] as? String == "playback_audio" }
        XCTAssertEqual(playbackFrames.count, 1)
        XCTAssertEqual((playbackFrames[0]["payload"] as? [String: Any])?["message_id"] as? String, "assistant-fast-final")
        XCTAssertEqual(client.runStatus, .idle)
    }

    @MainActor
    func testOutstandingFollowupFinalBeforeProgressSupersedesOlderActiveProgress() throws {
        let socket = RecordingWebSocketTask()
        let client = makeSocketBackedClient(socket: socket)
        XCTAssertTrue(client.sendText("first run before followup final"))
        let firstRoot = try frameRoot(from: try XCTUnwrap(socket.sentMessages.last))
        let firstRequestID = try XCTUnwrap(firstRoot["request_id"] as? String)
        client.handleFrameString("""
        {"type":"tool_progress","request_id":"\(firstRequestID)","project_key":"default","session_id":"project:default","payload":{"kind":"terminal","text":"First run active before followup final"}}
        """)
        XCTAssertEqual(client.progressActivity?.requestID, firstRequestID)

        XCTAssertTrue(client.sendText("second final before progress"))
        let secondRoot = try frameRoot(from: try XCTUnwrap(socket.sentMessages.last))
        let secondRequestID = try XCTUnwrap(secondRoot["request_id"] as? String)
        let baselineCount = socket.sentMessages.count
        client.handleFrameString("""
        {"type":"state_update","request_id":"\(secondRequestID)","project_key":"default","session_id":"project:default","server_seq":143,"payload":{"op":"message_appended","message":{"project_key":"default","session_id":"project:default","message_id":"assistant-second-final-before-progress","server_seq":143,"role":"assistant","content":"Second final before progress.","timestamp":138.0,"metadata":{"finalized":true,"source":"fast_response"}}}}
        """)

        let newFrames = try socket.sentMessages.dropFirst(baselineCount).map { try frameRoot(from: $0) }
        let playbackFrames = newFrames.filter { $0["type"] as? String == "playback_audio" }
        XCTAssertEqual(playbackFrames.count, 1)
        XCTAssertEqual((playbackFrames[0]["payload"] as? [String: Any])?["message_id"] as? String, "assistant-second-final-before-progress")
        XCTAssertEqual(client.progressActivity?.requestID, secondRequestID)
        XCTAssertEqual(client.progressActivity?.isComplete, true)
        XCTAssertEqual(client.progressActivity?.completedFinalMessageID, "project:default:assistant-second-final-before-progress")
        XCTAssertEqual(client.runStatus, .idle)
    }

    @MainActor
    func testLateStaleProgressAfterNewTextBeforeProgressDoesNotReleaseStaleFinal() throws {
        let socket = RecordingWebSocketTask()
        let client = makeSocketBackedClient(socket: socket)
        client.handleFrameString(#"""
        {"type":"tool_progress","request_id":"req-old-stale-progress","project_key":"default","session_id":"project:default","payload":{"kind":"terminal","text":"Old request was running"}}
        """#)
        client.cancelRun()
        let cancelRoot = try frameRoot(from: try XCTUnwrap(socket.sentMessages.last))
        let cancelRequestID = try XCTUnwrap(cancelRoot["request_id"] as? String)
        client.handleFrameString("""
        {"type":"run_status","request_id":"\(cancelRequestID)","project_key":"default","session_id":"project:default","payload":{"status":"idle","cancelled":true}}
        """)
        XCTAssertTrue(client.sendText("new request before stale progress"))
        let textRoot = try frameRoot(from: try XCTUnwrap(socket.sentMessages.last))
        let newRequestID = try XCTUnwrap(textRoot["request_id"] as? String)
        let baselineCount = socket.sentMessages.count

        client.handleFrameString(#"""
        {"type":"tool_progress","request_id":"req-old-stale-progress","project_key":"default","session_id":"project:default","payload":{"kind":"terminal","text":"Late old progress"}}
        """#)
        client.handleFrameString(#"""
        {"type":"state_update","request_id":"req-old-stale-progress","project_key":"default","session_id":"project:default","server_seq":136,"payload":{"op":"message_updated","message":{"project_key":"default","session_id":"project:default","message_id":"assistant-old-stale-progress-final","server_seq":136,"role":"assistant","content":"Old final after stale progress.","timestamp":131.0,"metadata":{"finalized":true,"source":"hermes"}}}}
        """#)

        let newFrames = try socket.sentMessages.dropFirst(baselineCount).map { try frameRoot(from: $0) }
        XCTAssertTrue(newFrames.filter { $0["type"] as? String == "playback_audio" }.isEmpty)
        XCTAssertEqual(client.progressActivity?.requestID, newRequestID)
        XCTAssertEqual(client.progressActivity?.isComplete, false)
        XCTAssertEqual(client.progressActivity?.updateCount, 0)
    }

    @MainActor
    func testLateStaleProgressAfterNewProgressDoesNotReplaceNewProgressOrAutoplay() throws {
        let socket = RecordingWebSocketTask()
        let client = makeSocketBackedClient(socket: socket)
        client.handleFrameString(#"""
        {"type":"tool_progress","request_id":"req-old-after-new-progress","project_key":"default","session_id":"project:default","payload":{"kind":"terminal","text":"Old request was running"}}
        """#)
        client.cancelRun()
        let cancelRoot = try frameRoot(from: try XCTUnwrap(socket.sentMessages.last))
        let cancelRequestID = try XCTUnwrap(cancelRoot["request_id"] as? String)
        client.handleFrameString("""
        {"type":"run_status","request_id":"\(cancelRequestID)","project_key":"default","session_id":"project:default","payload":{"status":"idle","cancelled":true}}
        """)
        XCTAssertTrue(client.sendText("new request with valid progress"))
        let textRoot = try frameRoot(from: try XCTUnwrap(socket.sentMessages.last))
        let newRequestID = try XCTUnwrap(textRoot["request_id"] as? String)

        client.handleFrameString("""
        {"type":"tool_progress","request_id":"\(newRequestID)","project_key":"default","session_id":"project:default","payload":{"kind":"terminal","text":"New request progress"}}
        """)
        XCTAssertEqual(client.progressActivity?.requestID, newRequestID)
        let baselineCount = socket.sentMessages.count

        client.handleFrameString(#"""
        {"type":"tool_progress","request_id":"req-old-after-new-progress","project_key":"default","session_id":"project:default","payload":{"kind":"terminal","text":"Late old progress after new progress"}}
        """#)
        client.handleFrameString(#"""
        {"type":"state_update","request_id":"req-old-after-new-progress","project_key":"default","session_id":"project:default","server_seq":137,"payload":{"op":"message_updated","message":{"project_key":"default","session_id":"project:default","message_id":"assistant-old-after-new-progress-final","server_seq":137,"role":"assistant","content":"Old final after the new request has progress.","timestamp":132.0,"metadata":{"finalized":true,"source":"hermes"}}}}
        """#)

        let newFrames = try socket.sentMessages.dropFirst(baselineCount).map { try frameRoot(from: $0) }
        XCTAssertTrue(newFrames.filter { $0["type"] as? String == "playback_audio" }.isEmpty)
        XCTAssertEqual(client.progressActivity?.requestID, newRequestID)
        XCTAssertEqual(client.runStatus, .running)
    }

    @MainActor
    func testCancelSuppressesAllOutstandingOutboundRequests() throws {
        let socket = RecordingWebSocketTask()
        let client = makeSocketBackedClient(socket: socket)
        var requestIDs: [String] = []
        for index in 0..<70 {
            XCTAssertTrue(client.sendText("pending request \(index)"))
            let root = try frameRoot(from: try XCTUnwrap(socket.sentMessages.last))
            requestIDs.append(try XCTUnwrap(root["request_id"] as? String))
        }
        XCTAssertEqual(Set(requestIDs).count, 70)
        let firstRequestID = try XCTUnwrap(requestIDs.first)

        client.cancelRun()
        let cancelRoot = try frameRoot(from: try XCTUnwrap(socket.sentMessages.last))
        let cancelRequestID = try XCTUnwrap(cancelRoot["request_id"] as? String)
        client.handleFrameString("""
        {"type":"run_status","request_id":"\(cancelRequestID)","project_key":"default","session_id":"project:default","payload":{"status":"idle","cancelled":true}}
        """)
        let baselineCount = socket.sentMessages.count

        client.handleFrameString("""
        {"type":"state_update","request_id":"\(firstRequestID)","project_key":"default","session_id":"project:default","server_seq":138,"payload":{"op":"message_appended","message":{"project_key":"default","session_id":"project:default","message_id":"assistant-first-pending-after-cancel","server_seq":138,"role":"assistant","content":"Old first pending final after cancel.","timestamp":133.0,"metadata":{"finalized":true,"source":"hermes"}}}}
        """)

        let newFrames = try socket.sentMessages.dropFirst(baselineCount).map { try frameRoot(from: $0) }
        XCTAssertTrue(newFrames.filter { $0["type"] as? String == "playback_audio" }.isEmpty)
        XCTAssertEqual(client.runStatus, .idle)
    }

    @MainActor
    func testOutstandingFollowupProgressSupersedesOlderActiveProgress() throws {
        let socket = RecordingWebSocketTask()
        let client = makeSocketBackedClient(socket: socket)
        XCTAssertTrue(client.sendText("first run"))
        let firstRoot = try frameRoot(from: try XCTUnwrap(socket.sentMessages.last))
        let firstRequestID = try XCTUnwrap(firstRoot["request_id"] as? String)
        client.handleFrameString("""
        {"type":"tool_progress","request_id":"\(firstRequestID)","project_key":"default","session_id":"project:default","payload":{"kind":"terminal","text":"First run progress"}}
        """)
        XCTAssertEqual(client.progressActivity?.requestID, firstRequestID)

        XCTAssertTrue(client.sendText("second run"))
        let secondRoot = try frameRoot(from: try XCTUnwrap(socket.sentMessages.last))
        let secondRequestID = try XCTUnwrap(secondRoot["request_id"] as? String)
        client.handleFrameString("""
        {"type":"tool_progress","request_id":"\(secondRequestID)","project_key":"default","session_id":"project:default","payload":{"kind":"terminal","text":"Second run progress"}}
        """)
        XCTAssertEqual(client.progressActivity?.requestID, secondRequestID)
        let baselineCount = socket.sentMessages.count

        client.handleFrameString("""
        {"type":"state_update","request_id":"\(secondRequestID)","project_key":"default","session_id":"project:default","server_seq":140,"payload":{"op":"message_appended","message":{"project_key":"default","session_id":"project:default","message_id":"assistant-second-run-final","server_seq":140,"role":"assistant","content":"Second run final.","timestamp":135.0,"metadata":{"finalized":true,"source":"hermes"}}}}
        """)

        let newFrames = try socket.sentMessages.dropFirst(baselineCount).map { try frameRoot(from: $0) }
        let playbackFrames = newFrames.filter { $0["type"] as? String == "playback_audio" }
        XCTAssertEqual(playbackFrames.count, 1)
        XCTAssertEqual((playbackFrames[0]["payload"] as? [String: Any])?["message_id"] as? String, "assistant-second-run-final")
        XCTAssertEqual(client.runStatus, .idle)
    }

    @MainActor
    func testPostCancelUnscopedFinalDoesNotAutoplayAfterMatchingNewFinal() throws {
        let socket = RecordingWebSocketTask()
        let client = makeSocketBackedClient(socket: socket)
        client.handleFrameString(#"""
        {"type":"tool_progress","request_id":"req-old-unscoped-after-good-final","project_key":"default","session_id":"project:default","payload":{"kind":"terminal","text":"Old run progress"}}
        """#)
        client.cancelRun()
        let cancelRoot = try frameRoot(from: try XCTUnwrap(socket.sentMessages.last))
        let cancelRequestID = try XCTUnwrap(cancelRoot["request_id"] as? String)
        client.handleFrameString("""
        {"type":"run_status","request_id":"\(cancelRequestID)","project_key":"default","session_id":"project:default","payload":{"status":"idle","cancelled":true}}
        """)
        XCTAssertTrue(client.sendText("new run after cancel"))
        let newRoot = try frameRoot(from: try XCTUnwrap(socket.sentMessages.last))
        let newRequestID = try XCTUnwrap(newRoot["request_id"] as? String)
        let baselineCount = socket.sentMessages.count
        client.handleFrameString("""
        {"type":"state_update","request_id":"\(newRequestID)","project_key":"default","session_id":"project:default","server_seq":141,"payload":{"op":"message_appended","message":{"project_key":"default","session_id":"project:default","message_id":"assistant-new-after-cancel-final","server_seq":141,"role":"assistant","content":"New final after cancel.","timestamp":136.0,"metadata":{"finalized":true,"source":"hermes"}}}}
        """)
        client.handleFrameString(#"""
        {"type":"state_update","project_key":"default","session_id":"project:default","server_seq":142,"payload":{"op":"message_appended","message":{"project_key":"default","session_id":"project:default","message_id":"assistant-old-unscoped-after-good-final","server_seq":142,"role":"assistant","content":"Old unscoped final after the good final.","timestamp":137.0,"metadata":{"finalized":true,"source":"hermes"}}}}
        """#)

        let newFrames = try socket.sentMessages.dropFirst(baselineCount).map { try frameRoot(from: $0) }
        let playbackFrames = newFrames.filter { $0["type"] as? String == "playback_audio" }
        XCTAssertEqual(playbackFrames.count, 1)
        XCTAssertEqual((playbackFrames[0]["payload"] as? [String: Any])?["message_id"] as? String, "assistant-new-after-cancel-final")
    }

    @MainActor
    func testServerDrivenCancelSuppressesActiveRunBeforeStaleFinal() throws {
        let socket = RecordingWebSocketTask()
        let client = makeSocketBackedClient(socket: socket)
        client.handleFrameString(#"""
        {"type":"tool_progress","request_id":"req-server-driven-cancel","project_key":"default","session_id":"project:default","payload":{"kind":"terminal","text":"Server-side run is active"}}
        """#)
        XCTAssertEqual(client.progressActivity?.requestID, "req-server-driven-cancel")

        client.handleFrameString(#"""
        {"type":"run_status","request_id":"server-cancel-status","project_key":"default","session_id":"project:default","payload":{"status":"cancelling"}}
        """#)
        client.handleFrameString(#"""
        {"type":"run_status","request_id":"server-cancel-status","project_key":"default","session_id":"project:default","payload":{"status":"idle","cancelled":true}}
        """#)
        XCTAssertEqual(client.runStatus, .idle)
        XCTAssertEqual(client.progressActivity?.isComplete, true)
        XCTAssertEqual(client.progressActivity?.finalStatus, .stopped)
        XCTAssertNil(client.progressActivity?.retryRequest)
        let baselineCount = socket.sentMessages.count

        client.handleFrameString(#"""
        {"type":"state_update","request_id":"req-server-driven-cancel","project_key":"default","session_id":"project:default","server_seq":139,"payload":{"op":"message_appended","message":{"project_key":"default","session_id":"project:default","message_id":"assistant-server-driven-cancel-final","server_seq":139,"role":"assistant","content":"Server-canceled final arrived late.","timestamp":134.0,"metadata":{"finalized":true,"source":"hermes"}}}}
        """#)

        let newFrames = try socket.sentMessages.dropFirst(baselineCount).map { try frameRoot(from: $0) }
        XCTAssertTrue(newFrames.filter { $0["type"] as? String == "playback_audio" }.isEmpty)
        XCTAssertEqual(client.runStatus, .idle)
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
        XCTAssertEqual(client.runStatus, .idle)
        XCTAssertNotNil(client.connectionRetryState)
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
    func testReceivingAudioKeepsSpectrumIdleUntilPlaybackStarts() throws {
        let socket = RecordingWebSocketTask()
        let session = RecordingAudioSessionManager()
        let factory = RecordingAudioPlayerFactory()
        let controller = AudioPlaybackController(sessionManager: session, playerFactory: factory)
        let client = makeSocketBackedClient(socket: socket, audioPlayback: controller)
        let message = LogosMessage(
            projectKey: "default",
            sessionID: "session-receiving-idle",
            messageID: "assistant-receiving-idle-1",
            serverSeq: 101,
            role: "assistant",
            content: "Play this response.",
            timestamp: 123,
            status: "persisted"
        )

        client.playback(message: message)
        let requestRoot = try frameRoot(from: try XCTUnwrap(socket.sentMessages.last))
        let requestPayload = try XCTUnwrap(requestRoot["payload"] as? [String: Any])
        let audioID = try XCTUnwrap(requestPayload["audio_id"] as? String)
        client.handleFrameString("""
        {"type":"audio_chunk","device_id":"ios-simulator","project_key":"default","session_id":"session-receiving-idle","payload":{"audio_id":"\(audioID)","message_id":"assistant-receiving-idle-1","chunk_index":0,"data":"\(Data([255, 255, 255, 255]).base64EncodedString())"}}
        """)

        XCTAssertEqual(client.audioPlaybackOverlay?.phase, .receiving)
        XCTAssertLessThanOrEqual(client.audioPlaybackOverlay?.spectrumBins.max() ?? 1, 0.08)
    }

    @MainActor
    func testPlaybackSpectrumRefreshUsesDecodedPCMAtCurrentTime() async throws {
        let socket = RecordingWebSocketTask()
        let session = RecordingAudioSessionManager()
        let factory = RecordingAudioPlayerFactory()
        let sampleRate = 24_000.0
        let decoder = RecordingAudioSampleDecoder(decodedSamples: DecodedAudioSamples(
            samples: sineWave(frequency: 160, sampleRate: sampleRate) + sineWave(frequency: 3_000, sampleRate: sampleRate),
            sampleRate: sampleRate
        ))
        let controller = AudioPlaybackController(sessionManager: session, playerFactory: factory, sampleDecoder: decoder)
        let client = makeSocketBackedClient(socket: socket, audioPlayback: controller)
        let message = LogosMessage(
            projectKey: "default",
            sessionID: "session-spectrum-refresh",
            messageID: "assistant-spectrum-refresh-1",
            serverSeq: 103,
            role: "assistant",
            content: "Play this response.",
            timestamp: 123,
            status: "persisted"
        )

        client.playback(message: message)
        let requestRoot = try frameRoot(from: try XCTUnwrap(socket.sentMessages.last))
        let requestPayload = try XCTUnwrap(requestRoot["payload"] as? [String: Any])
        let audioID = try XCTUnwrap(requestPayload["audio_id"] as? String)
        client.handleFrameString("""
        {"type":"audio_chunk","device_id":"ios-simulator","project_key":"default","session_id":"session-spectrum-refresh","payload":{"audio_id":"\(audioID)","message_id":"assistant-spectrum-refresh-1","chunk_index":0,"data":"\(Data([1, 2, 3]).base64EncodedString())"}}
        """)
        client.handleFrameString("""
        {"type":"audio_end","device_id":"ios-simulator","project_key":"default","session_id":"session-spectrum-refresh","payload":{"audio_id":"\(audioID)","message_id":"assistant-spectrum-refresh-1","chunk_count":1}}
        """)
        let decoded = await controller.waitForSpectrumDecodeForTesting(audioID: audioID)
        XCTAssertTrue(decoded)

        factory.player.currentTime = 0.25
        client.refreshPlaybackSpectrumForTesting(audioID: audioID)
        let lowOverlay = try XCTUnwrap(client.audioPlaybackOverlay)
        XCTAssertLessThanOrEqual(try dominantSpectrumIndex(in: lowOverlay.spectrumBins), 3)

        factory.player.currentTime = 1.25
        client.refreshPlaybackSpectrumForTesting(audioID: audioID)
        let highOverlay = try XCTUnwrap(client.audioPlaybackOverlay)
        XCTAssertGreaterThanOrEqual(try dominantSpectrumIndex(in: highOverlay.spectrumBins), 8)
    }

    @MainActor
    func testPlaybackSpectrumTickerRefreshesWithoutManualCall() async throws {
        let socket = RecordingWebSocketTask()
        let session = RecordingAudioSessionManager()
        let factory = RecordingAudioPlayerFactory()
        let sampleRate = 24_000.0
        let decoder = RecordingAudioSampleDecoder(decodedSamples: DecodedAudioSamples(
            samples: sineWave(frequency: 160, sampleRate: sampleRate) + sineWave(frequency: 3_000, sampleRate: sampleRate),
            sampleRate: sampleRate
        ))
        let controller = AudioPlaybackController(sessionManager: session, playerFactory: factory, sampleDecoder: decoder)
        let client = makeSocketBackedClient(socket: socket, audioPlayback: controller)
        let message = LogosMessage(
            projectKey: "default",
            sessionID: "session-spectrum-ticker",
            messageID: "assistant-spectrum-ticker-1",
            serverSeq: 105,
            role: "assistant",
            content: "Play this response.",
            timestamp: 123,
            status: "persisted"
        )

        client.playback(message: message)
        let requestRoot = try frameRoot(from: try XCTUnwrap(socket.sentMessages.last))
        let requestPayload = try XCTUnwrap(requestRoot["payload"] as? [String: Any])
        let audioID = try XCTUnwrap(requestPayload["audio_id"] as? String)
        client.handleFrameString("""
        {"type":"audio_chunk","device_id":"ios-simulator","project_key":"default","session_id":"session-spectrum-ticker","payload":{"audio_id":"\(audioID)","message_id":"assistant-spectrum-ticker-1","chunk_index":0,"data":"\(Data([1, 2, 3]).base64EncodedString())"}}
        """)
        factory.player.currentTime = 0.25
        client.handleFrameString("""
        {"type":"audio_end","device_id":"ios-simulator","project_key":"default","session_id":"session-spectrum-ticker","payload":{"audio_id":"\(audioID)","message_id":"assistant-spectrum-ticker-1","chunk_count":1}}
        """)
        let decoded = await controller.waitForSpectrumDecodeForTesting(audioID: audioID)
        XCTAssertTrue(decoded)
        try await waitUntilSpectrumDominantIndex(in: client, isAtMost: 3)

        factory.player.currentTime = 1.25
        try await waitUntilSpectrumDominantIndex(in: client, isAtLeast: 8)
        client.stopPlayback()
    }

    @MainActor
    func testLateAudioFramesAfterFinishedPlaybackAreIgnored() async throws {
        let socket = RecordingWebSocketTask()
        let session = RecordingAudioSessionManager()
        let factory = RecordingAudioPlayerFactory()
        let controller = AudioPlaybackController(sessionManager: session, playerFactory: factory)
        let client = makeSocketBackedClient(socket: socket, audioPlayback: controller)
        let message = LogosMessage(
            projectKey: "default",
            sessionID: "session-finished-late-audio",
            messageID: "assistant-finished-late-audio-1",
            serverSeq: 106,
            role: "assistant",
            content: "Play this response.",
            timestamp: 123,
            status: "persisted"
        )

        client.playback(message: message)
        let requestRoot = try frameRoot(from: try XCTUnwrap(socket.sentMessages.last))
        let requestPayload = try XCTUnwrap(requestRoot["payload"] as? [String: Any])
        let audioID = try XCTUnwrap(requestPayload["audio_id"] as? String)
        client.handleFrameString("""
        {"type":"audio_chunk","device_id":"ios-simulator","project_key":"default","session_id":"session-finished-late-audio","payload":{"audio_id":"\(audioID)","message_id":"assistant-finished-late-audio-1","chunk_index":0,"data":"\(Data([1, 2, 3]).base64EncodedString())"}}
        """)
        client.handleFrameString("""
        {"type":"audio_end","device_id":"ios-simulator","project_key":"default","session_id":"session-finished-late-audio","payload":{"audio_id":"\(audioID)","message_id":"assistant-finished-late-audio-1","chunk_count":1}}
        """)
        let playCallsBeforeFinish = factory.player.playCalls

        controller.onPlaybackFinished?(audioID, true)
        try await Task.sleep(nanoseconds: 1_000_000)
        XCTAssertEqual(client.audioPlaybackOverlay?.phase, .finished)
        client.handleFrameString("""
        {"type":"audio_chunk","device_id":"ios-simulator","project_key":"default","session_id":"session-finished-late-audio","payload":{"audio_id":"\(audioID)","message_id":"assistant-finished-late-audio-1","chunk_index":1,"data":"\(Data([4, 5, 6]).base64EncodedString())"}}
        """)
        client.handleFrameString("""
        {"type":"audio_end","device_id":"ios-simulator","project_key":"default","session_id":"session-finished-late-audio","payload":{"audio_id":"\(audioID)","message_id":"assistant-finished-late-audio-1","chunk_count":2}}
        """)

        XCTAssertEqual(client.audioPlaybackOverlay?.phase, .finished)
        XCTAssertEqual(factory.player.playCalls, playCallsBeforeFinish)
    }

    @MainActor
    func testStoppedAudioRejectsStaleSpectrumRefresh() throws {
        let socket = RecordingWebSocketTask()
        let session = RecordingAudioSessionManager()
        let factory = RecordingAudioPlayerFactory()
        let sampleRate = 24_000.0
        let decoder = RecordingAudioSampleDecoder(decodedSamples: DecodedAudioSamples(
            samples: sineWave(frequency: 160, sampleRate: sampleRate),
            sampleRate: sampleRate
        ))
        let controller = AudioPlaybackController(sessionManager: session, playerFactory: factory, sampleDecoder: decoder)
        let client = makeSocketBackedClient(socket: socket, audioPlayback: controller)
        let message = LogosMessage(
            projectKey: "default",
            sessionID: "session-spectrum-stopped",
            messageID: "assistant-spectrum-stopped-1",
            serverSeq: 104,
            role: "assistant",
            content: "Play this response.",
            timestamp: 123,
            status: "persisted"
        )

        client.playback(message: message)
        let requestRoot = try frameRoot(from: try XCTUnwrap(socket.sentMessages.last))
        let requestPayload = try XCTUnwrap(requestRoot["payload"] as? [String: Any])
        let audioID = try XCTUnwrap(requestPayload["audio_id"] as? String)
        client.handleFrameString("""
        {"type":"audio_chunk","device_id":"ios-simulator","project_key":"default","session_id":"session-spectrum-stopped","payload":{"audio_id":"\(audioID)","message_id":"assistant-spectrum-stopped-1","chunk_index":0,"data":"\(Data([1, 2, 3]).base64EncodedString())"}}
        """)
        client.handleFrameString("""
        {"type":"audio_end","device_id":"ios-simulator","project_key":"default","session_id":"session-spectrum-stopped","payload":{"audio_id":"\(audioID)","message_id":"assistant-spectrum-stopped-1","chunk_count":1}}
        """)
        XCTAssertEqual(client.audioPlaybackOverlay?.phase, .playing)

        client.stopPlayback()
        client.refreshPlaybackSpectrumForTesting(audioID: audioID)

        XCTAssertNil(client.audioPlaybackOverlay)
        XCTAssertNil(client.playbackStatus)
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

    func testSpectrumAnalyzerMapsLowToneToLowerBands() throws {
        let analyzer = AudioSpectrumAnalyzer()
        let sampleRate = 24_000.0
        let bins = analyzer.analyze(
            samples: sineWave(frequency: 160, sampleRate: sampleRate),
            sampleRate: sampleRate,
            playheadTime: 0.25,
            configuration: AudioSpectrumAnalyzer.Configuration(fftSize: 1024, binCount: 12, minimumFrequency: 80, maximumFrequency: 8000, floorDB: -80)
        )

        let dominantIndex = try XCTUnwrap(bins.indices.max(by: { bins[$0] < bins[$1] }))
        let upperBandMax = bins[7...].max() ?? 0

        XCTAssertLessThanOrEqual(dominantIndex, 3)
        XCTAssertGreaterThan(bins[dominantIndex], 0.35)
        XCTAssertGreaterThan(bins[dominantIndex], upperBandMax + 0.15)
    }

    func testSpectrumAnalyzerMapsHighToneToHigherBands() throws {
        let analyzer = AudioSpectrumAnalyzer()
        let sampleRate = 24_000.0
        let bins = analyzer.analyze(
            samples: sineWave(frequency: 3_000, sampleRate: sampleRate),
            sampleRate: sampleRate,
            playheadTime: 0.25,
            configuration: AudioSpectrumAnalyzer.Configuration(fftSize: 1024, binCount: 12, minimumFrequency: 80, maximumFrequency: 8000, floorDB: -80)
        )

        let dominantIndex = try XCTUnwrap(bins.indices.max(by: { bins[$0] < bins[$1] }))
        let lowerBandMax = bins[0...4].max() ?? 0

        XCTAssertGreaterThanOrEqual(dominantIndex, 8)
        XCTAssertGreaterThan(bins[dominantIndex], 0.35)
        XCTAssertGreaterThan(bins[dominantIndex], lowerBandMax + 0.15)
    }

    func testSpectrumAnalyzerSilenceReturnsFloorBins() {
        let analyzer = AudioSpectrumAnalyzer()
        let bins = analyzer.analyze(
            samples: Array(repeating: 0, count: 4096),
            sampleRate: 24_000,
            playheadTime: 0.05,
            configuration: AudioSpectrumAnalyzer.Configuration(fftSize: 1024, binCount: 12, minimumFrequency: 80, maximumFrequency: 8000, floorDB: -80)
        )

        XCTAssertEqual(bins.count, 12)
        XCTAssertTrue(bins.allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 1 })
        XCTAssertLessThanOrEqual(bins.max() ?? 1, 0.08)
    }

    func testAudioPlaybackControllerUsesDecodedSamplesForSpectrumBins() async throws {
        let session = RecordingAudioSessionManager()
        let factory = RecordingAudioPlayerFactory()
        let sampleRate = 24_000.0
        let decoder = RecordingAudioSampleDecoder(decodedSamples: DecodedAudioSamples(
            samples: sineWave(frequency: 160, sampleRate: sampleRate) + sineWave(frequency: 3_000, sampleRate: sampleRate),
            sampleRate: sampleRate
        ))
        let controller = AudioPlaybackController(sessionManager: session, playerFactory: factory, sampleDecoder: decoder)
        try controller.appendChunk(audioID: "audio-decoded-spectrum", chunkIndex: 0, base64: Data([1, 2, 3]).base64EncodedString())
        try controller.finish(audioID: "audio-decoded-spectrum", expectedChunkCount: 1)
        let decoded = await controller.waitForSpectrumDecodeForTesting(audioID: "audio-decoded-spectrum")
        XCTAssertTrue(decoded)

        factory.player.currentTime = 0.25
        let lowBins = controller.spectrumBins(audioID: "audio-decoded-spectrum", count: 12)
        factory.player.currentTime = 1.25
        let highBins = controller.spectrumBins(audioID: "audio-decoded-spectrum", count: 12)

        XCTAssertLessThanOrEqual(try dominantSpectrumIndex(in: lowBins), 3)
        XCTAssertGreaterThanOrEqual(try dominantSpectrumIndex(in: highBins), 8)
        XCTAssertEqual(decoder.decodeCalls, 1)
    }

    func testAudioPlaybackDecodeFailureDoesNotBlockPlaybackAndUsesFloorBins() async throws {
        let session = RecordingAudioSessionManager()
        let factory = RecordingAudioPlayerFactory()
        let decoder = RecordingAudioSampleDecoder(error: RecordingAudioSampleDecoderError())
        let controller = AudioPlaybackController(sessionManager: session, playerFactory: factory, sampleDecoder: decoder)
        try controller.appendChunk(audioID: "audio-decode-fail", chunkIndex: 0, base64: Data([1, 2, 3]).base64EncodedString())

        let result = try controller.finish(audioID: "audio-decode-fail", expectedChunkCount: 1)
        let decoded = await controller.waitForSpectrumDecodeForTesting(audioID: "audio-decode-fail")
        XCTAssertTrue(decoded)
        let bins = controller.spectrumBins(audioID: "audio-decode-fail", count: 12)

        XCTAssertTrue(result.started)
        XCTAssertEqual(factory.player.playCalls, 1)
        XCTAssertLessThanOrEqual(bins.max() ?? 1, 0.08)
        XCTAssertEqual(decoder.decodeCalls, 1)
    }

    func testAudioPlaybackRejectsOversizedChunkBeforeDecode() throws {
        let decoder = RecordingAudioSampleDecoder(decodedSamples: DecodedAudioSamples(samples: [0.1], sampleRate: 24_000))
        let controller = AudioPlaybackController(
            sessionManager: RecordingAudioSessionManager(),
            playerFactory: RecordingAudioPlayerFactory(),
            sampleDecoder: decoder,
            limits: AudioPlaybackLimits(maxChunkCount: 4, maxChunkBytes: 2, maxEncodedBytes: 4)
        )

        XCTAssertThrowsError(try controller.appendChunk(audioID: "audio-too-large-chunk", chunkIndex: 0, base64: Data([1, 2, 3]).base64EncodedString())) { error in
            XCTAssertEqual(error as? AudioPlaybackError, .chunkTooLarge)
        }
        XCTAssertEqual(decoder.decodeCalls, 0)
    }

    func testAudioPlaybackRejectsEncodedAudioOverTotalLimit() throws {
        let decoder = RecordingAudioSampleDecoder(decodedSamples: DecodedAudioSamples(samples: [0.1], sampleRate: 24_000))
        let controller = AudioPlaybackController(
            sessionManager: RecordingAudioSessionManager(),
            playerFactory: RecordingAudioPlayerFactory(),
            sampleDecoder: decoder,
            limits: AudioPlaybackLimits(maxChunkCount: 4, maxChunkBytes: 4, maxEncodedBytes: 4)
        )
        try controller.appendChunk(audioID: "audio-total-too-large", chunkIndex: 0, base64: Data([1, 2]).base64EncodedString())

        XCTAssertThrowsError(try controller.appendChunk(audioID: "audio-total-too-large", chunkIndex: 1, base64: Data([3, 4, 5]).base64EncodedString())) { error in
            XCTAssertEqual(error as? AudioPlaybackError, .audioTooLarge)
        }
        XCTAssertEqual(decoder.decodeCalls, 0)
    }

    func testAudioPlaybackRejectsSparseChunksOnFinish() throws {
        let factory = RecordingAudioPlayerFactory()
        let controller = AudioPlaybackController(
            sessionManager: RecordingAudioSessionManager(),
            playerFactory: factory,
            sampleDecoder: RecordingAudioSampleDecoder(decodedSamples: DecodedAudioSamples(samples: [0.1], sampleRate: 24_000)),
            limits: AudioPlaybackLimits(maxChunkCount: 8, maxChunkBytes: 8, maxEncodedBytes: 16)
        )
        try controller.appendChunk(audioID: "audio-sparse", chunkIndex: 0, base64: Data([1]).base64EncodedString())
        try controller.appendChunk(audioID: "audio-sparse", chunkIndex: 2, base64: Data([2]).base64EncodedString())

        XCTAssertThrowsError(try controller.finish(audioID: "audio-sparse", expectedChunkCount: 2)) { error in
            XCTAssertEqual(error as? AudioPlaybackError, .missingChunks)
        }
        XCTAssertEqual(factory.player.playCalls, 0)
    }

    func testAudioPlaybackRejectsExtraChunksOnFinish() throws {
        let controller = AudioPlaybackController(
            sessionManager: RecordingAudioSessionManager(),
            playerFactory: RecordingAudioPlayerFactory(),
            sampleDecoder: RecordingAudioSampleDecoder(decodedSamples: DecodedAudioSamples(samples: [0.1], sampleRate: 24_000)),
            limits: AudioPlaybackLimits(maxChunkCount: 8, maxChunkBytes: 8, maxEncodedBytes: 16)
        )
        try controller.appendChunk(audioID: "audio-extra", chunkIndex: 0, base64: Data([1]).base64EncodedString())
        try controller.appendChunk(audioID: "audio-extra", chunkIndex: 1, base64: Data([2]).base64EncodedString())

        XCTAssertThrowsError(try controller.finish(audioID: "audio-extra", expectedChunkCount: 1)) { error in
            XCTAssertEqual(error as? AudioPlaybackError, .missingChunks)
        }
    }

    @MainActor
    func testOversizedInboundFrameIsRejectedBeforeJSONParsing() throws {
        let socket = RecordingWebSocketTask()
        let client = makeSocketBackedClient(socket: socket)
        let previousState = client.connectionState

        let oversizedMessage = String(repeating: "x", count: 2_000_000)
        let frame = """
        {"type":"error","request_id":"oversized-error","payload":{"code":"auth_failed","reason":"invalid_signature","message":"\(oversizedMessage)"}}
        """
        XCTAssertGreaterThan(frame.utf8.count, 2_000_000)

        client.handleFrameString(frame)

        XCTAssertEqual(client.connectionState, previousState)
        XCTAssertNil(client.lastError)
    }

    func testAVAudioFileSampleDecoderDecodesGeneratedMonoWAV() throws {
        let sampleRate = 8_000.0
        let samples = sineWave(frequency: 440, sampleRate: sampleRate, seconds: 0.05)
        let decoder = AVAudioFileSampleDecoder(maxDecodedDuration: 1, maxChannelCount: 1)

        let decoded = try decoder.decodeSamples(from: wavData(samples: samples, sampleRate: Int(sampleRate)))

        XCTAssertEqual(decoded.sampleRate, sampleRate, accuracy: 0.1)
        XCTAssertFalse(decoded.samples.isEmpty)
        XCTAssertGreaterThan(decoded.samples.map(abs).max() ?? 0, 0.1)
    }

    func testAVAudioFileSampleDecoderRejectsExcessiveDecodedDuration() throws {
        let sampleRate = 8_000.0
        let samples = sineWave(frequency: 440, sampleRate: sampleRate, seconds: 0.2)
        let decoder = AVAudioFileSampleDecoder(maxDecodedDuration: 0.1, maxChannelCount: 1)

        XCTAssertThrowsError(try decoder.decodeSamples(from: wavData(samples: samples, sampleRate: Int(sampleRate)))) { error in
            XCTAssertEqual(error as? AudioSampleDecodingError, .tooManyDecodedFrames)
        }
    }

    func testAVAudioFileSampleDecoderCleansStaleTemporaryFiles() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("logos-spectrum-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let staleFile = directory.appendingPathComponent("logos-spectrum-stale.wav")
        try Data([1, 2, 3]).write(to: staleFile)

        _ = AVAudioFileSampleDecoder(temporaryDirectory: directory, maxDecodedDuration: 1, maxChannelCount: 1)

        XCTAssertFalse(FileManager.default.fileExists(atPath: staleFile.path))
        try? FileManager.default.removeItem(at: directory)
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

    private func sineWave(frequency: Float, sampleRate: Double, seconds: Double = 1.0, amplitude: Float = 0.85) -> [Float] {
        let sampleCount = Int(sampleRate * seconds)
        return (0..<sampleCount).map { index in
            amplitude * Float(sin(2 * Double.pi * Double(frequency) * Double(index) / sampleRate))
        }
    }

    private func wavData(samples: [Float], sampleRate: Int) -> Data {
        var data = Data()
        let channelCount: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let byteRate = UInt32(sampleRate) * UInt32(channelCount) * UInt32(bitsPerSample / 8)
        let blockAlign = channelCount * (bitsPerSample / 8)
        let pcmBytes = UInt32(samples.count) * UInt32(blockAlign)

        data.appendASCII("RIFF")
        data.appendLittleEndian(UInt32(36) + pcmBytes)
        data.appendASCII("WAVE")
        data.appendASCII("fmt ")
        data.appendLittleEndian(UInt32(16))
        data.appendLittleEndian(UInt16(1))
        data.appendLittleEndian(channelCount)
        data.appendLittleEndian(UInt32(sampleRate))
        data.appendLittleEndian(byteRate)
        data.appendLittleEndian(blockAlign)
        data.appendLittleEndian(bitsPerSample)
        data.appendASCII("data")
        data.appendLittleEndian(pcmBytes)
        for sample in samples {
            let clamped = max(-1, min(1, sample))
            data.appendLittleEndian(Int16((clamped * Float(Int16.max)).rounded()))
        }
        return data
    }

    @MainActor
    private func waitUntilSpectrumDominantIndex(
        in client: LogosClient,
        isAtMost maximum: Int? = nil,
        isAtLeast minimum: Int? = nil,
        timeout: TimeInterval = 1.0
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        var latestIndex: Int?
        repeat {
            if let bins = client.audioPlaybackOverlay?.spectrumBins {
                let index = try dominantSpectrumIndex(in: bins)
                latestIndex = index
                if let maximum, index <= maximum { return }
                if let minimum, index >= minimum { return }
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        } while Date() < deadline
        XCTFail("Timed out waiting for spectrum dominant index. latest=\(latestIndex.map(String.init) ?? "<none>") max=\(maximum.map(String.init) ?? "<none>") min=\(minimum.map(String.init) ?? "<none>")")
    }

    private func dominantSpectrumIndex(in bins: [Double]) throws -> Int {
        try XCTUnwrap(bins.indices.max(by: { bins[$0] < bins[$1] }))
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

private extension Data {
    mutating func appendASCII(_ string: String) {
        append(Data(string.utf8))
    }

    mutating func appendLittleEndian(_ value: UInt16) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }

    mutating func appendLittleEndian(_ value: UInt32) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }

    mutating func appendLittleEndian(_ value: Int16) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
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

private final class RecordingAudioSampleDecoder: AudioSampleDecoding {
    let decodedSamples: DecodedAudioSamples?
    let error: Error?
    private let lock = NSLock()
    private var _decodeCalls = 0
    var decodeCalls: Int {
        lock.lock()
        defer { lock.unlock() }
        return _decodeCalls
    }

    init(decodedSamples: DecodedAudioSamples? = nil, error: Error? = nil) {
        self.decodedSamples = decodedSamples
        self.error = error
    }

    func decodeSamples(from data: Data) throws -> DecodedAudioSamples {
        lock.lock()
        _decodeCalls += 1
        lock.unlock()
        if let error {
            throw error
        }
        if let decodedSamples {
            return decodedSamples
        }
        throw RecordingAudioSampleDecoderError()
    }
}

private struct RecordingAudioSampleDecoderError: LocalizedError {
    var errorDescription: String? {
        "decode failed"
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
    staleTimeoutInterval: TimeInterval = 45
) -> LogosClient {
    let client = LogosClient(
        store: store ?? SQLiteMessageStore(filename: "LogosTests-\(UUID().uuidString).sqlite3"),
        socketFactory: RecordingWebSocketTaskFactory(socket: socket),
        audioPlayback: audioPlayback,
        staleTimeoutInterval: staleTimeoutInterval
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
