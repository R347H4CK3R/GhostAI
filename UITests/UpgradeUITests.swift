import XCTest

@MainActor final class UpgradeUITests: XCTestCase {
    func testRetainedChatNotesAndHomeIcon() throws {
        guard ProcessInfo.processInfo.environment["ASTERION_UPGRADE_SMOKE"] == "1" else {
            throw XCTSkip("Runs only after the isolated simulator upgrade has been seeded")
        }
        continueAfterFailure = false
        let app = XCUIApplication()
        // Do not pass --uitest-chat: exercise the real persisted store and normal startup.
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["Assistant"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.staticTexts["Upgrade fixture: a saved question, not a model request."].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Upgrade fixture: a saved response, not generated inference."].exists)
        XCTAssertFalse(app.alerts["Asterion"].exists, "An unreadable old store must fail the upgrade gate")
        saveScreenshot(app.screenshot(), name: "Upgrade retained prior conversation")

        app.tabBars.buttons["Memory"].tap()
        let note = app.staticTexts["Upgrade fixture: keep this offline note."]
        for _ in 0..<7 where !note.isHittable { app.swipeUp() }
        XCTAssertTrue(note.isHittable, "The prior note must be readable in the real Memory screen")
        XCTAssertFalse(app.staticTexts["Upgrade fixture: keep the other project separate."].exists)
        saveScreenshot(app.screenshot(), name: "Upgrade retained offline note")

        // Check installed icon presence and tappability. Screenshot artwork needs visual review.
        XCUIDevice.shared.press(.home)
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        XCTAssertTrue(springboard.wait(for: .runningForeground, timeout: 10))
        saveScreenshot(XCUIScreen.main.screenshot(), name: "Upgrade Home before icon selection")
        let icons = springboard.icons.matching(identifier: "Asterion Veyra")
        var visibleIcon: XCUIElement?
        // Home can still be settling when SpringBoard becomes foreground. Do
        // not swipe away from an already-visible icon or choose an off-page
        // representation via firstMatch. This isolated simulator needs no
        // App Library/search fallback: require a genuine visible Home icon.
        let homeIconReady = NSPredicate { _, _ in
            visibleIcon = icons.allElementsBoundByIndex.first { candidate in
                guard candidate.exists else { return false }
                let frame = candidate.frame
                return !frame.isEmpty && springboard.frame.contains(frame) && candidate.isHittable
            }
            return visibleIcon != nil
        }
        expectation(for: homeIconReady, evaluatedWith: springboard)
        waitForExpectations(timeout: 10)
        let icon = try XCTUnwrap(visibleIcon, "The upgraded app must expose a visible Home icon")
        XCTAssertTrue(icon.waitForExistence(timeout: 5), "The upgraded app must retain its home-screen icon")
        XCTAssertTrue(icon.isHittable)
        saveScreenshot(XCUIScreen.main.screenshot(), name: "Upgrade home-screen icon for visual review")
        icon.tap()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        app.tabBars.buttons["Assistant"].tap()
        XCTAssertTrue(app.staticTexts["Upgrade fixture: a saved response, not generated inference."].waitForExistence(timeout: 10))
        saveScreenshot(app.screenshot(), name: "Upgrade resumed from current icon")
        app.terminate()
        app.launch()
        XCTAssertTrue(app.staticTexts["Upgrade fixture: a saved response, not generated inference."].waitForExistence(timeout: 10))
        app.terminate()
    }

    private func saveScreenshot(_ screenshot: XCUIScreenshot, name: String) {
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
