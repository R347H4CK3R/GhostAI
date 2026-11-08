import Foundation
import XCTest
@testable import AsterionVeyra

final class AssistantConnectionTests: XCTestCase {
    func testAvailablePathDoesNotClaimVerifiedInternetOrOfflineWithoutScope() {
        XCTAssertEqual(AssistantConnectionPolicy.initial(path: .available, hasRepository: false), .setupRequired)
        XCTAssertEqual(AssistantConnectionPolicy.initial(path: .available, hasRepository: true), .ready)
        XCTAssertEqual(AssistantConnectionPolicy.initial(path: .unknown, hasRepository: true), .ready)
        XCTAssertEqual(AssistantConnectionPolicy.initial(path: .unavailable, hasRepository: true), .offline)
        XCTAssertFalse(AssistantConnectionState.setupRequired.usesSavedOnlyFallback)
        XCTAssertFalse(AssistantConnectionState.ready.usesSavedOnlyFallback)
    }

    func testConnectionFailuresAndServiceOutagesAreDistinctFromAccessErrors() {
        let unavailableCodes: [URLError.Code] = [.notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed, .timedOut]
        for code in unavailableCodes {
            let safe = GitHubRequestPolicy.safeError(URLError(code), authenticated: false)
            XCTAssertEqual(AssistantConnectionPolicy.failure(safe), .offline)
        }
        XCTAssertEqual(AssistantConnectionPolicy.failure(GitHubAccessError.expired), .authenticationRequired)
        XCTAssertEqual(AssistantConnectionPolicy.failure(GitHubAccessError.rateLimited), .rateLimited)
        XCTAssertEqual(AssistantConnectionPolicy.failure(GitHubAccessError.accessDenied), .accessDenied)
        XCTAssertEqual(AssistantConnectionPolicy.failure(GitHubAccessError.serviceUnavailable), .serviceUnavailable)
        let otherCodes: [URLError.Code] = [.serverCertificateUntrusted, .secureConnectionFailed, .badURL]
        for code in otherCodes {
            XCTAssertEqual(AssistantConnectionPolicy.failure(GitHubRequestPolicy.safeError(URLError(code), authenticated: false)), .failed)
        }
        XCTAssertTrue(GitHubRequestPolicy.safeError(URLError(.cancelled), authenticated: false) is CancellationError)
    }

    func testHTTPResponsesNeverBecomeNoService() throws {
        let client = GitHubClient()
        let cases: [(Int, AssistantConnectionState)] = [(401, .authenticationRequired), (403, .accessDenied), (404, .accessDenied), (429, .rateLimited), (503, .serviceUnavailable)]
        for (code, expected) in cases {
            do { try client.validateResponseStatus(code); XCTFail("Expected failure") }
            catch { XCTAssertEqual(AssistantConnectionPolicy.failure(error), expected) }
        }
    }

    func testGitHub403WithRateHeadersIsNotAnAuthenticationOrOfflineFailure() {
        let client = GitHubClient()
        XCTAssertThrowsError(try client.validateResponseStatus(403, rateLimitRemaining: "0")) {
            XCTAssertEqual(AssistantConnectionPolicy.failure($0), .rateLimited)
        }
        XCTAssertThrowsError(try client.validateResponseStatus(403, retryAfter: "60")) {
            XCTAssertEqual(AssistantConnectionPolicy.failure($0), .rateLimited)
        }
    }

    func testInterruptedLiveReadDoesNotClaimAnswerUsedOnlySavedNotes() {
        XCTAssertTrue(AssistantConnectionState.offline.responseSource(usedLiveReference: true).contains("Partial live reference"))
        XCTAssertTrue(AssistantConnectionState.serviceUnavailable.responseSource(usedLiveReference: true).contains("Partial live reference"))
        XCTAssertEqual(AssistantConnectionState.offline.responseSource(usedLiveReference: false), "Apple on device · Saved context; connection unavailable")
    }

    func testPromptDescribesMissingSelectionAsSetupRatherThanNoService() {
        let instruction = AssistantConnectionPolicy.scopeInstruction(repository: nil, state: .setupRequired)
        XCTAssertTrue(instruction.contains("Projects"))
        XCTAssertTrue(instruction.contains("not evidence of no internet"))
        XCTAssertFalse(instruction.contains("offline memory only"))
        XCTAssertTrue(AssistantConnectionPolicy.scopeInstruction(repository: "owner/repo", state: .online).contains("live GitHub"))
        XCTAssertTrue(AssistantConnectionPolicy.scopeInstruction(repository: "owner/repo", state: .offline).contains("saved context only"))
        XCTAssertTrue(AssistantConnectionState.online.responseSource.contains("Live GitHub"))
        XCTAssertFalse(AssistantConnectionState.setupRequired.responseSource.contains("Offline"))
    }
}

