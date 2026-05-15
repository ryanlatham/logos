import XCTest

final class LogosUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testTextMessageRoundTripThroughMockAdapter() throws {
        let app = launchConfiguredApp()
        XCTAssertTrue(app.staticTexts["Connected"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["Notifications"].waitForExistence(timeout: 8))
        assertVoicePanelPresent(in: app)

        let composer = app.textFields["composerTextField"]
        XCTAssertTrue(composer.waitForExistence(timeout: 8))
        composer.tap()
        composer.typeText("from simulator ui test")
        submitComposer(in: app)

        XCTAssertTrue(app.staticTexts["Mock Hermes received: from simulator ui test"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Idle"].waitForExistence(timeout: 10))
        let playButtons = app.buttons.matching(identifier: "playMessageButton")
        XCTAssertTrue(playButtons.firstMatch.waitForExistence(timeout: 8))
        let playButton = playButtons.element(boundBy: max(playButtons.count - 1, 0))
        playButton.tap()
        XCTAssertTrue(app.staticTexts["Playing audio"].waitForExistence(timeout: 10))
    }

    func testApprovalAndClarificationCardsRenderFromMockAdapterFixtures() throws {
        let app = launchConfiguredApp()
        XCTAssertTrue(app.staticTexts["Connected"].waitForExistence(timeout: 8))

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
        XCTAssertTrue(app.staticTexts["Connected"].waitForExistence(timeout: 8))

        let projectTitle = app.textFields["newProjectTitleField"]
        XCTAssertTrue(projectTitle.waitForExistence(timeout: 8))
        projectTitle.tap()
        projectTitle.typeText("scenario two")

        XCTAssertEqual(projectTitle.value as? String, "scenario two")
        XCTAssertTrue(app.buttons["New"].isEnabled)
    }

    private func launchConfiguredApp() -> XCUIApplication {
        let app = XCUIApplication()
        let environment = ProcessInfo.processInfo.environment
        app.launchEnvironment = [
            "LOGOS_WS_URL": environment["LOGOS_UI_TEST_WS_URL"] ?? "ws://127.0.0.1:8766",
            "LOGOS_DEVICE_SECRET": environment["LOGOS_UI_TEST_DEVICE_SECRET"] ?? "stage-f-secret",
            "LOGOS_DEVICE_ID": "ios-ui-test-\(UUID().uuidString)",
            "LOGOS_AUTOCONNECT": "1"
        ]
        app.launch()
        return app
    }

    private func assertVoicePanelPresent(in app: XCUIApplication) {
        XCTAssertTrue(app.staticTexts["Voice"].waitForExistence(timeout: 8))
        let hold = app.descendants(matching: .any)["holdToTalkButton"]
        XCTAssertTrue(hold.waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["tapToTalkButton"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["voiceAvailabilityLabel"].exists)
    }

    private func send(_ text: String, in app: XCUIApplication) {
        let composer = app.textFields["composerTextField"]
        XCTAssertTrue(composer.waitForExistence(timeout: 8))
        composer.tap()
        composer.typeText(text)
        submitComposer(in: app)
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
