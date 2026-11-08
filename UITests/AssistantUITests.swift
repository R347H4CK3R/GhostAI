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
        app.buttons["Delete note"].tap()
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: saved)
        waitForExpectations(timeout: 5)
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
}