@MainActor final class AssistantConnectionIntegrationTests: XCTestCase {
    private let repository = Repository(id: 1, full_name: "owner/repo", default_branch: "main")
    private let commit = String(repeating: "a", count: 40)

    func testPathHintDoesNotEraseAccessDenialButNextQuestionCanRecheck() async throws {
        let reads = RecoveringAssistantReader(initialFailure: .accessDenied)
        let store = AssistantStore(launchArguments: ["--uitest-chat", "success"], repositoryReader: { _ in reads.reader })
        store.selectRepository(repository, commit: commit, client: GitHubClient(), workspace: repository.full_name)
        XCTAssertTrue(store.ask("Inspect this project"))
        try await waitForIdle(store)
        XCTAssertEqual(store.connectionState, .accessDenied)
        store.networkPathChanged(.available)
        XCTAssertEqual(store.connectionState, .accessDenied, "A Wi-Fi/cellular hint does not establish permissions")
        XCTAssertTrue(store.ask("Check again"))
        try await waitForIdle(store)
        XCTAssertEqual(store.connectionState, .online)
    }

    func testDeletingProjectChatPrunesOnlyItsEphemeralResponseSources() throws {
        let store = AssistantStore(launchArguments: ["--uitest-chat", "success"])
        try store.acceptAnswer("First reply", question: "First question", project: "General", repository: nil)
        let firstID = try XCTUnwrap(store.saved.chats.last?.id)
        store.switchProject("Other")
        try store.acceptAnswer("Second reply", question: "Second question", project: "Other", repository: nil)
        let secondID = try XCTUnwrap(store.saved.chats.last?.id)
        XCTAssertEqual(store.responseSources.count, 2)
        store.clearProjectChat()
        XCTAssertNil(store.responseSources[secondID])
        XCTAssertNotNil(store.responseSources[firstID])
        XCTAssertEqual(store.responseSources.count, 1)
        store.switchProject("General")
        store.clearProjectChat()
        XCTAssertTrue(store.responseSources.isEmpty)
    }

    func testRevocationDuringPreflightReportsAuthenticationAndWithholdsLateReply() async throws {
        let session = try GitHubAuthSession(token: "github_pat_SYNTHETIC_TEST_ONLY_123")
        let client = GitHubClient(authentication: session)
        let gate = AssistantPreflightGate()
        let reader = RepositoryToolReader(tree: { _, _ in try await gate.read() }, text: { _, _ in ("", 0) },
                                          checkAccess: { try client.validateSession() })
        let store = AssistantStore(launchArguments: ["--uitest-chat", "success"], repositoryReader: { _ in reader })
        store.selectRepository(repository, commit: commit, client: client, workspace: repository.full_name)
        let originalCount = store.saved.chats.count
        XCTAssertTrue(store.ask("Inspect private source"))
        await gate.waitUntilStarted()
        session.revoke()
        await gate.release()
        try await waitForIdle(store)
        XCTAssertEqual(store.connectionState, .authenticationRequired)
        XCTAssertTrue(store.answer.isEmpty)
        XCTAssertEqual(store.saved.chats.count, originalCount)
        XCTAssertTrue(store.responseSources.isEmpty)
        XCTAssertThrowsError(try store.acceptAnswer("Late private reply", question: "Inspect", project: store.project,
                                                   repository: store.selectedRepository))
        store.cancel()
        XCTAssertEqual(store.connectionState, .authenticationRequired, "Reset/path hints must not call an expired session ready")
    }

    func testGeneralDoesNotInventOfflineAndKeepsExistingBackupSchema() async throws {
        let store = AssistantStore(launchArguments: ["--uitest-chat", "success"])
        XCTAssertEqual(store.connectionState, .setupRequired)
        XCTAssertTrue(store.ask("How do I connect GitHub?"))
        try await waitForIdle(store)
        XCTAssertNil(store.error)
        let reply = try XCTUnwrap(store.saved.chats.last)
        XCTAssertEqual(store.responseSources[reply.id], "Apple on device · No live source used")
        let data = try store.backupData()
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let chats = try XCTUnwrap(object["chats"] as? [[String: Any]])
        XCTAssertEqual(Set(try XCTUnwrap(chats.last).keys), ["id", "project", "role", "text", "date"])
    }

