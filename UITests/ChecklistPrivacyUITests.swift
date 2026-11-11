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

    func testCaptureDraftFieldsWithExplicitPrivacyRedaction() {
        let app = launchPrivacyEditor()
        let goal = enterSyntheticDraft(in: app)
        let step = app.descendants(matching: .any).matching(identifier: "checklist.step").firstMatch
        let counts = content("checklist.counts", in: app)
        capturePair(app, name: "Privacy QA 1 draft fields and completion",
            targets: [goal, step, app.switches["checklist.done"], counts],
            redactedTargets: [goal, step, content("checklist.done.redacted", in: app), counts],
            inspectOriginal: {
                XCTAssertTrue(counts.label.hasPrefix("Goal: "))
                XCTAssertTrue(counts.label.contains("/300 · Step:"))
            })
        app.buttons["checklist.cancel"].tap()
        let open = app.buttons["checklistLifecycle.open"]
        XCTAssertTrue(open.waitForExistence(timeout: 5))
        open.tap()
        XCTAssertTrue(goal.waitForExistence(timeout: 5))
        XCTAssertEqual(goal.value as? String, "Synthetic editable goal", "Privacy QA must not save the synthetic draft")
        app.buttons["checklist.cancel"].tap()
    }

    func testCaptureWorkspaceAndSaveErrorWithExplicitPrivacyRedaction() {
        let app = launchPrivacyEditor()
        _ = enterSyntheticDraft(in: app)
        // This route throws only a synthetic error. It cannot persist or sync.
        XCTAssertTrue(app.buttons["checklist.save"].isEnabled)
        app.buttons["checklist.save"].tap()
        let issue = app.staticTexts["checklist.issue"]
        XCTAssertTrue(issue.waitForExistence(timeout: 5))
        XCTAssertEqual(issue.label, "Synthetic private save detail for redaction QA")
        let workspace = content("checklist.workspaceNotice", in: app)
        capturePair(app, name: "Privacy QA 2 workspace and save error", targets: [workspace, issue], inspectOriginal: {
            XCTAssertTrue(workspace.label.hasPrefix("Save updates only this copy in General."))
        })
        app.buttons["checklist.cancel"].tap()
    }

    func testCaptureReferenceProvenanceWithExplicitPrivacyRedaction() {
        let app = launchPrivacyEditor()
        let source = content("checklist.reference.source", in: app)
        let reference = content("checklist.reference.text", in: app)
        // Keep the complete source and selectable reference visible together;
        // capture identity/date separately rather than requiring all four rows
        // to fit one viewport after the unrelated typing/error capture work.
        capturePair(app, name: "Privacy QA 3 original source and reference", targets: [source, reference], inspectOriginal: {
            XCTAssertEqual(source.label, "Luma checklist snapshot · Synthetic.json · source synthetic-task · no source timestamp; date is import time")
            XCTAssertTrue(reference.label.hasPrefix("Luma checklist snapshot (reference only, not an executable job)\nGoal: Synthetic editable goal"))
        })
        let identity = content("checklist.reference.id", in: app)
        let date = content("checklist.reference.date", in: app)
        capturePair(app, name: "Privacy QA 4 source identity and date", targets: [identity, date], inspectOriginal: {
            XCTAssertTrue(identity.label.hasPrefix("Source snapshot ID:"))
            XCTAssertTrue(date.label.hasPrefix("Copy creation/import time:"))
        })
        app.buttons["checklist.cancel"].tap()
    }

    func testCompletionStateIsConcealedAndRestored() {
        let app = launchPrivacyEditor()
        // Keep Save enabled in both original states, so the screenshot comparison
        // varies only completion and not unrelated draft-change chrome.
        _ = enterSyntheticDraft(in: app)
        let done = app.switches["checklist.done"]
        XCTAssertTrue(done.waitForExistence(timeout: 5))
        XCTAssertEqual(done.value as? String, "0")
        let offLabel = captureCompletionPair(app, expectedValue: "0", name: "Privacy QA completion initially OFF")
        done.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        XCTAssertEqual(done.value as? String, "1", "The ordinary toggle must remain interactive")
        let onLabel = captureCompletionPair(app, expectedValue: "1", name: "Privacy QA completion initially ON")
        XCTAssertEqual(onLabel, offLabel, "The placeholder's presented label must be independent of completion state")
        done.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        XCTAssertEqual(done.value as? String, "0", "Restoring the editor must not disable its binding")
        app.buttons["checklist.cancel"].tap()
    }

    private func captureCompletionPair(_ app: XCUIApplication, expectedValue: String, name: String) -> String {
        let done = app.switches["checklist.done"]
        let placeholder = app.descendants(matching: .any).matching(identifier: "checklist.done.redacted").firstMatch
        XCTAssertEqual(done.value as? String, expectedValue)
        XCTAssertTrue(done.isEnabled)
        XCTAssertFalse(placeholder.exists)
        var presentedLabel = ""
        capturePair(app, name: name, targets: [done], redactedTargets: [placeholder], inspectRedacted: {
            XCTAssertTrue(placeholder.waitForExistence(timeout: 5))
            // iOS may mask even this generic label. Require state-independent
            // semantics rather than forcing privacy-rendered text to be readable.
            presentedLabel = placeholder.label
            XCTAssertFalse(["0", "1", "On", "Off", "Completed", "Not completed"].contains(presentedLabel))
            XCTAssertNil(placeholder.value, "The privacy placeholder must not expose a state value")
            XCTAssertNotEqual(placeholder.elementType, .button)
            XCTAssertFalse(placeholder.buttons.firstMatch.exists)
            XCTAssertFalse(app.switches.firstMatch.exists, "No state-bearing switch may remain in the redacted editor")
        })
        XCTAssertTrue(done.waitForExistence(timeout: 5))
        XCTAssertEqual(done.value as? String, expectedValue, "Redaction must not alter the unsaved completion state")
        XCTAssertTrue(done.isEnabled)
        XCTAssertFalse(placeholder.exists)
        return presentedLabel
    }

    private func content(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func launchPrivacyEditor() -> XCUIApplication {
        let app = XCUIApplication()
        application = app
        app.terminate()
        app.launchArguments = ["--uitest-chat", "checklists", "--uitest-checklist-lifecycle", "privacy-qa"]
        app.launch()
        let open = app.buttons["checklistLifecycle.open"]
        XCTAssertTrue(open.waitForExistence(timeout: 15))
        open.tap()
        let goal = app.descendants(matching: .any).matching(identifier: "checklist.goal").firstMatch
        XCTAssertTrue(goal.waitForExistence(timeout: 5))
        XCTAssertEqual(goal.value as? String, "Synthetic editable goal")
        return app
    }

    private func enterSyntheticDraft(in app: XCUIApplication) -> XCUIElement {
        let goal = app.descendants(matching: .any).matching(identifier: "checklist.goal").firstMatch
        let step = app.descendants(matching: .any).matching(identifier: "checklist.step").firstMatch
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
        return goal
    }

    private func capturePair(_ app: XCUIApplication, name: String, targets: [XCUIElement],
                             redactedTargets: [XCUIElement]? = nil,
                             inspectOriginal: () -> Void = {}, inspectRedacted: () -> Void = {}) {
        let toggle = app.buttons["checklistPrivacy.toggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        XCTAssertEqual(toggle.value as? String, "Off")
        revealTogether(targets, in: app)
        XCTAssertEqual(toggle.value as? String, "Off")
        inspectOriginal()
        attachScreenshot(app, name: name + " - original synthetic content")
        toggle.tap()
        waitForRedactionMode("On", toggle: toggle)
        inspectRedacted()
        // Privacy rendering can reset the Form scroll position. Reacquire the
        // same non-data IDs and prove their full geometry in this mode too.
        revealTogether(redactedTargets ?? targets, in: app)
        XCTAssertEqual(toggle.value as? String, "On", "The redacted target capture must remain in privacy mode")
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
        var previousTarget: CGRect?
        var stalledAttempts = 0
        for attempt in 0...6 {
            let formFrame = form.frame
            let bounds = app.frame.intersection(formFrame)
            let navigation = app.navigationBars["Edit checklist"]
            let toggle = app.buttons["checklistPrivacy.toggle"]
            // The QA control is a separate sibling above NavigationStack, not
            // an overlay hiding the Form's last row at maximum scroll.
            let top = max(bounds.minY, max(navigation.frame.maxY, toggle.frame.maxY)) + 8
            let bottom = bounds.maxY - 8
            guard bounds.width > 32, bottom - top > 80 else {
                XCTFail("No unobscured Form region for the privacy QA capture")
                return
            }
            // Cache each frame once per attempt instead of repeating expensive
            // accessibility snapshot queries for the same target geometry.
            let frames = elements.map { $0.exists ? $0.frame : CGRect.null }
            let materialized = frames.allSatisfy { !$0.isNull && !$0.isEmpty }
            let target = materialized ? frames.reduce(CGRect.null) { $0.union($1) } : .null
            print("Privacy QA reveal \(attempt): frames=\(frames), safe top=\(top), bottom=\(bottom)")
            if materialized, target.minY >= top, target.maxY <= bottom,
               target.minX >= bounds.minX, target.maxX <= bounds.maxX,
               elements.allSatisfy({
                   // This fixed placeholder deliberately rejects hit testing.
                   // Its full geometry is still required, like every target.
                   $0.identifier == "checklist.done.redacted" || $0.isHittable
               }) { return }
            if materialized {
                guard target.height <= bottom - top else {
                    print("Privacy QA group is taller than the safe viewport: \(target)")
                    break
                }
                if let previousTarget, abs(previousTarget.minY - target.minY) < 1,
                   abs(previousTarget.maxY - target.maxY) < 1 {
                    stalledAttempts += 1
                } else { stalledAttempts = 0 }
                // Capture the actual failure before the XCTest deadline instead
                // of repeating a gesture at an unchanged scroll boundary.
                guard stalledAttempts < 2 else { break }
                previousTarget = target
            }
            guard attempt < 6 else { break }
            let maximum = (bottom - top) * 0.6
            let offset = materialized ? min(maximum, max(-maximum, (top + bottom) / 2 - target.midY)) : -maximum
            let startY = offset > 0 ? top + (bottom - top) * 0.2 : top + (bottom - top) * 0.8
            let origin = form.coordinate(withNormalizedOffset: .zero)
            // Use the Form's empty left gutter, not the selectable reference
            // text. Coordinates remain inside this native scroll container.
            let x = bounds.minX + 8 - formFrame.minX
            let start = origin.withOffset(CGVector(dx: x, dy: startY - formFrame.minY))
            let end = origin.withOffset(CGVector(dx: x, dy: startY + offset - formFrame.minY))
            start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.2)
        }
        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = "Privacy QA visibility failure hierarchy"; hierarchy.lifetime = .keepAlways; add(hierarchy)
        attachScreenshot(app, name: "Privacy QA visibility failure")
        XCTFail("Every target must be fully visible in the current original or redacted capture")
    }

    private func attachScreenshot(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
