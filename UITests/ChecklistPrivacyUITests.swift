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
        capturePair(app, name: "Privacy QA 1 draft fields and completion",
            identifiers: ["checklist.goal", "checklist.step", "checklist.done", "checklist.counts"],
            redactedIdentifiers: ["checklist.goal", "checklist.step", "checklist.done.redacted", "checklist.counts"],
            inspectOriginal: { form in
                let counts = self.content("checklist.counts", in: form)
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
        capturePair(app, name: "Privacy QA 2 workspace and save error",
            identifiers: ["checklist.workspaceNotice", "checklist.issue"], inspectOriginal: { form in
            let workspace = self.content("checklist.workspaceNotice", in: form)
            XCTAssertTrue(workspace.label.hasPrefix("Save updates only this copy in General."))
            XCTAssertEqual(self.content("checklist.issue", in: form).label, "Synthetic private save detail for redaction QA")
        })
        app.buttons["checklist.cancel"].tap()
    }

    func testCaptureReferenceProvenanceWithExplicitPrivacyRedaction() {
        let app = launchPrivacyEditor()
        // Keep the complete source and selectable reference visible together;
        // capture identity/date separately rather than requiring all four rows
        // to fit one viewport after the unrelated typing/error capture work.
        capturePair(app, name: "Privacy QA 3 original source and reference",
            identifiers: ["checklist.reference.source", "checklist.reference.text"], inspectOriginal: { form in
            let source = self.content("checklist.reference.source", in: form)
            let reference = self.content("checklist.reference.text", in: form)
            XCTAssertEqual(source.label, "Luma checklist snapshot · Synthetic.json · source synthetic-task · no source timestamp; date is import time")
            XCTAssertTrue(reference.label.hasPrefix("Luma checklist snapshot (reference only, not an executable job)\nGoal: Synthetic editable goal"))
        })
        capturePair(app, name: "Privacy QA 4 source identity and date",
            identifiers: ["checklist.reference.id", "checklist.reference.date"], inspectOriginal: { form in
            let identity = self.content("checklist.reference.id", in: form)
            let date = self.content("checklist.reference.date", in: form)
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
        let off = captureCompletionPair(app, expectedValue: "0", name: "Privacy QA completion initially OFF")
        done.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        XCTAssertEqual(done.value as? String, "1", "The ordinary toggle must remain interactive")
        let on = captureCompletionPair(app, expectedValue: "1", name: "Privacy QA completion initially ON")
        XCTAssertEqual(on.label, off.label, "The placeholder's presented label must be independent of completion state")
        XCTAssertEqual(on.value, off.value, "Even the empty value representation must be independent of completion state")
        done.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        XCTAssertEqual(done.value as? String, "0", "Restoring the editor must not disable its binding")
        app.buttons["checklist.cancel"].tap()
    }

    private func captureCompletionPair(_ app: XCUIApplication, expectedValue: String, name: String) -> (label: String, value: String?) {
        let done = app.switches["checklist.done"]
        let placeholders = app.descendants(matching: .any).matching(identifier: "checklist.done.redacted")
        XCTAssertEqual(done.value as? String, expectedValue)
        XCTAssertTrue(done.isEnabled)
        XCTAssertEqual(placeholders.count, 0)
        var presentedLabel = ""
        var presentedValue: String?
        capturePair(app, name: name, identifiers: ["checklist.done"],
            redactedIdentifiers: ["checklist.done.redacted"], inspectRedacted: { form in
            let placeholder = self.content("checklist.done.redacted", in: form)
            XCTAssertTrue(placeholder.waitForExistence(timeout: 5))
            // iOS may mask even this generic label. Require state-independent
            // semantics rather than forcing privacy-rendered text to be readable.
            presentedLabel = placeholder.label
            XCTAssertFalse(["0", "1", "On", "Off", "Completed", "Not completed"].contains(presentedLabel))
            // iOS reports a value-less Other as either nil or an empty String.
            // Do not coerce other types to nil or accept any nonempty value.
            if let value = placeholder.value {
                XCTAssertTrue(value is String, "The privacy placeholder must not expose a typed state value")
                presentedValue = value as? String
                XCTAssertEqual(presentedValue, "", "The privacy placeholder must not expose a state value")
            }
            XCTAssertNotEqual(placeholder.elementType, .button)
            XCTAssertEqual(placeholder.buttons.count, 0)
            XCTAssertEqual(form.switches.count, 0, "No state-bearing switch may remain in the redacted Form")
            // SwiftUI retains a covered original Form in its accessibility
            // tree. Prove that its switches are covered, not merely offscreen.
            let visibleBounds = unobscuredBounds(in: app, form: form)
            for backingSwitch in app.switches.allElementsBoundByIndex {
                let frame = backingSwitch.frame
                XCTAssertFalse(frame.isEmpty)
                XCTAssertTrue(visibleBounds.contains(frame), "Check the backing switch while its full frame is in the viewport")
                XCTAssertFalse(backingSwitch.isHittable, "A backing switch must not be usable through privacy rendering")
            }
        })
        XCTAssertTrue(done.waitForExistence(timeout: 5))
        XCTAssertEqual(done.value as? String, expectedValue, "Redaction must not alter the unsaved completion state")
        XCTAssertTrue(done.isEnabled)
        XCTAssertEqual(placeholders.count, 0)
        return (presentedLabel, presentedValue)
    }

    private func content(_ identifier: String, in root: XCUIElement) -> XCUIElement {
        // On iOS 26, firstMatch can continue past an index-bound ancestor into
        // its sibling Form. Exact-one resolution preserves this query boundary.
        root.descendants(matching: .any).matching(identifier: identifier).element
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

    private func capturePair(_ app: XCUIApplication, name: String, identifiers: [String],
                             redactedIdentifiers: [String]? = nil,
                             inspectOriginal: (XCUIElement) -> Void = { _ in },
                             inspectRedacted: (XCUIElement) -> Void = { _ in }) {
        let toggle = app.buttons["checklistPrivacy.toggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        XCTAssertEqual(toggle.value as? String, "Off")
        guard let originalForm = captureForm(in: app, redacted: false) else { return }
        revealTogether(identifiers.map { content($0, in: originalForm) }, in: app, form: originalForm, redacted: false)
        XCTAssertEqual(toggle.value as? String, "Off")
        inspectOriginal(originalForm)
        attachScreenshot(app, name: name + " - original synthetic content")
        // Lower captures can virtualize completion. Materialize its ordinary
        // row before the mode change so the new privacy copy has a known marker.
        revealTogether([content("checklist.done", in: originalForm)], in: app,
            form: originalForm, redacted: false, towardTop: true)
        toggle.tap()
        waitForRedactionMode("On", toggle: toggle)
        guard let redactedForm = captureForm(in: app, redacted: true) else { return }
        // Privacy rendering retains a covered original Form and can reset the
        // visible copy's scroll position. Query only the verified redacted copy.
        revealTogether((redactedIdentifiers ?? identifiers).map { content($0, in: redactedForm) },
            in: app, form: redactedForm, redacted: true)
        inspectRedacted(redactedForm)
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

    private func captureForm(in app: XCUIApplication, redacted: Bool) -> XCUIElement? {
        let forms: XCUIElementQuery
        if app.collectionViews.firstMatch.waitForExistence(timeout: 5) {
            forms = app.collectionViews
        } else {
            forms = app.tables
            XCTAssertTrue(forms.firstMatch.waitForExistence(timeout: 5))
        }
        let indexedForms = forms.allElementsBoundByIndex
        let marker = redacted ? "checklist.done.redacted" : "checklist.done"
        // Enumerate the complete bounded queries. A firstMatch existence query
        // can find the same redacted marker from both sibling Form indices.
        let markerCounts = indexedForms.map { $0.descendants(matching: .any).matching(identifier: marker).count }
        let globalMarkerCount = app.descendants(matching: .any).matching(identifier: marker).count
        if !redacted {
            // The fixture has exactly one ordinary Form, even when its
            // completion row has been virtualized by a previous lower capture.
            guard indexedForms.count == 1 else {
                failFormSelection(in: app, forms: indexedForms, marker: marker,
                    markerCounts: markerCounts, globalMarkerCount: globalMarkerCount,
                    reason: "Original mode must have exactly one Form, not a retained privacy copy")
                return nil
            }
            return indexedForms[0]
        }
        let candidateIndices = markerCounts.indices.filter { markerCounts[$0] > 0 }
        guard candidateIndices.count == 1, markerCounts[candidateIndices[0]] == 1, globalMarkerCount == 1 else {
            failFormSelection(in: app, forms: indexedForms, marker: marker,
                markerCounts: markerCounts, globalMarkerCount: globalMarkerCount,
                reason: "Require exactly one Form containing the single materialized privacy completion marker")
            return nil
        }
        // Keep the selected index-based element, not a query dependent on a
        // virtualized row continuing to exist while lower targets are scrolled.
        return indexedForms[candidateIndices[0]]
    }

    private func failFormSelection(in app: XCUIApplication, forms: [XCUIElement], marker: String,
                                   markerCounts: [Int], globalMarkerCount: Int, reason: String) {
        let summary = "\(reason); forms=\(forms.count), marker=\(marker), scoped counts=\(markerCounts), global count=\(globalMarkerCount)"
        let modeValue = String(describing: app.buttons["checklistPrivacy.toggle"].value)
        var details = [summary, "Privacy control value: \(modeValue)"]
        for (index, form) in forms.enumerated() {
            details.append("Form \(index): frame=\(form.frame), marker count=\(markerCounts[index]), hittable=\(form.isHittable)")
        }
        print(details.joined(separator: "\n"))
        let selection = XCTAttachment(string: details.joined(separator: "\n"))
        selection.name = "Privacy QA Form selection counts"; selection.lifetime = .keepAlways; add(selection)
        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = "Privacy QA Form selection hierarchy"; hierarchy.lifetime = .keepAlways; add(hierarchy)
        attachScreenshot(app, name: "Privacy QA Form selection failure")
        XCTFail(summary)
    }

    private func unobscuredBounds(in app: XCUIApplication, form: XCUIElement) -> CGRect {
        let bounds = app.frame.intersection(form.frame)
        let navigation = app.navigationBars["Edit checklist"]
        let toggle = app.buttons["checklistPrivacy.toggle"]
        let top = max(bounds.minY, max(navigation.frame.maxY, toggle.frame.maxY)) + 8
        return CGRect(x: bounds.minX, y: top, width: bounds.width, height: max(0, bounds.maxY - 8 - top))
    }

    private func revealTogether(_ elements: [XCUIElement], in app: XCUIApplication,
                                form: XCUIElement, redacted: Bool, towardTop: Bool = false) {
        var previousTarget: CGRect?
        var stalledAttempts = 0
        for attempt in 0...6 {
            let formFrame = form.frame
            let bounds = unobscuredBounds(in: app, form: form)
            // The QA control is a separate sibling above NavigationStack, not
            // an overlay hiding the Form's last row at maximum scroll.
            let top = bounds.minY
            let bottom = bounds.maxY
            guard bounds.width > 32, bottom - top > 80 else {
                XCTFail("No unobscured Form region for the privacy QA capture")
                return
            }
            // Cache each frame once per attempt instead of repeating expensive
            // accessibility snapshot queries for the same target geometry.
            let frames = elements.map { $0.exists ? $0.frame : CGRect.null }
            let materialized = frames.allSatisfy { !$0.isNull && !$0.isEmpty }
            let target = materialized ? frames.reduce(CGRect.null) { $0.union($1) } : .null
            print("Privacy QA reveal \(attempt): redacted=\(redacted), frames=\(frames), safe top=\(top), bottom=\(bottom)")
            if materialized, target.minY >= top, target.maxY <= bottom,
               target.minX >= bounds.minX, target.maxX <= bounds.maxX,
               // Hittability is required for the ordinary editor, not its
               // noninteractive privacy rendering. Both retain full geometry.
               (redacted || elements.allSatisfy({ $0.isHittable })) { return }
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
            let offset = materialized ? min(maximum, max(-maximum, (top + bottom) / 2 - target.midY))
                : (towardTop ? maximum : -maximum)
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
