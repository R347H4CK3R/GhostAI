import XCTest

/// Characterization cases, not a production fix. Compare these with the existing
/// full-app no-voice background case before attributing a failure to voice entry.
@MainActor final class ChecklistLifecycleUITests: XCTestCase {
    private var application: XCUIApplication?

    override func setUpWithError() throws { continueAfterFailure = false }

    override func tearDown() async throws {
        await MainActor.run {
            application?.terminate()
            application = nil
        }
        try await super.tearDown()
    }

    // XCTest's default alphabetical order runs the control before the exact
    // editor, so a crashing editor cannot contaminate the first control launch.
    func testControlFormPreservesUnsavedDraftAcrossBackground() {
        verifyUnsavedDraft(scenario: "form", goalID: "checklistLifecycle.goal", doneID: "checklistLifecycle.keyboardDone",
                           cancelID: "checklistLifecycle.cancel")
    }

    func testIsolatedChecklistEditorPreservesUnsavedDraftAcrossBackground() {
        verifyUnsavedDraft(scenario: "editor", goalID: "checklist.goal", doneID: "checklist.keyboardDone",
                           cancelID: "checklist.cancel")
    }

    private func verifyUnsavedDraft(scenario: String, goalID: String, doneID: String, cancelID: String) {
        let app = XCUIApplication()
        application = app
        app.terminate()
        app.launchArguments = ["--uitest-chat", "checklists", "--uitest-checklist-lifecycle", scenario]
        app.launch()
        let open = app.buttons["checklistLifecycle.open"]
        XCTAssertTrue(open.waitForExistence(timeout: 15))
        XCTAssertFalse(app.tabBars.firstMatch.exists, "The reduced host must not use MainView's tabs")
        XCTAssertFalse(app.navigationBars.firstMatch.exists, "The reduced host must not add a parent navigation bar")
        open.tap()

        let goal = app.descendants(matching: .any).matching(identifier: goalID).firstMatch
        XCTAssertTrue(goal.waitForExistence(timeout: 5))
        XCTAssertEqual(goal.value as? String, "Synthetic editable goal")
        goal.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        // Match the full-app regression's insertion point and multiline suffix.
        goal.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.95)).tap()
        app.typeText("\nKeep this unsaved draft")
        assertExactDraft(in: goal, app: app, name: scenario + " before background")
        app.buttons[doneID].tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
        attachDiagnostics(app, name: scenario + " before Home")

        for cycle in 1...2 {
            XCUIDevice.shared.press(.home)
            let background = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                app.state == .runningBackground || app.state == .runningBackgroundSuspended
            }, object: app)
            let result = XCTWaiter.wait(for: [background], timeout: 5)
            guard result == .completed else {
                // Do not activate after a failed alive check: activate can relaunch
                // a crashed process and obscure the actual lifecycle failure.
                let state = XCTAttachment(string: "scenario=\(scenario) cycle=\(cycle) state=\(app.state.rawValue) wait=\(result.rawValue)")
                state.name = "Reduced lifecycle failed before activation"; state.lifetime = .keepAlways; add(state)
                XCTFail("\(scenario) must remain alive after Home; actual state: \(app.state.rawValue)")
                return
            }
            app.activate()
            XCTAssertTrue(app.wait(for: .runningForeground, timeout: 5))
            XCTAssertTrue(goal.waitForExistence(timeout: 5), "The same unsaved editor must survive activation")
            assertExactDraft(in: goal, app: app, name: "\(scenario) after cycle \(cycle)")
            XCTAssertFalse(app.alerts.firstMatch.exists, "A lifecycle-only route must not request permissions")
        }
        attachDiagnostics(app, name: scenario + " after two background cycles")
        app.buttons[cancelID].tap()
        XCTAssertTrue(open.waitForExistence(timeout: 5))
        open.tap()
        XCTAssertTrue(goal.waitForExistence(timeout: 5))
        XCTAssertEqual(goal.value as? String, "Synthetic editable goal", "The exercised draft was never saved")
        app.buttons[cancelID].tap()
    }

    private func assertExactDraft(in goal: XCUIElement, app: XCUIApplication, name: String) {
        let expected = "Synthetic editable goal\nKeep this unsaved draft"
        let matches = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", expected), object: goal)
        let result = XCTWaiter.wait(for: [matches], timeout: 5)
        let actual = goal.value as? String
        if result != .completed || actual != expected { attachDiagnostics(app, name: name) }
        XCTAssertEqual(actual, expected, "The complete unsaved multiline draft must survive")
        XCTAssertEqual(result, .completed)
    }

    private func attachDiagnostics(_ app: XCUIApplication, name: String) {
        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = name + " hierarchy"; hierarchy.lifetime = .keepAlways; add(hierarchy)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = name; screenshot.lifetime = .keepAlways; add(screenshot)
    }
}
