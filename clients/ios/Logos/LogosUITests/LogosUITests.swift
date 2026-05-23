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
}
