import XCTest

@MainActor final class AssistantUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    func testLaunchMemoryPersistenceAndDeletion() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["Memory"].waitForExistence(timeout: 20))
        let launch = XCTAttachment(screenshot: app.screenshot()); launch.name = "Assistant launch"; launch.lifetime = .keepAlways; add(launch)
        app.tabBars.buttons["Memory"].tap()
        let note = "UI verification " + UUID().uuidString.prefix(8)
        let field = app.descendants(matching: .any).matching(identifier: "memoryNoteInput").firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap(); app.typeText(note)
        app.buttons["Remember note"].tap()
        // Dismiss keyboard so saved content can be navigated reliably.
        app.swipeUp()
        app.terminate(); app.launch()
        app.tabBars.buttons["Memory"].tap()
        let saved = app.staticTexts[note]
        for _ in 0..<5 where !saved.isHittable { app.swipeUp() }
        XCTAssertTrue(saved.exists)
        let memory = XCTAttachment(screenshot: app.screenshot()); memory.name = "Saved offline memory"; memory.lifetime = .keepAlways; add(memory)
        let delete = app.buttons["Delete note: " + note]
        for _ in 0..<3 where !delete.isHittable { app.swipeUp() }
        XCTAssertTrue(delete.exists); delete.tap()
        app.buttons["Cancel"].tap()
        XCTAssertTrue(saved.exists, "Cancelling must preserve the note")
        delete.tap()
        app.buttons["Delete note"].tap()
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: saved)
        waitForExpectations(timeout: 5)
        app.terminate(); app.launch()
        app.tabBars.buttons["Memory"].tap()
        XCTAssertFalse(app.staticTexts[note].exists, "Deletion must persist across launches")
    }

    func testCapabilitiesAndVoiceControlsAreVisible() {
        let app = XCUIApplication(); app.launch()
        XCTAssertTrue(app.buttons["Voice conversation"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.switches["Continue active voice in background"].exists)
        app.tabBars.buttons["About"].tap()
        let title = app.navigationBars["Capabilities"]
        XCTAssertTrue(title.waitForExistence(timeout: 10))
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "Capabilities"; shot.lifetime = .keepAlways; add(shot)
    }
    func testEncryptedTransferCancelsWithoutExport() {
        let app = XCUIApplication(); app.launch()
        app.tabBars.buttons["Memory"].tap()
        let open = app.buttons["encryptedTransferOpen"]
        for _ in 0..<4 where !open.isHittable { app.swipeUp() }
        XCTAssertTrue(open.waitForExistence(timeout: 10)); open.tap()
        let passphrase = app.secureTextFields["encryptedExportPassphrase"]
        XCTAssertTrue(passphrase.waitForExistence(timeout: 10))
        passphrase.tap(); app.typeText("synthetic test phrase")
        let repeatField = app.secureTextFields["encryptedExportRepeat"]
        repeatField.tap(); app.typeText("synthetic test phrase")
        let review = app.buttons["encryptedExportReview"]
        for _ in 0..<3 where !review.isHittable { app.swipeUp() }
        review.tap()
        let confirmation = app.alerts["Export encrypted memory?"]
        XCTAssertTrue(confirmation.waitForExistence(timeout: 10))
        confirmation.buttons["Cancel"].tap()
        XCTAssertFalse(review.isEnabled, "Cancelling must clear export passphrases")
        app.buttons["Done"].tap()
        XCTAssertTrue(open.waitForExistence(timeout: 10))
    }

    func testPrivateGitHubConsentCanCancelWithoutConnecting() {
        let app = XCUIApplication(); app.launch()
        app.tabBars.buttons["Projects"].tap()
        let direct = app.switches["github-direct-install-toggle"]
        for _ in 0..<6 where !direct.isHittable { app.swipeUp() }
        XCTAssertTrue(direct.waitForExistence(timeout: 10)); direct.tap()
        let token = app.secureTextFields["github-token-field"]
        for _ in 0..<4 where !token.isHittable { app.swipeUp() }
        token.tap(); app.typeText("github_pat_SYNTHETIC_TEST_ONLY_123")
        let connect = app.buttons["github-connect-button"]
        for _ in 0..<4 where !connect.isHittable { app.swipeUp() }
        connect.tap()
        let consent = app.alerts["Use this GitHub token?"]
        XCTAssertTrue(consent.waitForExistence(timeout: 10)); consent.buttons["Cancel"].tap()
        XCTAssertFalse(connect.isEnabled, "Cancelled consent must clear the synthetic token")
        XCTAssertFalse(app.staticTexts["Checking GitHub account"].exists)
    }

}
