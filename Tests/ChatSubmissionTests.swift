import XCTest
@testable import AsterionVeyra

@MainActor final class ChatSubmissionTests: XCTestCase {
    func testBlankModelOutputCannotBePublishedOrSaved() {
        let store = AssistantStore()
        let originalCount = store.saved.chats.count
        for content in ["", " \n\t "] {
            XCTAssertThrowsError(try store.acceptAnswer(content, question: "Hello", project: store.project, repository: nil))
        }
        XCTAssertEqual(store.saved.chats.count, originalCount)
        XCTAssertTrue(store.answer.isEmpty)
    }

    func testRejectedRequestsReportNotAcceptedWithoutStartingGeneration() {
        let store = AssistantStore()
        XCTAssertFalse(store.ask(" \n "))
        XCTAssertFalse(store.ask(String(repeating: "x", count: 2_001)))
        XCTAssertNotNil(store.error)
        XCTAssertFalse(store.busy)
        XCTAssertFalse(store.ask("password = synthetic-only"))
        XCTAssertFalse(store.busy)
    }

    func testBusyRequestDoesNotReplaceCurrentAnswer() {
        let store = AssistantStore()
        store.busy = true
        store.answer = "Existing response"
        XCTAssertFalse(store.ask("Another question"))
        XCTAssertEqual(store.answer, "Existing response")
        XCTAssertTrue(store.busy)
    }
}
