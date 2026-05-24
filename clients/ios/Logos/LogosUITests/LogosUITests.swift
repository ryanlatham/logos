import XCTest

final class LogosUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testTextMessageRoundTripThroughMockAdapter() throws {
        let app = launchConfiguredApp()
        XCTAssertTrue(waitForConnectedHome(in: app))
        assertSettingsSectionsPresent(in: app)
        assertComposerPresent(in: app)

        send("from simulator ui test", in: app)

        XCTAssertTrue(app.staticTexts["Mock Hermes received: from simulator ui test"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts.matching(identifier: "connectionStatusLabel").firstMatch.waitForExistence(timeout: 8))
        let playButtons = app.buttons.matching(identifier: "playMessageButton")
        XCTAssertTrue(playButtons.firstMatch.waitForExistence(timeout: 8))
        let playButton = playButtons.element(boundBy: max(playButtons.count - 1, 0))
        playButton.tap()
        XCTAssertTrue(waitForPlaybackStatus(in: app))
    }

    func testApprovalAndClarificationCardsRenderFromMockAdapterFixtures() throws {
        let app = launchConfiguredApp()
        XCTAssertTrue(waitForConnectedHome(in: app))

        send("/mock_approval", in: app)
        XCTAssertTrue(app.staticTexts["Stage F fixture approval"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Fixture only; no command is executed."].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Approve"].exists)
        app.buttons["Approve"].tap()

        send("/mock_clarify", in: app)
        XCTAssertTrue(app.staticTexts["Which Stage F path should Logos test?"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["text"].waitForExistence(timeout: 10))
        app.buttons["text"].tap()
    }

    func testProjectTitleFieldAcceptsImmediateTyping() throws {
        let app = launchConfiguredApp()
        XCTAssertTrue(waitForConnectedHome(in: app))

        let projectPicker = app.buttons["projectPicker"]
        XCTAssertTrue(projectPicker.waitForExistence(timeout: 8))
        projectPicker.tap()

        let newProject = app.buttons["New project"]
        XCTAssertTrue(newProject.waitForExistence(timeout: 8))
        newProject.tap()

        let projectTitle = app.textFields["newProjectTitleField"]
        XCTAssertTrue(projectTitle.waitForExistence(timeout: 8))
        projectTitle.tap()
        projectTitle.typeText("scenario two")

        XCTAssertEqual(projectTitle.value as? String, "scenario two")
        XCTAssertTrue(app.buttons["Create & open"].isEnabled)
    }

    func testProjectHeaderIsCenteredInNavigationBar() throws {
        let app = launchConfiguredApp()
        XCTAssertTrue(waitForConnectedHome(in: app))

        let projectPicker = app.buttons["projectPicker"]
        let statusLabel = app.staticTexts.matching(identifier: "connectionStatusLabel").firstMatch
        XCTAssertTrue(projectPicker.waitForExistence(timeout: 8))
        XCTAssertTrue(statusLabel.waitForExistence(timeout: 8))

        let screenMidX = app.windows.firstMatch.frame.midX
        XCTAssertLessThan(abs(projectPicker.frame.midX - screenMidX), 8, "Project selector should be visually centered in the nav bar")
        XCTAssertLessThan(abs(statusLabel.frame.midX - screenMidX), 14, "Status text should sit under the centered project selector")
    }

    func testComposerStartsInAudioMode() throws {
        let app = launchConfiguredApp()
        XCTAssertTrue(waitForConnectedHome(in: app))

        XCTAssertTrue(app.buttons["recordButton"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["keyboardModeButton"].waitForExistence(timeout: 8))
        XCTAssertFalse(app.textFields["composerTextField"].exists)
    }

    func testThreadAutoFollowsDelayedUpdatesWhenNearBottom() throws {
        let app = launchConfiguredApp()
        XCTAssertTrue(waitForConnectedHome(in: app))
        createUniqueProject(in: app)
        fillOverflowingThread(in: app)

        send("/mock_delayed_thread_updates", in: app)

        let finalUpdate = app.staticTexts["Delayed final update: thread auto-follow fixture complete."].firstMatch
        XCTAssertTrue(finalUpdate.waitForExistence(timeout: 12))
        XCTAssertTrue(waitForVisible(finalUpdate, in: app, timeout: 8), "Latest delayed update should be visible when the thread is near the bottom")
        XCTAssertFalse(app.buttons["threadNewUpdatesButton"].exists)
    }

    func testThreadStillAutoFollowsAfterSmallBottomDrag() throws {
        let app = launchConfiguredApp()
        XCTAssertTrue(waitForConnectedHome(in: app))
        createUniqueProject(in: app)
        fillOverflowingThread(in: app)

        send("/mock_delayed_thread_updates", in: app)

        let thread = app.scrollViews["conversationThreadScrollView"]
        XCTAssertTrue(thread.waitForExistence(timeout: 8))
        nudgeThreadNearBottom(thread)

        let finalUpdate = app.staticTexts["Delayed final update: thread auto-follow fixture complete."].firstMatch
        XCTAssertTrue(finalUpdate.waitForExistence(timeout: 12))
        XCTAssertTrue(waitForVisible(finalUpdate, in: app, timeout: 8), "A small drag at the bottom should not detach auto-follow")
        XCTAssertFalse(app.buttons["threadNewUpdatesButton"].exists)
    }

    func testThreadAutoFollowsTallUpdateWhenNearBottom() throws {
        let app = launchConfiguredApp()
        XCTAssertTrue(waitForConnectedHome(in: app))
        createUniqueProject(in: app)
        fillOverflowingThread(in: app)

        send("/mock_tall_thread_update", in: app)

        let finalUpdate = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Tall delayed final update")).firstMatch
        XCTAssertTrue(finalUpdate.waitForExistence(timeout: 12))
        XCTAssertTrue(waitForVisible(finalUpdate, in: app, timeout: 8), "A tall incoming bubble should still auto-follow when the user was at the bottom")
        XCTAssertFalse(app.buttons["threadNewUpdatesButton"].exists)
    }

    func testShortThreadBottomAlignsLatestMessageNearComposer() throws {
        let app = launchConfiguredApp()
        XCTAssertTrue(waitForConnectedHome(in: app))
        createUniqueProject(in: app)

        send("short bottom alignment target", in: app)

        let responseMessage = app.staticTexts["Mock Hermes received: short bottom alignment target"].firstMatch
        XCTAssertTrue(responseMessage.waitForExistence(timeout: 10))
        XCTAssertTrue(waitForVisible(responseMessage, in: app, timeout: 8))

        assertElementSitsNearComposer(responseMessage, in: app, message: "A short thread should keep the latest message visually anchored near the composer")
    }

    func testThreadReanchorsAfterRunControlDisappears() throws {
        let app = launchConfiguredApp()
        XCTAssertTrue(waitForConnectedHome(in: app))
        createUniqueProject(in: app)
        fillOverflowingThread(in: app)

        send("/mock_run_control_shrink", in: app)

        let runningStatus = app.staticTexts["Running"].firstMatch
        XCTAssertTrue(runningStatus.waitForExistence(timeout: 8))
        XCTAssertTrue(waitForVisible(runningStatus, in: app, timeout: 8))

        let responseMessage = app.staticTexts["Run control shrink final update complete."].firstMatch
        XCTAssertTrue(responseMessage.waitForExistence(timeout: 12))
        XCTAssertTrue(waitForVisible(responseMessage, in: app, timeout: 8))
        XCTAssertFalse(runningStatus.exists)
        assertElementSitsNearComposer(responseMessage, in: app, message: "The thread should stay pinned after the running strip is replaced by the final response")
    }

    func testThreadDoesNotShowNewUpdatesPillJustForScrollingUp() throws {
        let app = launchConfiguredApp()
        XCTAssertTrue(waitForConnectedHome(in: app))
        createUniqueProject(in: app)
        fillOverflowingThread(in: app)

        let thread = app.scrollViews["conversationThreadScrollView"]
        XCTAssertTrue(thread.waitForExistence(timeout: 8))
        scrollThreadToOlderContent(thread)

        let oldMessage = app.staticTexts["history marker 1"].firstMatch
        XCTAssertTrue(waitForVisible(oldMessage, in: app, timeout: 8), "The test should begin from a detached reading position")
        XCTAssertFalse(app.buttons["threadNewUpdatesButton"].exists)
    }

    func testThreadPreservesScrolledUpReadingPositionForDelayedUpdates() throws {
        let app = launchConfiguredApp()
        XCTAssertTrue(waitForConnectedHome(in: app))
        createUniqueProject(in: app)
        fillOverflowingThread(in: app)

        send("/mock_slow_thread_updates", in: app)
        waitForUIToSettle()

        let thread = app.scrollViews["conversationThreadScrollView"]
        XCTAssertTrue(thread.waitForExistence(timeout: 8))
        scrollThreadToOlderContent(thread)

        let oldMessage = app.staticTexts["history marker 1"].firstMatch
        XCTAssertTrue(waitForVisible(oldMessage, in: app, timeout: 8), "Older content should remain readable after intentionally scrolling up")

        let finalUpdate = app.staticTexts["Slow delayed final update: detached reading fixture complete."].firstMatch
        XCTAssertTrue(finalUpdate.waitForExistence(timeout: 12))
        XCTAssertFalse(isVisible(finalUpdate, in: app), "Passive delayed updates should not force the thread away from older content")

        let newUpdatesButton = app.buttons["threadNewUpdatesButton"].firstMatch
        XCTAssertTrue(newUpdatesButton.waitForExistence(timeout: 8))
        newUpdatesButton.tap()

        XCTAssertTrue(waitForVisible(finalUpdate, in: app, timeout: 8))
    }

    func testThreadClearsNewUpdatesWhenManuallyScrolledBackToBottom() throws {
        let app = launchConfiguredApp()
        XCTAssertTrue(waitForConnectedHome(in: app))
        createUniqueProject(in: app)
        fillOverflowingThread(in: app)

        send("/mock_slow_thread_updates", in: app)
        waitForUIToSettle()

        let thread = app.scrollViews["conversationThreadScrollView"]
        XCTAssertTrue(thread.waitForExistence(timeout: 8))
        scrollThreadToOlderContent(thread)

        let oldMessage = app.staticTexts["history marker 1"].firstMatch
        XCTAssertTrue(waitForVisible(oldMessage, in: app, timeout: 8), "The test should begin from a detached reading position")

        let finalUpdate = app.staticTexts["Slow delayed final update: detached reading fixture complete."].firstMatch
        XCTAssertTrue(finalUpdate.waitForExistence(timeout: 12))
        XCTAssertFalse(isVisible(finalUpdate, in: app), "The delayed update should remain offscreen while reading older content")

        let newUpdatesButton = app.buttons["threadNewUpdatesButton"].firstMatch
        XCTAssertTrue(newUpdatesButton.waitForExistence(timeout: 8))

        thread.swipeUp()
        thread.swipeUp()

        XCTAssertTrue(waitForVisible(finalUpdate, in: app, timeout: 8), "Manual scrolling to the bottom should reveal the latest update")
        XCTAssertFalse(app.buttons["threadNewUpdatesButton"].exists)
    }

    func testTypedMessageForceFollowsWhenThreadIsScrolledUp() throws {
        let app = launchConfiguredApp()
        XCTAssertTrue(waitForConnectedHome(in: app))
        createUniqueProject(in: app)
        fillOverflowingThread(in: app)

        let thread = app.scrollViews["conversationThreadScrollView"]
        XCTAssertTrue(thread.waitForExistence(timeout: 8))
        scrollThreadToOlderContent(thread)

        let oldMessage = app.staticTexts["history marker 1"].firstMatch
        XCTAssertTrue(waitForVisible(oldMessage, in: app, timeout: 8), "The test should begin from a detached reading position")

        send("typed force follow target", in: app)

        let sentMessage = app.staticTexts["typed force follow target"].firstMatch
        XCTAssertTrue(sentMessage.waitForExistence(timeout: 8))
        XCTAssertTrue(waitForVisible(sentMessage, in: app, timeout: 8), "Sending typed text should force-scroll to the new outgoing bubble")

        let responseMessage = app.staticTexts["Mock Hermes received: typed force follow target"].firstMatch
        XCTAssertTrue(responseMessage.waitForExistence(timeout: 10))
        XCTAssertTrue(waitForVisible(responseMessage, in: app, timeout: 8), "The response to a typed send should also remain visible after force-following")
        XCTAssertFalse(app.buttons["threadNewUpdatesButton"].exists)
    }

    func testSendButtonMessageForceFollowsWhenThreadIsScrolledUp() throws {
        let app = launchConfiguredApp()
        XCTAssertTrue(waitForConnectedHome(in: app))
        createUniqueProject(in: app)
        fillOverflowingThread(in: app)

        let thread = app.scrollViews["conversationThreadScrollView"]
        XCTAssertTrue(thread.waitForExistence(timeout: 8))
        scrollThreadToOlderContent(thread)

        let oldMessage = app.staticTexts["history marker 1"].firstMatch
        XCTAssertTrue(waitForVisible(oldMessage, in: app, timeout: 8), "The test should begin from a detached reading position")
        XCTAssertFalse(app.buttons["threadNewUpdatesButton"].exists)

        openTextComposer(in: app)
        let composer = app.textFields["composerTextField"]
        XCTAssertTrue(composer.waitForExistence(timeout: 8))
        composer.tap()
        composer.typeText("keyboard force follow target")
        submitComposer(in: app)

        let sentMessage = app.staticTexts["keyboard force follow target"].firstMatch
        XCTAssertTrue(sentMessage.waitForExistence(timeout: 8))
        XCTAssertTrue(waitForVisible(sentMessage, in: app, timeout: 8), "Keyboard-submitted text should force-scroll to the new outgoing bubble")
        XCTAssertFalse(app.buttons["threadNewUpdatesButton"].exists)
    }

    private func launchConfiguredApp() -> XCUIApplication {
        let app = XCUIApplication()
        let environment = ProcessInfo.processInfo.environment
        let testID = UUID().uuidString
        app.launchEnvironment = [
            "LOGOS_WS_URL": environment["LOGOS_UI_TEST_WS_URL"] ?? "ws://127.0.0.1:8766",
            "LOGOS_DEVICE_SECRET": environment["LOGOS_UI_TEST_DEVICE_SECRET"] ?? "stage-f-secret",
            "LOGOS_DEVICE_ID": "ios-ui-test-\(testID)",
            "LOGOS_MESSAGE_STORE_FILENAME": "LogosUITests-\(testID).sqlite3",
            "LOGOS_AUTOCONNECT": "1"
        ]
        app.launch()
        return app
    }

    private func waitForConnectedHome(in app: XCUIApplication, timeout: TimeInterval = 10) -> Bool {
        app.staticTexts["Connected"].waitForExistence(timeout: timeout)
    }

    private func assertSettingsSectionsPresent(in app: XCUIApplication) {
        let settings = app.buttons["Settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 8))
        settings.tap()
        XCTAssertTrue(app.staticTexts["Hermes Adapter"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["Voice"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["Notifications"].waitForExistence(timeout: 8))
        let back = app.buttons["Logos"]
        XCTAssertTrue(back.waitForExistence(timeout: 8))
        back.tap()
    }

    private func assertComposerPresent(in app: XCUIApplication) {
        XCTAssertTrue(app.buttons["recordButton"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["keyboardModeButton"].waitForExistence(timeout: 8))
        openTextComposer(in: app)
        XCTAssertTrue(app.textFields["composerTextField"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["tapToTalkButton"].waitForExistence(timeout: 8))
    }

    private func waitForPlaybackStatus(in app: XCUIApplication, timeout: TimeInterval = 10) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        let playbackOverlay = app.descendants(matching: .any).matching(identifier: "audioPlaybackOverlay").firstMatch
        let pauseControl = app.buttons["audioOverlayPauseButton"]
        let stopControl = app.buttons["audioOverlayStopButton"]
        let legacyStatus = app.descendants(matching: .any).matching(identifier: "playbackStatusLabel").firstMatch
        while Date() < deadline {
            if playbackOverlay.exists || pauseControl.exists || stopControl.exists {
                return true
            }
            if legacyStatus.exists,
               ["Receiving audio", "Playing audio", "Audio finished"].contains(legacyStatus.label) {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        return false
    }

    private func send(_ text: String, in app: XCUIApplication) {
        openTextComposer(in: app)
        let composer = app.textFields["composerTextField"]
        XCTAssertTrue(composer.waitForExistence(timeout: 8))
        composer.tap()
        composer.typeText(text)
        submitComposer(in: app)
    }

    private func openTextComposer(in app: XCUIApplication) {
        let composer = app.textFields["composerTextField"]
        if composer.exists { return }
        let keyboard = app.buttons["keyboardModeButton"]
        XCTAssertTrue(keyboard.waitForExistence(timeout: 8))
        keyboard.tap()
        XCTAssertTrue(composer.waitForExistence(timeout: 8))
    }

    private func submitComposer(in app: XCUIApplication) {
        let send = app.buttons["sendButton"]
        XCTAssertTrue(send.waitForExistence(timeout: 8))
        if send.isHittable {
            send.tap()
        } else {
            send.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }
    }

    private func createUniqueProject(in app: XCUIApplication) {
        let title = "ui-test-\(UUID().uuidString.prefix(8))"
        let projectPicker = app.buttons["projectPicker"]
        XCTAssertTrue(projectPicker.waitForExistence(timeout: 8))
        projectPicker.tap()

        let newProject = app.buttons["New project"]
        XCTAssertTrue(newProject.waitForExistence(timeout: 8))
        newProject.tap()

        let titleField = app.textFields["newProjectTitleField"]
        XCTAssertTrue(titleField.waitForExistence(timeout: 8))
        titleField.tap()
        titleField.typeText(title)

        let create = app.buttons["createProjectButton"]
        XCTAssertTrue(create.waitForExistence(timeout: 8))
        create.tap()
        XCTAssertTrue(titleField.waitForNonExistence(timeout: 8))
    }

    private func fillOverflowingThread(in app: XCUIApplication) {
        for index in 1...6 {
            send("history marker \(index)", in: app)
            XCTAssertTrue(app.staticTexts["Mock Hermes received: history marker \(index)"].waitForExistence(timeout: 10))
        }
    }

    private func nudgeThreadNearBottom(_ thread: XCUIElement) {
        let start = thread.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85))
        let end = thread.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.78))
        start.press(forDuration: 0.05, thenDragTo: end)
    }

    private func scrollThreadToOlderContent(_ thread: XCUIElement) {
        let start = thread.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.28))
        let end = thread.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.88))
        start.press(forDuration: 0.05, thenDragTo: end)
    }

    private func waitForUIToSettle() {
        RunLoop.current.run(until: Date().addingTimeInterval(6.0))
    }

    private func waitForVisible(_ element: XCUIElement, in app: XCUIApplication, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if isVisible(element, in: app) {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        return false
    }

    private func isVisible(_ element: XCUIElement, in app: XCUIApplication) -> Bool {
        guard element.exists, element.frame.isEmpty == false else { return false }
        return app.windows.firstMatch.frame.intersects(element.frame)
    }

    private func assertElementSitsNearComposer(_ element: XCUIElement, in app: XCUIApplication, message: String) {
        let composerButton = app.buttons["tapToTalkButton"].firstMatch
        XCTAssertTrue(composerButton.waitForExistence(timeout: 8))
        let gapToComposer = composerButton.frame.minY - element.frame.maxY
        XCTAssertGreaterThanOrEqual(gapToComposer, 8, message)
        XCTAssertLessThan(gapToComposer, 140, message)
    }
}
