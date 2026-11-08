import XCTest
@testable import AsterionVeyra

@MainActor final class RepositorySelectionTests: XCTestCase {
    func testSelectionIsEphemeralAndClearedByWorkspaceChange() {
        let store = AssistantStore()
        let repository = Repository(id: 42, full_name: "owner/repo", default_branch: "main")
        store.selectRepository(repository, commit: String(repeating: "a", count: 40), client: GitHubClient(), workspace: "account42: owner/repo")
        XCTAssertEqual(store.project, "account42: owner/repo")
        XCTAssertEqual(store.selectedRepository?.repository, "owner/repo")
        store.attached = "private source"
        store.switchProject("General")
        XCTAssertNil(store.selectedRepository)
        XCTAssertTrue(store.attached.isEmpty)
    }
    func testSelectingAnotherRepositoryClearsPriorAttachment() {
        let store = AssistantStore()
        store.attached = "old source"
        store.attachmentSource = "old repo"
        store.selectRepository(Repository(id: 3, full_name: "other/repo", default_branch: "main"), commit: String(repeating: "b", count: 40), client: GitHubClient(), workspace: "other/repo")
        XCTAssertTrue(store.attached.isEmpty)
        XCTAssertTrue(store.attachmentSource.isEmpty)
        XCTAssertEqual(store.selectedRepository?.commit, String(repeating: "b", count: 40))
    }
    func testRevocationAfterSourceRetrievalWithholdsModelCompletion() async throws {
        let store = AssistantStore()
        let session = try GitHubAuthSession(token: "github_pat_SYNTHETIC_TEST_ONLY_123")
        let client = GitHubClient(authentication: session)
        store.selectRepository(Repository(id: 9, full_name: "owner/private", default_branch: "main"), commit: String(repeating: "c", count: 40), client: client, workspace: "account9: owner/private")
        let capturedContext = store.selectedRepository
        let oldChats = store.saved.chats.count
        // Model completion resumes after a transport/session has been revoked.
        await Task.yield()
        session.revoke()
        XCTAssertThrowsError(try store.acceptAnswer("private source-derived reply", question: "inspect", project: store.project, repository: capturedContext))
        XCTAssertTrue(store.answer.isEmpty)
        XCTAssertEqual(store.saved.chats.count, oldChats)
    }

    func testSessionEndClearsAssistantWithoutProjectsView() throws {
        let store = AssistantStore()
        let credentials = GitHubCredentialStore(onSessionEnded: { store.switchProject("General") })
        let session = try credentials.begin(token: "github_pat_SYNTHETIC_TEST_ONLY_123", directInstallationConfirmed: true)
        store.selectRepository(Repository(id: 9, full_name: "owner/private", default_branch: "main"), commit: String(repeating: "d", count: 40), client: GitHubClient(authentication: session), workspace: "account9: owner/private")
        store.attached = "private retrieved source"
        store.busy = true
        credentials.endSession()
        XCTAssertEqual(store.project, "General")
        XCTAssertNil(store.selectedRepository)
        XCTAssertTrue(store.attached.isEmpty)
        XCTAssertFalse(store.busy)
    }

}
