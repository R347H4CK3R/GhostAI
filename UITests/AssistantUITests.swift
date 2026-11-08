import XCTest

@MainActor final class AssistantUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    func testLongChatRemainsVisibleWhileTypingAndSwipeDownDismissesKeyboard() {
        let app = launchChatFixture("success")
        let field = composer(in: app)
        field.tap(); app.typeText("A draft that must survive keyboard dismissal")
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        let transcript = app.scrollViews["chatTranscript"]
        XCTAssertTrue(transcript.exists)
        XCTAssertGreaterThan(transcript.frame.height, 120, "Keyboard must not squeeze the transcript away")
        let latest = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Synthetic project answer 12.")).firstMatch
        expectation(for: NSPredicate(format: "hittable == true"), evaluatedWith: latest)
        waitForExpectations(timeout: 5)
        saveScreenshot(app, name: "Visible latest message while keyboard is open")
        XCTAssertLessThanOrEqual(field.frame.maxY, app.keyboards.firstMatch.frame.minY + 1)
        // The scroll container can have no hittable point while its message children do.
        // Start on the verified visible message, not the scroll view's full content bounds.
        let start = latest.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1))
        let finish = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.88))
        start.press(forDuration: 0.05, thenDragTo: finish)
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
        XCTAssertEqual(field.value as? String, "A draft that must survive keyboard dismissal")
        field.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        app.buttons["chatKeyboardDone"].tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
        saveScreenshot(app, name: "Long chat after interactive keyboard dismissal")
    }

    func testAcceptedSendClearsDraftDismissesKeyboardAndShowsReply() {
        let app = launchChatFixture("success")
        let field = composer(in: app)
        field.tap(); app.typeText("Show my latest reply")
        app.buttons["chatSend"].tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
        XCTAssertEqual(field.value as? String, "")
        let reply = app.staticTexts["Synthetic reply: Show my latest reply"]
        XCTAssertTrue(reply.waitForExistence(timeout: 10))
        XCTAssertTrue(reply.isHittable, "A new answer must be scrolled into view")
        XCTAssertFalse(app.buttons["chatSend"].isEnabled, "The cleared composer must not submit an empty message")
        saveScreenshot(app, name: "Visible latest answer and bottom composer")
    }

    func testPendingReplyIsVisibleWhileTypingAndStopPreservesNextDraft() {
        let app = launchChatFixture("pending")
        let field = composer(in: app)
        field.tap(); app.typeText("A request awaiting a response")
        app.buttons["chatSend"].tap()
        let pending = app.staticTexts["chatPendingStatus"]
        XCTAssertTrue(pending.waitForExistence(timeout: 5))
        field.tap(); app.typeText("Draft for later")
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(pending.isHittable)
        XCTAssertGreaterThan(app.scrollViews["chatTranscript"].frame.height, 120)
        saveScreenshot(app, name: "Pending response with keyboard open")
        app.buttons["chatStop"].tap()
        XCTAssertTrue(pending.waitForNonExistence(timeout: 5))
        XCTAssertEqual(field.value as? String, "Draft for later")
    }

    func testRejectedSendKeepsDraftAndShowsInlineErrorAfterAlertDismissal() {
        let app = launchChatFixture("success")
        let field = composer(in: app)
        field.tap(); app.typeText("password = synthetic-only")
        app.buttons["chatSend"].tap()
        let alert = app.alerts["Asterion"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5)); alert.buttons["OK"].tap()
        XCTAssertEqual(field.value as? String, "password = synthetic-only")
        let error = app.staticTexts["chatInlineError"]
        XCTAssertTrue(error.waitForExistence(timeout: 5))
        XCTAssertTrue(error.isHittable)
        XCTAssertFalse(app.buttons["chatStop"].exists)
    }

    func testEmptyModelReplyShowsRecoverableErrorInsteadOfAnEmptyBubble() {
        let app = launchChatFixture("empty")
        let field = composer(in: app)
        field.tap(); app.typeText("Request an answer")
        app.buttons["chatSend"].tap()
        let alert = app.alerts["Asterion"]
        XCTAssertTrue(alert.waitForExistence(timeout: 10)); alert.buttons["OK"].tap()
        let error = app.staticTexts["chatInlineError"]
        XCTAssertTrue(error.waitForExistence(timeout: 5))
        XCTAssertTrue(error.label.contains("empty answer"))
        XCTAssertTrue(error.isHittable)
        XCTAssertTrue(app.buttons["chatRestoreDraft"].exists)
        app.buttons["chatRestoreDraft"].tap()
        XCTAssertEqual(field.value as? String, "Request an answer")
    }

    func testUnsentDraftSurvivesVoiceSheetAndTabNavigation() {
        let app = launchChatFixture("success")
        let field = composer(in: app)
        field.tap(); app.typeText("Keep this unfinished thought")
        app.buttons["chatVoiceSettings"].tap()
        XCTAssertTrue(app.buttons["chatStartVoiceCall"].waitForExistence(timeout: 5))
        app.buttons["voiceSettingsDone"].tap()
        XCTAssertEqual(field.value as? String, "Keep this unfinished thought")
        app.tabBars.buttons["Memory"].tap()
        app.tabBars.buttons["Assistant"].tap()
        XCTAssertEqual(field.value as? String, "Keep this unfinished thought")
    }

    func testDraftsCannotLeakIntoAnotherProject() {
        let app = launchChatFixture("success")
        let field = composer(in: app)
        field.tap(); app.typeText("General project draft")
        app.buttons["chatKeyboardDone"].tap()
        app.tabBars.buttons["Projects"].tap()
        let otherProject = app.buttons["Synthetic second project"]
        for _ in 0..<8 where !otherProject.isHittable { app.swipeUp() }
        XCTAssertTrue(otherProject.isHittable); otherProject.tap()
        app.tabBars.buttons["Assistant"].tap()
        XCTAssertEqual(field.value as? String, "")
        XCTAssertFalse(app.buttons["chatSend"].isEnabled)
        field.tap(); app.typeText("Second project draft")
        app.buttons["chatKeyboardDone"].tap()
        app.tabBars.buttons["Projects"].tap()
        let general = app.buttons["General"]
        for _ in 0..<8 where !general.isHittable { app.swipeUp() }
        XCTAssertTrue(general.isHittable); general.tap()
        app.tabBars.buttons["Assistant"].tap()
        XCTAssertEqual(field.value as? String, "General project draft")
    }

    private func launchChatFixture(_ scenario: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--uitest-chat", scenario]
        app.launch()
        XCTAssertTrue(app.buttons["chatSend"].waitForExistence(timeout: 15))
        return app
    }

    private func composer(in app: XCUIApplication) -> XCUIElement {
        let field = app.descendants(matching: .any).matching(identifier: "chatComposer").firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        return field
    }

    private func saveScreenshot(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }

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
        let voice = app.buttons["chatVoiceSettings"]
        XCTAssertTrue(voice.waitForExistence(timeout: 15)); voice.tap()
        XCTAssertTrue(app.buttons["chatStartVoiceCall"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.switches["Continue active voice in background"].exists)
        app.buttons["voiceSettingsDone"].tap()
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
        XCTAssertTrue(direct.waitForExistence(timeout: 10))
        // SwiftUI exposes the whole labeled row as a Switch; tap its actual thumb.
        direct.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        XCTAssertEqual(direct.value as? String, "1", "The direct-install acknowledgment must be enabled")
        let token = app.secureTextFields["github-token-field"]
        for _ in 0..<4 where !token.isHittable { app.swipeUp() }
        token.tap(); app.typeText("github_pat_SYNTHETIC_TEST_ONLY_123")
        let connect = app.buttons["github-connect-button"]
        for _ in 0..<4 where !connect.isHittable { app.swipeUp() }
        XCTAssertTrue(connect.isEnabled)
        connect.tap()
        let consent = app.alerts["Use this GitHub token?"]
        XCTAssertTrue(consent.waitForExistence(timeout: 10))
        // iOS 26 exposes the same alert action as a nested button and wrapper.
        // Scope to the action identifier inside this alert, then select its first representation.
        consent.buttons.matching(identifier: "github-cancel-connect").firstMatch.tap()
        XCTAssertTrue(consent.waitForNonExistence(timeout: 10))
        XCTAssertFalse(connect.isEnabled, "Cancelled consent must clear the synthetic token")
        XCTAssertFalse(app.staticTexts["Checking GitHub account"].exists)
    }

}
