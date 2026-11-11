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
    func testTruncatedPreviewDisclosesOmittedAndShortenedLines() {
        let app = XCUIApplication()
        app.launchArguments = ["--uitest-proposal-review", "--uitest-proposal-review-large"]
        app.launch()
        let preview = app.buttons["proposal-change-preview"]
        XCTAssertTrue(preview.waitForExistence(timeout: 5))
        let limits = app.staticTexts["proposal-change-limits"]
        XCTAssertTrue(limits.label.contains("12 of 20 old lines and 12 of 15 new lines"))
        XCTAssertTrue(limits.label.contains("Omitted: 8 old and 3 new lines"))
        XCTAssertTrue(limits.label.contains("Shortened displayed lines: 1"))
        preview.tap()
        let detail = app.staticTexts["proposal-change-lines"]
        XCTAssertTrue(detail.waitForExistence(timeout: 5))
        XCTAssertTrue(detail.label.contains("[line shortened]"))
        XCTAssertTrue(detail.label.contains("- old 12 | old12"))
        XCTAssertTrue(detail.label.contains("+ new 12 | new12"))
        XCTAssertFalse(detail.label.contains("- old 13 |"))
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "Bounded preview explicitly reports omissions"; shot.lifetime = .keepAlways; add(shot)
        preview.tap()
        let original = app.staticTexts["proposal-original-review"]
        for _ in 0..<5 where !original.exists { app.swipeUp() }
        XCTAssertTrue(original.exists)
        XCTAssertTrue(original.label.contains("old20 \n"), "Preview truncation must not truncate complete source")
        let replacement = app.staticTexts["proposal-new-review"]
        for _ in 0..<8 where !replacement.exists { app.swipeUp() }
        XCTAssertTrue(replacement.exists)
        XCTAssertTrue(replacement.label.contains("new15\n"))
    }

}
