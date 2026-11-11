import XCTest

@MainActor final class RepositoryProposalReviewUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    func testChangePreviewKeepsBothCompleteFilesAndShowsLineEndings() {
        let app = XCUIApplication()
        app.launchArguments = ["--uitest-proposal-review"]
        app.launch()
        let original = app.staticTexts["proposal-original-review"]
        let replacement = app.staticTexts["proposal-new-review"]
        XCTAssertTrue(original.waitForExistence(timeout: 5))
        XCTAssertEqual(original.label, "let greeting = \"Hello\"\r\nprint(greeting)\n")
        XCTAssertEqual(replacement.label, "let greeting = \"Hello, Jarvis\"\nprint(greeting)\n")
        let preview = app.buttons["proposal-change-preview"]
        XCTAssertTrue(preview.waitForExistence(timeout: 5), "Prepared proposals need a change-focused comparison, not just two whole files")
        preview.tap()
        let detail = app.staticTexts["proposal-change-lines"]
        XCTAssertTrue(detail.waitForExistence(timeout: 5))
        XCTAssertTrue(detail.label.contains("- old 1 | let greeting = \"Hello\" ⟦CRLF⟧"))
        XCTAssertTrue(detail.label.contains("+ new 1 | let greeting = \"Hello, Jarvis\" ⟦LF⟧"))
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "Changed lines preserve complete proposal review"; shot.lifetime = .keepAlways; add(shot)
        preview.tap()
        XCTAssertTrue(original.exists)
        XCTAssertTrue(replacement.exists)
        XCTAssertFalse(app.buttons["proposal-confirm-publish"].exists, "The read-only display fixture has no publishing capability")
    }
}
