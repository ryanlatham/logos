import XCTest
import AVFoundation
@testable import Logos

@MainActor
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

    func testSlashCommandCatalogDecodesRanksAndReplacesCommands() throws {
        let catalog = try XCTUnwrap(SlashCommandCatalog.from(dictionary: [
            "schema_version": 1,
            "catalog_version": "v-test",
            "generated_at": "2026-05-27T00:00:00Z",
            "fallback_used": false,
            "warnings": [],
            "commands": [
                [
                    "id": "builtin:resume",
                    "trigger": "/resume",
                    "canonical": "/resume",
                    "aliases": [],
                    "description": "Resume a named session",
                    "category": "Session",
                    "args_hint": "[name]",
                    "subcommands": [],
                    "source": "builtin",
                    "available": true,
                    "unavailable_reason": "",
                    "requires_args": false,
                    "adds_trailing_space": true,
                    "deprecated": false
                ],
                [
                    "id": "builtin:queue",
                    "trigger": "/queue",
                    "canonical": "/queue",
                    "aliases": ["/q"],
                    "description": "Queue a prompt",
                    "category": "Session",
                    "args_hint": "<prompt>",
                    "subcommands": [],
                    "source": "builtin",
                    "available": true,
                    "unavailable_reason": "",
                    "requires_args": true,
                    "adds_trailing_space": true,
                    "deprecated": false
                ],
                [
                    "id": "builtin:sessions",
                    "trigger": "/sessions",
                    "canonical": "/sessions",
                    "aliases": [],
                    "description": "Browse sessions",
                    "category": "Session",
                    "args_hint": "",
                    "subcommands": [],
                    "source": "builtin",
                    "available": false,
                    "unavailable_reason": "not available in Logos",
                    "requires_args": false,
                    "adds_trailing_space": false,
                    "deprecated": false
                ]
            ]
        ]))

        XCTAssertEqual(catalog.catalogVersion, "v-test")
        XCTAssertEqual(catalog.commands.count, 3)
        XCTAssertEqual(catalog.rankedCommands(for: "/res", recents: []).first?.canonical, "/resume")
        XCTAssertEqual(catalog.rankedCommands(for: "/q", recents: []).first?.canonical, "/queue")
        XCTAssertEqual(catalog.rankedCommands(for: "/", recents: ["/queue"]).first?.canonical, "/queue")
        XCTAssertEqual(catalog.replacementText(for: try XCTUnwrap(catalog.command(canonical: "/resume"))), "/resume ")
        XCTAssertEqual(catalog.replacementText(for: try XCTUnwrap(catalog.command(canonical: "/sessions"))), "/sessions")
        XCTAssertEqual(catalog.rankedCommands(for: "/zzz", recents: []).count, 0)
    }

    func testSlashCommandCompletionResultDecodesAbsoluteReplacement() throws {
        let result = try XCTUnwrap(SlashCommandCompletionResult.from(dictionary: [
            "catalog_version": "v-test",
            "fallback_used": false,
            "warnings": [],
            "items": [
                [
                    "canonical": "/resume",
                    "replacement_text": "/resume ",
                    "replacement_start": 0,
                    "replacement_end": 4,
                    "display": "/resume",
                    "detail": "[name]",
                    "kind": "command",
                    "adds_trailing_space": true
                ]
            ]
        ]))

        XCTAssertEqual(result.catalogVersion, "v-test")
        XCTAssertEqual(result.items.first?.replacementText, "/resume ")
        XCTAssertEqual(result.items.first?.replacementStart, 0)
        XCTAssertEqual(result.items.first?.replacementEnd, 4)
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
        XCTAssertNotEqual(base, makeThreadTimelineSnapshot(focusRequest: .init(id: "focus-1", targetMessageID: "session:final")))
        XCTAssertNotEqual(base, makeThreadTimelineSnapshot(slashCommandMenuState: "browsing"))
        XCTAssertNotEqual(base, makeThreadTimelineSnapshot(slashCommandCatalogFingerprint: "commands-v2"))
        XCTAssertNotEqual(base, makeThreadTimelineSnapshot(slashCommandMenuHeight: 236))
    }

    func testSlashCommandMenuChromeDoesNotChangeThreadContentFingerprint() {
        let base = makeThreadTimelineSnapshot()

        XCTAssertEqual(base.contentFingerprint, makeThreadTimelineSnapshot(slashCommandMenuState: "browsing").contentFingerprint)
        XCTAssertEqual(base.contentFingerprint, makeThreadTimelineSnapshot(slashCommandCatalogFingerprint: "commands-v2").contentFingerprint)
        XCTAssertEqual(base.contentFingerprint, makeThreadTimelineSnapshot(slashCommandMenuHeight: 236).contentFingerprint)
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
        runStatus: String = "running",
        focusRequest: ThreadTimelineSnapshot.FocusRequest? = nil,
        slashCommandMenuState: String = "inactive",
        slashCommandCatalogFingerprint: String = "none",
        slashCommandMenuHeight: CGFloat = 0
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
            runStatus: runStatus,
            focusRequest: focusRequest,
            slashCommandMenuState: slashCommandMenuState,
            slashCommandCatalogFingerprint: slashCommandCatalogFingerprint,
            slashCommandMenuHeight: slashCommandMenuHeight
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

    func testGatewayErrorStatusTextIsProgressEvenWithLegacyFinalMetadata() throws {
        let retryStatus = try XCTUnwrap(LogosMessage.from(dictionary: [
            "project_key": "alpha",
            "session_id": "sess-alpha",
            "message_id": "m-retry-status",
            "server_seq": 10,
            "role": "assistant",
            "content": "⚠️ Non-retryable error (HTTP None) — trying fallback...",
            "timestamp": 126.0,
            "metadata": [
                "finalized": true,
                "source": "hermes",
                "request_id": "req-error"
            ]
        ]))
        XCTAssertTrue(retryStatus.isProgressUpdate)
        XCTAssertEqual(retryStatus.gatewayProgressKind, "gateway_status")

        let terminalStatus = try XCTUnwrap(LogosMessage.from(dictionary: [
            "project_key": "alpha",
            "session_id": "sess-alpha",
            "message_id": "m-terminal-status",
            "server_seq": 11,
            "role": "assistant",
            "content": "❌ Non-retryable error (HTTP None): 'NoneType' object is not iterable",
            "timestamp": 127.0,
            "metadata": [
                "finalized": true,
                "source": "hermes",
                "request_id": "req-error"
            ]
        ]))
        XCTAssertTrue(terminalStatus.isProgressUpdate)
        XCTAssertEqual(terminalStatus.gatewayProgressKind, "gateway_status")
    }

    func testReadableErrorFinalMetadataMarksMessageFailedButNotProgress() throws {
        let message = try XCTUnwrap(LogosMessage.from(dictionary: [
            "project_key": "alpha",
            "session_id": "sess-alpha",
            "message_id": "m-readable-error",
            "server_seq": 12,
            "role": "assistant",
            "content": "Hermes hit an unrecoverable error before it could answer.",
            "timestamp": 128.0,
            "metadata": [
                "finalized": true,
                "source": "hermes_error",
                "final_status": "failed",
                "error": true,
                "request_id": "req-error"
            ]
        ]))

        XCTAssertFalse(message.isProgressUpdate)
        XCTAssertTrue(message.isFinal)
        XCTAssertEqual(message.metadataSource, "hermes_error")
        XCTAssertEqual(message.metadataFinalStatus, "failed")
        XCTAssertTrue(message.metadataIsError)
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

    func testSQLiteMessageStoreLoadsLatestMessagesInAscendingOrder() throws {
        let store = SQLiteMessageStore(filename: "LogosTests-\(UUID().uuidString).sqlite3")
        for index in 1...150 {
            store.upsert(LogosMessage(
                projectKey: "default",
                sessionID: "session-history",
                messageID: "message-\(index)",
                serverSeq: index,
                role: "assistant",
                content: "Message \(index)",
                timestamp: TimeInterval(index),
                status: "persisted"
            ))
        }

        let loaded = store.loadMessages(projectKey: "default", limit: 100)

        XCTAssertEqual(loaded.map(\.serverSeq), Array(51...150))
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
        await yieldUntil { socket.sentMessages.isEmpty == false }

        XCTAssertEqual(try socket.sentMessages.map { try frameType(from: $0) }, ["hello"])
        XCTAssertEqual(client.connectionState, .connecting)

        await client.handleFrameString(#"{"type":"hello","request_id":"hello-1","payload":{"authenticated":true}}"#)

        XCTAssertEqual(client.connectionState, .connected)
        XCTAssertEqual(try socket.sentMessages.map { try frameType(from: $0) }, [
            "hello",
            "register_device",
            "list_projects"
        ])
    }

    @MainActor
    func testCommandCatalogRequestAndStaleResponseHandling() async throws {
        let socket = RecordingWebSocketTask()
        let client = await makeSocketBackedClient(socket: socket)

        let __sendResult1 = await client.requestCommandCatalog()
        XCTAssertTrue(__sendResult1)
        let requestFrame = try frameRoot(from: try XCTUnwrap(socket.sentMessages.last))
        let requestID = try XCTUnwrap(requestFrame["request_id"] as? String)
        XCTAssertEqual(requestFrame["type"] as? String, "commands_get")

        await client.handleFrameString(#"""
        {"type":"commands_list","request_id":"stale-catalog","payload":{"schema_version":1,"catalog_version":"old","generated_at":"2026-05-27T00:00:00Z","fallback_used":false,"warnings":[],"commands":[]}}
        """#)
        XCTAssertNotEqual(client.slashCommandCatalog.catalogVersion, "old")

        await client.handleFrameString("""
        {"type":"commands_list","request_id":"\(requestID)","payload":{"schema_version":1,"catalog_version":"fresh","generated_at":"2026-05-27T00:00:00Z","fallback_used":false,"warnings":[],"commands":[{"id":"builtin:resume","trigger":"/resume","canonical":"/resume","aliases":[],"description":"Resume","category":"Session","args_hint":"[name]","subcommands":[],"source":"builtin","available":true,"unavailable_reason":"","requires_args":false,"adds_trailing_space":true,"deprecated":false}]}}
        """)

        XCTAssertEqual(client.slashCommandCatalog.catalogVersion, "fresh")
        XCTAssertEqual(client.slashCommandCatalog.commands.first?.canonical, "/resume")
    }

    @MainActor
    func testCommandCompletionRequestAndStaleResponseHandling() async throws {
        let socket = RecordingWebSocketTask()
        let client = await makeSocketBackedClient(socket: socket)

        let __sendResult2 = await client.requestSlashCommandCompletion(text: "/res")
        XCTAssertTrue(__sendResult2)
        let requestFrame = try frameRoot(from: try XCTUnwrap(socket.sentMessages.last))
        let requestID = try XCTUnwrap(requestFrame["request_id"] as? String)
        XCTAssertEqual(requestFrame["type"] as? String, "commands_complete")

        await client.handleFrameString(#"""
        {"type":"commands_complete_result","request_id":"stale-completion","payload":{"catalog_version":"v1","fallback_used":false,"warnings":[],"items":[{"canonical":"/wrong","replacement_text":"/wrong","replacement_start":0,"replacement_end":4,"display":"/wrong","detail":"","kind":"command","adds_trailing_space":false}]}}
        """#)
        XCTAssertTrue(client.slashCommandCompletion.items.isEmpty)

        await client.handleFrameString("""
        {"type":"commands_complete_result","request_id":"\(requestID)","payload":{"catalog_version":"v1","fallback_used":false,"warnings":[],"items":[{"canonical":"/resume","replacement_text":"/resume ","replacement_start":0,"replacement_end":4,"display":"/resume","detail":"[name]","kind":"command","adds_trailing_space":true}]}}
        """)

        XCTAssertEqual(client.slashCommandCompletion.items.first?.canonical, "/resume")
        XCTAssertEqual(client.slashCommandCompletion.items.first?.replacementText, "/resume ")
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
        await client.registerDevice(apnsToken: "apns-token")

        XCTAssertEqual(client.connectionState, .connecting)
        XCTAssertNil(client.lastError)
        XCTAssertTrue(socket.sentMessages.isEmpty)

        socket.open()
        await yieldUntil { socket.sentMessages.isEmpty == false }

        XCTAssertEqual(try socket.sentMessages.map { try frameType(from: $0) }, ["hello"])

        await client.handleFrameString(#"{"type":"hello","request_id":"hello-1","payload":{"authenticated":true}}"#)

        XCTAssertEqual(try socket.sentMessages.map { try frameType(from: $0) }, [
            "hello",
            "register_device",
            "list_projects"
        ])
        let registerFrame = try frameRoot(from: socket.sentMessages[1])
        let registerPayload = try XCTUnwrap(registerFrame["payload"] as? [String: Any])
        XCTAssertEqual(registerPayload["apns_token"] as? String, "apns-token")

        await client.handleFrameString(#"{"type":"registered","request_id":"register-1","payload":{"device":{"device_id":"iphone-a","apns_registered":true}}}"#)
        await client.registerDevice(apnsToken: nil)

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
        await yieldUntil { socket.sentMessages.isEmpty == false }

        XCTAssertEqual(try socket.sentMessages.map { try frameType(from: $0) }, ["hello"])

        await socket.receiveString(#"{"type":"error","request_id":"hello-1","project_key":"default","payload":{"code":"auth_failed","reason":"invalid_signature","message":"invalid Logos signed hello: signature mismatch"}}"#)
        await yieldUntil { client.connectionState == .error }

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
        await yieldUntil { client.connectionState == .error }

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
        await yieldUntil { client.connectionState == .error }

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
        await yieldUntil { client.connectionState == .error }
        XCTAssertNotNil(client.connectionRetryState)

        client.connect()
        socket.open()
        await yieldUntil { socket.sentMessages.isEmpty == false }
        await client.handleFrameString(#"{"type":"hello","request_id":"hello-1","payload":{"authenticated":true}}"#)

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
        await yieldUntil { socket.sentMessages.isEmpty == false }
        await client.handleFrameString(#"{"type":"hello","request_id":"hello-1","payload":{"authenticated":true}}"#)
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
        let __sendResult3 = await client.createProject(title: "Still usable")
        XCTAssertTrue(__sendResult3)
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
    func testDisconnectedFinalSpeechReturnsFalseWithoutAppendingPendingMessage() async throws {
        let client = LogosClient()
        client.disconnect()
        let before = client.messages

        let sent = await client.sendSpeech(
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
        let client = await makeSocketBackedClient(socket: socket, store: store)
        let sent = await client.sendSpeech(
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
    func testSuccessfulConnectionMarksFirstConnectionComplete() async throws {
        let socket = RecordingWebSocketTask()
        let client = await makeSocketBackedClient(socket: socket, autoConnect: false)

        XCTAssertTrue(client.settings.hasCompletedFirstConnection)
    }

    @MainActor
    func testFinalSpeechPendingAppearsImmediatelyAfterASRFinalBeforeSocketSendCompletes() async throws {
        let socket = RecordingWebSocketTask()
        let client = await makeSocketBackedClient(socket: socket)
        let sent = await client.sendSpeech(
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

        XCTAssertEqual(client.messages.filter { $0.messageID == "voice-turn-queued" }.count, 1)
        XCTAssertNil(client.undeliveredSpeechDraft)
    }

    @MainActor
    func testTextSendFailureRemovesPendingMessage() async throws {
        let socket = RecordingWebSocketTask()
        let client = await makeSocketBackedClient(socket: socket)

        socket.failNextSend(RecordingSocketError())
        let sent = await client.sendText("this text send will fail")
        XCTAssertTrue(sent)

        XCTAssertFalse(client.messages.contains { $0.content == "this text send will fail" && $0.status == "pending" })
        XCTAssertEqual(client.connectionState, .error)
        XCTAssertNotNil(client.lastError)
    }

    @MainActor
    func testFinalSpeechSocketFailureRestoresUndeliveredDraftWithoutPendingMessage() async throws {
        let socket = RecordingWebSocketTask()
        let client = await makeSocketBackedClient(socket: socket)
        socket.failNextSend(RecordingSocketError())
        let sent = await client.sendSpeech(
            text: "restore this transcript",
            isFinal: true,
            inputID: "voice-turn-failed",
            partialSeq: 2,
            startedAtMilliseconds: 123
        )

        XCTAssertTrue(sent)

        XCTAssertEqual(client.undeliveredSpeechDraft?.id, "voice-turn-failed")
        XCTAssertEqual(client.undeliveredSpeechDraft?.text, "restore this transcript")
        XCTAssertFalse(client.messages.contains { $0.messageID == "voice-turn-failed" })
        XCTAssertEqual(client.connectionState, .error)
    }

    @MainActor
    func testDisconnectRestoresInFlightFinalSpeechDraftBeforeSendCompletion() async throws {
        let socket = RecordingWebSocketTask()
        let client = await makeSocketBackedClient(socket: socket)
        // Park the send so the final-speech draft stays in flight across the disconnect.
        socket.holdNextSends()
        let sendTask = Task { @MainActor in
            await client.sendSpeech(
                text: "save this before disconnect",
                isFinal: true,
                inputID: "voice-turn-disconnect",
                partialSeq: 2,
                startedAtMilliseconds: 123
            )
        }
        while client.messages.contains(where: { $0.messageID == "voice-turn-disconnect" }) == false {
            await Task.yield()
        }

        client.disconnect()
        await Task.yield()

        XCTAssertEqual(client.undeliveredSpeechDraft?.id, "voice-turn-disconnect")
        XCTAssertEqual(client.undeliveredSpeechDraft?.text, "save this before disconnect")
        XCTAssertFalse(client.messages.contains { $0.messageID == "voice-turn-disconnect" })

        // Release the parked send so the suspended task can finish.
        await socket.completeHeldSend(error: nil)
        _ = await sendTask.value
    }

    @MainActor
    func testLateFinalSpeechSendCompletionAfterDisconnectIsIgnored() async throws {
        let socket = RecordingWebSocketTask()
        let client = await makeSocketBackedClient(socket: socket)
        // Park the send so the disconnect happens while it is still in flight; the send then
        // completes (late) on the now-stale connection and must be ignored.
        socket.holdNextSends()
        let sendTask = Task { @MainActor in
            await client.sendSpeech(
                text: "do not resurrect error after disconnect",
                isFinal: true,
                inputID: "voice-turn-late-completion",
                partialSeq: 2,
                startedAtMilliseconds: 123
            )
        }
        while client.messages.contains(where: { $0.messageID == "voice-turn-late-completion" }) == false {
            await Task.yield()
        }

        client.disconnect()
        await Task.yield()
        let restoredReason = client.undeliveredSpeechDraft?.reason

        await socket.completeHeldSend(error: RecordingSocketError())
        _ = await sendTask.value
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

    @MainActor
    func testNotificationCoordinatorReplaysLastRouteWhenHandlerInstalls() throws {
        let coordinator = NotificationCoordinator.shared
        coordinator.onRoute = nil
        defer { coordinator.onRoute = nil }
        let route = LogosNotificationRoute(
            kind: "finished",
            projectKey: "default",
            sessionID: "session-cold-route",
            messageID: "assistant-cold-route-final",
            requestID: "req-cold-route",
            serverSeq: 177
        )

        coordinator.route(route)
        var delivered: LogosNotificationRoute?
        coordinator.onRoute = { delivered = $0 }

        XCTAssertEqual(delivered, route)
        delivered = nil
        coordinator.onRoute = { delivered = $0 }
        XCTAssertNil(delivered)
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

    func testAPNSEnvironmentUsesBuildConfiguration() {
        XCTAssertEqual(LogosAPNSEnvironment.resolved(isDebugBuild: true), "sandbox")
        XCTAssertEqual(LogosAPNSEnvironment.resolved(isDebugBuild: false), "production")
    }

    @MainActor
    func testNotificationRouteDefersMessageFetchUntilAuthenticatedConnection() async throws {
        let socket = RecordingWebSocketTask()
        let client = LogosClient(
            store: SQLiteMessageStore(filename: "LogosTests-\(UUID().uuidString).sqlite3"),
            socketFactory: RecordingWebSocketTaskFactory(socket: socket)
        )
        client.settings.urlString = "ws://127.0.0.1:8765"
        client.settings.secret = "test-secret"

        await client.handleNotificationRoute(LogosNotificationRoute(
            kind: "finished",
            projectKey: "alpha",
            sessionID: "session-alpha",
            messageID: "assistant-alpha-final",
            requestID: nil,
            serverSeq: 42
        ))

        XCTAssertEqual(client.activeProjectKey, "alpha")
        XCTAssertEqual(client.connectionState, .connecting)
        XCTAssertTrue(socket.sentMessages.isEmpty)

        socket.open()
        await yieldUntil { socket.sentMessages.isEmpty == false }

        XCTAssertEqual(try socket.sentMessages.map { try frameType(from: $0) }, ["hello"])

        await client.handleFrameString(#"{"type":"hello","request_id":"hello-alpha","payload":{"authenticated":true}}"#)

        XCTAssertEqual(try socket.sentMessages.map { try frameType(from: $0) }, [
            "hello",
            "register_device",
            "list_projects",
            "messages_get"
        ])
        let fetchFrame = try frameRoot(from: try XCTUnwrap(socket.sentMessages.last))
        XCTAssertEqual(fetchFrame["project_key"] as? String, "alpha")
        let payload = try XCTUnwrap(fetchFrame["payload"] as? [String: Any])
        XCTAssertEqual(payload["after_server_seq"] as? Int, 17)
    }

    @MainActor
    func testFinishedNotificationRouteAutoplaysReplayedFinalOnce() async throws {
        let socket = RecordingWebSocketTask()
        let client = await makeSocketBackedClient(socket: socket)
        let baselineCount = socket.sentMessages.count

        await client.handleNotificationRoute(LogosNotificationRoute(
            kind: "finished",
            projectKey: "default",
            sessionID: "session-notification",
            messageID: "assistant-notification-final",
            requestID: "req-notification",
            serverSeq: 120
        ))

        let fetchFrame = try frameRoot(from: try XCTUnwrap(socket.sentMessages.last))
        XCTAssertEqual(fetchFrame["type"] as? String, "messages_get")
        XCTAssertEqual(fetchFrame["project_key"] as? String, "default")
        XCTAssertEqual((try XCTUnwrap(fetchFrame["payload"] as? [String: Any]))["after_server_seq"] as? Int, 95)

        await client.handleFrameString(#"""
        {"type":"messages_batch","request_id":"messages-get-notification","project_key":"default","session_id":"session-notification","payload":{"messages":[{"project_key":"default","session_id":"session-notification","message_id":"user-notification-prompt","server_seq":119,"role":"user","content":"Notification prompt context.","timestamp":122.0,"metadata":{"request_id":"req-notification"}},{"project_key":"default","session_id":"session-notification","message_id":"assistant-notification-final","server_seq":120,"role":"assistant","content":"Notification final response.","timestamp":123.0,"metadata":{"finalized":true,"source":"hermes","request_id":"req-notification"}}]}}
        """#)

        var newFrames = try socket.sentMessages.dropFirst(baselineCount).map { try frameRoot(from: $0) }
        var playbackFrames = newFrames.filter { $0["type"] as? String == "playback_audio" }
        XCTAssertEqual(playbackFrames.count, 1)
        XCTAssertEqual(playbackFrames.first?["project_key"] as? String, "default")
        XCTAssertEqual(playbackFrames.first?["session_id"] as? String, "session-notification")
        let playbackPayload = try XCTUnwrap(playbackFrames.first?["payload"] as? [String: Any])
        XCTAssertEqual(playbackPayload["message_id"] as? String, "assistant-notification-final")
        XCTAssertEqual(playbackPayload["mode"] as? String, "final_auto")
        XCTAssertEqual(playbackPayload["text"] as? String, "Notification final response.")
        XCTAssertEqual(client.messages.filter { $0.messageID == "user-notification-prompt" }.count, 1)
        XCTAssertEqual(client.messages.filter { $0.messageID == "assistant-notification-final" }.count, 1)
        XCTAssertEqual(client.threadFocusRequest?.targetMessageID, "session-notification:assistant-notification-final")
        XCTAssertEqual(client.threadFocusRequest?.reason, .finishedNotification)

        await client.handleFrameString(#"""
        {"type":"messages_batch","request_id":"messages-get-notification","project_key":"default","session_id":"session-notification","payload":{"messages":[{"project_key":"default","session_id":"session-notification","message_id":"assistant-notification-final","server_seq":120,"role":"assistant","content":"Notification final response.","timestamp":123.0,"metadata":{"finalized":true,"source":"hermes","request_id":"req-notification"}}]}}
        """#)

        newFrames = try socket.sentMessages.dropFirst(baselineCount).map { try frameRoot(from: $0) }
        playbackFrames = newFrames.filter { $0["type"] as? String == "playback_audio" }
        XCTAssertEqual(playbackFrames.count, 1)
    }

    @MainActor
    func testFinishedNotificationRouteAutoplaysCachedFinalOnce() async throws {
        let socket = RecordingWebSocketTask()
        let store = SQLiteMessageStore(filename: "LogosTests-\(UUID().uuidString).sqlite3")
        let cachedMessage = try XCTUnwrap(LogosMessage.from(dictionary: [
            "project_key": "default",
            "session_id": "session-cached-notification",
            "message_id": "assistant-cached-notification-final",
            "server_seq": 222,
            "role": "assistant",
            "content": "Cached notification response.",
            "timestamp": 123.0,
            "metadata": ["finalized": true, "source": "hermes"]
        ]))
        store.upsert(cachedMessage)
        let client = await makeSocketBackedClient(socket: socket, store: store)
        let baselineCount = socket.sentMessages.count

        await client.handleNotificationRoute(LogosNotificationRoute(
            kind: "finished",
            projectKey: "default",
            sessionID: "session-cached-notification",
            messageID: "assistant-cached-notification-final",
            requestID: nil,
            serverSeq: 222
        ))

        let newFrames = try socket.sentMessages.dropFirst(baselineCount).map { try frameRoot(from: $0) }
        let playbackFrames = newFrames.filter { $0["type"] as? String == "playback_audio" }
        XCTAssertEqual(playbackFrames.count, 1)
        XCTAssertEqual((try XCTUnwrap(playbackFrames.first?["payload"] as? [String: Any]))["message_id"] as? String, "assistant-cached-notification-final")
        XCTAssertEqual(client.threadFocusRequest?.targetMessageID, "session-cached-notification:assistant-cached-notification-final")
        XCTAssertEqual(client.threadFocusRequest?.reason, .finishedNotification)
        let focusID = client.threadFocusRequest?.id

        await client.handleNotificationRoute(LogosNotificationRoute(
            kind: "finished",
            projectKey: "default",
            sessionID: "session-cached-notification",
            messageID: "assistant-cached-notification-final",
            requestID: nil,
            serverSeq: 222
        ))

        let afterDuplicateFrames = try socket.sentMessages.dropFirst(baselineCount).map { try frameRoot(from: $0) }
        XCTAssertEqual(afterDuplicateFrames.filter { $0["type"] as? String == "playback_audio" }.count, 1)
        XCTAssertEqual(client.threadFocusRequest?.id, focusID)
    }

    @MainActor
    func testFinishedNotificationRouteFindsFinalPastOldLocalRows() async throws {
        let socket = RecordingWebSocketTask()
        let store = SQLiteMessageStore(filename: "LogosTests-\(UUID().uuidString).sqlite3")
        for index in 1...550 {
            store.upsert(LogosMessage(
                projectKey: "default",
                sessionID: "session-long-history",
                messageID: "assistant-old-\(index)",
                serverSeq: index,
                role: "assistant",
                content: "Old response \(index).",
                timestamp: TimeInterval(index),
                status: "persisted",
                isFinal: true,
                hasFinalizedMetadata: true,
                metadataSource: "hermes"
            ))
        }
        store.upsert(LogosMessage(
            projectKey: "default",
            sessionID: "session-long-history",
            messageID: "assistant-notified-final",
            serverSeq: 551,
            role: "assistant",
            content: "The notified final response.",
            timestamp: 551,
            status: "persisted",
            isFinal: true,
            hasFinalizedMetadata: true,
            metadataSource: "hermes",
            metadataRequestID: "req-notified-final"
        ))
        let client = await makeSocketBackedClient(socket: socket, store: store)
        let baselineCount = socket.sentMessages.count

        await client.handleNotificationRoute(LogosNotificationRoute(
            kind: "finished",
            projectKey: "default",
            sessionID: "session-long-history",
            messageID: "assistant-notified-final",
            requestID: "req-notified-final",
            serverSeq: 551
        ))

        let newFrames = try socket.sentMessages.dropFirst(baselineCount).map { try frameRoot(from: $0) }
        let playbackFrames = newFrames.filter { $0["type"] as? String == "playback_audio" }
        XCTAssertEqual(playbackFrames.count, 1)
        let playbackPayload = try XCTUnwrap(playbackFrames.first?["payload"] as? [String: Any])
        XCTAssertEqual(playbackPayload["message_id"] as? String, "assistant-notified-final")
        XCTAssertTrue(client.messages.contains { $0.messageID == "assistant-notified-final" })
        XCTAssertEqual(client.threadFocusRequest?.targetMessageID, "session-long-history:assistant-notified-final")
    }

    @MainActor
    func testFinishedNotificationRouteAnchorsCachedFinalOutsideLatestWindow() async throws {
        let socket = RecordingWebSocketTask()
        let store = SQLiteMessageStore(filename: "LogosTests-\(UUID().uuidString).sqlite3")
        store.upsert(LogosMessage(
            projectKey: "default",
            sessionID: "session-anchor-cached",
            messageID: "assistant-anchor-cached-final",
            serverSeq: 10,
            role: "assistant",
            content: "Older cached final response.",
            timestamp: 10,
            status: "persisted",
            isFinal: true,
            hasFinalizedMetadata: true,
            metadataSource: "hermes",
            metadataRequestID: "req-anchor-cached"
        ))
        for index in 11...150 {
            store.upsert(LogosMessage(
                projectKey: "default",
                sessionID: "session-anchor-cached",
                messageID: "assistant-newer-\(index)",
                serverSeq: index,
                role: "assistant",
                content: "Newer response \(index).",
                timestamp: TimeInterval(index),
                status: "persisted",
                isFinal: true,
                hasFinalizedMetadata: true,
                metadataSource: "hermes"
            ))
        }
        let client = await makeSocketBackedClient(socket: socket, store: store)
        XCTAssertFalse(client.messages.contains { $0.messageID == "assistant-anchor-cached-final" })
        let baselineCount = socket.sentMessages.count

        await client.handleNotificationRoute(LogosNotificationRoute(
            kind: "finished",
            projectKey: "default",
            sessionID: "session-anchor-cached",
            messageID: "assistant-anchor-cached-final",
            requestID: "req-anchor-cached",
            serverSeq: 10
        ))

        let newFrames = try socket.sentMessages.dropFirst(baselineCount).map { try frameRoot(from: $0) }
        XCTAssertEqual(newFrames.filter { $0["type"] as? String == "playback_audio" }.count, 1)
        XCTAssertEqual(client.messages.filter { $0.messageID == "assistant-anchor-cached-final" }.count, 1)
        XCTAssertEqual(client.threadFocusRequest?.targetMessageID, "session-anchor-cached:assistant-anchor-cached-final")
    }

    @MainActor
    func testFinishedNotificationRouteAnchorsReplayedFinalOutsideLatestWindow() async throws {
        let socket = RecordingWebSocketTask()
        let store = SQLiteMessageStore(filename: "LogosTests-\(UUID().uuidString).sqlite3")
        for index in 11...150 {
            store.upsert(LogosMessage(
                projectKey: "default",
                sessionID: "session-anchor-replayed",
                messageID: "assistant-newer-replayed-\(index)",
                serverSeq: index,
                role: "assistant",
                content: "Newer replay response \(index).",
                timestamp: TimeInterval(index),
                status: "persisted",
                isFinal: true,
                hasFinalizedMetadata: true,
                metadataSource: "hermes"
            ))
        }
        let client = await makeSocketBackedClient(socket: socket, store: store)
        let baselineCount = socket.sentMessages.count

        await client.handleNotificationRoute(LogosNotificationRoute(
            kind: "finished",
            projectKey: "default",
            sessionID: "session-anchor-replayed",
            messageID: "assistant-anchor-replayed-final",
            requestID: "req-anchor-replayed",
            serverSeq: 10
        ))
        await client.handleFrameString(#"""
        {"type":"messages_batch","request_id":"messages-get-anchor-replayed","project_key":"default","session_id":"session-anchor-replayed","payload":{"messages":[{"project_key":"default","session_id":"session-anchor-replayed","message_id":"assistant-anchor-replayed-final","server_seq":10,"role":"assistant","content":"Older replayed final response.","timestamp":10.0,"metadata":{"finalized":true,"source":"hermes","request_id":"req-anchor-replayed"}}]}}
        """#)

        let newFrames = try socket.sentMessages.dropFirst(baselineCount).map { try frameRoot(from: $0) }
        XCTAssertEqual(newFrames.filter { $0["type"] as? String == "playback_audio" }.count, 1)
        XCTAssertEqual(client.messages.filter { $0.messageID == "assistant-anchor-replayed-final" }.count, 1)
        XCTAssertEqual(client.threadFocusRequest?.targetMessageID, "session-anchor-replayed:assistant-anchor-replayed-final")
        let focusID = client.threadFocusRequest?.id

        await client.handleNotificationRoute(LogosNotificationRoute(
            kind: "finished",
            projectKey: "default",
            sessionID: "session-anchor-replayed",
            messageID: "assistant-anchor-replayed-final",
            requestID: "req-anchor-replayed",
            serverSeq: 10
        ))

        let afterDuplicateFrames = try socket.sentMessages.dropFirst(baselineCount).map { try frameRoot(from: $0) }
        XCTAssertEqual(afterDuplicateFrames.filter { $0["type"] as? String == "playback_audio" }.count, 1)
        XCTAssertEqual(client.messages.filter { $0.messageID == "assistant-anchor-replayed-final" }.count, 1)
        XCTAssertEqual(client.threadFocusRequest?.id, focusID)
    }

    @MainActor
    func testFinishedNotificationReplayedFinalCompletesActiveProgressAndStaysVisible() async throws {
        let socket = RecordingWebSocketTask()
        let store = SQLiteMessageStore(filename: "LogosTests-\(UUID().uuidString).sqlite3")
        for index in 11...150 {
            store.upsert(LogosMessage(
                projectKey: "default",
                sessionID: "session-anchor-active",
                messageID: "assistant-newer-active-\(index)",
                serverSeq: index,
                role: "assistant",
                content: "Newer active response \(index).",
                timestamp: TimeInterval(index),
                status: "persisted",
                isFinal: true,
                hasFinalizedMetadata: true,
                metadataSource: "hermes"
            ))
        }
        let client = await makeSocketBackedClient(socket: socket, store: store)
        let __sendResult4 = await client.sendText("finish from notification while backgrounded")
        XCTAssertTrue(__sendResult4)
        let textFrame = try frameRoot(from: try XCTUnwrap(socket.sentMessages.last))
        let requestID = try XCTUnwrap(textFrame["request_id"] as? String)
        let baselineCount = socket.sentMessages.count

        await client.handleNotificationRoute(LogosNotificationRoute(
            kind: "finished",
            projectKey: "default",
            sessionID: "session-anchor-active",
            messageID: "assistant-anchor-active-final",
            requestID: requestID,
            serverSeq: 10
        ))
        await client.handleFrameString("""
        {"type":"messages_batch","request_id":"messages-get-anchor-active","project_key":"default","session_id":"session-anchor-active","payload":{"messages":[{"project_key":"default","session_id":"session-anchor-active","message_id":"assistant-anchor-active-final","server_seq":10,"role":"assistant","content":"Older active final response.","timestamp":10.0,"metadata":{"finalized":true,"source":"hermes","request_id":"\(requestID)"}}]}}
        """)

        let newFrames = try socket.sentMessages.dropFirst(baselineCount).map { try frameRoot(from: $0) }
        XCTAssertEqual(newFrames.filter { $0["type"] as? String == "playback_audio" }.count, 1)
        XCTAssertEqual(client.progressActivity?.isComplete, true)
        XCTAssertEqual(client.progressActivity?.finalStatus, .complete)
        XCTAssertEqual(client.progressActivity?.completedFinalMessageID, "session-anchor-active:assistant-anchor-active-final")
        XCTAssertEqual(client.messages.filter { $0.messageID == "assistant-anchor-active-final" }.count, 1)
        XCTAssertEqual(client.threadFocusRequest?.targetMessageID, "session-anchor-active:assistant-anchor-active-final")
    }

    @MainActor
    func testFinishedNotificationAutoplayWaitsUntilSceneIsActive() async throws {
        let socket = RecordingWebSocketTask()
        let client = await makeSocketBackedClient(socket: socket)
        await client.updateSceneActivationForPlayback(isActive: false)
        let baselineCount = socket.sentMessages.count

        await client.handleNotificationRoute(LogosNotificationRoute(
            kind: "finished",
            projectKey: "default",
            sessionID: "session-inactive-notification",
            messageID: "assistant-inactive-notification-final",
            requestID: "req-inactive-notification",
            serverSeq: 180
        ))
        await client.handleFrameString(#"""
        {"type":"messages_batch","request_id":"messages-get-inactive","project_key":"default","session_id":"session-inactive-notification","payload":{"messages":[{"project_key":"default","session_id":"session-inactive-notification","message_id":"assistant-inactive-notification-final","server_seq":180,"role":"assistant","content":"Notification final while inactive.","timestamp":180.0,"metadata":{"finalized":true,"source":"hermes","request_id":"req-inactive-notification"}}]}}
        """#)

        var newFrames = try socket.sentMessages.dropFirst(baselineCount).map { try frameRoot(from: $0) }
        XCTAssertTrue(newFrames.filter { $0["type"] as? String == "playback_audio" }.isEmpty)

        await client.updateSceneActivationForPlayback(isActive: true)
        await Task.yield()

        newFrames = try socket.sentMessages.dropFirst(baselineCount).map { try frameRoot(from: $0) }
        let playbackFrames = newFrames.filter { $0["type"] as? String == "playback_audio" }
        XCTAssertEqual(playbackFrames.count, 1)
        let playbackPayload = try XCTUnwrap(playbackFrames.first?["payload"] as? [String: Any])
        XCTAssertEqual(playbackPayload["message_id"] as? String, "assistant-inactive-notification-final")
    }

    @MainActor
    func testLiveFinalAutoplayWaitsUntilSceneIsActive() async throws {
        let socket = RecordingWebSocketTask()
        let client = await makeSocketBackedClient(socket: socket)
        await client.updateSceneActivationForPlayback(isActive: false)
        let baselineCount = socket.sentMessages.count

        let __sendResult5 = await client.sendText("finish while inactive")
        XCTAssertTrue(__sendResult5)
        let textFrame = try frameRoot(from: try XCTUnwrap(socket.sentMessages.last))
        let requestID = try XCTUnwrap(textFrame["request_id"] as? String)
        await client.handleFrameString("""
        {"type":"state_update","request_id":"\(requestID)","project_key":"default","session_id":"session-live-inactive","payload":{"op":"message_appended","message":{"project_key":"default","session_id":"session-live-inactive","message_id":"assistant-live-inactive-final","server_seq":181,"role":"assistant","content":"Live final while inactive.","timestamp":181.0,"metadata":{"finalized":true,"source":"hermes","request_id":"\(requestID)"}}}}
        """)

        var newFrames = try socket.sentMessages.dropFirst(baselineCount).map { try frameRoot(from: $0) }
        XCTAssertTrue(newFrames.filter { $0["type"] as? String == "playback_audio" }.isEmpty)

        await client.updateSceneActivationForPlayback(isActive: true)
        await Task.yield()

        newFrames = try socket.sentMessages.dropFirst(baselineCount).map { try frameRoot(from: $0) }
        let playbackFrames = newFrames.filter { $0["type"] as? String == "playback_audio" }
        XCTAssertEqual(playbackFrames.count, 1)
        let playbackPayload = try XCTUnwrap(playbackFrames.first?["payload"] as? [String: Any])
        XCTAssertEqual(playbackPayload["message_id"] as? String, "assistant-live-inactive-final")
        XCTAssertEqual(playbackPayload["mode"] as? String, "final_auto")
    }

    @MainActor
    func testFinishedNotificationPlaybackSendFailureAllowsRouteRetry() async throws {
        let socket = RecordingWebSocketTask()
        let client = await makeSocketBackedClient(socket: socket)
        let route = LogosNotificationRoute(
            kind: "finished",
            projectKey: "default",
            sessionID: "session-notification-retry",
            messageID: "assistant-notification-retry-final",
            requestID: "req-notification-retry",
            serverSeq: 181
        )
        let finalBatch = #"""
        {"type":"messages_batch","request_id":"messages-get-retry","project_key":"default","session_id":"session-notification-retry","payload":{"messages":[{"project_key":"default","session_id":"session-notification-retry","message_id":"assistant-notification-retry-final","server_seq":181,"role":"assistant","content":"Notification final for retry.","timestamp":181.0,"metadata":{"finalized":true,"source":"hermes","request_id":"req-notification-retry"}}]}}
        """#
        let baselineCount = socket.sentMessages.count

        await client.handleNotificationRoute(route)
        // Fail the playback send so the auto-play / route keys are released for retry.
        socket.failNextSend(RecordingSocketError())
        await client.handleFrameString(finalBatch)
        var newFrames = try socket.sentMessages.dropFirst(baselineCount).map { try frameRoot(from: $0) }
        XCTAssertEqual(newFrames.filter { $0["type"] as? String == "playback_audio" }.count, 1)

        await client.handleNotificationRoute(route)
        socket.open()
        let helloCount = socket.sentMessages.count
        await yieldUntil { socket.sentMessages.count > helloCount }
        await client.handleFrameString(#"{"type":"hello","request_id":"hello-retry","payload":{}}"#)
        await yieldUntil {
            (try? socket.sentMessages.dropFirst(baselineCount).map { try frameRoot(from: $0) }
                .filter { $0["type"] as? String == "playback_audio" }.count) == 2
        }
        newFrames = try socket.sentMessages.dropFirst(baselineCount).map { try frameRoot(from: $0) }
        XCTAssertEqual(newFrames.filter { $0["type"] as? String == "playback_audio" }.count, 2)
    }

    @MainActor
    func testFinishedNotificationPlaybackStreamFailureAllowsRouteRetry() async throws {
        let socket = RecordingWebSocketTask()
        let session = RecordingAudioSessionManager()
        session.preparePlaybackError = RecordingAudioSessionError()
        let controller = AudioPlaybackController(
            sessionManager: session,
            playerFactory: RecordingAudioPlayerFactory()
        )
        let client = await makeSocketBackedClient(socket: socket, audioPlayback: controller)
        let route = LogosNotificationRoute(
            kind: "finished",
            projectKey: "default",
            sessionID: "session-notification-stream-retry",
            messageID: "assistant-notification-stream-retry-final",
            requestID: "req-notification-stream-retry",
            serverSeq: 182
        )
        let finalBatch = #"""
        {"type":"messages_batch","request_id":"messages-get-stream-retry","project_key":"default","session_id":"session-notification-stream-retry","payload":{"messages":[{"project_key":"default","session_id":"session-notification-stream-retry","message_id":"assistant-notification-stream-retry-final","server_seq":182,"role":"assistant","content":"Notification final for stream retry.","timestamp":182.0,"metadata":{"finalized":true,"source":"hermes","request_id":"req-notification-stream-retry"}}]}}
        """#
        let baselineCount = socket.sentMessages.count

        await client.handleNotificationRoute(route)
        await client.handleFrameString(finalBatch)
        var newFrames = try socket.sentMessages.dropFirst(baselineCount).map { try frameRoot(from: $0) }
        var playbackFrames = newFrames.filter { $0["type"] as? String == "playback_audio" }
        XCTAssertEqual(playbackFrames.count, 1)
        let firstPayload = try XCTUnwrap(playbackFrames.first?["payload"] as? [String: Any])
        let audioID = try XCTUnwrap(firstPayload["audio_id"] as? String)

        await client.handleFrameString("""
        {"type":"audio_chunk","device_id":"ios-simulator","project_key":"default","session_id":"session-notification-stream-retry","payload":{"audio_id":"\(audioID)","message_id":"assistant-notification-stream-retry-final","chunk_index":0,"data":"\(Data([1, 2, 3]).base64EncodedString())"}}
        """)
        await client.handleFrameString("""
        {"type":"audio_end","device_id":"ios-simulator","project_key":"default","session_id":"session-notification-stream-retry","payload":{"audio_id":"\(audioID)","message_id":"assistant-notification-stream-retry-final","chunk_count":1}}
        """)
        XCTAssertEqual(client.audioPlaybackOverlay?.phase, .failed)

        await client.handleNotificationRoute(route)
        newFrames = try socket.sentMessages.dropFirst(baselineCount).map { try frameRoot(from: $0) }
        playbackFrames = newFrames.filter { $0["type"] as? String == "playback_audio" }
        XCTAssertEqual(playbackFrames.count, 2)
    }

    @MainActor
    func testApprovalNotificationRouteFetchesWithoutAutoplay() async throws {
        let socket = RecordingWebSocketTask()
        let client = await makeSocketBackedClient(socket: socket)
        let baselineCount = socket.sentMessages.count

        await client.handleNotificationRoute(LogosNotificationRoute(
            kind: "approval",
            projectKey: "default",
            sessionID: "session-approval",
            messageID: nil,
            requestID: "appr-1",
            serverSeq: 9
        ))

        let newFrames = try socket.sentMessages.dropFirst(baselineCount).map { try frameRoot(from: $0) }
        XCTAssertEqual(newFrames.filter { $0["type"] as? String == "messages_get" }.count, 1)
        XCTAssertTrue(newFrames.filter { $0["type"] as? String == "playback_audio" }.isEmpty)
        XCTAssertTrue(client.messages.isEmpty)
        XCTAssertNil(client.threadFocusRequest)
    }

    func testProgressActivityCardLivesInActiveBottomFlowAndScrollsOnProgressUpdates() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let projectDirectory = testsDirectory.deletingLastPathComponent()
        // ProgressActivityCard and the related thread/progress views were extracted into Views/*.
        // This structural test spans the decomposed view layer, so read ContentView plus the
        // extracted view files as one source. ContentView is first, so the placement/ordering
        // checks below still resolve within its body.
        let logosDirectory = projectDirectory.appendingPathComponent("Logos")
        let contentViewSource = try [
            "ContentView.swift",
            "Views/ThreadViews.swift",
            "Views/AudioViews.swift",
            "Views/MessageViews.swift",
            "Views/ListRowViews.swift",
            "Views/SettingsViews.swift",
        ].map { try String(contentsOf: logosDirectory.appendingPathComponent($0), encoding: .utf8) }
            .joined(separator: "\n")
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
        XCTAssertTrue(contentViewSource.contains(".onChange(of: threadTimelineSnapshot) { oldValue, newValue in"))
        XCTAssertTrue(contentViewSource.contains("handleThreadTimelineSnapshotChanged(from: oldValue, to: newValue)"))
        XCTAssertTrue(contentViewSource.contains("oldValue.contentFingerprint != newValue.contentFingerprint"))
        XCTAssertTrue(contentViewSource.contains("threadScrollPosition.scrollTo(id: \"thread-bottom\", anchor: .bottom)"))
        XCTAssertTrue(contentViewSource.contains(".defaultScrollAnchor(.bottom, for: .alignment)"))
        XCTAssertTrue(contentViewSource.contains("ThreadAutoFollowPolicy.isNearBottom"))
        XCTAssertTrue(contentViewSource.contains("Only detach"))
        XCTAssertTrue(contentViewSource.contains("ThreadTimelineSnapshot"))
        XCTAssertTrue(contentViewSource.contains("focusRequest: client.threadFocusRequest.map"))
        XCTAssertTrue(contentViewSource.contains("scrollThreadToTargetAfterLayout"))
        XCTAssertTrue(contentViewSource.contains("threadScrollPosition.scrollTo(id: targetID, anchor: anchor)"))
        XCTAssertTrue(contentViewSource.contains("client.completeThreadFocusRequest(id: focus.id)"))
        XCTAssertTrue(contentViewSource.contains("generic bottom scrolling is insufficient for notification replay"))
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
        let configureRuntimeRange = try XCTUnwrap(contentViewSource.range(of: "private func configureRuntime()"))
        let routeHandlerRange = try XCTUnwrap(contentViewSource.range(
            of: "notifications.onRoute = { route in",
            range: configureRuntimeRange.lowerBound..<contentViewSource.endIndex
        ))
        XCTAssertNotNil(contentViewSource.range(
            of: "client.updateSceneActivationForPlayback(isActive: scenePhase == .active)",
            range: configureRuntimeRange.lowerBound..<routeHandlerRange.lowerBound
        ))
        XCTAssertFalse(contentViewSource.contains("action: { _, newValue in\n                handleThreadBottomProximityChanged(newValue)"))
        XCTAssertFalse(contentViewSource.contains("Text(event.kind)"))
        XCTAssertFalse(contentViewSource.contains(".lineLimit(4)"))
        XCTAssertFalse(contentViewSource.contains("Text(latestEvent.text)"))
        XCTAssertTrue(contentViewSource.contains("event.count > 1"))
    }

    func testSlashCommandMenuKeepsComposerPillInStableViewHierarchy() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let projectDirectory = testsDirectory.deletingLastPathComponent()
        let contentViewSource = try String(contentsOf: projectDirectory.appendingPathComponent("Logos/ContentView.swift"), encoding: .utf8)
        let composerBarStart = try XCTUnwrap(contentViewSource.range(of: "private var composerBar: some View"))
        let composerBarEnd = try XCTUnwrap(contentViewSource.range(of: "@ViewBuilder\n    private var composerPillSurface"))
        let composerBarSource = String(contentViewSource[composerBarStart.lowerBound..<composerBarEnd.lowerBound])

        XCTAssertTrue(composerBarSource.contains("VStack(alignment: .leading"))
        XCTAssertEqual(composerBarSource.components(separatedBy: "composerPillSurface").count - 1, 1)
        XCTAssertFalse(composerBarSource.contains("} else {\n                composerPillSurface"))
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
    func testSuccessfulInboundFrameClearsVisibleErrorAndMarksConnected() async throws {
        let client = LogosClient()
        client.lastError = "Cannot reconnect: stale socket failure."

        await client.handleFrameString("""
        {"type":"hello","request_id":"hello-1","payload":{}}
        """)

        XCTAssertNil(client.lastError)
        XCTAssertEqual(client.connectionState, .connected)
    }

    @MainActor
    func testSuccessfulOperationFrameClearsPriorAdapterError() async throws {
        let client = LogosClient()
        client.lastError = "Cannot send a message: Logos is not connected."

        await client.handleFrameString("""
        {"type":"projects_list","payload":{"projects":[],"active_project_key":"default"}}
        """)

        XCTAssertNil(client.lastError)
    }

    @MainActor
    func testStateUpdateMessageUpdatedReplacesExistingMessageContent() async throws {
        let client = LogosClient(store: SQLiteMessageStore(filename: "LogosTests-\(UUID().uuidString).sqlite3"))

        await client.handleFrameString("""
        {"type":"state_update","project_key":"default","payload":{"op":"message_appended","message":{"project_key":"default","session_id":"project:default","message_id":"tool-progress-1","server_seq":10,"role":"assistant","content":"🔧 terminal…","timestamp":123.0}}}
        """)
        XCTAssertEqual(client.messages.count, 1)
        XCTAssertEqual(client.messages.first?.content, "🔧 terminal…")

        await client.handleFrameString(#"""
        {"type":"state_update","project_key":"default","payload":{"op":"message_updated","message":{"project_key":"default","session_id":"project:default","message_id":"tool-progress-1","server_seq":11,"role":"assistant","content":"🔧 terminal…\n✅ terminal done","timestamp":124.0,"metadata":{"finalized":true}}}}
        """#)

        XCTAssertEqual(client.messages.count, 1)
        XCTAssertEqual(client.messages.first?.content, "🔧 terminal…\n✅ terminal done")
        XCTAssertEqual(client.messages.first?.serverSeq, 11)
    }

    @MainActor
    func testManualPlaybackRequestsFullMessageAudio() async throws {
        let socket = RecordingWebSocketTask()
        let client = await makeSocketBackedClient(socket: socket)
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

        await client.playback(message: message)

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
    func testLiveFinalAssistantMessageAutoplaysFinalAutoAudioOnce() async throws {
        let socket = RecordingWebSocketTask()
        let client = await makeSocketBackedClient(socket: socket)
        let baselineCount = socket.sentMessages.count

        await client.handleFrameString(#"""
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

        await client.handleFrameString(#"""
        {"type":"state_update","project_key":"default","session_id":"session-live","server_seq":50,"payload":{"op":"message_appended","message":{"project_key":"default","session_id":"session-live","message_id":"assistant-live-1","server_seq":50,"role":"assistant","content":"Hello. Ada here. What are we tackling?","timestamp":123.0}}}
        """#)

        let framesAfterDuplicate = try socket.sentMessages.dropFirst(baselineCount).map { try frameRoot(from: $0) }
        XCTAssertEqual(framesAfterDuplicate.filter { $0["type"] as? String == "playback_audio" }.count, 1)
    }

    @MainActor
    func testNonFinalProgressPersistsInProgressCardOnlyAndNeverAutoplays() async throws {
        let socket = RecordingWebSocketTask()
        let client = await makeSocketBackedClient(socket: socket)
        let baselineCount = socket.sentMessages.count

        await client.handleFrameString(#"""
        {"type":"state_update","request_id":"req-progress","project_key":"default","session_id":"session-progress","server_seq":70,"payload":{"op":"message_updated","message":{"project_key":"default","session_id":"session-progress","message_id":"assistant-progress-1","server_seq":70,"role":"assistant","content":"🔧 terminal…","timestamp":123.0,"metadata":{"finalized":false,"source":"tool_progress","progress_kind":"terminal"}}}}
        """#)

        XCTAssertTrue(client.messages.isEmpty)
        XCTAssertEqual(client.progressActivity?.requestID, "req-progress")
        XCTAssertEqual(client.progressActivity?.updateCount, 1)
        XCTAssertEqual(client.progressActivity?.events.count, 1)
        XCTAssertEqual(client.progressActivity?.events.first?.text, "🔧 terminal…")
        XCTAssertEqual(client.runStatus, .running)

        await client.handleFrameString(#"""
        {"type":"tool_progress","request_id":"req-progress","project_key":"default","session_id":"session-progress","server_seq":71,"payload":{"kind":"tool_progress","progress_kind":"terminal","message_id":"assistant-progress-1","text":"✅ terminal done","transient":false,"finalized":false,"message":{"project_key":"default","session_id":"session-progress","message_id":"assistant-progress-1","server_seq":71,"role":"assistant","content":"✅ terminal done","timestamp":124.0,"metadata":{"finalized":false,"source":"tool_progress","progress_kind":"terminal","transient":false}}}}
        """#)

        XCTAssertTrue(client.messages.isEmpty)
        XCTAssertEqual(client.progressActivity?.updateCount, 2)
        XCTAssertEqual(client.progressActivity?.events.count, 1)
        XCTAssertEqual(client.progressActivity?.events.first?.text, "✅ terminal done")

        await client.handleFrameString(#"""
        {"type":"tool_progress","request_id":"req-progress","project_key":"default","session_id":"session-progress","server_seq":72,"payload":{"kind":"tool_progress","progress_kind":"terminal","message_id":"assistant-progress-2","text":"✅ terminal done","transient":false,"finalized":false,"message":{"project_key":"default","session_id":"session-progress","message_id":"assistant-progress-2","server_seq":72,"role":"assistant","content":"✅ terminal done","timestamp":125.0,"metadata":{"finalized":false,"source":"tool_progress","progress_kind":"terminal","transient":false}}}}
        """#)

        XCTAssertEqual(client.progressActivity?.updateCount, 3)
        XCTAssertEqual(client.progressActivity?.events.count, 1)
        XCTAssertEqual(client.progressActivity?.events.first?.count, 2)
        let newFrames = try socket.sentMessages.dropFirst(baselineCount).map { try frameRoot(from: $0) }
        XCTAssertTrue(newFrames.filter { $0["type"] as? String == "playback_audio" }.isEmpty)

        await client.handleFrameString(#"""
        {"type":"run_status","project_key":"default","payload":{"status":"idle"}}
        """#)
        XCTAssertEqual(client.runStatus, .running)
    }

    @MainActor
    func testScopedIdleRunStatusCompletesCurrentSlashCommandProgress() async throws {
        let socket = RecordingWebSocketTask()
        let client = await makeSocketBackedClient(socket: socket)
        let __sendResult6 = await client.sendText("/status")
        XCTAssertTrue(__sendResult6)
        let textFrame = try XCTUnwrap(try socket.sentMessages.map { try frameRoot(from: $0) }.last { $0["type"] as? String == "text_input" })
        let requestID = try XCTUnwrap(textFrame["request_id"] as? String)

        await client.handleFrameString("""
        {"type":"tool_progress","request_id":"\(requestID)","project_key":"default","session_id":"project:default","payload":{"kind":"gateway_status","progress_kind":"gateway_status","text":"Slash command is running"}}
        """)

        XCTAssertEqual(client.runStatus, .running)
        XCTAssertEqual(client.progressActivity?.isComplete, false)

        await client.handleFrameString("""
        {"type":"run_status","request_id":"\(requestID)","project_key":"default","session_id":"project:default","payload":{"status":"idle"}}
        """)

        XCTAssertEqual(client.runStatus, .idle)
        XCTAssertEqual(client.progressActivity?.isComplete, true)
        XCTAssertEqual(client.progressActivity?.finalStatus, .complete)
    }

    @MainActor
    func testInterruptedRunStatusCompletesProgressAndAllowsRetry() async throws {
        let socket = RecordingWebSocketTask()
        let client = await makeSocketBackedClient(socket: socket)
        let __sendResult7 = await client.sendText("/restart-hermes")
        XCTAssertTrue(__sendResult7)
        let textFrame = try XCTUnwrap(try socket.sentMessages.map { try frameRoot(from: $0) }.last { $0["type"] as? String == "text_input" })
        let requestID = try XCTUnwrap(textFrame["request_id"] as? String)

        await client.handleFrameString("""
        {"type":"run_status","request_id":"\(requestID)","project_key":"default","session_id":"project:default","payload":{"status":"idle","interrupted":true,"final_status":"interrupted","reason":"gateway_restarting"}}
        """)

        XCTAssertEqual(client.runStatus, .idle)
        XCTAssertEqual(client.progressActivity?.isComplete, true)
        XCTAssertEqual(client.progressActivity?.finalStatus, .interrupted)
        XCTAssertEqual(client.progressActivity?.failureMessage, "Hermes restarted before this run finished.")
        let __sendResult8 = await client.retryProgressActivity()
        XCTAssertTrue(__sendResult8)
        let retryFrame = try XCTUnwrap(try socket.sentMessages.map { try frameRoot(from: $0) }.last { $0["type"] as? String == "text_input" })
        XCTAssertEqual((retryFrame["payload"] as? [String: Any])?["text"] as? String, "/restart-hermes")
    }

    @MainActor
    func testMessagesBatchRunStatusRunningKeepsActiveProgressWorking() async throws {
        let socket = RecordingWebSocketTask()
        let client = await makeSocketBackedClient(socket: socket)
        let __sendResult9 = await client.sendText("/long-running")
        XCTAssertTrue(__sendResult9)
        let textFrame = try XCTUnwrap(try socket.sentMessages.map { try frameRoot(from: $0) }.last { $0["type"] as? String == "text_input" })
        let requestID = try XCTUnwrap(textFrame["request_id"] as? String)

        await client.handleFrameString("""
        {"type":"messages_batch","request_id":"hello-replay","project_key":"default","session_id":"project:default","payload":{"messages":[],"pending_interactions":[],"run_status":{"project_key":"default","session_id":"project:default","status":"running","request_id":"\(requestID)","payload":{"source":"typing"},"server_seq":10,"updated_at":123.0},"has_more":false,"after_server_seq":0}}
        """)

        XCTAssertEqual(client.runStatus, .running)
        XCTAssertEqual(client.progressActivity?.requestID, requestID)
        XCTAssertEqual(client.progressActivity?.isComplete, false)
    }

    @MainActor
    func testMessagesBatchInterruptedRunStatusClearsWorkingState() async throws {
        let socket = RecordingWebSocketTask()
        let client = await makeSocketBackedClient(socket: socket)
        let __sendResult10 = await client.sendText("/restart-hermes")
        XCTAssertTrue(__sendResult10)
        let textFrame = try XCTUnwrap(try socket.sentMessages.map { try frameRoot(from: $0) }.last { $0["type"] as? String == "text_input" })
        let requestID = try XCTUnwrap(textFrame["request_id"] as? String)

        await client.handleFrameString("""
        {"type":"messages_batch","request_id":"hello-replay","project_key":"default","session_id":"project:default","payload":{"messages":[],"pending_interactions":[],"run_status":{"project_key":"default","session_id":"project:default","status":"idle","request_id":"\(requestID)","payload":{"interrupted":true,"final_status":"interrupted","reason":"gateway_restarting"},"server_seq":11,"updated_at":124.0},"has_more":false,"after_server_seq":0}}
        """)

        XCTAssertEqual(client.runStatus, .idle)
        XCTAssertEqual(client.progressActivity?.isComplete, true)
        XCTAssertEqual(client.progressActivity?.finalStatus, .interrupted)
        XCTAssertEqual(client.progressActivity?.failureMessage, "Hermes restarted before this run finished.")
    }

    @MainActor
    func testLegacyReconnectReplayWithoutRunStateInterruptsActiveProgress() async throws {
        let socket = RecordingWebSocketTask()
        let client = await makeSocketBackedClient(socket: socket)
        let __sendResult11 = await client.sendText("/restart-hermes")
        XCTAssertTrue(__sendResult11)
        let textFrame = try XCTUnwrap(try socket.sentMessages.map { try frameRoot(from: $0) }.last { $0["type"] as? String == "text_input" })
        let requestID = try XCTUnwrap(textFrame["request_id"] as? String)

        socket.fail(message: "Gateway restarted")
        await yieldUntil { client.connectionState == .error }
        let helloCountBeforeReconnect = socket.sentMessages.count
        client.connect()
        socket.open()
        await yieldUntil { socket.sentMessages.count > helloCountBeforeReconnect }
        let reconnectHello = try XCTUnwrap(try socket.sentMessages.map { try frameRoot(from: $0) }.last { $0["type"] as? String == "hello" })
        let reconnectHelloID = try XCTUnwrap(reconnectHello["request_id"] as? String)
        await client.handleFrameString(#"{"type":"hello","request_id":"hello-reconnected","payload":{"authenticated":true}}"#)
        await client.handleFrameString("""
        {"type":"messages_batch","request_id":"\(reconnectHelloID)","project_key":"default","session_id":"project:default","payload":{"messages":[],"pending_interactions":[],"has_more":false,"after_server_seq":0}}
        """)

        XCTAssertEqual(client.runStatus, .idle)
        XCTAssertEqual(client.progressActivity?.requestID, requestID)
        XCTAssertEqual(client.progressActivity?.isComplete, true)
        XCTAssertEqual(client.progressActivity?.finalStatus, .interrupted)
    }

    @MainActor
    func testLegacyGatewayStillWorkingMessageAggregatesOutsideMessagesAndNeverAutoplays() async throws {
        let socket = RecordingWebSocketTask()
        let client = await makeSocketBackedClient(socket: socket)
        let baselineCount = socket.sentMessages.count
        let progressText = "⏳ Still working... (3 min elapsed — iteration 1/1000, API call #1 completed)"

        await client.handleFrameString(#"""
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

        await client.handleFrameString(#"""
        {"type":"run_status","project_key":"default","payload":{"status":"idle"}}
        """#)
        XCTAssertEqual(client.runStatus, .running)
    }

    @MainActor
    func testGatewayStatusProgressCanBecomeLocalStaleNoticeWithoutAutoplay() async throws {
        let socket = RecordingWebSocketTask()
        let scheduler = ManualStaleTimeoutScheduler()
        let client = await makeSocketBackedClient(socket: socket, staleTimeoutInterval: 0.05, staleTimeoutScheduler: scheduler)
        let baselineCount = socket.sentMessages.count

        await client.handleFrameString(#"""
        {"type":"tool_progress","request_id":"req-gateway-status","project_key":"default","session_id":"session-gateway-status","payload":{"kind":"gateway_status","progress_kind":"gateway_status","text":"⏳ Still working... (3 min elapsed — iteration 1/1000, API call #1 completed)"}}
        """#)
        XCTAssertTrue(scheduler.fireStaleTimeout())

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

    func testFinalAnswerAboutContextCompressionIsNotClassifiedAsGatewayProgress() throws {
        let finalAnswers = [
            "Context compression is useful when a conversation grows long.",
            "Context compression: a practical technique for long conversations.",
            "Preflight compression: a practical technique for long conversations.",
            "Context compression for long conversations reduces token usage.",
            "Compacting context for long tasks can help.",
            "Preflight compression: compacting context can reduce token usage.",
            "Context compression: compressing older turns is useful.",
            "Context compression: complete guide to long conversations.",
            "Preflight compression: context management for long prompts.",
            "Context compression: starting with a short summary can help."
        ]

        for (index, content) in finalAnswers.enumerated() {
            let answer = try XCTUnwrap(LogosMessage.from(dictionary: [
                "project_key": "default",
                "session_id": "session-context-answer",
                "message_id": "assistant-context-answer-\(index)",
                "server_seq": 78 + index,
                "role": "assistant",
                "content": content,
                "timestamp": 126.0
            ]))

            XCTAssertNil(answer.gatewayProgressKind, content)
            XCTAssertFalse(answer.isProgressUpdate, content)
        }
    }

    @MainActor
    func testRetryStatusStateUpdateAggregatesOutsideMessagesAndNeverAutoplays() async throws {
        let socket = RecordingWebSocketTask()
        let client = await makeSocketBackedClient(socket: socket)
        let baselineCount = socket.sentMessages.count

        await client.handleFrameString(#"""
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
    func testUnscopedLegacyGatewayStatusStateUpdateAttachesToActiveProgress() async throws {
        let socket = RecordingWebSocketTask()
        let client = await makeSocketBackedClient(socket: socket)
        let __sendResult12 = await client.sendText("legacy unscoped status")
        XCTAssertTrue(__sendResult12)
        let textFrame = try XCTUnwrap(try socket.sentMessages.map { try frameRoot(from: $0) }.last { $0["type"] as? String == "text_input" })
        let requestID = try XCTUnwrap(textFrame["request_id"] as? String)
        let baselineCount = socket.sentMessages.count

        await client.handleFrameString("""
        {"type":"state_update","project_key":"default","session_id":"project:default","server_seq":77,"payload":{"op":"message_appended","message":{"project_key":"default","session_id":"project:default","message_id":"assistant-unscoped-still-working","server_seq":77,"role":"assistant","content":"⏳ Still working... (1 min elapsed)","timestamp":125.0}}}
        """)

        XCTAssertFalse(client.messages.contains { $0.messageID == "assistant-unscoped-still-working" })
        XCTAssertEqual(client.progressActivity?.requestID, requestID)
        XCTAssertEqual(client.progressActivity?.events.last?.kind, "gateway_status")
        XCTAssertEqual(client.progressActivity?.events.last?.text, "⏳ Still working... (1 min elapsed)")
        XCTAssertEqual(client.runStatus, .running)
        let newFrames = try socket.sentMessages.dropFirst(baselineCount).map { try frameRoot(from: $0) }
        XCTAssertTrue(newFrames.filter { $0["type"] as? String == "playback_audio" }.isEmpty)
    }

    @MainActor
    func testProviderAbortStateUpdateStaysInProgressAndAllowsLaterFinal() async throws {
        let socket = RecordingWebSocketTask()
        let client = await makeSocketBackedClient(socket: socket)
        let __sendResult13 = await client.sendText("trigger provider abort status")
        XCTAssertTrue(__sendResult13)
        let textFrame = try XCTUnwrap(try socket.sentMessages.map { try frameRoot(from: $0) }.last { $0["type"] as? String == "text_input" })
        let requestID = try XCTUnwrap(textFrame["request_id"] as? String)
        let providerStatusText = "⚠️ No response from provider for 300s (non-streaming, model: gpt-5.5). Aborting call."
        let baselineCount = socket.sentMessages.count

        await client.handleFrameString("""
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
        await client.handleFrameString("""
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
    func testRetryStatusMessagesBatchAggregatesForActivePromptAndNeverAutoplays() async throws {
        let socket = RecordingWebSocketTask()
        let client = await makeSocketBackedClient(socket: socket)
        let __sendResult14 = await client.sendText("trigger retry status")
        XCTAssertTrue(__sendResult14)
        let textFrame = try XCTUnwrap(try socket.sentMessages.map { try frameRoot(from: $0) }.last { $0["type"] as? String == "text_input" })
        let requestID = try XCTUnwrap(textFrame["request_id"] as? String)
        let baselineCount = socket.sentMessages.count

        await client.handleFrameString("""
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
    func testUnscopedLegacyGatewayStatusMessagesBatchAttachesToActiveProgress() async throws {
        let socket = RecordingWebSocketTask()
        let client = await makeSocketBackedClient(socket: socket)
        let __sendResult15 = await client.sendText("legacy unscoped status batch")
        XCTAssertTrue(__sendResult15)
        let textFrame = try XCTUnwrap(try socket.sentMessages.map { try frameRoot(from: $0) }.last { $0["type"] as? String == "text_input" })
        let requestID = try XCTUnwrap(textFrame["request_id"] as? String)
        let baselineCount = socket.sentMessages.count

        await client.handleFrameString("""
        {"type":"messages_batch","project_key":"default","session_id":"project:default","payload":{"messages":[{"project_key":"default","session_id":"project:default","message_id":"assistant-unscoped-batch-still-working","server_seq":77,"role":"assistant","content":"⏳ Still working... (2 min elapsed)","timestamp":125.0}]}}
        """)

        XCTAssertFalse(client.messages.contains { $0.messageID == "assistant-unscoped-batch-still-working" })
        XCTAssertEqual(client.progressActivity?.requestID, requestID)
        XCTAssertEqual(client.progressActivity?.events.last?.kind, "gateway_status")
        XCTAssertEqual(client.progressActivity?.events.last?.text, "⏳ Still working... (2 min elapsed)")
        XCTAssertEqual(client.runStatus, .running)
        let newFrames = try socket.sentMessages.dropFirst(baselineCount).map { try frameRoot(from: $0) }
        XCTAssertTrue(newFrames.filter { $0["type"] as? String == "playback_audio" }.isEmpty)
    }

    @MainActor
    func testFetchScopedLegacyGatewayStatusMessagesBatchAttachesToActiveProgress() async throws {
        let socket = RecordingWebSocketTask()
        let client = await makeSocketBackedClient(socket: socket)
        let __sendResult16 = await client.sendText("legacy fetch status batch")
        XCTAssertTrue(__sendResult16)
        let textFrame = try XCTUnwrap(try socket.sentMessages.map { try frameRoot(from: $0) }.last { $0["type"] as? String == "text_input" })
        let requestID = try XCTUnwrap(textFrame["request_id"] as? String)
        let baselineCount = socket.sentMessages.count

        await client.handleFrameString("""
        {"type":"messages_batch","request_id":"messages-get-replay","project_key":"default","session_id":"project:default","payload":{"messages":[{"project_key":"default","session_id":"project:default","message_id":"assistant-fetch-batch-still-working","server_seq":77,"role":"assistant","content":"⏳ Still working... (2 min elapsed)","timestamp":125.0}]}}
        """)

        XCTAssertFalse(client.messages.contains { $0.messageID == "assistant-fetch-batch-still-working" })
        XCTAssertEqual(client.progressActivity?.requestID, requestID)
        XCTAssertEqual(client.progressActivity?.events.last?.kind, "gateway_status")
        XCTAssertEqual(client.progressActivity?.events.last?.text, "⏳ Still working... (2 min elapsed)")
        XCTAssertEqual(client.runStatus, .running)
        let newFrames = try socket.sentMessages.dropFirst(baselineCount).map { try frameRoot(from: $0) }
        XCTAssertTrue(newFrames.filter { $0["type"] as? String == "playback_audio" }.isEmpty)
    }

    @MainActor
    func testProviderAbortMessagesBatchAggregatesForActivePromptAndNeverAutoplays() async throws {
        let socket = RecordingWebSocketTask()
        let client = await makeSocketBackedClient(socket: socket)
        let __sendResult17 = await client.sendText("trigger provider abort batch status")
        XCTAssertTrue(__sendResult17)
        let textFrame = try XCTUnwrap(try socket.sentMessages.map { try frameRoot(from: $0) }.last { $0["type"] as? String == "text_input" })
        let requestID = try XCTUnwrap(textFrame["request_id"] as? String)
        let providerStatusText = "⚠️ No response from provider for 300s (non-streaming, model: gpt-5.5). Aborting call."
        let baselineCount = socket.sentMessages.count

        await client.handleFrameString("""
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
    func testActiveRunAssistantStatusWithoutFinalMetadataStaysInProgressUntilExplicitFinal() async throws {
        let socket = RecordingWebSocketTask()
        let client = await makeSocketBackedClient(socket: socket)
        let __sendResult18 = await client.sendText("trigger nonterminal status")
        XCTAssertTrue(__sendResult18)
        let textFrame = try XCTUnwrap(try socket.sentMessages.map { try frameRoot(from: $0) }.last { $0["type"] as? String == "text_input" })
        let requestID = try XCTUnwrap(textFrame["request_id"] as? String)
        let statusText = "Preflight compression: compacting context before continuing."
        let baselineCount = socket.sentMessages.count

        await client.handleFrameString("""
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
        await client.handleFrameString("""
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
    func testReadableErrorFinalMetadataMarksProgressFailedAfterRawErrorProgress() async throws {
        let socket = RecordingWebSocketTask()
        let client = await makeSocketBackedClient(socket: socket)
        let __sendResult19 = await client.sendText("trigger raw provider failure")
        XCTAssertTrue(__sendResult19)
        let textFrame = try XCTUnwrap(try socket.sentMessages.map { try frameRoot(from: $0) }.last { $0["type"] as? String == "text_input" })
        let requestID = try XCTUnwrap(textFrame["request_id"] as? String)
        let rawError = "⚠️ 'NoneType' object is not iterable"
        let readableError = "Hermes hit an unrecoverable error before it could answer. The underlying error was: 'NoneType' object is not iterable."

        await client.handleFrameString("""
        {"type":"tool_progress","request_id":"\(requestID)","project_key":"default","session_id":"project:default","payload":{"kind":"gateway_status","progress_kind":"gateway_status","message_id":"progress-error","text":"\(rawError)","transient":true}}
        """)

        XCTAssertEqual(client.progressActivity?.events.last?.text, rawError)
        XCTAssertEqual(client.progressActivity?.isComplete, false)
        XCTAssertFalse(client.messages.contains { $0.content == rawError })

        await client.handleFrameString("""
        {"type":"state_update","request_id":"\(requestID)","project_key":"default","session_id":"project:default","server_seq":91,"payload":{"op":"message_appended","message":{"project_key":"default","session_id":"project:default","message_id":"assistant-readable-error","server_seq":91,"role":"assistant","content":"\(readableError)","timestamp":131.0,"metadata":{"finalized":true,"source":"hermes_error","final_status":"failed","error":true,"request_id":"\(requestID)"}}}}
        """)

        XCTAssertEqual(client.progressActivity?.isComplete, true)
        XCTAssertEqual(client.progressActivity?.finalStatus, .failed)
        XCTAssertEqual(client.progressActivity?.failureMessage, readableError)
        XCTAssertEqual(client.progressActivity?.retryRequest, .text("trigger raw provider failure"))
        XCTAssertEqual(client.progressActivity?.completedFinalMessageID, "project:default:assistant-readable-error")
        XCTAssertTrue(client.messages.contains { $0.messageID == "assistant-readable-error" && $0.content == readableError })
        XCTAssertEqual(client.runStatus, .idle)
    }

    @MainActor
    func testMessagesBatchErrorFinalMetadataMarksProgressFailed() async throws {
        let socket = RecordingWebSocketTask()
        let client = await makeSocketBackedClient(socket: socket)
        let __sendResult20 = await client.sendText("trigger replayed provider failure")
        XCTAssertTrue(__sendResult20)
        let textFrame = try XCTUnwrap(try socket.sentMessages.map { try frameRoot(from: $0) }.last { $0["type"] as? String == "text_input" })
        let requestID = try XCTUnwrap(textFrame["request_id"] as? String)
        let readableError = "Hermes hit an unrecoverable error before it could answer."

        await client.handleFrameString("""
        {"type":"messages_batch","request_id":"\(requestID)","project_key":"default","session_id":"project:default","payload":{"messages":[{"project_key":"default","session_id":"project:default","message_id":"assistant-batch-readable-error","server_seq":92,"role":"assistant","content":"\(readableError)","timestamp":132.0,"metadata":{"finalized":true,"source":"hermes_error","final_status":"failed","error":true,"request_id":"\(requestID)"}}]}}
        """)

        XCTAssertEqual(client.progressActivity?.isComplete, true)
        XCTAssertEqual(client.progressActivity?.finalStatus, .failed)
        XCTAssertEqual(client.progressActivity?.failureMessage, readableError)
        XCTAssertEqual(client.progressActivity?.retryRequest, .text("trigger replayed provider failure"))
        XCTAssertEqual(client.progressActivity?.completedFinalMessageID, "project:default:assistant-batch-readable-error")
        XCTAssertEqual(client.runStatus, .idle)
    }

    @MainActor
    func testTextSendCreatesProgressActivityBeforeFirstAdapterUpdate() async throws {
        let socket = RecordingWebSocketTask()
        let client = await makeSocketBackedClient(socket: socket)

        let __sendResult21 = await client.sendText("start progress immediately")
        XCTAssertTrue(__sendResult21)
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

        await client.handleFrameString("""
        {"type":"tool_progress","request_id":"\(requestID)","project_key":"default","session_id":"project:default","payload":{"kind":"terminal","text":"Adapter update arrived"}}
        """)
        XCTAssertEqual(client.progressActivity?.updateCount, 1)
        XCTAssertEqual(client.progressActivity?.adapterUpdateCount, 1)
    }

    @MainActor
    func testProgressActivityCompletionFreezesElapsedTime() async throws {
        let socket = RecordingWebSocketTask()
        let client = await makeSocketBackedClient(socket: socket)

        let __sendResult22 = await client.sendText("measure elapsed progress")
        XCTAssertTrue(__sendResult22)
        let textFrame = try XCTUnwrap(try socket.sentMessages.map { try frameRoot(from: $0) }.last { $0["type"] as? String == "text_input" })
        let requestID = try XCTUnwrap(textFrame["request_id"] as? String)
        let startedAt = try XCTUnwrap(client.progressActivity?.startedAt)
        XCTAssertNil(client.progressActivity?.completedAt)

        await client.handleFrameString("""
        {"type":"state_update","request_id":"\(requestID)","project_key":"default","session_id":"project:default","server_seq":91,"payload":{"op":"message_appended","message":{"project_key":"default","session_id":"project:default","message_id":"assistant-elapsed-final","server_seq":91,"role":"assistant","content":"Done measuring.","timestamp":131.0,"metadata":{"finalized":true,"source":"hermes"}}}}
        """)

        let completedAt = try XCTUnwrap(client.progressActivity?.completedAt)
        XCTAssertGreaterThanOrEqual(completedAt, startedAt)
        XCTAssertEqual(client.progressActivity?.isComplete, true)
        XCTAssertEqual(client.progressActivity?.finalStatus, .complete)
        XCTAssertNil(client.progressActivity?.retryRequest)
    }

    @MainActor
    func testLateDifferentRequestProgressAfterCompletionDoesNotReplaceCompletedCard() async throws {
        let socket = RecordingWebSocketTask()
        let client = await makeSocketBackedClient(socket: socket)

        let __sendResult23 = await client.sendText("finish before stale progress")
        XCTAssertTrue(__sendResult23)
        let textFrame = try XCTUnwrap(try socket.sentMessages.map { try frameRoot(from: $0) }.last { $0["type"] as? String == "text_input" })
        let requestID = try XCTUnwrap(textFrame["request_id"] as? String)
        await client.handleFrameString("""
        {"type":"state_update","request_id":"\(requestID)","project_key":"default","session_id":"project:default","server_seq":92,"payload":{"op":"message_appended","message":{"project_key":"default","session_id":"project:default","message_id":"assistant-completed-before-late-progress","server_seq":92,"role":"assistant","content":"Done before stale progress.","timestamp":132.0,"metadata":{"finalized":true,"source":"hermes"}}}}
        """)

        XCTAssertEqual(client.progressActivity?.requestID, requestID)
        XCTAssertEqual(client.progressActivity?.finalStatus, .complete)

        await client.handleFrameString(#"""
        {"type":"tool_progress","request_id":"req-stale-progress-after-complete","project_key":"default","session_id":"project:default","payload":{"kind":"terminal","text":"Stale progress after completion"}}
        """#)

        XCTAssertEqual(client.runStatus, .idle)
        XCTAssertEqual(client.progressActivity?.requestID, requestID)
        XCTAssertEqual(client.progressActivity?.finalStatus, .complete)
        XCTAssertFalse(client.progressActivity?.events.contains { $0.text == "Stale progress after completion" } ?? true)
    }

    @MainActor
    func testRunStatusErrorMarksProgressFailedAndTextRetryResendsOriginalPrompt() async throws {
        let socket = RecordingWebSocketTask()
        let client = await makeSocketBackedClient(socket: socket)

        let __sendResult24 = await client.sendText("retry this exact text")
        XCTAssertTrue(__sendResult24)
        let textFrame = try XCTUnwrap(try socket.sentMessages.map { try frameRoot(from: $0) }.last { $0["type"] as? String == "text_input" })
        let requestID = try XCTUnwrap(textFrame["request_id"] as? String)

        await client.handleFrameString("""
        {"type":"run_status","request_id":"\(requestID)","project_key":"default","payload":{"status":"error","message":"Hermes failed the request"}}
        """)

        XCTAssertEqual(client.runStatus, .idle)
        XCTAssertEqual(client.progressActivity?.isComplete, true)
        XCTAssertEqual(client.progressActivity?.finalStatus, .failed)
        XCTAssertEqual(client.progressActivity?.failureMessage, "Hermes failed the request")
        XCTAssertEqual(client.progressActivity?.retryRequest, .text("retry this exact text"))

        let baselineCount = socket.sentMessages.count
        let __sendResult25 = await client.retryProgressActivity()
        XCTAssertTrue(__sendResult25)

        let retryFrame = try XCTUnwrap(try socket.sentMessages.dropFirst(baselineCount).map { try frameRoot(from: $0) }.last { $0["type"] as? String == "text_input" })
        let retryPayload = try XCTUnwrap(retryFrame["payload"] as? [String: Any])
        XCTAssertEqual(retryPayload["text"] as? String, "retry this exact text")
        XCTAssertNotEqual(retryFrame["request_id"] as? String, requestID)
        XCTAssertEqual(client.progressActivity?.finalStatus, nil)
    }

    @MainActor
    func testUnscopedAdapterErrorDoesNotFailActiveProgressRun() async throws {
        let socket = RecordingWebSocketTask()
        let client = await makeSocketBackedClient(socket: socket)

        let __sendResult26 = await client.sendText("keep working after unrelated adapter error")
        XCTAssertTrue(__sendResult26)
        let textFrame = try XCTUnwrap(try socket.sentMessages.map { try frameRoot(from: $0) }.last { $0["type"] as? String == "text_input" })
        let requestID = try XCTUnwrap(textFrame["request_id"] as? String)

        await client.handleFrameString(#"""
        {"type":"error","project_key":"default","payload":{"code":"server_error","message":"Unscoped adapter notice"}}
        """#)

        XCTAssertEqual(client.runStatus, .running)
        XCTAssertEqual(client.progressActivity?.requestID, requestID)
        XCTAssertEqual(client.progressActivity?.isComplete, false)
        XCTAssertNil(client.progressActivity?.finalStatus)
        XCTAssertEqual(client.lastError, "Unscoped adapter notice")
    }

    @MainActor
    func testLateFinalAfterRunErrorDoesNotCompleteFailedProgressOrAutoplay() async throws {
        let socket = RecordingWebSocketTask()
        let client = await makeSocketBackedClient(socket: socket)

        let __sendResult27 = await client.sendText("fail then late final")
        XCTAssertTrue(__sendResult27)
        let textFrame = try XCTUnwrap(try socket.sentMessages.map { try frameRoot(from: $0) }.last { $0["type"] as? String == "text_input" })
        let requestID = try XCTUnwrap(textFrame["request_id"] as? String)
        await client.handleFrameString("""
        {"type":"run_status","request_id":"\(requestID)","project_key":"default","payload":{"status":"error","message":"Hermes failed before final"}}
        """)
        XCTAssertEqual(client.progressActivity?.finalStatus, .failed)
        let baselineCount = socket.sentMessages.count

        await client.handleFrameString("""
        {"type":"state_update","request_id":"\(requestID)","project_key":"default","session_id":"project:default","server_seq":93,"payload":{"op":"message_appended","message":{"project_key":"default","session_id":"project:default","message_id":"assistant-late-after-failed-run","server_seq":93,"role":"assistant","content":"Late final after failed run.","timestamp":133.0,"metadata":{"finalized":true,"source":"hermes"}}}}
        """)

        XCTAssertEqual(client.runStatus, .idle)
        XCTAssertEqual(client.progressActivity?.requestID, requestID)
        XCTAssertEqual(client.progressActivity?.finalStatus, .failed)
        XCTAssertEqual(client.progressActivity?.retryRequest, .text("fail then late final"))
        XCTAssertFalse(client.messages.contains { $0.messageID == "assistant-late-after-failed-run" })
        let newFrames = try socket.sentMessages.dropFirst(baselineCount).map { try frameRoot(from: $0) }
        XCTAssertTrue(newFrames.filter { $0["type"] as? String == "playback_audio" }.isEmpty)
    }

    @MainActor
    func testVoiceRetryResendsOriginalTranscriptAsFreshFinalSpeech() async throws {
        let socket = RecordingWebSocketTask()
        let client = await makeSocketBackedClient(socket: socket)

        let speechRetrySent = await client.sendSpeech(
            text: "retry this voice transcript",
            isFinal: true,
            inputID: "voice-original-failed",
            partialSeq: 4,
            startedAtMilliseconds: 123
        )
        XCTAssertTrue(speechRetrySent)
        let speechFrame = try XCTUnwrap(try socket.sentMessages.map { try frameRoot(from: $0) }.last { $0["type"] as? String == "speech" })
        let requestID = try XCTUnwrap(speechFrame["request_id"] as? String)

        await client.handleFrameString("""
        {"type":"run_status","request_id":"\(requestID)","project_key":"default","payload":{"status":"error","message":"Voice request failed"}}
        """)

        XCTAssertEqual(client.progressActivity?.finalStatus, .failed)
        XCTAssertEqual(client.progressActivity?.retryRequest, .speech(text: "retry this voice transcript"))

        let baselineCount = socket.sentMessages.count
        let __sendResult28 = await client.retryProgressActivity()
        XCTAssertTrue(__sendResult28)

        let retryFrame = try XCTUnwrap(try socket.sentMessages.dropFirst(baselineCount).map { try frameRoot(from: $0) }.last { $0["type"] as? String == "speech" })
        let retryPayload = try XCTUnwrap(retryFrame["payload"] as? [String: Any])
        XCTAssertEqual(retryPayload["text"] as? String, "retry this voice transcript")
        XCTAssertEqual(retryPayload["is_final"] as? Bool, true)
        XCTAssertEqual(retryPayload["partial_seq"] as? Int, 0)
        XCTAssertNotEqual(retryPayload["client_msg_id"] as? String, "voice-original-failed")
    }

    @MainActor
    func testFinalSpeechSendCreatesProgressActivityBeforeFirstAdapterUpdate() async throws {
        let socket = RecordingWebSocketTask()
        let client = await makeSocketBackedClient(socket: socket)

        let speechProgressSent = await client.sendSpeech(
            text: "voice request starts progress",
            isFinal: true,
            inputID: "voice-progress-start",
            partialSeq: 1,
            startedAtMilliseconds: 123
        )
        XCTAssertTrue(speechProgressSent)
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
    func testStoredLegacyGatewayProgressMessagesAreFilteredAndPlaybackGuarded() async throws {
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
        let client = await makeSocketBackedClient(socket: socket, store: store)
        let baselineCount = socket.sentMessages.count

        XCTAssertTrue(client.messages.isEmpty)
        await client.playback(message: legacyProgress)

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
    func testMessagesBatchClearsProgressWhenFinalResponseArrivesInSameBatch() async throws {
        let socket = RecordingWebSocketTask()
        let client = await makeSocketBackedClient(socket: socket)

        await client.handleFrameString(#"""
        {"type":"messages_batch","request_id":"req-batch-final","project_key":"default","session_id":"session-batch-final","payload":{"messages":[{"project_key":"default","session_id":"session-batch-final","message_id":"legacy-progress-in-batch","server_seq":81,"role":"assistant","content":"⏳ Still working... (3 min elapsed — iteration 1/1000, API call #1 completed)","timestamp":123.0},{"project_key":"default","session_id":"session-batch-final","message_id":"assistant-batch-final","server_seq":82,"role":"assistant","content":"Final response after progress.","timestamp":124.0,"metadata":{"finalized":true}}]}}
        """#)

        XCTAssertNil(client.progressActivity)
        XCTAssertEqual(client.runStatus, .idle)
        XCTAssertEqual(client.messages.count, 1)
        XCTAssertEqual(client.messages.first?.messageID, "assistant-batch-final")
    }

    @MainActor
    func testMessagesBatchKeepsDurableProgressOutOfConversationBubblesWhenFinalResponseArrivesInSameBatch() async throws {
        let socket = RecordingWebSocketTask()
        let client = await makeSocketBackedClient(socket: socket)
        let baselineCount = socket.sentMessages.count

        await client.handleFrameString(#"""
        {"type":"messages_batch","request_id":"req-batch-durable-final","project_key":"default","session_id":"session-batch-durable-final","payload":{"messages":[{"project_key":"default","session_id":"session-batch-durable-final","message_id":"progress-batch","server_seq":81,"role":"assistant","content":"🔧 terminal: \"pytest\"","timestamp":123.0,"metadata":{"finalized":false,"source":"tool_progress","progress_kind":"terminal","transient":false}},{"project_key":"default","session_id":"session-batch-durable-final","message_id":"assistant-batch-final","server_seq":82,"role":"assistant","content":"Final response after progress.","timestamp":124.0,"metadata":{"finalized":true,"source":"hermes"}}]}}
        """#)

        XCTAssertNil(client.progressActivity)
        XCTAssertEqual(client.runStatus, .idle)
        XCTAssertEqual(client.messages.map(\.messageID), ["assistant-batch-final"])
        let newFrames = try socket.sentMessages.dropFirst(baselineCount).map { try frameRoot(from: $0) }
        XCTAssertTrue(newFrames.filter { $0["type"] as? String == "playback_audio" }.isEmpty)
    }

    @MainActor
    func testMessagesBatchFinalCompletesExistingProgressActivity() async throws {
        let socket = RecordingWebSocketTask()
        let client = await makeSocketBackedClient(socket: socket)

        await client.handleFrameString(#"""
        {"type":"tool_progress","request_id":"req-final-only-replay","project_key":"default","session_id":"session-final-only-replay","payload":{"kind":"gateway_status","progress_kind":"gateway_status","text":"⏳ Still working... (3 min elapsed — iteration 1/1000, API call #1 completed)"}}
        """#)
        XCTAssertNotNil(client.progressActivity)
        XCTAssertEqual(client.runStatus, .running)

        await client.handleFrameString(#"""
        {"type":"messages_batch","request_id":"req-final-only-replay","project_key":"default","session_id":"session-final-only-replay","payload":{"messages":[{"project_key":"default","session_id":"session-final-only-replay","message_id":"assistant-final-only","server_seq":83,"role":"assistant","content":"Final response replayed without transient progress.","timestamp":125.0,"metadata":{"finalized":true}}]}}
        """#)

        XCTAssertEqual(client.progressActivity?.requestID, "req-final-only-replay")
        XCTAssertEqual(client.progressActivity?.isComplete, true)
        XCTAssertEqual(client.runStatus, .idle)
        XCTAssertEqual(client.messages.count, 1)
        XCTAssertEqual(client.messages.first?.messageID, "assistant-final-only")
    }

    @MainActor
    func testMessagesBatchFinalDuringCancelDoesNotClearCancelLatch() async throws {
        let socket = RecordingWebSocketTask()
        let client = await makeSocketBackedClient(socket: socket)

        await client.handleFrameString(#"""
        {"type":"tool_progress","request_id":"req-cancel-batch","project_key":"default","session_id":"session-cancel-batch","payload":{"kind":"terminal","text":"Still running before cancel"}}
        """#)
        await client.cancelRun()
        XCTAssertEqual(client.runStatus, .cancelling)
        XCTAssertEqual(client.progressActivity?.requestID, "req-cancel-batch")

        await client.handleFrameString(#"""
        {"type":"messages_batch","request_id":"req-cancel-batch","project_key":"default","session_id":"session-cancel-batch","payload":{"messages":[{"project_key":"default","session_id":"session-cancel-batch","message_id":"assistant-cancelled-final-replay","server_seq":84,"role":"assistant","content":"Late final replay after local cancel.","timestamp":126.0,"metadata":{"finalized":true,"source":"hermes"}}]}}
        """#)

        XCTAssertEqual(client.runStatus, .cancelling)
        XCTAssertEqual(client.progressActivity?.requestID, "req-cancel-batch")
        XCTAssertEqual(client.progressActivity?.sessionID, "session-cancel-batch")
    }

    @MainActor
    func testMessagesBatchFinalForDifferentRequestDoesNotClearCurrentProgress() async throws {
        let socket = RecordingWebSocketTask()
        let client = await makeSocketBackedClient(socket: socket)

        await client.handleFrameString(#"""
        {"type":"tool_progress","request_id":"req-current-batch","project_key":"default","session_id":"session-shared-batch","payload":{"kind":"terminal","text":"Current request still running"}}
        """#)
        XCTAssertEqual(client.runStatus, .running)
        XCTAssertEqual(client.progressActivity?.requestID, "req-current-batch")

        await client.handleFrameString(#"""
        {"type":"messages_batch","request_id":"req-old-batch","project_key":"default","session_id":"session-shared-batch","payload":{"messages":[{"project_key":"default","session_id":"session-shared-batch","message_id":"assistant-old-batch-final","server_seq":85,"role":"assistant","content":"Old same-session final replay.","timestamp":127.0,"metadata":{"finalized":true,"source":"hermes"}}]}}
        """#)

        XCTAssertEqual(client.runStatus, .running)
        XCTAssertEqual(client.progressActivity?.requestID, "req-current-batch")
        XCTAssertEqual(client.progressActivity?.sessionID, "session-shared-batch")
    }

    @MainActor
    func testUnscopedMessagesBatchFinalAfterNewTextBeforeProgressDoesNotIdlePrompt() async throws {
        let socket = RecordingWebSocketTask()
        let client = await makeSocketBackedClient(socket: socket)
        let __sendResult29 = await client.sendText("new request before unscoped batch final")
        XCTAssertTrue(__sendResult29)
        let textRoot = try frameRoot(from: try XCTUnwrap(socket.sentMessages.last))
        let newRequestID = try XCTUnwrap(textRoot["request_id"] as? String)
        let baselineCount = socket.sentMessages.count

        await client.handleFrameString(#"""
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
    func testMessagesBatchFinalMetadataRequestIDCompletesProgressWithoutFrameRequestID() async throws {
        let socket = RecordingWebSocketTask()
        let client = await makeSocketBackedClient(socket: socket)

        await client.handleFrameString(#"""
        {"type":"tool_progress","request_id":"req-batch-metadata-final","project_key":"default","session_id":"session-batch-metadata-final","payload":{"kind":"terminal","text":"Running before metadata final"}}
        """#)

        await client.handleFrameString(#"""
        {"type":"messages_batch","project_key":"default","session_id":"session-batch-metadata-final","payload":{"messages":[{"project_key":"default","session_id":"session-batch-metadata-final","message_id":"assistant-batch-metadata-final","server_seq":87,"role":"assistant","content":"Final with metadata request id.","timestamp":129.0,"metadata":{"finalized":true,"source":"hermes","request_id":"req-batch-metadata-final"}}]}}
        """#)

        XCTAssertEqual(client.progressActivity?.isComplete, true)
        XCTAssertEqual(client.progressActivity?.completedFinalMessageID, "session-batch-metadata-final:assistant-batch-metadata-final")
        XCTAssertEqual(client.runStatus, .idle)
    }

    @MainActor
    func testMessagesBatchFinalPrefersMessageMetadataRequestIDOverBatchFetchRequestID() async throws {
        let socket = RecordingWebSocketTask()
        let client = await makeSocketBackedClient(socket: socket)

        let __sendResult30 = await client.sendText("complete from replay metadata")
        XCTAssertTrue(__sendResult30)
        let textFrame = try XCTUnwrap(try socket.sentMessages.map { try frameRoot(from: $0) }.last { $0["type"] as? String == "text_input" })
        let runRequestID = try XCTUnwrap(textFrame["request_id"] as? String)

        await client.handleFrameString("""
        {"type":"messages_batch","request_id":"messages-get-replay","project_key":"default","session_id":"project:default","payload":{"messages":[{"project_key":"default","session_id":"project:default","message_id":"assistant-replay-final-metadata-request","server_seq":88,"role":"assistant","content":"Replay final with metadata request id.","timestamp":128.0,"metadata":{"finalized":true,"source":"hermes","request_id":"\(runRequestID)"}}]}}
        """)

        XCTAssertEqual(client.runStatus, .idle)
        XCTAssertEqual(client.progressActivity?.requestID, runRequestID)
        XCTAssertEqual(client.progressActivity?.finalStatus, .complete)
        XCTAssertEqual(client.progressActivity?.completedFinalMessageID, "project:default:assistant-replay-final-metadata-request")
    }

    @MainActor
    func testStateUpdateFinalMetadataRequestIDCompletesProgressWithoutFrameRequestID() async throws {
        let socket = RecordingWebSocketTask()
        let client = await makeSocketBackedClient(socket: socket)

        await client.handleFrameString(#"""
        {"type":"tool_progress","request_id":"req-state-metadata-final","project_key":"default","session_id":"session-state-metadata-final","payload":{"kind":"terminal","text":"Running before metadata state final"}}
        """#)

        await client.handleFrameString(#"""
        {"type":"state_update","project_key":"default","session_id":"session-state-metadata-final","server_seq":88,"payload":{"op":"message_appended","message":{"project_key":"default","session_id":"session-state-metadata-final","message_id":"assistant-state-metadata-final","server_seq":88,"role":"assistant","content":"State final with metadata request id.","timestamp":130.0,"metadata":{"finalized":true,"source":"hermes","request_id":"req-state-metadata-final"}}}}
        """#)

        XCTAssertEqual(client.progressActivity?.isComplete, true)
        XCTAssertEqual(client.progressActivity?.completedFinalMessageID, "session-state-metadata-final:assistant-state-metadata-final")
        XCTAssertEqual(client.runStatus, .idle)
    }

    @MainActor
    func testFinalizedMessageUpdatedKeepsProgressCardAndAutoplaysFinalAutoOnce() async throws {
        let socket = RecordingWebSocketTask()
        let client = await makeSocketBackedClient(socket: socket)

        await client.handleFrameString(#"""
        {"type":"state_update","request_id":"req-finalize","project_key":"default","session_id":"session-finalize","server_seq":80,"payload":{"op":"message_updated","message":{"project_key":"default","session_id":"session-finalize","message_id":"assistant-finalize-1","server_seq":80,"role":"assistant","content":"🔧 terminal…","timestamp":123.0,"metadata":{"finalized":false,"progress_kind":"terminal"}}}}
        """#)
        XCTAssertEqual(client.progressActivity?.events.count, 1)
        XCTAssertTrue(client.messages.isEmpty)
        let baselineCount = socket.sentMessages.count

        await client.handleFrameString(#"""
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

        await client.handleFrameString(#"""
        {"type":"state_update","project_key":"default","session_id":"session-finalize","server_seq":82,"payload":{"op":"message_appended","message":{"project_key":"default","session_id":"session-finalize","message_id":"assistant-later-unrelated","server_seq":82,"role":"assistant","content":"Later unrelated assistant message.","timestamp":125.0,"metadata":{"finalized":true,"source":"hermes"}}}}
        """#)
        XCTAssertEqual(client.progressActivity?.completedFinalMessageID, "session-finalize:assistant-finalize-1")

        await client.handleFrameString(#"""
        {"type":"state_update","request_id":"req-finalize","project_key":"default","session_id":"session-finalize","server_seq":83,"payload":{"op":"message_appended","message":{"project_key":"default","session_id":"session-finalize","message_id":"assistant-second-same-request","server_seq":83,"role":"assistant","content":"A later same-request final should not move progress.","timestamp":126.0,"metadata":{"finalized":true,"source":"hermes"}}}}
        """#)
        XCTAssertEqual(client.progressActivity?.completedFinalMessageID, "session-finalize:assistant-finalize-1")
        let framesAfterLaterSameRequest = try socket.sentMessages.dropFirst(baselineCount).map { try frameRoot(from: $0) }
        XCTAssertEqual(framesAfterLaterSameRequest.filter { $0["type"] as? String == "playback_audio" }.count, 1)

        await client.handleFrameString(#"""
        {"type":"state_update","request_id":"req-finalize","project_key":"default","session_id":"session-finalize","server_seq":81,"payload":{"op":"message_updated","message":{"project_key":"default","session_id":"session-finalize","message_id":"assistant-finalize-1","server_seq":81,"role":"assistant","content":"Done with the terminal work.","timestamp":124.0,"metadata":{"finalized":true,"source":"hermes"}}}}
        """#)
        let framesAfterDuplicate = try socket.sentMessages.dropFirst(baselineCount).map { try frameRoot(from: $0) }
        XCTAssertEqual(framesAfterDuplicate.filter { $0["type"] as? String == "playback_audio" }.count, 1)
    }

    @MainActor
    func testFinalStateUpdateForDifferentSessionDoesNotClearCurrentProgressOrAutoplay() async throws {
        let socket = RecordingWebSocketTask()
        let client = await makeSocketBackedClient(socket: socket)
        await client.handleFrameString(#"""
        {"type":"tool_progress","request_id":"req-current","project_key":"default","session_id":"session-current","payload":{"kind":"terminal","text":"Current request is still running"}}
        """#)
        let baselineCount = socket.sentMessages.count

        await client.handleFrameString(#"""
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
        let scheduler = ManualStaleTimeoutScheduler()
        let client = await makeSocketBackedClient(socket: socket, staleTimeoutInterval: 0.05, staleTimeoutScheduler: scheduler)
        let baselineCount = socket.sentMessages.count

        await client.handleFrameString(#"""
        {"type":"tool_progress","request_id":"req-timeout","project_key":"default","session_id":"session-timeout","payload":{"kind":"terminal","text":"Still running"}}
        """#)
        XCTAssertTrue(scheduler.fireStaleTimeout())

        XCTAssertEqual(client.progressActivity?.timedOut, true)
        XCTAssertNotEqual(client.runStatus, .error)
        XCTAssertEqual(client.messages.filter { $0.status == "local_notice" }.count, 1)
        var newFrames = try socket.sentMessages.dropFirst(baselineCount).map { try frameRoot(from: $0) }
        var playbackFrames = newFrames.filter { $0["type"] as? String == "playback_audio" }
        XCTAssertTrue(playbackFrames.isEmpty)

        // A repeated timeout fire stays visual-only and never triggers autoplay.
        XCTAssertTrue(scheduler.fireStaleTimeout())
        newFrames = try socket.sentMessages.dropFirst(baselineCount).map { try frameRoot(from: $0) }
        playbackFrames = newFrames.filter { $0["type"] as? String == "playback_audio" }
        XCTAssertTrue(playbackFrames.isEmpty)

        let socket2 = RecordingWebSocketTask()
        let scheduler2 = ManualStaleTimeoutScheduler()
        let client2 = await makeSocketBackedClient(socket: socket2, staleTimeoutInterval: 0.05, staleTimeoutScheduler: scheduler2)
        let baselineCount2 = socket2.sentMessages.count
        await client2.handleFrameString(#"""
        {"type":"tool_progress","request_id":"req-cancel-timeout","project_key":"default","session_id":"session-cancel-timeout","payload":{"kind":"terminal","text":"Almost done"}}
        """#)
        await client2.handleFrameString(#"""
        {"type":"state_update","request_id":"req-cancel-timeout","project_key":"default","session_id":"session-cancel-timeout","server_seq":90,"payload":{"op":"message_updated","message":{"project_key":"default","session_id":"session-cancel-timeout","message_id":"assistant-cancel-timeout","server_seq":90,"role":"assistant","content":"Finished before timeout.","timestamp":125.0,"metadata":{"finalized":true}}}}
        """#)
        XCTAssertFalse(scheduler2.hasPendingTimeout)

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
        let scheduler = ManualStaleTimeoutScheduler()
        let client = await makeSocketBackedClient(socket: socket, staleTimeoutInterval: 30, staleTimeoutScheduler: scheduler)

        await client.handleFrameString(#"""
        {"type":"hello","request_id":"hello-config","payload":{"client_config":{"stale_timeout_seconds":0.05}}}
        """#)
        let baselineCount = socket.sentMessages.count
        let __sendResult31 = await client.sendText("Do something slow.")
        XCTAssertTrue(__sendResult31)
        let sentCount = socket.sentMessages.count

        // The server-provided client_config overrides the 30s default down to 0.05s.
        XCTAssertEqual(try XCTUnwrap(scheduler.lastInterval), 0.05, accuracy: 0.0001)
        XCTAssertTrue(scheduler.fireStaleTimeout())

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
        let scheduler = ManualStaleTimeoutScheduler()
        let client = await makeSocketBackedClient(socket: socket, staleTimeoutInterval: 0.08, staleTimeoutScheduler: scheduler)
        let __sendResult32 = await client.sendText("Stay alive while working.")
        XCTAssertTrue(__sendResult32)
        let textFrame = try XCTUnwrap(try socket.sentMessages.map { try frameRoot(from: $0) }.last { $0["type"] as? String == "text_input" })
        let requestID = try XCTUnwrap(textFrame["request_id"] as? String)
        let scheduleCountAfterSend = scheduler.scheduleCount

        await client.handleFrameString("""
        {"type":"run_status","request_id":"\(requestID)","project_key":"default","session_id":"project:default","payload":{"status":"running","keepalive":true,"source":"typing"}}
        """)
        // A matching keepalive reschedules (resets) the active stale timer, and no
        // notice is posted until the reset timer actually fires.
        XCTAssertGreaterThan(scheduler.scheduleCount, scheduleCountAfterSend)
        XCTAssertTrue(client.messages.filter { $0.status == "local_notice" }.isEmpty)

        XCTAssertTrue(scheduler.fireStaleTimeout())
        XCTAssertEqual(client.messages.filter { $0.status == "local_notice" }.count, 1)
        XCTAssertNotEqual(client.runStatus, .error)
    }

    @MainActor
    func testMismatchedRunStatusKeepaliveDoesNotResetActiveStaleTimer() async throws {
        let socket = RecordingWebSocketTask()
        let scheduler = ManualStaleTimeoutScheduler()
        let client = await makeSocketBackedClient(socket: socket, staleTimeoutInterval: 0.08, staleTimeoutScheduler: scheduler)
        let __sendResult33 = await client.sendText("Active run should not be reset by old keepalive.")
        XCTAssertTrue(__sendResult33)
        let scheduleCountAfterSend = scheduler.scheduleCount

        await client.handleFrameString(#"""
        {"type":"run_status","request_id":"req-old-keepalive","project_key":"default","session_id":"project:default","payload":{"status":"running","keepalive":true,"source":"typing"}}
        """#)
        // A keepalive for a stale request ID must not reschedule the active timer.
        XCTAssertEqual(scheduler.scheduleCount, scheduleCountAfterSend)

        XCTAssertTrue(scheduler.fireStaleTimeout())
        XCTAssertEqual(client.messages.filter { $0.status == "local_notice" }.count, 1)
        XCTAssertNotEqual(client.runStatus, .error)
    }

    @MainActor
    func testTerminalRunStatusAfterStaleNoticeStopsRepeatingNotices() async throws {
        let socket = RecordingWebSocketTask()
        let scheduler = ManualStaleTimeoutScheduler()
        let client = await makeSocketBackedClient(socket: socket, staleTimeoutInterval: 0.05, staleTimeoutScheduler: scheduler)
        let __sendResult34 = await client.sendText("This will become stale, then idle.")
        XCTAssertTrue(__sendResult34)
        let textFrame = try XCTUnwrap(try socket.sentMessages.map { try frameRoot(from: $0) }.last { $0["type"] as? String == "text_input" })
        let requestID = try XCTUnwrap(textFrame["request_id"] as? String)

        XCTAssertTrue(scheduler.fireStaleTimeout())
        XCTAssertEqual(client.messages.filter { $0.status == "local_notice" }.count, 1)

        await client.handleFrameString("""
        {"type":"run_status","request_id":"\(requestID)","project_key":"default","session_id":"project:default","payload":{"status":"idle"}}
        """)
        // The terminal idle status cancels the repeating timer; firing again is a no-op.
        XCTAssertFalse(scheduler.fireStaleTimeout())

        XCTAssertEqual(client.runStatus, .idle)
        XCTAssertEqual(client.messages.filter { $0.status == "local_notice" }.count, 1)
    }

    @MainActor
    func testTimedOutProgressIgnoresUnrelatedLateProgress() async throws {
        let socket = RecordingWebSocketTask()
        let scheduler = ManualStaleTimeoutScheduler()
        let client = await makeSocketBackedClient(socket: socket, staleTimeoutInterval: 0.05, staleTimeoutScheduler: scheduler)

        await client.handleFrameString(#"""
        {"type":"tool_progress","request_id":"req-timeout-current","project_key":"default","session_id":"session-timeout-current","payload":{"kind":"terminal","text":"Current request running"}}
        """#)
        XCTAssertTrue(scheduler.fireStaleTimeout())
        XCTAssertEqual(client.progressActivity?.requestID, "req-timeout-current")
        XCTAssertEqual(client.progressActivity?.timedOut, true)

        await client.handleFrameString(#"""
        {"type":"tool_progress","request_id":"req-unrelated-late","project_key":"default","session_id":"session-timeout-current","payload":{"kind":"terminal","text":"Unrelated late progress"}}
        """#)

        XCTAssertEqual(client.progressActivity?.requestID, "req-timeout-current")
        XCTAssertTrue(client.progressActivity?.events.last?.text.contains("not heard from Hermes") == true)
    }

    @MainActor
    func testMessagesBatchDurableProgressDoesNotReviveLiveProgressOrStaleTimer() async throws {
        let socket = RecordingWebSocketTask()
        let scheduler = ManualStaleTimeoutScheduler()
        let client = await makeSocketBackedClient(socket: socket, staleTimeoutInterval: 0.05, staleTimeoutScheduler: scheduler)

        await client.handleFrameString(#"""
        {"type":"messages_batch","request_id":"hello-replay","project_key":"default","session_id":"session-replay","payload":{"messages":[{"project_key":"default","session_id":"session-replay","message_id":"progress-replay","server_seq":91,"role":"assistant","content":"🔧 terminal: \"old\"","timestamp":123.0,"metadata":{"finalized":false,"source":"tool_progress","progress_kind":"terminal","request_id":"req-old-replay","transient":false}}]}}
        """#)
        // Durable progress replay must not arm a stale timer.
        XCTAssertFalse(scheduler.hasPendingTimeout)

        XCTAssertNil(client.progressActivity)
        XCTAssertTrue(client.messages.isEmpty)
        XCTAssertTrue(client.messages.filter { $0.status == "local_notice" }.isEmpty)
    }

    @MainActor
    func testLocalStaleNoticePersistsAcrossStoreReload() async throws {
        let socket = RecordingWebSocketTask()
        let store = SQLiteMessageStore(filename: "LogosTests-\(UUID().uuidString).sqlite3")
        let scheduler = ManualStaleTimeoutScheduler()
        let client = await makeSocketBackedClient(socket: socket, store: store, staleTimeoutInterval: 0.05, staleTimeoutScheduler: scheduler)
        let __sendResult35 = await client.sendText("Persist stale notice.")
        XCTAssertTrue(__sendResult35)

        XCTAssertTrue(scheduler.fireStaleTimeout())

        let reloaded = LogosClient(store: store, staleTimeoutInterval: 0.05)
        XCTAssertEqual(reloaded.messages.filter { $0.status == "local_notice" }.count, 1)
        XCTAssertEqual(reloaded.messages.first(where: { $0.status == "local_notice" })?.metadataSource, "local_notice")
    }

    @MainActor
    func testProgressTimeoutSuspendsWhileAwaitingApproval() async throws {
        let socket = RecordingWebSocketTask()
        let scheduler = ManualStaleTimeoutScheduler()
        let client = await makeSocketBackedClient(socket: socket, staleTimeoutInterval: 0.05, staleTimeoutScheduler: scheduler)
        let baselineCount = socket.sentMessages.count

        await client.handleFrameString(#"""
        {"type":"tool_progress","request_id":"req-approval-wait","project_key":"default","session_id":"session-approval-wait","payload":{"kind":"terminal","text":"🔧 terminal running"}}
        """#)
        await client.handleFrameString(#"""
        {"type":"approval_request","request_id":"req-approval-wait","project_key":"default","session_id":"session-approval-wait","payload":{"approval_id":"approval-wait","title":"Approve?","summary":"Needs confirmation","command_preview":"echo ok","risk":"fixture"}}
        """#)
        // Awaiting approval suspends the stale timer; nothing remains armed to fire.
        XCTAssertFalse(scheduler.hasPendingTimeout)

        XCTAssertEqual(client.runStatus, .awaitingApproval)
        XCTAssertEqual(client.progressActivity?.timedOut, false)
        XCTAssertEqual(client.progressActivity?.events.filter { $0.kind == "timeout" }.count, 0)
        let newFrames = try socket.sentMessages.dropFirst(baselineCount).map { try frameRoot(from: $0) }
        XCTAssertTrue(newFrames.filter { $0["type"] as? String == "playback_audio" }.isEmpty)
    }

    @MainActor
    func testCancelRunDedupeSuspendsProgressTimeoutAndAcceptsIdle() async throws {
        let socket = RecordingWebSocketTask()
        let scheduler = ManualStaleTimeoutScheduler()
        let client = await makeSocketBackedClient(socket: socket, staleTimeoutInterval: 0.05, staleTimeoutScheduler: scheduler)
        await client.handleFrameString(#"""
        {"type":"tool_progress","request_id":"req-cancel","project_key":"default","session_id":"session-cancel","payload":{"kind":"terminal","text":"Long task running"}}
        """#)
        let baselineCount = socket.sentMessages.count

        await client.cancelRun()
        await client.cancelRun()

        XCTAssertEqual(client.runStatus, .cancelling)
        let cancelFrames = try socket.sentMessages.dropFirst(baselineCount)
            .map { try frameRoot(from: $0) }
            .filter { $0["type"] as? String == "run_cancel" }
        XCTAssertEqual(cancelFrames.count, 1)
        XCTAssertEqual(cancelFrames.first?["project_key"] as? String, "default")
        let payload = try XCTUnwrap(cancelFrames.first?["payload"] as? [String: Any])
        XCTAssertTrue(payload.isEmpty)

        await client.handleFrameString(#"""
        {"type":"run_status","project_key":"default","payload":{"status":"cancelling"}}
        """#)
        // Cancelling suspends the stale timer, so no timeout fire remains armed.
        XCTAssertFalse(scheduler.hasPendingTimeout)

        XCTAssertEqual(client.runStatus, .cancelling)
        XCTAssertEqual(client.progressActivity?.events.filter { $0.kind == "timeout" }.count, 0)

        await client.handleFrameString(#"""
        {"type":"run_status","request_id":"stale-idle","project_key":"default","payload":{"status":"idle"}}
        """#)

        XCTAssertEqual(client.runStatus, .cancelling)
        XCTAssertNotNil(client.progressActivity)

        let cancelRequestID = try XCTUnwrap(cancelFrames.first?["request_id"] as? String)
        await client.handleFrameString("""
        {"type":"run_status","request_id":"\(cancelRequestID)","project_key":"default","payload":{"status":"idle","cancelled":true}}
        """)

        XCTAssertEqual(client.runStatus, .idle)
        XCTAssertEqual(client.progressActivity?.isComplete, true)
        XCTAssertEqual(client.progressActivity?.finalStatus, .stopped)
        XCTAssertNil(client.progressActivity?.retryRequest)
    }

    @MainActor
    func testCancelRunClearsInteractionCardsAndIgnoresLateRequests() async throws {
        let socket = RecordingWebSocketTask()
        let client = await makeSocketBackedClient(socket: socket)

        await client.handleFrameString(#"""
        {"type":"approval_request","request_id":"approval-before-cancel","project_key":"default","session_id":"session-cancel-interaction","payload":{"approval_id":"approval-before-cancel","title":"Approve?","summary":"Needs confirmation","command_preview":"echo ok","risk":"fixture"}}
        """#)
        XCTAssertEqual(client.runStatus, .awaitingApproval)
        XCTAssertEqual(client.approvalCard?.id, "approval-before-cancel")

        await client.cancelRun()

        XCTAssertEqual(client.runStatus, .cancelling)
        XCTAssertNil(client.approvalCard)
        XCTAssertNil(client.clarifyCard)
        XCTAssertNil(client.pendingInteractionResponseID)

        await client.handleFrameString(#"""
        {"type":"approval_request","request_id":"approval-late","project_key":"default","session_id":"session-cancel-interaction","payload":{"approval_id":"approval-late","title":"Approve late?","summary":"Late approval","command_preview":"echo late","risk":"fixture"}}
        """#)
        await client.handleFrameString(#"""
        {"type":"clarify_request","request_id":"clarify-late","project_key":"default","session_id":"session-cancel-interaction","payload":{"clarify_id":"clarify-late","question":"Late question?","choices":["yes"],"allow_free_text":true}}
        """#)

        XCTAssertEqual(client.runStatus, .cancelling)
        XCTAssertNil(client.approvalCard)
        XCTAssertNil(client.clarifyCard)
    }

    @MainActor
    func testProjectSwitchClearsRunStatusAndIgnoresStaleProjectFrames() async throws {
        let socket = RecordingWebSocketTask()
        let client = await makeSocketBackedClient(socket: socket)
        await client.handleFrameString(#"""
        {"type":"tool_progress","request_id":"req-alpha","project_key":"default","session_id":"session-alpha","payload":{"kind":"terminal","text":"Alpha is running"}}
        """#)
        XCTAssertEqual(client.runStatus, .running)

        await client.switchProject("beta")

        XCTAssertEqual(client.activeProjectKey, "beta")
        XCTAssertEqual(client.runStatus, .idle)
        XCTAssertNil(client.progressActivity)

        await client.handleFrameString(#"""
        {"type":"state_update","request_id":"switch-alpha-old","project_key":"default","server_seq":130,"payload":{"op":"active_project_changed","project":{"project_key":"default","title":"Default"}}}
        """#)
        XCTAssertEqual(client.activeProjectKey, "beta")

        await client.handleFrameString(#"""
        {"type":"projects_list","request_id":"list-stale","project_key":"default","payload":{"active_project_key":"default","projects":[{"project_key":"default","title":"Default"},{"project_key":"beta","title":"Beta"}]}}
        """#)
        XCTAssertEqual(client.activeProjectKey, "beta")
    }

    @MainActor
    func testAdapterErrorsClearPendingInteractionAndCancelState() async throws {
        let socket = RecordingWebSocketTask()
        let client = await makeSocketBackedClient(socket: socket)
        await Task.yield()

        await client.handleFrameString(#"""
        {"type":"approval_request","request_id":"approval-not-pending","project_key":"default","session_id":"session-approval-error","payload":{"approval_id":"approval-not-pending","title":"Approve?","summary":"Needs confirmation","command_preview":"echo ok","risk":"fixture"}}
        """#)
        await client.approveCurrentRequest()
        XCTAssertEqual(client.pendingInteractionResponseID, "approval-not-pending")

        await client.handleFrameString(#"""
        {"type":"error","request_id":"approval-not-pending","project_key":"default","payload":{"code":"approval_not_pending","message":"approval_response requires a matching pending approval for this project"}}
        """#)

        XCTAssertNil(client.pendingInteractionResponseID)
        XCTAssertNil(client.approvalCard)
        XCTAssertNil(client.ackText)

        await client.handleFrameString(#"""
        {"type":"tool_progress","request_id":"req-cancel-error","project_key":"default","session_id":"session-cancel-error","payload":{"kind":"terminal","text":"Long task running"}}
        """#)
        await client.cancelRun()
        let cancelRoot = try frameRoot(from: try XCTUnwrap(socket.sentMessages.last))
        let cancelRequestID = try XCTUnwrap(cancelRoot["request_id"] as? String)
        XCTAssertEqual(client.runStatus, .cancelling)

        await client.handleFrameString("""
        {"type":"error","request_id":"\(cancelRequestID)","project_key":"default","payload":{"code":"run_cancel_failed","message":"cancel failed"}}
        """)

        XCTAssertEqual(client.runStatus, .error)
        XCTAssertNil(client.progressActivity)
    }

    @MainActor
    func testCancelRunSendFailureClearsProgressAndReportsError() async throws {
        let socket = RecordingWebSocketTask()
        let client = await makeSocketBackedClient(socket: socket)
        await Task.yield()
        await client.handleFrameString(#"""
        {"type":"tool_progress","request_id":"req-cancel-send-fail","project_key":"default","session_id":"session-cancel-send-fail","payload":{"kind":"terminal","text":"Long task running"}}
        """#)

        socket.failNextSend(RecordingSocketError())
        await client.cancelRun()

        XCTAssertEqual(client.runStatus, .error)
        XCTAssertNil(client.progressActivity)
        XCTAssertEqual(client.connectionState, .error)
    }

    @MainActor
    func testSameSessionDifferentRequestFinalDoesNotClearProgressOrAutoplay() async throws {
        let socket = RecordingWebSocketTask()
        let client = await makeSocketBackedClient(socket: socket)
        await client.handleFrameString(#"""
        {"type":"tool_progress","request_id":"req-current-shared","project_key":"default","session_id":"session-shared","payload":{"kind":"terminal","text":"Current request is still running"}}
        """#)
        let baselineCount = socket.sentMessages.count

        await client.handleFrameString(#"""
        {"type":"state_update","request_id":"req-old-shared","project_key":"default","session_id":"session-shared","server_seq":131,"payload":{"op":"message_appended","message":{"project_key":"default","session_id":"session-shared","message_id":"assistant-old-shared-final","server_seq":131,"role":"assistant","content":"Old final response arrived late.","timestamp":126.0,"metadata":{"finalized":true,"source":"hermes"}}}}
        """#)

        XCTAssertEqual(client.progressActivity?.requestID, "req-current-shared")
        XCTAssertEqual(client.progressActivity?.sessionID, "session-shared")
        XCTAssertEqual(client.runStatus, .running)
        let newFrames = try socket.sentMessages.dropFirst(baselineCount).map { try frameRoot(from: $0) }
        XCTAssertTrue(newFrames.filter { $0["type"] as? String == "playback_audio" }.isEmpty)
    }

    @MainActor
    func testUnsolicitedSameDeviceAudioIsIgnoredButFastAckAudioIsAuthorized() async throws {
        let socket = RecordingWebSocketTask()
        let session = RecordingAudioSessionManager()
        let factory = RecordingAudioPlayerFactory()
        let controller = AudioPlaybackController(sessionManager: session, playerFactory: factory)
        let client = await makeSocketBackedClient(socket: socket, audioPlayback: controller)
        let unsolicited = Data([4, 5, 6]).base64EncodedString()

        await client.handleFrameString("""
        {"type":"audio_chunk","device_id":"ios-simulator","project_key":"default","session_id":"session-audio","payload":{"audio_id":"unsolicited-audio","message_id":"assistant-audio","chunk_index":0,"data":"\(unsolicited)"}}
        """)
        await client.handleFrameString(#"""
        {"type":"audio_end","device_id":"ios-simulator","project_key":"default","session_id":"session-audio","payload":{"audio_id":"unsolicited-audio","message_id":"assistant-audio","chunk_count":1}}
        """#)
        XCTAssertEqual(factory.player.playCalls, 0)

        await client.handleFrameString(#"""
        {"type":"state_update","request_id":"ack-req","project_key":"default","session_id":"session-audio","payload":{"op":"fast_ack","ack_text":"On it.","audio_id":"ack-audio","transient":true}}
        """#)
        await client.handleFrameString("""
        {"type":"audio_chunk","device_id":"ios-simulator","project_key":"default","session_id":"session-audio","payload":{"audio_id":"ack-audio","chunk_index":0,"data":"\(unsolicited)"}}
        """)
        await client.handleFrameString(#"""
        {"type":"audio_end","device_id":"ios-simulator","project_key":"default","session_id":"session-audio","payload":{"audio_id":"ack-audio","chunk_count":1}}
        """#)

        XCTAssertEqual(factory.player.playCalls, 1)
    }

    @MainActor
    func testStaleTextSendCompletionAfterDisconnectRemovesPendingBubble() async throws {
        let socket = RecordingWebSocketTask()
        let client = await makeSocketBackedClient(socket: socket)
        await Task.yield()

        // Park the send so the disconnect happens while the text send is still in flight; the send
        // then completes (late) on the now-stale connection and the optimistic bubble is rolled back.
        socket.holdNextSends()
        let sendTask = Task { @MainActor in
            await client.sendText("pending then disconnect")
        }
        while client.messages.contains(where: { $0.content == "pending then disconnect" }) == false {
            await Task.yield()
        }
        XCTAssertEqual(client.messages.last?.content, "pending then disconnect")
        XCTAssertEqual(client.messages.last?.status, "pending")

        client.disconnect()
        await socket.completeHeldSend(error: nil)
        _ = await sendTask.value
        await yieldUntil { client.messages.allSatisfy { $0.content != "pending then disconnect" } }

        XCTAssertTrue(client.messages.allSatisfy { $0.content != "pending then disconnect" })
    }

    @MainActor
    func testLateRunStatusCannotOverrideCancellingUntilIdle() async throws {
        let socket = RecordingWebSocketTask()
        let client = await makeSocketBackedClient(socket: socket)
        await client.handleFrameString(#"""
        {"type":"tool_progress","request_id":"req-cancel-latch","project_key":"default","session_id":"session-cancel-latch","payload":{"kind":"terminal","text":"Still running"}}
        """#)
        await client.cancelRun()
        XCTAssertEqual(client.runStatus, .cancelling)

        await client.handleFrameString(#"""
        {"type":"run_status","request_id":"late-running","project_key":"default","payload":{"status":"running"}}
        """#)
        await client.handleFrameString(#"""
        {"type":"run_status","request_id":"late-approval","project_key":"default","payload":{"status":"awaiting_approval"}}
        """#)

        XCTAssertEqual(client.runStatus, .cancelling)
        XCTAssertNil(client.approvalCard)
        XCTAssertNil(client.clarifyCard)

        let cancelRoot = try frameRoot(from: try XCTUnwrap(socket.sentMessages.last))
        let cancelRequestID = try XCTUnwrap(cancelRoot["request_id"] as? String)
        await client.handleFrameString(#"""
        {"type":"run_status","request_id":"stale-cancel-complete","project_key":"default","payload":{"status":"idle"}}
        """#)
        XCTAssertEqual(client.runStatus, .cancelling)

        await client.handleFrameString("""
        {"type":"run_status","request_id":"\(cancelRequestID)","project_key":"default","payload":{"status":"idle","cancelled":true}}
        """)
        XCTAssertEqual(client.runStatus, .idle)
        XCTAssertEqual(client.progressActivity?.isComplete, true)
        XCTAssertEqual(client.progressActivity?.finalStatus, .stopped)
        XCTAssertNil(client.progressActivity?.retryRequest)
    }

    @MainActor
    func testLateUnscopedFinalDuringCancelDoesNotClearProgressOrAutoplay() async throws {
        let socket = RecordingWebSocketTask()
        let client = await makeSocketBackedClient(socket: socket)
        await client.handleFrameString(#"""
        {"type":"tool_progress","request_id":"req-cancel-current","project_key":"default","session_id":"session-shared-cancel","payload":{"kind":"terminal","text":"Current request is running"}}
        """#)
        await client.cancelRun()
        let baselineCount = socket.sentMessages.count

        await client.handleFrameString(#"""
        {"type":"state_update","project_key":"default","session_id":"session-shared-cancel","server_seq":132,"payload":{"op":"message_appended","message":{"project_key":"default","session_id":"session-shared-cancel","message_id":"assistant-unscoped-late-final","server_seq":132,"role":"assistant","content":"Late final after cancel.","timestamp":127.0,"metadata":{"finalized":true,"source":"hermes"}}}}
        """#)

        XCTAssertEqual(client.runStatus, .cancelling)
        XCTAssertEqual(client.progressActivity?.requestID, "req-cancel-current")
        let newFrames = try socket.sentMessages.dropFirst(baselineCount).map { try frameRoot(from: $0) }
        XCTAssertTrue(newFrames.filter { $0["type"] as? String == "playback_audio" }.isEmpty)
    }

    @MainActor
    func testLateUnscopedFinalAfterCancelCompleteDoesNotClearNewSameSessionRunOrAutoplay() async throws {
        let socket = RecordingWebSocketTask()
        let client = await makeSocketBackedClient(socket: socket)
        await client.handleFrameString(#"""
        {"type":"tool_progress","request_id":"req-old-before-cancel","project_key":"default","session_id":"session-shared-rerun","payload":{"kind":"terminal","text":"Old request is running"}}
        """#)
        await client.cancelRun()
        let cancelRoot = try frameRoot(from: try XCTUnwrap(socket.sentMessages.last))
        let cancelRequestID = try XCTUnwrap(cancelRoot["request_id"] as? String)
        await client.handleFrameString("""
        {"type":"run_status","request_id":"\(cancelRequestID)","project_key":"default","session_id":"session-shared-rerun","payload":{"status":"idle","cancelled":true}}
        """)
        XCTAssertEqual(client.runStatus, .idle)
        XCTAssertEqual(client.progressActivity?.isComplete, true)
        XCTAssertEqual(client.progressActivity?.finalStatus, .stopped)
        XCTAssertNil(client.progressActivity?.retryRequest)

        await client.handleFrameString(#"""
        {"type":"tool_progress","request_id":"req-new-after-cancel","project_key":"default","session_id":"session-shared-rerun","payload":{"kind":"terminal","text":"New request is running"}}
        """#)
        XCTAssertEqual(client.progressActivity?.requestID, "req-old-before-cancel")
        XCTAssertEqual(client.progressActivity?.finalStatus, .stopped)

        let __sendResult36 = await client.sendText("new run after cancel")
        XCTAssertTrue(__sendResult36)
        let textRoot = try frameRoot(from: try XCTUnwrap(socket.sentMessages.last))
        let newRequestID = try XCTUnwrap(textRoot["request_id"] as? String)
        XCTAssertEqual(client.progressActivity?.requestID, newRequestID)
        let baselineCount = socket.sentMessages.count

        await client.handleFrameString(#"""
        {"type":"state_update","project_key":"default","session_id":"session-shared-rerun","server_seq":133,"payload":{"op":"message_appended","message":{"project_key":"default","session_id":"session-shared-rerun","message_id":"assistant-old-unscoped-after-cancel","server_seq":133,"role":"assistant","content":"Old final after the user started over.","timestamp":128.0,"metadata":{"finalized":true,"source":"hermes"}}}}
        """#)

        XCTAssertEqual(client.runStatus, .running)
        XCTAssertEqual(client.progressActivity?.requestID, newRequestID)
        let newFrames = try socket.sentMessages.dropFirst(baselineCount).map { try frameRoot(from: $0) }
        XCTAssertTrue(newFrames.filter { $0["type"] as? String == "playback_audio" }.isEmpty)
    }

    @MainActor
    func testLateUnscopedFinalAfterNewTextBeforeProgressDoesNotAutoplay() async throws {
        let socket = RecordingWebSocketTask()
        let client = await makeSocketBackedClient(socket: socket)
        await client.handleFrameString(#"""
        {"type":"tool_progress","request_id":"req-old-before-text-rerun","project_key":"default","session_id":"project:default","payload":{"kind":"terminal","text":"Old request is running"}}
        """#)
        await client.cancelRun()
        let cancelRoot = try frameRoot(from: try XCTUnwrap(socket.sentMessages.last))
        let cancelRequestID = try XCTUnwrap(cancelRoot["request_id"] as? String)
        await client.handleFrameString("""
        {"type":"run_status","request_id":"\(cancelRequestID)","project_key":"default","session_id":"project:default","payload":{"status":"idle","cancelled":true}}
        """)
        let __sendResult37 = await client.sendText("new request before progress")
        XCTAssertTrue(__sendResult37)
        let baselineCount = socket.sentMessages.count

        await client.handleFrameString(#"""
        {"type":"state_update","project_key":"default","session_id":"project:default","server_seq":134,"payload":{"op":"message_appended","message":{"project_key":"default","session_id":"project:default","message_id":"assistant-old-unscoped-before-progress","server_seq":134,"role":"assistant","content":"Old final before new progress starts.","timestamp":129.0,"metadata":{"finalized":true,"source":"hermes"}}}}
        """#)

        let newFrames = try socket.sentMessages.dropFirst(baselineCount).map { try frameRoot(from: $0) }
        XCTAssertTrue(newFrames.filter { $0["type"] as? String == "playback_audio" }.isEmpty)
        XCTAssertTrue(client.messages.contains { $0.content == "new request before progress" && $0.status == "pending" })
    }

    @MainActor
    func testMatchingFinalAfterNewTextBeforeProgressAutoplays() async throws {
        let socket = RecordingWebSocketTask()
        let client = await makeSocketBackedClient(socket: socket)
        let __sendResult38 = await client.sendText("fast hello before progress")
        XCTAssertTrue(__sendResult38)
        let textRoot = try frameRoot(from: try XCTUnwrap(socket.sentMessages.last))
        let requestID = try XCTUnwrap(textRoot["request_id"] as? String)
        let baselineCount = socket.sentMessages.count

        await client.handleFrameString("""
        {"type":"state_update","request_id":"\(requestID)","project_key":"default","session_id":"project:default","server_seq":135,"payload":{"op":"message_appended","message":{"project_key":"default","session_id":"project:default","message_id":"assistant-fast-final","server_seq":135,"role":"assistant","content":"Fast response before progress.","timestamp":130.0,"metadata":{"finalized":true,"source":"fast_response"}}}}
        """)

        let newFrames = try socket.sentMessages.dropFirst(baselineCount).map { try frameRoot(from: $0) }
        let playbackFrames = newFrames.filter { $0["type"] as? String == "playback_audio" }
        XCTAssertEqual(playbackFrames.count, 1)
        XCTAssertEqual((playbackFrames[0]["payload"] as? [String: Any])?["message_id"] as? String, "assistant-fast-final")
        XCTAssertEqual(client.runStatus, .idle)
    }

    @MainActor
    func testOutstandingFollowupFinalBeforeProgressSupersedesOlderActiveProgress() async throws {
        let socket = RecordingWebSocketTask()
        let client = await makeSocketBackedClient(socket: socket)
        let __sendResult39 = await client.sendText("first run before followup final")
        XCTAssertTrue(__sendResult39)
        let firstRoot = try frameRoot(from: try XCTUnwrap(socket.sentMessages.last))
        let firstRequestID = try XCTUnwrap(firstRoot["request_id"] as? String)
        await client.handleFrameString("""
        {"type":"tool_progress","request_id":"\(firstRequestID)","project_key":"default","session_id":"project:default","payload":{"kind":"terminal","text":"First run active before followup final"}}
        """)
        XCTAssertEqual(client.progressActivity?.requestID, firstRequestID)

        let __sendResult40 = await client.sendText("second final before progress")
        XCTAssertTrue(__sendResult40)
        let secondRoot = try frameRoot(from: try XCTUnwrap(socket.sentMessages.last))
        let secondRequestID = try XCTUnwrap(secondRoot["request_id"] as? String)
        let baselineCount = socket.sentMessages.count
        await client.handleFrameString("""
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
    func testLateStaleProgressAfterNewTextBeforeProgressDoesNotReleaseStaleFinal() async throws {
        let socket = RecordingWebSocketTask()
        let client = await makeSocketBackedClient(socket: socket)
        await client.handleFrameString(#"""
        {"type":"tool_progress","request_id":"req-old-stale-progress","project_key":"default","session_id":"project:default","payload":{"kind":"terminal","text":"Old request was running"}}
        """#)
        await client.cancelRun()
        let cancelRoot = try frameRoot(from: try XCTUnwrap(socket.sentMessages.last))
        let cancelRequestID = try XCTUnwrap(cancelRoot["request_id"] as? String)
        await client.handleFrameString("""
        {"type":"run_status","request_id":"\(cancelRequestID)","project_key":"default","session_id":"project:default","payload":{"status":"idle","cancelled":true}}
        """)
        let __sendResult41 = await client.sendText("new request before stale progress")
        XCTAssertTrue(__sendResult41)
        let textRoot = try frameRoot(from: try XCTUnwrap(socket.sentMessages.last))
        let newRequestID = try XCTUnwrap(textRoot["request_id"] as? String)
        let baselineCount = socket.sentMessages.count

        await client.handleFrameString(#"""
        {"type":"tool_progress","request_id":"req-old-stale-progress","project_key":"default","session_id":"project:default","payload":{"kind":"terminal","text":"Late old progress"}}
        """#)
        await client.handleFrameString(#"""
        {"type":"state_update","request_id":"req-old-stale-progress","project_key":"default","session_id":"project:default","server_seq":136,"payload":{"op":"message_updated","message":{"project_key":"default","session_id":"project:default","message_id":"assistant-old-stale-progress-final","server_seq":136,"role":"assistant","content":"Old final after stale progress.","timestamp":131.0,"metadata":{"finalized":true,"source":"hermes"}}}}
        """#)

        let newFrames = try socket.sentMessages.dropFirst(baselineCount).map { try frameRoot(from: $0) }
        XCTAssertTrue(newFrames.filter { $0["type"] as? String == "playback_audio" }.isEmpty)
        XCTAssertEqual(client.progressActivity?.requestID, newRequestID)
        XCTAssertEqual(client.progressActivity?.isComplete, false)
        XCTAssertEqual(client.progressActivity?.updateCount, 0)
    }

    @MainActor
    func testLateStaleProgressAfterNewProgressDoesNotReplaceNewProgressOrAutoplay() async throws {
        let socket = RecordingWebSocketTask()
        let client = await makeSocketBackedClient(socket: socket)
        await client.handleFrameString(#"""
        {"type":"tool_progress","request_id":"req-old-after-new-progress","project_key":"default","session_id":"project:default","payload":{"kind":"terminal","text":"Old request was running"}}
        """#)
        await client.cancelRun()
        let cancelRoot = try frameRoot(from: try XCTUnwrap(socket.sentMessages.last))
        let cancelRequestID = try XCTUnwrap(cancelRoot["request_id"] as? String)
        await client.handleFrameString("""
        {"type":"run_status","request_id":"\(cancelRequestID)","project_key":"default","session_id":"project:default","payload":{"status":"idle","cancelled":true}}
        """)
        let __sendResult42 = await client.sendText("new request with valid progress")
        XCTAssertTrue(__sendResult42)
        let textRoot = try frameRoot(from: try XCTUnwrap(socket.sentMessages.last))
        let newRequestID = try XCTUnwrap(textRoot["request_id"] as? String)

        await client.handleFrameString("""
        {"type":"tool_progress","request_id":"\(newRequestID)","project_key":"default","session_id":"project:default","payload":{"kind":"terminal","text":"New request progress"}}
        """)
        XCTAssertEqual(client.progressActivity?.requestID, newRequestID)
        let baselineCount = socket.sentMessages.count

        await client.handleFrameString(#"""
        {"type":"tool_progress","request_id":"req-old-after-new-progress","project_key":"default","session_id":"project:default","payload":{"kind":"terminal","text":"Late old progress after new progress"}}
        """#)
        await client.handleFrameString(#"""
        {"type":"state_update","request_id":"req-old-after-new-progress","project_key":"default","session_id":"project:default","server_seq":137,"payload":{"op":"message_updated","message":{"project_key":"default","session_id":"project:default","message_id":"assistant-old-after-new-progress-final","server_seq":137,"role":"assistant","content":"Old final after the new request has progress.","timestamp":132.0,"metadata":{"finalized":true,"source":"hermes"}}}}
        """#)

        let newFrames = try socket.sentMessages.dropFirst(baselineCount).map { try frameRoot(from: $0) }
        XCTAssertTrue(newFrames.filter { $0["type"] as? String == "playback_audio" }.isEmpty)
        XCTAssertEqual(client.progressActivity?.requestID, newRequestID)
        XCTAssertEqual(client.runStatus, .running)
    }

    @MainActor
    func testCancelSuppressesAllOutstandingOutboundRequests() async throws {
        let socket = RecordingWebSocketTask()
        let client = await makeSocketBackedClient(socket: socket)
        var requestIDs: [String] = []
        for index in 0..<70 {
            let __sendResult43 = await client.sendText("pending request \(index)")
            XCTAssertTrue(__sendResult43)
            let root = try frameRoot(from: try XCTUnwrap(socket.sentMessages.last))
            requestIDs.append(try XCTUnwrap(root["request_id"] as? String))
        }
        XCTAssertEqual(Set(requestIDs).count, 70)
        let firstRequestID = try XCTUnwrap(requestIDs.first)

        await client.cancelRun()
        let cancelRoot = try frameRoot(from: try XCTUnwrap(socket.sentMessages.last))
        let cancelRequestID = try XCTUnwrap(cancelRoot["request_id"] as? String)
        await client.handleFrameString("""
        {"type":"run_status","request_id":"\(cancelRequestID)","project_key":"default","session_id":"project:default","payload":{"status":"idle","cancelled":true}}
        """)
        let baselineCount = socket.sentMessages.count

        await client.handleFrameString("""
        {"type":"state_update","request_id":"\(firstRequestID)","project_key":"default","session_id":"project:default","server_seq":138,"payload":{"op":"message_appended","message":{"project_key":"default","session_id":"project:default","message_id":"assistant-first-pending-after-cancel","server_seq":138,"role":"assistant","content":"Old first pending final after cancel.","timestamp":133.0,"metadata":{"finalized":true,"source":"hermes"}}}}
        """)

        let newFrames = try socket.sentMessages.dropFirst(baselineCount).map { try frameRoot(from: $0) }
        XCTAssertTrue(newFrames.filter { $0["type"] as? String == "playback_audio" }.isEmpty)
        XCTAssertEqual(client.runStatus, .idle)
    }

    @MainActor
    func testOutstandingFollowupProgressSupersedesOlderActiveProgress() async throws {
        let socket = RecordingWebSocketTask()
        let client = await makeSocketBackedClient(socket: socket)
        let __sendResult44 = await client.sendText("first run")
        XCTAssertTrue(__sendResult44)
        let firstRoot = try frameRoot(from: try XCTUnwrap(socket.sentMessages.last))
        let firstRequestID = try XCTUnwrap(firstRoot["request_id"] as? String)
        await client.handleFrameString("""
        {"type":"tool_progress","request_id":"\(firstRequestID)","project_key":"default","session_id":"project:default","payload":{"kind":"terminal","text":"First run progress"}}
        """)
        XCTAssertEqual(client.progressActivity?.requestID, firstRequestID)

        let __sendResult45 = await client.sendText("second run")
        XCTAssertTrue(__sendResult45)
        let secondRoot = try frameRoot(from: try XCTUnwrap(socket.sentMessages.last))
        let secondRequestID = try XCTUnwrap(secondRoot["request_id"] as? String)
        await client.handleFrameString("""
        {"type":"tool_progress","request_id":"\(secondRequestID)","project_key":"default","session_id":"project:default","payload":{"kind":"terminal","text":"Second run progress"}}
        """)
        XCTAssertEqual(client.progressActivity?.requestID, secondRequestID)
        let baselineCount = socket.sentMessages.count

        await client.handleFrameString("""
        {"type":"state_update","request_id":"\(secondRequestID)","project_key":"default","session_id":"project:default","server_seq":140,"payload":{"op":"message_appended","message":{"project_key":"default","session_id":"project:default","message_id":"assistant-second-run-final","server_seq":140,"role":"assistant","content":"Second run final.","timestamp":135.0,"metadata":{"finalized":true,"source":"hermes"}}}}
        """)

        let newFrames = try socket.sentMessages.dropFirst(baselineCount).map { try frameRoot(from: $0) }
        let playbackFrames = newFrames.filter { $0["type"] as? String == "playback_audio" }
        XCTAssertEqual(playbackFrames.count, 1)
        XCTAssertEqual((playbackFrames[0]["payload"] as? [String: Any])?["message_id"] as? String, "assistant-second-run-final")
        XCTAssertEqual(client.runStatus, .idle)
    }

    @MainActor
    func testPostCancelUnscopedFinalDoesNotAutoplayAfterMatchingNewFinal() async throws {
        let socket = RecordingWebSocketTask()
        let client = await makeSocketBackedClient(socket: socket)
        await client.handleFrameString(#"""
        {"type":"tool_progress","request_id":"req-old-unscoped-after-good-final","project_key":"default","session_id":"project:default","payload":{"kind":"terminal","text":"Old run progress"}}
        """#)
        await client.cancelRun()
        let cancelRoot = try frameRoot(from: try XCTUnwrap(socket.sentMessages.last))
        let cancelRequestID = try XCTUnwrap(cancelRoot["request_id"] as? String)
        await client.handleFrameString("""
        {"type":"run_status","request_id":"\(cancelRequestID)","project_key":"default","session_id":"project:default","payload":{"status":"idle","cancelled":true}}
        """)
        let __sendResult46 = await client.sendText("new run after cancel")
        XCTAssertTrue(__sendResult46)
        let newRoot = try frameRoot(from: try XCTUnwrap(socket.sentMessages.last))
        let newRequestID = try XCTUnwrap(newRoot["request_id"] as? String)
        let baselineCount = socket.sentMessages.count
        await client.handleFrameString("""
        {"type":"state_update","request_id":"\(newRequestID)","project_key":"default","session_id":"project:default","server_seq":141,"payload":{"op":"message_appended","message":{"project_key":"default","session_id":"project:default","message_id":"assistant-new-after-cancel-final","server_seq":141,"role":"assistant","content":"New final after cancel.","timestamp":136.0,"metadata":{"finalized":true,"source":"hermes"}}}}
        """)
        await client.handleFrameString(#"""
        {"type":"state_update","project_key":"default","session_id":"project:default","server_seq":142,"payload":{"op":"message_appended","message":{"project_key":"default","session_id":"project:default","message_id":"assistant-old-unscoped-after-good-final","server_seq":142,"role":"assistant","content":"Old unscoped final after the good final.","timestamp":137.0,"metadata":{"finalized":true,"source":"hermes"}}}}
        """#)

        let newFrames = try socket.sentMessages.dropFirst(baselineCount).map { try frameRoot(from: $0) }
        let playbackFrames = newFrames.filter { $0["type"] as? String == "playback_audio" }
        XCTAssertEqual(playbackFrames.count, 1)
        XCTAssertEqual((playbackFrames[0]["payload"] as? [String: Any])?["message_id"] as? String, "assistant-new-after-cancel-final")
    }

    @MainActor
    func testServerDrivenCancelSuppressesActiveRunBeforeStaleFinal() async throws {
        let socket = RecordingWebSocketTask()
        let client = await makeSocketBackedClient(socket: socket)
        await client.handleFrameString(#"""
        {"type":"tool_progress","request_id":"req-server-driven-cancel","project_key":"default","session_id":"project:default","payload":{"kind":"terminal","text":"Server-side run is active"}}
        """#)
        XCTAssertEqual(client.progressActivity?.requestID, "req-server-driven-cancel")

        await client.handleFrameString(#"""
        {"type":"run_status","request_id":"server-cancel-status","project_key":"default","session_id":"project:default","payload":{"status":"cancelling"}}
        """#)
        await client.handleFrameString(#"""
        {"type":"run_status","request_id":"server-cancel-status","project_key":"default","session_id":"project:default","payload":{"status":"idle","cancelled":true}}
        """#)
        XCTAssertEqual(client.runStatus, .idle)
        XCTAssertEqual(client.progressActivity?.isComplete, true)
        XCTAssertEqual(client.progressActivity?.finalStatus, .stopped)
        XCTAssertNil(client.progressActivity?.retryRequest)
        let baselineCount = socket.sentMessages.count

        await client.handleFrameString(#"""
        {"type":"state_update","request_id":"req-server-driven-cancel","project_key":"default","session_id":"project:default","server_seq":139,"payload":{"op":"message_appended","message":{"project_key":"default","session_id":"project:default","message_id":"assistant-server-driven-cancel-final","server_seq":139,"role":"assistant","content":"Server-canceled final arrived late.","timestamp":134.0,"metadata":{"finalized":true,"source":"hermes"}}}}
        """#)

        let newFrames = try socket.sentMessages.dropFirst(baselineCount).map { try frameRoot(from: $0) }
        XCTAssertTrue(newFrames.filter { $0["type"] as? String == "playback_audio" }.isEmpty)
        XCTAssertEqual(client.runStatus, .idle)
    }

    @MainActor
    func testOutboundTextAndSpeechAreRejectedWhileCancelling() async throws {
        let socket = RecordingWebSocketTask()
        let client = await makeSocketBackedClient(socket: socket)
        await client.handleFrameString(#"""
        {"type":"tool_progress","request_id":"req-cancel-outbound","project_key":"default","session_id":"session-cancel-outbound","payload":{"kind":"terminal","text":"Current request is running"}}
        """#)
        await client.cancelRun()
        let baselineCount = socket.sentMessages.count

        let __sendResult47 = await client.sendText("new text while stopping")
        XCTAssertFalse(__sendResult47)
        let __sendResult48 = await client.sendSpeech(text: "new final speech while stopping", isFinal: true, inputID: "voice-during-cancel", partialSeq: 0, startedAtMilliseconds: 1)
        XCTAssertFalse(__sendResult48)
        let __sendResult49 = await client.sendSpeech(text: "new partial speech while stopping", isFinal: false, inputID: "voice-partial-during-cancel", partialSeq: 1, startedAtMilliseconds: 1)
        XCTAssertFalse(__sendResult49)

        let newFrames = try socket.sentMessages.dropFirst(baselineCount).map { try frameRoot(from: $0) }
        XCTAssertTrue(newFrames.isEmpty)
        XCTAssertTrue(client.messages.allSatisfy { $0.content != "new text while stopping" && $0.content != "new final speech while stopping" })
    }

    @MainActor
    func testReceiveLoopFailureClearsPendingInteractionState() async throws {
        let socket = RecordingWebSocketTask()
        let client = await makeSocketBackedClient(socket: socket)
        await Task.yield()
        await client.handleFrameString(#"""
        {"type":"approval_request","request_id":"approval-before-receive-failure","project_key":"default","session_id":"session-receive-failure","payload":{"approval_id":"approval-before-receive-failure","title":"Approve?","summary":"Needs confirmation","command_preview":"echo ok","risk":"fixture"}}
        """#)
        await client.approveCurrentRequest()
        XCTAssertEqual(client.approvalCard?.id, "approval-before-receive-failure")
        XCTAssertEqual(client.pendingInteractionResponseID, "approval-before-receive-failure")

        await socket.receiveFailure(RecordingSocketError())
        await yieldUntil { client.connectionState == .error }

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
        let client = await makeSocketBackedClient(socket: socket)
        await Task.yield()

        await client.handleFrameString(#"""
        {"type":"approval_request","request_id":"approval-send-fail","project_key":"default","session_id":"session-approval-fail","payload":{"approval_id":"approval-send-fail","title":"Approve?","summary":"Needs confirmation","command_preview":"echo ok","risk":"fixture"}}
        """#)
        // Park the approval-response send so the optimistic pending/ack state is observable before the
        // send completes (late) with a failure, which then clears it for retry.
        socket.holdNextSends()
        let approveTask = Task { @MainActor in await client.approveCurrentRequest() }
        while client.pendingInteractionResponseID != "approval-send-fail" {
            await Task.yield()
        }

        XCTAssertEqual(client.pendingInteractionResponseID, "approval-send-fail")
        XCTAssertEqual(client.ackText, "Approved. Waiting for Hermes…")

        await socket.completeHeldSend(error: RecordingSocketError())
        _ = await approveTask.value
        await yieldUntil { client.pendingInteractionResponseID == nil && client.connectionState == .error }

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
        let client = await makeSocketBackedClient(socket: socket, audioPlayback: controller)
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

        // Park the playback-request send so the requesting overlay is observable before the send
        // completes (late) with a failure, which then clears the overlay.
        socket.holdNextSends()
        let playbackTask = Task { @MainActor in await client.playback(message: message) }
        // The overlay flips to `.requesting` before `await sendAudioFrame` records the (parked) frame,
        // so gate on BOTH the phase and the recorded request frame — gating on the phase alone races
        // the send on a loaded runner, where `sentMessages.last` would still be a stale connection frame.
        await yieldUntil {
            client.audioPlaybackOverlay?.phase == .requesting
                && ((try? frameRoot(from: socket.sentMessages.last ?? .string("")))?["payload"] as? [String: Any])?["audio_id"] != nil
        }
        XCTAssertEqual(client.audioPlaybackOverlay?.phase, .requesting)
        let requestRoot = try frameRoot(from: try XCTUnwrap(socket.sentMessages.last))
        let requestPayload = try XCTUnwrap(requestRoot["payload"] as? [String: Any])
        let audioID = try XCTUnwrap(requestPayload["audio_id"] as? String)

        await socket.completeHeldSend(error: RecordingSocketError())
        _ = await playbackTask.value
        await yieldUntil { client.audioPlaybackOverlay == nil && client.connectionState == .error }

        XCTAssertNil(client.audioPlaybackOverlay)
        XCTAssertNil(client.playbackStatus)
        XCTAssertEqual(client.connectionState, .error)

        await client.handleFrameString("""
        {"type":"audio_chunk","device_id":"ios-simulator","project_key":"default","session_id":"session-playback-fail","payload":{"audio_id":"\(audioID)","message_id":"assistant-playback-fail","chunk_index":0,"data":"\(Data([1, 2]).base64EncodedString())"}}
        """)
        await client.handleFrameString("""
        {"type":"audio_end","device_id":"ios-simulator","project_key":"default","session_id":"session-playback-fail","payload":{"audio_id":"\(audioID)","message_id":"assistant-playback-fail","chunk_count":1}}
        """)
        XCTAssertEqual(factory.player.playCalls, 0)
    }

    @MainActor
    func testAudioEndActivationFailureMarksOverlayFailed() async throws {
        let socket = RecordingWebSocketTask()
        let session = RecordingAudioSessionManager()
        session.preparePlaybackError = RecordingAudioSessionError()
        let factory = RecordingAudioPlayerFactory()
        let controller = AudioPlaybackController(sessionManager: session, playerFactory: factory)
        let client = await makeSocketBackedClient(socket: socket, audioPlayback: controller)
        let message = LogosMessage(
            projectKey: "default",
            sessionID: "session-audio-activation-fail",
            messageID: "assistant-audio-activation-fail",
            serverSeq: 190,
            role: "assistant",
            content: "This audio activation will fail.",
            timestamp: 190,
            status: "persisted"
        )

        await client.playback(message: message)
        let requestRoot = try frameRoot(from: try XCTUnwrap(socket.sentMessages.last))
        let requestPayload = try XCTUnwrap(requestRoot["payload"] as? [String: Any])
        let audioID = try XCTUnwrap(requestPayload["audio_id"] as? String)
        await client.handleFrameString("""
        {"type":"audio_chunk","device_id":"ios-simulator","project_key":"default","session_id":"session-audio-activation-fail","payload":{"audio_id":"\(audioID)","message_id":"assistant-audio-activation-fail","chunk_index":0,"data":"\(Data([1, 2]).base64EncodedString())"}}
        """)

        await client.handleFrameString("""
        {"type":"audio_end","device_id":"ios-simulator","project_key":"default","session_id":"session-audio-activation-fail","payload":{"audio_id":"\(audioID)","message_id":"assistant-audio-activation-fail","chunk_count":1}}
        """)

        XCTAssertEqual(client.audioPlaybackOverlay?.phase, .failed)
        XCTAssertEqual(client.audioPlaybackOverlay?.detail, "Session activation failed")
        XCTAssertNil(client.playbackStatus)
        XCTAssertEqual(factory.player.playCalls, 0)
    }

    @MainActor
    func testSocketFailureFailsInFlightRequestedAudioOverlay() async throws {
        let socket = RecordingWebSocketTask()
        let client = await makeSocketBackedClient(socket: socket)
        let message = LogosMessage(
            projectKey: "default",
            sessionID: "session-audio-socket-fail",
            messageID: "assistant-audio-socket-fail",
            serverSeq: 191,
            role: "assistant",
            content: "This audio stream will be interrupted.",
            timestamp: 191,
            status: "persisted"
        )

        await client.playback(message: message)
        XCTAssertEqual(client.audioPlaybackOverlay?.phase, .requesting)

        socket.fail(message: "socket dropped during audio")
        await yieldUntil { client.connectionState == .error }

        XCTAssertEqual(client.connectionState, .error)
        XCTAssertEqual(client.audioPlaybackOverlay?.phase, .failed)
        XCTAssertEqual(client.audioPlaybackOverlay?.detail, "Audio stream interrupted. Reconnect and try again.")
        XCTAssertEqual(client.lastError, "socket dropped during audio")
    }

    @MainActor
    func testPlaybackOverlayControlsAudioLifecycleAndSuppressesStoppedFrames() async throws {
        let socket = RecordingWebSocketTask()
        let session = RecordingAudioSessionManager()
        let factory = RecordingAudioPlayerFactory()
        let controller = AudioPlaybackController(sessionManager: session, playerFactory: factory)
        let client = await makeSocketBackedClient(socket: socket, audioPlayback: controller)
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

        await client.playback(message: message)
        let requestRoot = try frameRoot(from: try XCTUnwrap(socket.sentMessages.last))
        let requestPayload = try XCTUnwrap(requestRoot["payload"] as? [String: Any])
        let audioID = try XCTUnwrap(requestPayload["audio_id"] as? String)
        XCTAssertEqual(requestPayload["mode"] as? String, "full")
        XCTAssertEqual(client.audioPlaybackOverlay?.audioID, audioID)
        XCTAssertEqual(client.audioPlaybackOverlay?.messageID, "assistant-overlay-1")
        XCTAssertEqual(client.audioPlaybackOverlay?.phase, .requesting)
        XCTAssertEqual(client.audioPlaybackOverlay?.canStop, true)

        let chunk = Data([1, 2, 3, 4]).base64EncodedString()
        await client.handleFrameString("""
        {"type":"audio_chunk","device_id":"ios-simulator","project_key":"default","session_id":"session-overlay","payload":{"audio_id":"\(audioID)","message_id":"assistant-overlay-1","chunk_index":0,"data":"\(chunk)"}}
        """)
        XCTAssertEqual(client.audioPlaybackOverlay?.phase, .receiving)
        XCTAssertEqual(client.audioPlaybackOverlay?.spectrumBins.count, 12)

        await client.handleFrameString("""
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
        await client.handleFrameString("""
        {"type":"audio_chunk","device_id":"ios-simulator","project_key":"default","session_id":"session-overlay","payload":{"audio_id":"\(audioID)","message_id":"assistant-overlay-1","chunk_index":1,"data":"\(chunk)"}}
        """)
        await client.handleFrameString("""
        {"type":"audio_end","device_id":"ios-simulator","project_key":"default","session_id":"session-overlay","payload":{"audio_id":"\(audioID)","message_id":"assistant-overlay-1","chunk_count":2}}
        """)
        XCTAssertEqual(factory.player.playCalls, playCallsAfterStop)
        XCTAssertNil(client.lastError)
    }

    @MainActor
    func testReceivingAudioKeepsSpectrumIdleUntilPlaybackStarts() async throws {
        let socket = RecordingWebSocketTask()
        let session = RecordingAudioSessionManager()
        let factory = RecordingAudioPlayerFactory()
        let controller = AudioPlaybackController(sessionManager: session, playerFactory: factory)
        let client = await makeSocketBackedClient(socket: socket, audioPlayback: controller)
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

        await client.playback(message: message)
        let requestRoot = try frameRoot(from: try XCTUnwrap(socket.sentMessages.last))
        let requestPayload = try XCTUnwrap(requestRoot["payload"] as? [String: Any])
        let audioID = try XCTUnwrap(requestPayload["audio_id"] as? String)
        await client.handleFrameString("""
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
        let client = await makeSocketBackedClient(socket: socket, audioPlayback: controller)
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

        await client.playback(message: message)
        let requestRoot = try frameRoot(from: try XCTUnwrap(socket.sentMessages.last))
        let requestPayload = try XCTUnwrap(requestRoot["payload"] as? [String: Any])
        let audioID = try XCTUnwrap(requestPayload["audio_id"] as? String)
        await client.handleFrameString("""
        {"type":"audio_chunk","device_id":"ios-simulator","project_key":"default","session_id":"session-spectrum-refresh","payload":{"audio_id":"\(audioID)","message_id":"assistant-spectrum-refresh-1","chunk_index":0,"data":"\(Data([1, 2, 3]).base64EncodedString())"}}
        """)
        await client.handleFrameString("""
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
        let client = await makeSocketBackedClient(socket: socket, audioPlayback: controller)
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

        await client.playback(message: message)
        let requestRoot = try frameRoot(from: try XCTUnwrap(socket.sentMessages.last))
        let requestPayload = try XCTUnwrap(requestRoot["payload"] as? [String: Any])
        let audioID = try XCTUnwrap(requestPayload["audio_id"] as? String)
        await client.handleFrameString("""
        {"type":"audio_chunk","device_id":"ios-simulator","project_key":"default","session_id":"session-spectrum-ticker","payload":{"audio_id":"\(audioID)","message_id":"assistant-spectrum-ticker-1","chunk_index":0,"data":"\(Data([1, 2, 3]).base64EncodedString())"}}
        """)
        factory.player.currentTime = 0.25
        await client.handleFrameString("""
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
        let client = await makeSocketBackedClient(socket: socket, audioPlayback: controller)
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

        await client.playback(message: message)
        let requestRoot = try frameRoot(from: try XCTUnwrap(socket.sentMessages.last))
        let requestPayload = try XCTUnwrap(requestRoot["payload"] as? [String: Any])
        let audioID = try XCTUnwrap(requestPayload["audio_id"] as? String)
        await client.handleFrameString("""
        {"type":"audio_chunk","device_id":"ios-simulator","project_key":"default","session_id":"session-finished-late-audio","payload":{"audio_id":"\(audioID)","message_id":"assistant-finished-late-audio-1","chunk_index":0,"data":"\(Data([1, 2, 3]).base64EncodedString())"}}
        """)
        await client.handleFrameString("""
        {"type":"audio_end","device_id":"ios-simulator","project_key":"default","session_id":"session-finished-late-audio","payload":{"audio_id":"\(audioID)","message_id":"assistant-finished-late-audio-1","chunk_count":1}}
        """)
        let playCallsBeforeFinish = factory.player.playCalls

        controller.onPlaybackFinished?(audioID, true)
        try await Task.sleep(for: .milliseconds(1))
        XCTAssertEqual(client.audioPlaybackOverlay?.phase, .finished)
        await client.handleFrameString("""
        {"type":"audio_chunk","device_id":"ios-simulator","project_key":"default","session_id":"session-finished-late-audio","payload":{"audio_id":"\(audioID)","message_id":"assistant-finished-late-audio-1","chunk_index":1,"data":"\(Data([4, 5, 6]).base64EncodedString())"}}
        """)
        await client.handleFrameString("""
        {"type":"audio_end","device_id":"ios-simulator","project_key":"default","session_id":"session-finished-late-audio","payload":{"audio_id":"\(audioID)","message_id":"assistant-finished-late-audio-1","chunk_count":2}}
        """)

        XCTAssertEqual(client.audioPlaybackOverlay?.phase, .finished)
        XCTAssertEqual(factory.player.playCalls, playCallsBeforeFinish)
    }

    @MainActor
    func testStoppedAudioRejectsStaleSpectrumRefresh() async throws {
        let socket = RecordingWebSocketTask()
        let session = RecordingAudioSessionManager()
        let factory = RecordingAudioPlayerFactory()
        let sampleRate = 24_000.0
        let decoder = RecordingAudioSampleDecoder(decodedSamples: DecodedAudioSamples(
            samples: sineWave(frequency: 160, sampleRate: sampleRate),
            sampleRate: sampleRate
        ))
        let controller = AudioPlaybackController(sessionManager: session, playerFactory: factory, sampleDecoder: decoder)
        let client = await makeSocketBackedClient(socket: socket, audioPlayback: controller)
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

        await client.playback(message: message)
        let requestRoot = try frameRoot(from: try XCTUnwrap(socket.sentMessages.last))
        let requestPayload = try XCTUnwrap(requestRoot["payload"] as? [String: Any])
        let audioID = try XCTUnwrap(requestPayload["audio_id"] as? String)
        await client.handleFrameString("""
        {"type":"audio_chunk","device_id":"ios-simulator","project_key":"default","session_id":"session-spectrum-stopped","payload":{"audio_id":"\(audioID)","message_id":"assistant-spectrum-stopped-1","chunk_index":0,"data":"\(Data([1, 2, 3]).base64EncodedString())"}}
        """)
        await client.handleFrameString("""
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
        let client = await makeSocketBackedClient(socket: socket, audioPlayback: controller)
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

        await client.playback(message: message)
        let requestRoot = try frameRoot(from: try XCTUnwrap(socket.sentMessages.last))
        let requestPayload = try XCTUnwrap(requestRoot["payload"] as? [String: Any])
        let audioID = try XCTUnwrap(requestPayload["audio_id"] as? String)
        let chunk = Data([9, 10, 11]).base64EncodedString()
        await client.handleFrameString("""
        {"type":"audio_chunk","device_id":"ios-simulator","project_key":"default","session_id":"session-overlay-finished","payload":{"audio_id":"\(audioID)","message_id":"assistant-overlay-finished-1","chunk_index":0,"data":"\(chunk)"}}
        """)
        await client.handleFrameString("""
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
    func testSceneLifecyclePauseResumeIsLocalAndPreservesOffset() async throws {
        let socket = RecordingWebSocketTask()
        let session = RecordingAudioSessionManager()
        let factory = RecordingAudioPlayerFactory()
        let controller = AudioPlaybackController(sessionManager: session, playerFactory: factory)
        let client = await makeSocketBackedClient(socket: socket, audioPlayback: controller)
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

        await client.playback(message: message)
        let requestRoot = try frameRoot(from: try XCTUnwrap(socket.sentMessages.last))
        let requestPayload = try XCTUnwrap(requestRoot["payload"] as? [String: Any])
        let audioID = try XCTUnwrap(requestPayload["audio_id"] as? String)
        let chunk = Data([5, 6]).base64EncodedString()
        await client.handleFrameString("""
        {"type":"audio_chunk","device_id":"ios-simulator","project_key":"default","session_id":"session-lifecycle","payload":{"audio_id":"\(audioID)","message_id":"assistant-lifecycle-1","chunk_index":0,"data":"\(chunk)"}}
        """)
        await client.handleFrameString("""
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
    func testManualPausedAudioDoesNotResumeOnSceneActive() async throws {
        let socket = RecordingWebSocketTask()
        let session = RecordingAudioSessionManager()
        let factory = RecordingAudioPlayerFactory()
        let controller = AudioPlaybackController(sessionManager: session, playerFactory: factory)
        let client = await makeSocketBackedClient(socket: socket, audioPlayback: controller)
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

        await client.playback(message: message)
        let requestRoot = try frameRoot(from: try XCTUnwrap(socket.sentMessages.last))
        let requestPayload = try XCTUnwrap(requestRoot["payload"] as? [String: Any])
        let audioID = try XCTUnwrap(requestPayload["audio_id"] as? String)
        let chunk = Data([7, 8]).base64EncodedString()
        await client.handleFrameString("""
        {"type":"audio_chunk","device_id":"ios-simulator","project_key":"default","session_id":"session-manual-pause","payload":{"audio_id":"\(audioID)","message_id":"assistant-manual-pause-1","chunk_index":0,"data":"\(chunk)"}}
        """)
        await client.handleFrameString("""
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
    func testNewPlaybackRequestStopsPriorAudioAndSuppressesLateFrames() async throws {
        let socket = RecordingWebSocketTask()
        let session = RecordingAudioSessionManager()
        let factory = RecordingAudioPlayerFactory()
        let controller = AudioPlaybackController(sessionManager: session, playerFactory: factory)
        let client = await makeSocketBackedClient(socket: socket, audioPlayback: controller)
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

        await client.playback(message: first)
        let firstRoot = try frameRoot(from: try XCTUnwrap(socket.sentMessages.last))
        let firstPayload = try XCTUnwrap(firstRoot["payload"] as? [String: Any])
        let firstAudioID = try XCTUnwrap(firstPayload["audio_id"] as? String)
        let chunk = Data([3, 4]).base64EncodedString()
        await client.handleFrameString("""
        {"type":"audio_chunk","device_id":"ios-simulator","project_key":"default","session_id":"session-replay-one","payload":{"audio_id":"\(firstAudioID)","message_id":"assistant-replay-1","chunk_index":0,"data":"\(chunk)"}}
        """)
        await client.handleFrameString("""
        {"type":"audio_end","device_id":"ios-simulator","project_key":"default","session_id":"session-replay-one","payload":{"audio_id":"\(firstAudioID)","message_id":"assistant-replay-1","chunk_count":1}}
        """)
        XCTAssertEqual(factory.player.playCalls, 1)

        await client.playback(message: second)
        let secondRoot = try frameRoot(from: try XCTUnwrap(socket.sentMessages.last))
        let secondPayload = try XCTUnwrap(secondRoot["payload"] as? [String: Any])
        XCTAssertNotEqual(secondPayload["audio_id"] as? String, firstAudioID)
        XCTAssertEqual(factory.player.stopCalls, 1)
        XCTAssertEqual(client.audioPlaybackOverlay?.messageID, "assistant-replay-2")

        await client.handleFrameString("""
        {"type":"audio_chunk","device_id":"ios-simulator","project_key":"default","session_id":"session-replay-one","payload":{"audio_id":"\(firstAudioID)","message_id":"assistant-replay-1","chunk_index":1,"data":"\(chunk)"}}
        """)
        await client.handleFrameString("""
        {"type":"audio_end","device_id":"ios-simulator","project_key":"default","session_id":"session-replay-one","payload":{"audio_id":"\(firstAudioID)","message_id":"assistant-replay-1","chunk_count":2}}
        """)
        XCTAssertEqual(factory.player.playCalls, 1)
        XCTAssertEqual(client.audioPlaybackOverlay?.messageID, "assistant-replay-2")
    }

    @MainActor
    func testProjectSwitchStopsAudioAndRejectsLateFrames() async throws {
        let socket = RecordingWebSocketTask()
        let session = RecordingAudioSessionManager()
        let factory = RecordingAudioPlayerFactory()
        let controller = AudioPlaybackController(sessionManager: session, playerFactory: factory)
        let client = await makeSocketBackedClient(socket: socket, audioPlayback: controller)
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

        await client.playback(message: message)
        let requestRoot = try frameRoot(from: try XCTUnwrap(socket.sentMessages.last))
        let requestPayload = try XCTUnwrap(requestRoot["payload"] as? [String: Any])
        let audioID = try XCTUnwrap(requestPayload["audio_id"] as? String)
        await client.switchProject("beta")

        XCTAssertNil(client.audioPlaybackOverlay)
        XCTAssertNil(client.playbackStatus)
        await client.handleFrameString("""
        {"type":"audio_chunk","device_id":"ios-simulator","project_key":"default","session_id":"session-project-audio","payload":{"audio_id":"\(audioID)","message_id":"assistant-project-audio-1","chunk_index":0,"data":"\(Data([1]).base64EncodedString())"}}
        """)
        await client.handleFrameString("""
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
    func testFastAckClearsWhenAssistantMessageArrives() async throws {
        let client = LogosClient(store: SQLiteMessageStore(filename: "LogosTests-\(UUID().uuidString).sqlite3"))

        await client.handleFrameString(#"""
        {"type":"state_update","request_id":"req-ack","project_key":"default","payload":{"op":"fast_ack","ack_text":"I'll check.","transient":true,"ttl_ms":5000}}
        """#)
        XCTAssertEqual(client.ackText, "I'll check.")

        await client.handleFrameString(#"""
        {"type":"state_update","project_key":"default","session_id":"session-ack","server_seq":51,"payload":{"op":"message_appended","message":{"project_key":"default","session_id":"session-ack","message_id":"assistant-ack-1","server_seq":51,"role":"assistant","content":"Checked. Clean.","timestamp":123.0}}}
        """#)

        XCTAssertNil(client.ackText)
    }

    @MainActor
    func testFastAckClearsWhenRunStatusBecomesTerminal() async throws {
        let client = LogosClient(store: SQLiteMessageStore(filename: "LogosTests-\(UUID().uuidString).sqlite3"))

        await client.handleFrameString(#"""
        {"type":"state_update","request_id":"req-ack","project_key":"default","payload":{"op":"fast_ack","ack_text":"Working on it.","transient":true,"ttl_ms":5000}}
        """#)
        XCTAssertEqual(client.ackText, "Working on it.")

        await client.handleFrameString(#"""
        {"type":"run_status","project_key":"default","payload":{"status":"idle"}}
        """#)

        XCTAssertNil(client.ackText)
    }

    @MainActor
    func testFastAckTTLExpiresWithoutClearingNewerAckEarly() async throws {
        let scheduler = ManualAckClearScheduler()
        let client = LogosClient(
            store: SQLiteMessageStore(filename: "LogosTests-\(UUID().uuidString).sqlite3"),
            ackClearScheduler: scheduler
        )

        await client.handleFrameString(#"""
        {"type":"state_update","request_id":"old-ack","project_key":"default","payload":{"op":"fast_ack","ack_text":"Old ack.","transient":true,"ttl_ms":40}}
        """#)
        XCTAssertEqual(client.ackText, "Old ack.")
        // The shorter-lived ack armed a clear at its 40ms TTL.
        XCTAssertEqual(try XCTUnwrap(scheduler.lastInterval), 0.040, accuracy: 0.0001)
        let staleClear = try XCTUnwrap(scheduler.pendingClear)
        let scheduleCountAfterOld = scheduler.scheduleCount

        await client.handleFrameString(#"""
        {"type":"state_update","request_id":"new-ack","project_key":"default","payload":{"op":"fast_ack","ack_text":"New ack.","transient":true,"ttl_ms":220}}
        """#)
        XCTAssertEqual(client.ackText, "New ack.")
        // The newer ack supersedes the pending clear with its own 220ms timer, so
        // the stale 40ms timer no longer governs the visible ack.
        XCTAssertGreaterThan(scheduler.scheduleCount, scheduleCountAfterOld)
        XCTAssertEqual(try XCTUnwrap(scheduler.lastInterval), 0.220, accuracy: 0.0001)

        // Even if the superseded 40ms timer fires late, the id guard keeps the
        // newer ack visible — it must not be cleared early.
        staleClear()
        XCTAssertEqual(client.ackText, "New ack.")

        // The newer ack clears only when its own TTL fires.
        XCTAssertTrue(scheduler.fireAckClear())
        XCTAssertNil(client.ackText)
    }

    @MainActor
    func testFastAckIgnoresInactiveProject() async throws {
        let client = LogosClient(store: SQLiteMessageStore(filename: "LogosTests-\(UUID().uuidString).sqlite3"))
        client.activeProjectKey = "default"

        await client.handleFrameString(#"""
        {"type":"state_update","request_id":"req-ack","project_key":"other","payload":{"op":"fast_ack","ack_text":"Wrong project.","transient":true,"ttl_ms":5000}}
        """#)

        XCTAssertNil(client.ackText)
    }

    @MainActor
    func testFastAckSurvivesSameActiveProjectRefresh() async throws {
        let client = LogosClient(store: SQLiteMessageStore(filename: "LogosTests-\(UUID().uuidString).sqlite3"))

        await client.handleFrameString(#"""
        {"type":"state_update","request_id":"req-ack","project_key":"default","payload":{"op":"fast_ack","ack_text":"I'll check.","transient":true,"ttl_ms":5000}}
        """#)
        XCTAssertEqual(client.ackText, "I'll check.")

        await client.handleFrameString(#"""
        {"type":"projects_list","payload":{"active_project_key":"default","projects":[{"project_key":"default","title":"Default","current_session_id":"project:default","last_preview":""}]}}
        """#)

        XCTAssertEqual(client.ackText, "I'll check.")
    }

    @MainActor
    func testAdapterErrorClearsFastAck() async throws {
        let client = LogosClient(store: SQLiteMessageStore(filename: "LogosTests-\(UUID().uuidString).sqlite3"))

        await client.handleFrameString(#"""
        {"type":"state_update","request_id":"req-ack","project_key":"default","payload":{"op":"fast_ack","ack_text":"I'll check.","transient":true,"ttl_ms":5000}}
        """#)
        XCTAssertEqual(client.ackText, "I'll check.")

        await client.handleFrameString(#"""
        {"type":"error","request_id":"req-ack","project_key":"default","payload":{"code":"server_error","message":"Hermes failed."}}
        """#)

        XCTAssertNil(client.ackText)
        XCTAssertEqual(client.lastError, "Hermes failed.")
    }

    @MainActor
    func testInteractionReconciliationClearsResponseAck() async throws {
        let socket = RecordingWebSocketTask()
        let client = await makeSocketBackedClient(socket: socket)

        await client.handleFrameString(#"""
        {"type":"approval_request","request_id":"appr-1","project_key":"default","payload":{"title":"Approve command?","summary":"Hermes needs approval.","command_preview":"python test.py","risk":"low"}}
        """#)
        await client.approveCurrentRequest()
        XCTAssertEqual(client.ackText, "Approved. Waiting for Hermes…")

        await client.handleFrameString(#"""
        {"type":"messages_batch","project_key":"default","payload":{"messages":[],"pending_interactions":[]}}
        """#)

        XCTAssertNil(client.approvalCard)
        XCTAssertNil(client.pendingInteractionResponseID)
        XCTAssertNil(client.ackText)
    }

    @MainActor
    func testFastDirectResponseClearsAckAndAutoplaysOnce() async throws {
        let socket = RecordingWebSocketTask()
        let client = await makeSocketBackedClient(socket: socket)
        await client.handleFrameString(#"""
        {"type":"state_update","request_id":"req-ack","project_key":"default","payload":{"op":"fast_ack","ack_text":"I'll check.","transient":true,"ttl_ms":5000}}
        """#)
        XCTAssertEqual(client.ackText, "I'll check.")
        let baselineCount = socket.sentMessages.count

        await client.handleFrameString(#"""
        {"type":"state_update","project_key":"default","session_id":"session-fast","server_seq":60,"payload":{"op":"message_appended","message":{"project_key":"default","session_id":"session-fast","message_id":"fast-req-hi","server_seq":60,"role":"assistant","content":"I'm here.","timestamp":123.0,"metadata":{"source":"fast_response"}}}}
        """#)

        XCTAssertNil(client.ackText)
        XCTAssertEqual(client.messages.last?.messageID, "fast-req-hi")
        XCTAssertEqual(client.messages.last?.content, "I'm here.")
        let newFrames = try socket.sentMessages.dropFirst(baselineCount).map { try frameRoot(from: $0) }
        XCTAssertEqual(newFrames.filter { $0["type"] as? String == "playback_audio" }.count, 1)
    }

    @MainActor
    func testActiveFastDirectResponseWithFinalMetadataCompletesProgressAndAutoplays() async throws {
        let socket = RecordingWebSocketTask()
        let client = await makeSocketBackedClient(socket: socket)

        let __sendResult50 = await client.sendText("hi")
        XCTAssertTrue(__sendResult50)
        let textFrame = try XCTUnwrap(try socket.sentMessages.map { try frameRoot(from: $0) }.last { $0["type"] as? String == "text_input" })
        let requestID = try XCTUnwrap(textFrame["request_id"] as? String)
        let baselineCount = socket.sentMessages.count

        await client.handleFrameString("""
        {"type":"state_update","request_id":"\(requestID)","project_key":"default","session_id":"project:default","server_seq":61,"payload":{"op":"message_appended","message":{"project_key":"default","session_id":"project:default","message_id":"fast-\(requestID)","server_seq":61,"role":"assistant","content":"I'm here.","timestamp":124.0,"metadata":{"finalized":true,"source":"fast_response","request_id":"\(requestID)"}}}}
        """)

        XCTAssertEqual(client.progressActivity?.requestID, requestID)
        XCTAssertEqual(client.progressActivity?.finalStatus, .complete)
        XCTAssertTrue(client.messages.contains { $0.messageID == "fast-\(requestID)" && $0.content == "I'm here." })
        let newFrames = try socket.sentMessages.dropFirst(baselineCount).map { try frameRoot(from: $0) }
        XCTAssertEqual(newFrames.filter { $0["type"] as? String == "playback_audio" }.count, 1)
    }

    @MainActor
    func testAudioFramesForOtherDevicesAreIgnored() async throws {
        let client = LogosClient()
        client.settings.deviceID = "iphone-a"

        await client.handleFrameString("""
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

    // WS1 P5 prerequisite: behavioral coverage of the audio/playback flow THROUGH LogosClient
    // (request -> receive -> play -> stop, plus the unsolicited-frame gate). This pins the
    // observable state machine so the audio internals can later be lifted into a collaborator.
    @MainActor
    func testAudioPlaybackFlowThroughClientRequestReceivePlayStop() async throws {
        let socket = RecordingWebSocketTask()
        let factory = RecordingAudioPlayerFactory()
        let decoder = RecordingAudioSampleDecoder(decodedSamples: DecodedAudioSamples(samples: [0.1, -0.1, 0.2], sampleRate: 24_000))
        let audio = AudioPlaybackController(sessionManager: RecordingAudioSessionManager(), playerFactory: factory, sampleDecoder: decoder)
        let client = await makeSocketBackedClient(socket: socket, audioPlayback: audio)
        client.activeProjectKey = "default"

        let message = LogosMessage(
            projectKey: "default", sessionID: "s1", messageID: "m1", serverSeq: 5,
            role: "assistant", content: "hello world", timestamp: 1, status: "persisted"
        )

        // 1. Request playback -> requesting overlay + a playback_audio frame carrying the id.
        await client.playback(message: message)
        let audioID = try XCTUnwrap(client.audioPlaybackOverlay?.audioID)
        XCTAssertEqual(client.audioPlaybackOverlay?.phase, .requesting)
        XCTAssertEqual(client.playbackStatus, "Requesting audio")
        let sent = try frameRoot(from: try XCTUnwrap(socket.sentMessages.last))
        XCTAssertEqual(sent["type"] as? String, "playback_audio")
        XCTAssertEqual((sent["payload"] as? [String: Any])?["audio_id"] as? String, audioID)

        // 2. An unsolicited chunk (different id) must be ignored — the gate holds.
        await client.handleFrameString(#"{"type":"audio_chunk","device_id":"ios-simulator","project_key":"default","session_id":"s1","payload":{"audio_id":"intruder","chunk_index":0,"data":"AQID"}}"#)
        XCTAssertEqual(client.audioPlaybackOverlay?.audioID, audioID)
        XCTAssertEqual(client.audioPlaybackOverlay?.phase, .requesting)

        // 3. The matching chunk advances to receiving.
        await client.handleFrameString(
            "{\"type\":\"audio_chunk\",\"device_id\":\"ios-simulator\",\"project_key\":\"default\",\"session_id\":\"s1\",\"payload\":{\"audio_id\":\"\(audioID)\",\"chunk_index\":0,\"data\":\"AQID\",\"mime_type\":\"audio/mp4\",\"encoding\":\"m4a\"}}"
        )
        XCTAssertEqual(client.audioPlaybackOverlay?.phase, .receiving)
        XCTAssertEqual(client.playbackStatus, "Receiving audio")

        // 4. audio_end finalizes and starts playback.
        await client.handleFrameString(
            "{\"type\":\"audio_end\",\"device_id\":\"ios-simulator\",\"project_key\":\"default\",\"session_id\":\"s1\",\"payload\":{\"audio_id\":\"\(audioID)\",\"chunk_count\":1}}"
        )
        XCTAssertEqual(client.audioPlaybackOverlay?.phase, .playing)
        XCTAssertEqual(factory.player.playCalls, 1)

        // 5. Stop clears the overlay/status.
        client.stopPlayback()
        XCTAssertNil(client.audioPlaybackOverlay)
        XCTAssertNil(client.playbackStatus)
        XCTAssertEqual(factory.player.stopCalls, 1)
    }

    // WS1 P5 prerequisite (cont.): scene background/foreground pause+resume of active playback.
    @MainActor
    func testAudioPlaybackSceneLifecyclePauseResumeThroughClient() async throws {
        let socket = RecordingWebSocketTask()
        let factory = RecordingAudioPlayerFactory()
        let decoder = RecordingAudioSampleDecoder(decodedSamples: DecodedAudioSamples(samples: [0.1, -0.1], sampleRate: 24_000))
        let audio = AudioPlaybackController(sessionManager: RecordingAudioSessionManager(), playerFactory: factory, sampleDecoder: decoder)
        let client = await makeSocketBackedClient(socket: socket, audioPlayback: audio)
        client.activeProjectKey = "default"

        let message = LogosMessage(
            projectKey: "default", sessionID: "s1", messageID: "m1", serverSeq: 5,
            role: "assistant", content: "hello", timestamp: 1, status: "persisted"
        )
        await client.playback(message: message)
        let audioID = try XCTUnwrap(client.audioPlaybackOverlay?.audioID)
        await client.handleFrameString(
            "{\"type\":\"audio_chunk\",\"device_id\":\"ios-simulator\",\"project_key\":\"default\",\"session_id\":\"s1\",\"payload\":{\"audio_id\":\"\(audioID)\",\"chunk_index\":0,\"data\":\"AQID\"}}"
        )
        await client.handleFrameString(
            "{\"type\":\"audio_end\",\"device_id\":\"ios-simulator\",\"project_key\":\"default\",\"session_id\":\"s1\",\"payload\":{\"audio_id\":\"\(audioID)\",\"chunk_count\":1}}"
        )
        XCTAssertEqual(client.audioPlaybackOverlay?.phase, .playing)

        // Backgrounding the scene pauses the active player and reflects it in the overlay.
        client.pauseAudioForSceneBackground()
        XCTAssertEqual(client.audioPlaybackOverlay?.phase, .paused)
        XCTAssertEqual(factory.player.pauseCalls, 1)

        // Returning to foreground resumes it.
        client.resumeAudioForSceneActive()
        XCTAssertEqual(client.audioPlaybackOverlay?.phase, .playing)
        XCTAssertGreaterThanOrEqual(factory.player.playCalls, 2)
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
    func testOversizedInboundFrameIsRejectedBeforeJSONParsing() async throws {
        let socket = RecordingWebSocketTask()
        let client = await makeSocketBackedClient(socket: socket)
        let previousState = client.connectionState

        let oversizedMessage = String(repeating: "x", count: 2_000_000)
        let frame = """
        {"type":"error","request_id":"oversized-error","payload":{"code":"auth_failed","reason":"invalid_signature","message":"\(oversizedMessage)"}}
        """
        XCTAssertGreaterThan(frame.utf8.count, 2_000_000)

        await client.handleFrameString(frame)

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
            try await Task.sleep(for: .milliseconds(20))
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
    var preparePlaybackError: Error?

    func prepareForRecording() throws {
        prepareRecordingCalls += 1
    }

    func finishRecording() throws {
        finishRecordingCalls += 1
    }

    func prepareForPlayback() throws {
        prepareCalls += 1
        if let preparePlaybackError {
            throw preparePlaybackError
        }
    }

    func finishPlayback() throws {
        finishCalls += 1
    }
}

private struct RecordingAudioSessionError: LocalizedError {
    var errorDescription: String? {
        "Session activation failed"
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

private final class RecordingAudioSampleDecoder: AudioSampleDecoding, @unchecked Sendable {
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

private final class RecordingPairingCredentialExchanger: PairingCredentialExchanging, @unchecked Sendable {
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

/// Test double for `DelayedFireScheduling` that records scheduling activity and
/// fires the pending stale-timeout synchronously, so timeout behavior can be
/// asserted deterministically without sleeping against a real timer.
@MainActor
final class ManualStaleTimeoutScheduler: DelayedFireScheduling {
    private(set) var scheduleCount = 0
    private(set) var lastInterval: TimeInterval?
    private var pendingFire: (@MainActor () -> Void)?

    /// Whether a fire is currently armed (scheduled and not yet fired or cancelled).
    var hasPendingTimeout: Bool { pendingFire != nil }

    func schedule(after interval: TimeInterval, fire: @escaping @MainActor () -> Void) {
        scheduleCount += 1
        lastInterval = interval
        pendingFire = fire
    }

    func cancel() {
        pendingFire = nil
    }

    /// Synchronously invoke the currently-armed timeout, mimicking the real timer
    /// firing. The repeat-reschedule that happens inside the fire installs a fresh
    /// pending fire. Returns whether a fire was armed.
    @discardableResult
    func fireStaleTimeout() -> Bool {
        guard let fire = pendingFire else { return false }
        pendingFire = nil
        fire()
        return true
    }
}

/// Test double for `DelayedFireScheduling` that records scheduling activity and
/// fires the pending fast-ack clear synchronously, so TTL-expiry behavior can be
/// asserted deterministically without sleeping against a real timer.
@MainActor
final class ManualAckClearScheduler: DelayedFireScheduling {
    private(set) var scheduleCount = 0
    private(set) var lastInterval: TimeInterval?
    /// The currently-armed clear, exposed so a test can fire a superseded timer
    /// late and verify the id guard keeps a newer ack visible.
    private(set) var pendingClear: (@MainActor () -> Void)?

    func schedule(after interval: TimeInterval, fire: @escaping @MainActor () -> Void) {
        scheduleCount += 1
        lastInterval = interval
        pendingClear = fire
    }

    func cancel() {
        pendingClear = nil
    }

    /// Synchronously invoke the currently-armed clear, mimicking the real timer
    /// firing once the TTL elapses. Returns whether a clear was armed.
    @discardableResult
    func fireAckClear() -> Bool {
        guard let fire = pendingClear else { return false }
        pendingClear = nil
        fire()
        return true
    }
}

/// Cooperative-yield until `condition` holds (or a bounded number of hops elapse). Inbound-frame
/// handling now runs on the connection's receive-loop `Task`, so after feeding a frame / failure the
/// effects land a few executor hops later; this lets the test observe the settled state without a
/// fixed sleep.
@MainActor
private func yieldUntil(_ condition: @MainActor () -> Bool, maxYields: Int = 200) async {
    var hops = 0
    while condition() == false, hops < maxYields {
        await Task.yield()
        hops += 1
    }
}

@MainActor
private func makeSocketBackedClient(
    socket: RecordingWebSocketTask,
    autoConnect: Bool = true,
    store: SQLiteMessageStore? = nil,
    audioPlayback: AudioPlaybackController = AudioPlaybackController(),
    staleTimeoutInterval: TimeInterval = 45,
    staleTimeoutScheduler: (any DelayedFireScheduling)? = nil
) async -> LogosClient {
    let client = LogosClient(
        store: store ?? SQLiteMessageStore(filename: "LogosTests-\(UUID().uuidString).sqlite3"),
        socketFactory: RecordingWebSocketTaskFactory(socket: socket),
        audioPlayback: audioPlayback,
        staleTimeoutInterval: staleTimeoutInterval,
        staleTimeoutScheduler: staleTimeoutScheduler
    )
    client.settings.urlString = "ws://127.0.0.1:8765"
    client.settings.deviceID = "ios-simulator"
    client.settings.secret = "test-secret"
    client.settings.autoConnect = autoConnect
    await client.updateSceneActivationForPlayback(isActive: true)
    client.connect()
    socket.open()
    await client.handleFrameString(#"{"type":"hello","request_id":"hello-1","payload":{}}"#)
    return client
}

private final class RecordingWebSocketTaskFactory: WebSocketTaskMaking {
    private let socket: RecordingWebSocketTask

    init(socket: RecordingWebSocketTask) {
        self.socket = socket
    }

    private(set) var lastPinnedSPKISHA256: String?

    func webSocketTask(
        with url: URL,
        lifecycleObserver: (any WebSocketLifecycleObserving)?,
        pinnedSPKISHA256: String?
    ) -> any WebSocketTasking {
        socket.lifecycleObserver = lifecycleObserver
        lastPinnedSPKISHA256 = pinnedSPKISHA256
        return socket
    }
}

private final class RecordingWebSocketTask: WebSocketTasking, @unchecked Sendable {
    private let lock = NSLock()
    private var _sentMessages: [URLSessionWebSocketTask.Message] = []
    private var queuedSendErrors: [Error] = []
    private var receiveContinuations: [CheckedContinuation<URLSessionWebSocketTask.Message, Error>] = []
    private var bufferedReceives: [Result<URLSessionWebSocketTask.Message, Error>] = []
    // Parked-send support: when `holdSends` is set, `send()` suspends until `completeHeldSend(error:)`
    // resolves it. This recreates the old "in-flight send across a disconnect / stale connection"
    // window that the non-suspending fast path collapses, so the late-completion / disconnect-restore
    // tests can still exercise the stale-connection guard.
    private var holdSends = false
    private var heldSendContinuations: [CheckedContinuation<Void, Error>] = []
    weak var lifecycleObserver: (any WebSocketLifecycleObserving)?

    var sentMessages: [URLSessionWebSocketTask.Message] { lock.withLock { _sentMessages } }

    func resume() {}

    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {}

    func open() {
        lifecycleObserver?.webSocketDidOpen(taskID: ObjectIdentifier(self))
    }

    func fail(message: String = "Socket is not connected") {
        lifecycleObserver?.webSocketDidFail(taskID: ObjectIdentifier(self), message: message)
    }

    func send(_ message: URLSessionWebSocketTask.Message) async throws {
        let parked: Bool = lock.withLock {
            _sentMessages.append(message)
            return holdSends
        }
        if parked {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                lock.withLock { heldSendContinuations.append(continuation) }
            }
            return
        }
        let error: Error? = lock.withLock {
            queuedSendErrors.isEmpty ? nil : queuedSendErrors.removeFirst()
        }
        if let error { throw error }
    }

    /// Park subsequent sends so the send remains in flight (suspended) until `completeHeldSend(error:)`.
    func holdNextSends() { lock.withLock { holdSends = true } }

    /// Resolve the oldest parked send, modeling a late send completion that arrives after the socket
    /// changed; `error == nil` completes it successfully. Waits (cooperative yields) for a parked send.
    func completeHeldSend(error: Error?) async {
        while true {
            let continuation: CheckedContinuation<Void, Error>? = lock.withLock {
                heldSendContinuations.isEmpty ? nil : heldSendContinuations.removeFirst()
            }
            if let continuation {
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
                return
            }
            await Task.yield()
        }
    }

    func receive() async throws -> URLSessionWebSocketTask.Message {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URLSessionWebSocketTask.Message, Error>) in
            let buffered: Result<URLSessionWebSocketTask.Message, Error>? = lock.withLock {
                if bufferedReceives.isEmpty {
                    receiveContinuations.append(continuation)
                    return nil
                }
                return bufferedReceives.removeFirst()
            }
            if let buffered { continuation.resume(with: buffered) }
        }
    }

    /// Queue an error so the NEXT send throws (replaces the old `completeLastSend(error:)` failure path).
    func failNextSend(_ error: Error) { lock.withLock { queuedSendErrors.append(error) } }

    /// Feed an inbound frame; waits (cooperative yields) until the connection's receive() is pending, then resolves it.
    func receiveString(_ string: String) async { await resumeReceive(.success(.string(string))) }

    func receiveFailure(_ error: Error) async { await resumeReceive(.failure(error)) }

    private func resumeReceive(_ result: Result<URLSessionWebSocketTask.Message, Error>) async {
        while true {
            let continuation: CheckedContinuation<URLSessionWebSocketTask.Message, Error>? = lock.withLock {
                receiveContinuations.isEmpty ? nil : receiveContinuations.removeFirst()
            }
            if let continuation {
                continuation.resume(with: result)
                return
            }
            await Task.yield()
        }
    }
}

private struct RecordingSocketError: LocalizedError {
    var errorDescription: String? {
        "socket send failed"
    }
}