    func testRealQuestionFallsBackAfterTransportFailureAndNextQuestionRecovers() async throws {
        let reads = RecoveringAssistantReader()
        let store = AssistantStore(launchArguments: ["--uitest-chat", "success"], repositoryReader: { _ in reads.reader })
        store.selectRepository(repository, commit: commit, client: GitHubClient(), workspace: repository.full_name)
        XCTAssertTrue(store.ask("Inspect this project"))
        try await waitForIdle(store)
        XCTAssertNil(store.error)
        XCTAssertEqual(store.connectionState, .offline)
        let first = try XCTUnwrap(store.saved.chats.last)
        XCTAssertEqual(store.responseSources[first.id], "Apple on device · Saved context; connection unavailable")
        XCTAssertTrue(store.ask("Inspect it again"))
        try await waitForIdle(store)
        XCTAssertNil(store.error)
        XCTAssertEqual(store.connectionState, .online)
        let second = try XCTUnwrap(store.saved.chats.last)
        XCTAssertEqual(store.responseSources[second.id], "Apple on device · Live GitHub reference")
        let calls = await reads.calls
        XCTAssertEqual(calls, 2, "One live attempt per question, no automatic transport retry")
    }

    func testProviderRejectionStopsBeforeInferenceWithoutOfflineAnswer() async throws {
        let reader = RepositoryToolReader(tree: { _, _ in throw GitHubAccessError.rateLimited }, text: { _, _ in ("", 0) })
        let store = AssistantStore(launchArguments: ["--uitest-chat", "success"], repositoryReader: { _ in reader })
        store.selectRepository(repository, commit: commit, client: GitHubClient(), workspace: repository.full_name)
        let originalCount = store.saved.chats.count
        XCTAssertTrue(store.ask("Inspect this project"))
        try await waitForIdle(store)
        XCTAssertEqual(store.connectionState, .rateLimited)
        XCTAssertNotNil(store.error)
        XCTAssertTrue(store.answer.isEmpty)
        XCTAssertEqual(store.saved.chats.count, originalCount)
    }

    func testCancelledPreflightCannotPublishIntoChangedWorkspace() async throws {
        let gate = AssistantPreflightGate()
        let reader = RepositoryToolReader(tree: { _, _ in try await gate.read() }, text: { _, _ in ("", 0) })
        let store = AssistantStore(launchArguments: ["--uitest-chat", "success"], repositoryReader: { _ in reader })
        store.selectRepository(repository, commit: commit, client: GitHubClient(), workspace: repository.full_name)
        let originalCount = store.saved.chats.count
        XCTAssertTrue(store.ask("Inspect this project"))
        await gate.waitUntilStarted()
        store.cancel()
        store.switchProject("General")
        await gate.release()
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(store.connectionState, .setupRequired)
        XCTAssertFalse(store.busy)
        XCTAssertTrue(store.answer.isEmpty)
        XCTAssertEqual(store.saved.chats.count, originalCount)
    }

    private func waitForIdle(_ store: AssistantStore) async throws {
        let deadline = Date().addingTimeInterval(5)
        while store.busy && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertFalse(store.busy, "Question did not finish within the test deadline")
    }
}

private actor RecoveringAssistantReader {
    var calls = 0
    private let initialFailure: GitHubAccessError
    init(initialFailure: GitHubAccessError = .unavailable) { self.initialFailure = initialFailure }
    nonisolated var reader: RepositoryToolReader {
        RepositoryToolReader(tree: { _, _ in try await self.read() }, text: { _, _ in ("", 0) })
    }
    func read() throws -> (files: [RepoFile], responseBytes: Int) {
        calls += 1
        if calls == 1 { throw initialFailure }
        return ([], 29)
    }
}

private actor AssistantPreflightGate {
    private var pending: CheckedContinuation<(files: [RepoFile], responseBytes: Int), Error>?
    func read() async throws -> (files: [RepoFile], responseBytes: Int) {
        try await withCheckedThrowingContinuation { pending = $0 }
    }
    func waitUntilStarted() async {
        let deadline = Date().addingTimeInterval(3)
        while pending == nil && Date() < deadline { try? await Task.sleep(nanoseconds: 1_000_000) }
        XCTAssertNotNil(pending, "Preflight did not reach the injected transport")
    }
    func release() { pending?.resume(returning: ([], 29)); pending = nil }
}
