import XCTest

/// Collects manual visual evidence for explicit SwiftUI privacy redaction.
/// Passing capture assertions do not prove pixel concealment, screenshot
/// prevention or app-switcher protection. Review every original/redacted pair.
@MainActor final class ChecklistPrivacyUITests: XCTestCase {
    private var application: XCUIApplication?

    override func setUpWithError() throws { continueAfterFailure = false }

    override func tearDown() async throws {
        await MainActor.run {
            application?.terminate()
            application = nil
        }
        try await super.tearDown()
    }

    func testCaptureExplicitPrivacyRedactionAcrossChecklistContent() {
        let app = XCUIApplication()
        application = app
        app.terminate()
        app.launchArguments = ["--uitest-chat", "checklists", "--uitest-checklist-lifecycle", "privacy-qa"]
        app.launch()
        let open = app.buttons["checklistLifecycle.open"]
        XCTAssertTrue(open.waitForExistence(timeout: 15))
        open.tap()
        let goal = app.descendants(matching: .any).matching(identifier: "checklist.goal").firstMatch
        let step = app.descendants(matching: .any).matching(identifier: "checklist.step").firstMatch
        XCTAssertTrue(goal.waitForExistence(timeout: 5))
        XCTAssertEqual(goal.value as? String, "Synthetic editable goal")
        XCTAssertEqual(step.value as? String, "Verify the original snapshot")
        goal.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        goal.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.95)).tap()
        app.typeText("\nSynthetic private draft")
        let draft = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@",
            "Synthetic editable goal\nSynthetic private draft"), object: goal)
        XCTAssertEqual(XCTWaiter.wait(for: [draft], timeout: 5), .completed)
        app.buttons["checklist.keyboardDone"].tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))

        let counts = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@ AND label CONTAINS %@",
            "Goal: ", "/300 · Step:")).firstMatch
        revealTogether([goal, step, app.switches["checklist.done"], counts], in: app)
        capturePair(app, name: "Privacy QA 1 draft fields and completion")

        // This route throws only a synthetic error. It cannot persist or sync.
        XCTAssertTrue(app.buttons["checklist.save"].isEnabled)
        app.buttons["checklist.save"].tap()
        let issue = app.staticTexts["checklist.issue"]
        XCTAssertTrue(issue.waitForExistence(timeout: 5))
        XCTAssertEqual(issue.label, "Synthetic private save detail for redaction QA")
        let workspace = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@",
            "Save updates only this copy in General.")).firstMatch
        revealTogether([workspace, issue], in: app)
        capturePair(app, name: "Privacy QA 2 workspace and save error")

        let source = app.staticTexts["Luma checklist snapshot · Synthetic.json · source synthetic-task · no source timestamp; date is import time"]
        let reference = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@",
            "Luma checklist snapshot (reference only, not an executable job)\nGoal: Synthetic editable goal")).firstMatch
        let identity = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Source snapshot ID:")).firstMatch
        let date = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Copy creation/import time:")).firstMatch
        revealTogether([source, reference, identity, date], in: app)
        capturePair(app, name: "Privacy QA 3 original reference identity and date")
        app.buttons["checklist.cancel"].tap()
        XCTAssertTrue(open.waitForExistence(timeout: 5))
        open.tap()
        XCTAssertTrue(goal.waitForExistence(timeout: 5))
        XCTAssertEqual(goal.value as? String, "Synthetic editable goal", "Privacy QA must not save the synthetic draft")
        app.buttons["checklist.cancel"].tap()
    }

    private func capturePair(_ app: XCUIApplication, name: String) {
        let toggle = app.buttons["checklistPrivacy.toggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        XCTAssertEqual(toggle.value as? String, "Off")
        attachScreenshot(app, name: name + " - original synthetic content")
        toggle.tap()
        waitForRedactionMode("On", toggle: toggle)
        // Do not infer redaction from accessibility labels: the pixels, not this
        // toggle or the accessibility tree, are the manual acceptance evidence.
        attachScreenshot(app, name: name + " - explicit privacy redaction")
        toggle.tap()
        waitForRedactionMode("Off", toggle: toggle)
    }

    private func waitForRedactionMode(_ value: String, toggle: XCUIElement) {
        let matches = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", value), object: toggle)
        XCTAssertEqual(XCTWaiter.wait(for: [matches], timeout: 5), .completed)
    }

    private func revealTogether(_ elements: [XCUIElement], in app: XCUIApplication) {
        let form: XCUIElement
        if app.collectionViews.firstMatch.waitForExistence(timeout: 5) {
            form = app.collectionViews.firstMatch
        } else {
            form = app.tables.firstMatch
            XCTAssertTrue(form.waitForExistence(timeout: 5))
        }
        for attempt in 0...8 {
            let bounds = app.frame.intersection(form.frame)
            let navigation = app.navigationBars["Edit checklist"]
            let toggle = app.buttons["checklistPrivacy.toggle"]
            let top = max(bounds.minY, navigation.frame.maxY) + 8
            let bottom = min(bounds.maxY, toggle.frame.minY) - 8
            guard bounds.width > 32, bottom - top > 80 else {
                XCTFail("No unobscured Form region for the privacy QA capture")
                return
            }
            let materialized = elements.allSatisfy { $0.exists && !$0.frame.isEmpty }
            let target = materialized ? elements.reduce(CGRect.null) { $0.union($1.frame) } : .null
            if materialized, target.minY >= top, target.maxY <= bottom,
               target.minX >= bounds.minX, target.maxX <= bounds.maxX,
               elements.allSatisfy({ $0.isHittable }) { return }
            guard attempt < 8 else { break }
            let maximum = (bottom - top) * 0.6
            let offset = materialized ? min(maximum, max(-maximum, (top + bottom) / 2 - target.midY)) : -maximum
            let startY = offset > 0 ? top + (bottom - top) * 0.2 : top + (bottom - top) * 0.8
            let origin = form.coordinate(withNormalizedOffset: .zero)
            let start = origin.withOffset(CGVector(dx: bounds.midX - form.frame.minX, dy: startY - form.frame.minY))
            let end = origin.withOffset(CGVector(dx: bounds.midX - form.frame.minX, dy: startY + offset - form.frame.minY))
            start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.2)
        }
        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = "Privacy QA visibility failure hierarchy"; hierarchy.lifetime = .keepAlways; add(hierarchy)
        attachScreenshot(app, name: "Privacy QA visibility failure")
        XCTFail("All requested synthetic values must fit in the unredacted capture before making its redacted pair")
    }

    private func attachScreenshot(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
