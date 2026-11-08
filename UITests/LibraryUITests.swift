import XCTest

@MainActor final class LibraryUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    func testProjectSearchFindsSavedWorkspaceAndSwitchesWithoutNetwork() {
        let app = launchFixture()
        app.tabBars.buttons["Projects"].tap()
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap(); search.typeText("Synthetic second")
        waitForText("Synthetic second", in: search)
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
        waitForText("No such note", in: search)
        reveal(app.staticTexts["No matching notes"], in: app)
        XCTAssertFalse(app.staticTexts["Synthetic workspace for draft isolation"].exists)
        saveScreenshot(app, name: "Memory search stays in the current workspace")
        app.buttons["Cancel"].tap()
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
        let noteText = "Synthetic newest note"
        field.typeText(noteText)
        waitForText(noteText, in: field)
        let save = app.buttons["Remember note"]
        reveal(save, in: app)
        XCTAssertTrue(save.isEnabled)
        XCTAssertTrue(app.keyboards.firstMatch.exists, "Exercise saving with the keyboard still visible")
        save.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
        let note = app.staticTexts[noteText]
        reveal(note, in: app)
        XCTAssertTrue(note.isHittable)
        XCTAssertGreaterThanOrEqual(note.frame.minY, app.navigationBars.firstMatch.frame.maxY)
        XCTAssertLessThanOrEqual(note.frame.maxY, app.tabBars.firstMatch.frame.minY)
        saveScreenshot(app, name: "Latest memory note clears the floating tab bar")
    }

    private func launchFixture(largeText: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--uitest-chat", "library"]
        if largeText { app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"] }
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["Memory"].waitForExistence(timeout: 15))
        return app
    }
    private func waitForText(_ text: String, in field: XCUIElement) {
        // Synthesized typing can finish before the final characters reach SwiftUI.
        expectation(for: NSPredicate(format: "value == %@", text), evaluatedWith: field)
        waitForExpectations(timeout: 10)
        XCTAssertEqual(field.value as? String, text)
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
            XCTFail("The active library must expose its native List", file: file, line: line)
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
                XCTFail("No unobscured library area is available for scrolling", file: file, line: line)
                return
            }
            let frame = element.exists ? element.frame : .zero
            if !frame.isEmpty && frame.minY >= top && frame.maxY <= bottom &&
                frame.minX >= bounds.minX && frame.maxX <= bounds.maxX && element.isHittable { return }
            guard attempt < 10 else { break }
            let moveDown = !frame.isEmpty && frame.minY < top
            let upper = top + (bottom - top) * 0.2
            let lower = top + (bottom - top) * 0.8
            let origin = list.coordinate(withNormalizedOffset: .zero)
            let x = bounds.midX - list.frame.minX
            let start = origin.withOffset(CGVector(dx: x, dy: (moveDown ? upper : lower) - list.frame.minY))
            let end = origin.withOffset(CGVector(dx: x, dy: (moveDown ? lower : upper) - list.frame.minY))
            start.press(forDuration: 0.05, thenDragTo: end)
        }
        XCTFail("Expected the whole target below navigation and above the keyboard/tab bar", file: file, line: line)
    }
    private func saveScreenshot(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
