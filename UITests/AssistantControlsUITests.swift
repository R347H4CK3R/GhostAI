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
        name.press(forDuration: 1.1)
        if app.menuItems["Select All"].waitForExistence(timeout: 2) { app.menuItems["Select All"].tap() }
        else { name.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 40)) }
        name.typeText("Nova")
        app.buttons["assistantPreferences.save"].tap()
        let heading = app.descendants(matching: .any).matching(identifier: "chatIdentityAndConnection").firstMatch
        XCTAssertTrue(heading.label.contains("Nova"))
        XCTAssertEqual(composer.value as? String, "Keep this draft")
        app.terminate(); app.launch()
        XCTAssertTrue(heading.waitForExistence(timeout: 5))
        XCTAssertTrue(heading.label.contains("Nova"))
        app.buttons["Chat options"].tap(); app.buttons["Edit name & avatar"].tap()
        XCTAssertEqual(name.value as? String, "Nova")
        name.tap(); name.typeText(" unsaved")
        app.buttons["assistantPreferences.cancel"].tap()
        XCTAssertTrue(heading.label.contains("Nova"))
        XCTAssertFalse(heading.label.contains("unsaved"))
    }
}
