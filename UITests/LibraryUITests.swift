import XCTest

@MainActor final class LibraryUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    func testProjectSearchFindsSavedWorkspaceAndSwitchesWithoutNetwork() {
        let app = launchFixture()
        app.tabBars.buttons["Projects"].tap()
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap(); search.typeText("Synthetic second")
        waitForText("Synthetic second", in: search, app: app)
        let project = app.buttons["Synthetic second project"]
        reveal(project, in: app)
        project.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5), "Selecting a saved workspace must dismiss search")
        XCTAssertEqual(project.value as? String, "Selected")
        app.tabBars.buttons["Memory"].tap()
        reveal(app.staticTexts["Synthetic workspace for draft isolation"], in: app)
        saveScreenshot(app, name: "Memory workspace selected from project search")
    }

    func testMemorySearchDoesNotShowOtherWorkspaceNotesAndShowsEmptyState() {
        let app = launchFixture()
        app.tabBars.buttons["Memory"].tap()
        XCTAssertFalse(app.staticTexts["Synthetic workspace for draft isolation"].exists)
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap(); search.typeText("No such note")
        waitForText("No such note", in: search, app: app)
        reveal(app.staticTexts["No matching notes"], in: app)
        XCTAssertFalse(app.staticTexts["Synthetic workspace for draft isolation"].exists)
        saveScreenshot(app, name: "Memory search stays in the current workspace")
        let closeSearch = app.buttons["Close"]
        XCTAssertTrue(closeSearch.isHittable)
        closeSearch.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
        reveal(app.staticTexts["Make room for what matters"], in: app)
        XCTAssertFalse(app.staticTexts["No matching notes"].exists)
    }

    func testProjectCollectionFilterDoesNotLoseSavedWorkspaces() {
        let app = launchFixture()
        app.tabBars.buttons["Projects"].tap()
        let filter = app.segmentedControls["projects.collection"]
        reveal(filter, in: app)
        filter.buttons["GitHub"].tap()
        XCTAssertFalse(app.buttons["Synthetic second project"].exists)
        // Changing collection changes the list height and can move the control.
        // Reveal again in either direction before tapping the next segment.
        reveal(filter, in: app)
        filter.buttons["Saved"].tap()
        reveal(app.buttons["Synthetic second project"], in: app)
        saveScreenshot(app, name: "Projects filtered to saved workspaces")
    }

    func testLongWorkspaceNameKeepsItsFullAccessibleIdentityAtLargeText() {
        let app = launchFixture(largeText: true)
        app.tabBars.buttons["Projects"].tap()
        let filter = app.segmentedControls["projects.collection"]
        reveal(filter, in: app)
        filter.buttons["Saved"].tap()
        let identity = "GitHub account 42: sample-owner/A-long-readable-workspace-name-for-accessibility-layout"
        let workspace = app.buttons[identity]
        reveal(workspace, in: app)
        XCTAssertTrue(workspace.isHittable)
        XCTAssertEqual(workspace.label, identity)
        XCTAssertLessThanOrEqual(workspace.frame.maxX, app.frame.maxX)
        XCTAssertGreaterThanOrEqual(workspace.frame.minX, app.frame.minX)
        XCTAssertGreaterThanOrEqual(workspace.frame.minY, app.navigationBars.firstMatch.frame.maxY)
        XCTAssertLessThanOrEqual(workspace.frame.maxY, app.tabBars.firstMatch.frame.minY)
        saveScreenshot(app, name: "Long project name at accessibility text size")
        // A bounded row must not make the full visual name unavailable.
        workspace.press(forDuration: 1)
        app.buttons["Show full workspace name"].tap()
        let fullName = app.staticTexts[identity]
        XCTAssertTrue(fullName.waitForExistence(timeout: 5))
        XCTAssertEqual(fullName.label, identity)
        let close = app.buttons["projects.workspace.details.close"]
        XCTAssertTrue(close.isHittable)
        saveScreenshot(app, name: "Full workspace identity remains inspectable at large text")
        close.tap()
        reveal(workspace, in: app)
        workspace.tap()
        XCTAssertEqual(workspace.value as? String, "Selected")
    }

    func testPrivateSyncEntryOpensStatusAndSetup() {
        let app = XCUIApplication(); app.launch()
        XCTAssertTrue(app.tabBars.buttons["Memory"].waitForExistence(timeout: 15))
        app.tabBars.buttons["Memory"].tap()
        let sync = app.buttons["memory.sync.open"]
        reveal(sync, in: app)
        XCTAssertTrue(sync.isEnabled); sync.tap()
        XCTAssertTrue(app.navigationBars["Private memory sync"].waitForExistence(timeout: 5))
        saveScreenshot(app, name: "Private sync setup opened from Memory")
    }

    func testSavingNoteDismissesKeyboardAndKeepsLatestNoteAboveTabs() {
        let app = launchFixture()
        app.tabBars.buttons["Memory"].tap()
        let field = app.descendants(matching: .any).matching(identifier: "memoryNoteInput").firstMatch
        reveal(field, in: app)
        field.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        let save = app.buttons["memoryNoteSaveKeyboard"]
        XCTAssertTrue(save.waitForExistence(timeout: 5))
        XCTAssertFalse(save.isEnabled, "A blank note cannot be saved from the keyboard toolbar")
        let noteText = "Synthetic newest note"
        app.typeText(noteText)
        waitForText(noteText, in: field, app: app)
        XCTAssertTrue(save.isEnabled)
        XCTAssertTrue(save.isHittable)
        XCTAssertTrue(app.keyboards.firstMatch.exists, "Exercise saving with the keyboard still visible")
        XCTAssertGreaterThanOrEqual(save.frame.minY, app.navigationBars.firstMatch.frame.maxY)
        XCTAssertLessThanOrEqual(save.frame.maxY, app.keyboards.firstMatch.frame.minY)
        saveScreenshot(app, name: "Remember action is above the open keyboard")
        save.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
        let note = app.staticTexts[noteText]
        reveal(note, in: app)
        XCTAssertTrue(note.isHittable)
        XCTAssertGreaterThanOrEqual(note.frame.minY, app.navigationBars.firstMatch.frame.maxY)
        XCTAssertLessThanOrEqual(note.frame.maxY, app.tabBars.firstMatch.frame.minY)
        saveScreenshot(app, name: "Latest memory note clears the floating tab bar")
    }

    func testRevealMeasuredDragCentersClippedRowsWithoutOvershooting() {
        // Captured on the failed iOS 26.3 accessibility-size run: a 336.7-point
        // row fits in 519 points, but fixed 311.4-point swipes oscillated around it.
        let top: CGFloat = 264, bottom: CGFloat = 783
        for y in [CGFloat(494.3), CGFloat(182.9)] {
            let frame = CGRect(x: 16, y: y, width: 370, height: 336.7)
            let offset = revealDragOffset(for: frame, top: top, bottom: bottom)
            let moved = frame.offsetBy(dx: 0, dy: offset)
            XCTAssertLessThan(abs(offset), (bottom - top) * 0.6)
            XCTAssertEqual(moved.midY, (top + bottom) / 2, accuracy: 0.01)
            XCTAssertGreaterThanOrEqual(moved.minY, top)
            XCTAssertLessThanOrEqual(moved.maxY, bottom)
        }
        XCTAssertEqual(revealDragOffset(for: .zero, top: top, bottom: bottom), -311.4, accuracy: 0.01)
        let distant = CGRect(x: 16, y: 1200, width: 370, height: 336.7)
        XCTAssertEqual(revealDragOffset(for: distant, top: top, bottom: bottom), -311.4, accuracy: 0.01)
    }

    private func launchFixture(largeText: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--uitest-chat", "library"]
        if largeText { app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"] }
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["Memory"].waitForExistence(timeout: 15))
        return app
    }
    private func waitForText(_ text: String, in field: XCUIElement, app: XCUIApplication,
                             file: StaticString = #filePath, line: UInt = #line) {
        let matches = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", text), object: field)
        let result = XCTWaiter.wait(for: [matches], timeout: 10)
        let actual = field.value as? String
        if result != .completed || actual != text {
            let hierarchy = XCTAttachment(string: app.debugDescription)
            hierarchy.name = "Exact library input failure hierarchy"; hierarchy.lifetime = .keepAlways; add(hierarchy)
            saveScreenshot(app, name: "Exact library input failure")
        }
        XCTAssertEqual(actual, text, "Exact input wait result: \(result.rawValue)", file: file, line: line)
        XCTAssertEqual(result, .completed, "Input must settle within the existing deadline", file: file, line: line)
    }
    private func reveal(_ element: XCUIElement, in app: XCUIApplication,
                        file: StaticString = #filePath, line: UInt = #line) {
        // A library tab owns one native List. Never gesture through the root app,
        // navigation chrome, tab bar, keyboard or a different scroll container.
        let list: XCUIElement
        if app.collectionViews.firstMatch.waitForExistence(timeout: 2) {
            list = app.collectionViews.firstMatch
        } else if app.tables.firstMatch.waitForExistence(timeout: 2) {
            list = app.tables.firstMatch
        } else {
            failReveal("The active library must expose its native List", in: app, file: file, line: line)
            return
        }
        for attempt in 0...10 {
            let bounds = app.frame.intersection(list.frame)
            let navigation = app.navigationBars.firstMatch
            let tabs = app.tabBars.firstMatch
            let keyboard = app.keyboards.firstMatch
            let accessory = app.otherElements.matching(identifier: "SystemInputAssistantView").firstMatch
            let top = max(bounds.minY, navigation.exists ? navigation.frame.maxY : bounds.minY) + 8
            var bottom = min(bounds.maxY, tabs.exists ? tabs.frame.minY : bounds.maxY,
                             keyboard.exists ? keyboard.frame.minY : bounds.maxY) - 8
            if keyboard.exists && accessory.exists { bottom = min(bottom, accessory.frame.minY - 8) }
            guard !bounds.isEmpty, bounds.width > 32, bottom - top > 80 else {
                failReveal("No unobscured library area is available for scrolling", in: app, file: file, line: line)
                return
            }
            let frame = element.exists ? element.frame : .zero
            if !frame.isEmpty && frame.minY >= top && frame.maxY <= bottom &&
                frame.minX >= bounds.minX && frame.maxX <= bounds.maxX && element.isHittable { return }
            guard attempt < 10 else { break }
            // Center known targets rather than repeatedly overshooting a tall
            // accessibility row with a fixed swipe. All visibility requirements
            // above and the existing ten-gesture limit stay unchanged.
            let offset = revealDragOffset(for: frame, top: top, bottom: bottom)
            let upper = top + (bottom - top) * 0.2
            let lower = top + (bottom - top) * 0.8
            let origin = list.coordinate(withNormalizedOffset: .zero)
            let x = bounds.midX - list.frame.minX
            let startY = offset > 0 ? upper : lower
            let start = origin.withOffset(CGVector(dx: x, dy: startY - list.frame.minY))
            let end = origin.withOffset(CGVector(dx: x, dy: startY + offset - list.frame.minY))
            start.press(forDuration: 0.05, thenDragTo: end)
        }
        failReveal("Expected the whole target below navigation and above the keyboard/tab bar", in: app, file: file, line: line)
    }
    private func revealDragOffset(for frame: CGRect, top: CGFloat, bottom: CGFloat) -> CGFloat {
        let maximum = (bottom - top) * 0.6
        guard !frame.isEmpty else { return -maximum }
        let towardCenter = (top + bottom) / 2 - frame.midY
        return min(maximum, max(-maximum, towardCenter))
    }
    private func failReveal(_ message: String, in app: XCUIApplication, file: StaticString, line: UInt) {
        // Automatic XCTest snapshots can contain only the root app on iOS 26.
        // Preserve the actual controls and pixels when a visibility check fails.
        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = "Library visibility failure hierarchy"
        hierarchy.lifetime = .keepAlways
        add(hierarchy)
        saveScreenshot(app, name: "Library visibility failure")
        XCTFail(message, file: file, line: line)
    }
    private func saveScreenshot(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
