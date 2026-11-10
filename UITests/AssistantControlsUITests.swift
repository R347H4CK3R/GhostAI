import XCTest

@MainActor final class AssistantControlsUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    func testProfileEditsPersistWithoutLosingChatDraftAndCancelDoesNotSave() {
        let app = XCUIApplication()
        app.launchArguments = ["--uitest-chat", "success", "--uitest-preferences-suite", "controls-" + UUID().uuidString]
        app.launch()
        let composer = app.descendants(matching: .any).matching(identifier: "chatComposer").firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        composer.tap(); app.typeText("Keep this draft")
        app.buttons["chatKeyboardDone"].tap()
        app.buttons["Chat options"].tap()
        let edit = app.buttons["Edit name & avatar"]
        XCTAssertTrue(edit.waitForExistence(timeout: 5), "The screenshot's profile control must perform a real edit")
        edit.tap()
        let name = app.textFields["assistantPreferences.name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.tap()
        name.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 6) + "Nova")
        app.buttons["assistantPreferences.avatar.moon"].tap()
        capture(app, name: "Editable local name and avatar")
        app.buttons["assistantPreferences.save"].tap()
        let heading = app.descendants(matching: .any).matching(identifier: "chatIdentityAndConnection").firstMatch
        XCTAssertTrue(heading.label.contains("Nova"))
        XCTAssertEqual(composer.value as? String, "Keep this draft")
        capture(app, name: "Personalized assistant with preserved draft")
        app.terminate(); app.launch()
        XCTAssertTrue(heading.waitForExistence(timeout: 5))
        XCTAssertTrue(heading.label.contains("Nova"))
        app.buttons["Chat options"].tap(); app.buttons["Edit name & avatar"].tap()
        XCTAssertEqual(name.value as? String, "Nova")
        XCTAssertEqual(app.buttons["assistantPreferences.avatar.moon"].value as? String, "Selected")
        name.tap(); name.typeText(" unsaved")
        app.buttons["assistantPreferences.cancel"].tap()
        XCTAssertTrue(heading.label.contains("Nova"))
        XCTAssertFalse(heading.label.contains("unsaved"))
    }
    func testSavedStartScreenAppliesOnlyOnRelaunchAndAssistantShortcutRestoresIt() {
        let app = XCUIApplication()
        app.launchArguments = ["--uitest-chat", "success", "--uitest-preferences-suite", "controls-" + UUID().uuidString]
        app.launch()
        app.buttons["Chat options"].tap(); app.buttons["Edit name & avatar"].tap()
        app.buttons["assistantPreferences.startScreen"].tap()
        app.buttons["assistantPreferences.startScreen.memory"].tap()
        app.buttons["assistantPreferences.save"].tap()
        XCTAssertTrue(app.tabBars.buttons["Assistant"].isSelected, "Saving preferences must not jump tabs")
        app.tabBars.buttons["Projects"].tap()
        XCUIDevice.shared.press(.home); app.activate()
        XCTAssertTrue(app.tabBars.buttons["Projects"].isSelected, "Foregrounding must preserve current navigation")
        app.terminate(); app.launch()
        XCTAssertTrue(app.tabBars.buttons["Memory"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.tabBars.buttons["Memory"].isSelected)
        app.tabBars.buttons["Assistant"].tap()
        app.buttons["Chat options"].tap(); app.buttons["Set as start screen"].tap()
        app.terminate(); app.launch()
        XCTAssertTrue(app.tabBars.buttons["Assistant"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.tabBars.buttons["Assistant"].isSelected)
    }

    func testComputerMenuOpensExistingReviewAndDismissalKeepsDraft() {
        let app = XCUIApplication()
        app.launchArguments = ["--uitest-chat", "success"]
        app.launch()
        let composer = app.descendants(matching: .any).matching(identifier: "chatComposer").firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        composer.tap(); app.typeText("Keep this computer question")
        app.buttons["chatKeyboardDone"].tap()
        app.buttons["Chat options"].tap(); app.buttons["Computers"].tap()
        XCTAssertTrue(app.staticTexts["Foreground desktop jobs · Development"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["assistantComputer.done"].exists)
        app.buttons["assistantComputer.done"].tap()
        XCTAssertEqual(composer.value as? String, "Keep this computer question")
        XCTAssertFalse(app.buttons["chatStop"].exists)
    }

    func testInvalidNameIsVisibleAndDoesNotSave() {
        let app = XCUIApplication()
        app.launchArguments = ["--uitest-chat", "success"]
        app.launch()
        app.buttons["Chat options"].tap(); app.buttons["Edit name & avatar"].tap()
        let name = app.textFields["assistantPreferences.name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.tap(); name.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 6))
        app.buttons["assistantPreferences.save"].tap()
        XCTAssertTrue(app.staticTexts["assistantPreferences.error"].waitForExistence(timeout: 5))
        app.buttons["assistantPreferences.cancel"].tap()
        let heading = app.descendants(matching: .any).matching(identifier: "chatIdentityAndConnection").firstMatch
        XCTAssertTrue(heading.label.contains("Jarvis"))
    }
    func testVoiceEntryOverridesMemoryStartupWithoutStartingMicrophone() {
        let app = XCUIApplication()
        app.launchArguments = ["--uitest-chat", "success", "--uitest-preferences-suite", "controls-" + UUID().uuidString]
        app.launch()
        app.buttons["Chat options"].tap(); app.buttons["Edit name & avatar"].tap()
        app.buttons["assistantPreferences.startScreen"].tap(); app.buttons["assistantPreferences.startScreen.memory"].tap()
        app.buttons["assistantPreferences.save"].tap()
        app.terminate()
        app.launchArguments.append("--uitest-open-voice-controls")
        app.launch()
        XCTAssertTrue(app.buttons["chatStartVoiceCall"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons["chatStartVoiceCall"].label, "Start voice call")
        XCTAssertFalse(app.alerts.firstMatch.exists, "A voice navigation request must not request microphone permission")
        app.buttons["voiceSettingsDone"].tap()
        XCTAssertTrue(app.tabBars.buttons["Assistant"].isSelected)
    }

    private func capture(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }

}
