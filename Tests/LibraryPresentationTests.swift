import XCTest
@testable import AsterionVeyra

final class LibraryPresentationTests: XCTestCase {
    func testProjectSearchKeepsAccountIdentityAndCountsSeparate() {
        let first = "GitHub account 10: owner/Journal"
        let second = "GitHub account 20: owner/Journal"
        let state = SavedState(notes: [MemoryNote(project: first, text: "One", source: "Manual")],
                               chats: [ChatEntry(project: second, role: "user", text: "Two")])
        let matches = LibraryPresentation.workspaces(state: state, current: "General", query: "journal")
        XCTAssertEqual(Set(matches.map(\.id)), Set([first, second]))
        XCTAssertEqual(matches.first { $0.id == first }?.noteCount, 1)
        XCTAssertEqual(matches.first { $0.id == first }?.messageCount, 0)
        XCTAssertEqual(matches.first { $0.id == second }?.messageCount, 1)
        XCTAssertNotEqual(WorkspaceDisplay(first).subtitle, WorkspaceDisplay(second).subtitle)
    }

    func testEmptyCurrentWorkspaceRemainsSelectableAndIsFirstWithoutSearch() {
        let state = SavedState(notes: [MemoryNote(project: "Older", text: "Note", source: "Manual")], chats: [])
        let workspaces = LibraryPresentation.workspaces(state: state, current: "Fresh", query: " \n ")
        XCTAssertEqual(workspaces.first?.id, "Fresh")
        XCTAssertTrue(workspaces.contains { $0.id == "General" })
        XCTAssertEqual(workspaces.first?.noteCount, 0)
        XCTAssertTrue(LibraryPresentation.workspaces(state: state, current: "Fresh", query: "missing").isEmpty)
    }

    func testNoteSearchMatchesSourcesButNeverAnotherProject() {
        let old = MemoryNote(project: "General", text: "First", source: "Café research", savedAt: Date(timeIntervalSince1970: 1))
        let recent = MemoryNote(project: "General", text: "Second", source: "CAFE research", savedAt: Date(timeIntervalSince1970: 2))
        let privateNote = MemoryNote(project: "Other", text: "Cafe hidden", source: "Manual")
        let results = LibraryPresentation.notes([old, privateNote, recent], project: "General", query: " cafe ")
        XCTAssertEqual(results.map(\.text), ["Second", "First"])
    }

    func testRepositorySearchIncludesOwnerAndBranchWithoutChangingRepositoryIdentity() {
        let repositories = [Repository(id: 1, full_name: "zebra/Tools", default_branch: "main"),
                            Repository(id: 2, full_name: "acme/Journal", default_branch: "preview")]
        XCTAssertEqual(LibraryPresentation.repositories(repositories, query: " ACME ").map(\.id), [2])
        XCTAssertEqual(LibraryPresentation.repositories(repositories, query: "preview").map(\.id), [2])
        XCTAssertTrue(LibraryPresentation.repositories(repositories, query: "missing").isEmpty)
    }

    func testDisplaySimplifiesValidRepositoriesWithoutStrippingOrdinaryProjectNames() {
        XCTAssertEqual(WorkspaceDisplay("GitHub account 10: owner/Journal").title, "Journal")
        XCTAssertEqual(WorkspaceDisplay("GitHub account 10: owner/Journal").subtitle, "owner · Account 10")
        XCTAssertEqual(WorkspaceDisplay("owner/Journal").subtitle, "owner")
        XCTAssertEqual(WorkspaceDisplay("Design: phase two").title, "Design: phase two")
        XCTAssertEqual(WorkspaceDisplay("GitHub account invalid: owner/Journal").title,
                       "GitHub account invalid: owner/Journal")
    }
}
