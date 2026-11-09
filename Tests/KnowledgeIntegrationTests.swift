import XCTest
@testable import AsterionVeyra

final class KnowledgeWorkspacePolicyTests: XCTestCase {
    func testStablePrivateWorkspaceReopensSameScopeWithoutLiveRepository() throws {
        let workspace = "GitHub account 123: owner/private"
        let live = try KnowledgeWorkspacePolicy.scope(workspace: workspace, liveRepository: "owner/private")
        let offline = try KnowledgeWorkspacePolicy.scope(workspace: workspace)
        XCTAssertEqual(live.accountID, "github-user-123")
        XCTAssertEqual(live.project, workspace)
        XCTAssertEqual(live.storageKey, offline.storageKey)
        XCTAssertNil(offline.repository)
        XCTAssertNotEqual(offline.storageKey, try KnowledgeWorkspacePolicy.scope(workspace: "GitHub account 456: owner/private").storageKey)
        XCTAssertNotEqual(offline.storageKey, try KnowledgeWorkspacePolicy.scope(workspace: "owner/private").storageKey)
    }
    func testMalformedReservedNamesAndRepositoryMismatchAreRejected() {
        for value in ["GitHub account 0: owner/repo", "GitHub account 01: owner/repo", "GitHub account abc: owner/repo", "GitHub account 1: owner/repo/other", "GitHub account 1:owner/repo"] {
            XCTAssertThrowsError(try KnowledgeWorkspacePolicy.scope(workspace: value))
        }
        XCTAssertThrowsError(try KnowledgeWorkspacePolicy.scope(workspace: "GitHub account 1: owner/repo", liveRepository: "other/repo"))
        XCTAssertThrowsError(try KnowledgeWorkspacePolicy.scope(workspace: "General", liveRepository: "owner/repo"))
    }
    func testKnowledgeToolKeepsInitialAndToolContextBudgetsSmall() {
        let budget = KnowledgePromptBudget(hasRepository: false, hasKnowledge: true)
        XCTAssertEqual(budget.initialCharacters, 1_000)
        XCTAssertEqual(budget.knowledgeCharactersPerCall, 500)
        XCTAssertEqual(budget.recentMessages, 2)
        XCTAssertEqual(budget.recentMessageCharacters, 300)
        XCTAssertEqual(KnowledgePromptBudget(hasRepository: false, hasKnowledge: false).initialCharacters, 3_000)
        XCTAssertEqual(KnowledgePromptBudget(hasRepository: true, hasKnowledge: false).initialCharacters, 1_000)
    }
}

@MainActor final class KnowledgeStoreIntegrationTests: XCTestCase {
    private func root() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }
    private func store(_ root: URL) -> AssistantStore { AssistantStore(root: root, launchArguments: []) }
    private func enableConversationCapture(_ store: AssistantStore) throws -> KnowledgeLibraryModel {
        let library = try XCTUnwrap(store.knowledge)
        var settings = library.settings; settings.captureConversations = true; settings.captureActions = false
        library.updateSettings(settings, savedState: store.saved)
        return library
    }
    func testSuccessfulPersistenceAndCanonicalDeletionUpdateOfflineCache() throws {
        let directory = root(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = store(directory); let library = try enableConversationCapture(store)
        try store.acceptAnswer("orchid answer", question: "orchid question", project: store.project, repository: nil)
        XCTAssertEqual(library.coverage?.counts[.conversation], 2)
        XCTAssertFalse(library.context(query: "orchid").isEmpty)
        store.clearProjectChat()
        XCTAssertTrue(store.saved.chats.isEmpty)
        XCTAssertTrue(library.context(query: "orchid").isEmpty)
        XCTAssertEqual(library.coverage?.entries, 0)
    }
    func testProjectChangeInvalidatesOldModelAndOfflinePrivateReopenFindsResearch() throws {
        let directory = root(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = store(directory)
        let workspace = "GitHub account 123: owner/private"
        let repository = Repository(id: 7, full_name: "owner/private", default_branch: "main")
        store.selectRepository(repository, commit: String(repeating: "a", count: 40), client: GitHubClient(), workspace: workspace)
        let old = try XCTUnwrap(store.knowledge)
        var settings = old.settings; settings.captureResearch = true
        old.updateSettings(settings, savedState: store.saved)
        store.captureRepositoryRead("orchid source", repository: repository.full_name, path: "README.md", commit: String(repeating: "a", count: 40), workspace: workspace, client: GitHubClient())
        XCTAssertFalse(old.context(query: "orchid").isEmpty)
        store.switchProject("General")
        XCTAssertTrue(old.unavailable)
        XCTAssertTrue(old.context(query: "orchid").isEmpty)
        store.switchProject(workspace)
        XCTAssertNil(store.selectedRepository)
        XCTAssertNil(store.knowledge?.scope.repository)
        XCTAssertFalse(try XCTUnwrap(store.knowledge).context(query: "orchid").isEmpty)
    }
    func testBrowserCaptureUsesOwnWorkspaceAndCannotRerouteAssistant() throws {
        let directory = root(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = store(directory)
        let workspace = "owner/repo"
        store.selectRepository(Repository(id: 1, full_name: workspace, default_branch: "main"), commit: String(repeating: "a", count: 40), client: GitHubClient(), workspace: workspace)
        let selected = try XCTUnwrap(store.knowledge)
        var settings = selected.settings; settings.captureResearch = true; settings.captureActions = true
        selected.updateSettings(settings, savedState: store.saved)
        store.switchProject("General")
        let active = store.knowledge
        store.captureRepositoryRead("browser orchid", repository: workspace, path: "README.md", commit: String(repeating: "a", count: 40), workspace: workspace, client: GitHubClient())
        XCTAssertEqual(store.project, "General")
        XCTAssertTrue(store.knowledge === active)
        XCTAssertTrue(try XCTUnwrap(active).context(query: "orchid").isEmpty)
        store.switchProject(workspace)
        XCTAssertFalse(try XCTUnwrap(store.knowledge).context(query: "orchid").isEmpty)
        XCTAssertEqual(store.knowledge?.coverage?.counts[.action], 1)
    }
    func testRevokedBrowserSessionCannotCachePrivateSourceOrReadAction() throws {
        let directory = root(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = store(directory)
        let workspace = "GitHub account 123: owner/private"
        let session = try GitHubAuthSession(token: "github_pat_SYNTHETIC_TEST_ONLY_123")
        let client = GitHubClient(authentication: session)
        store.selectRepository(Repository(id: 7, full_name: "owner/private", default_branch: "main"), commit: String(repeating: "a", count: 40), client: client, workspace: workspace)
        let library = try XCTUnwrap(store.knowledge)
        var settings = library.settings; settings.captureResearch = true; settings.captureActions = true
        library.updateSettings(settings, savedState: store.saved)
        store.switchProject("General")
        session.revoke()
        store.captureRepositoryRead("private orchid", repository: "owner/private", path: "README.md", commit: String(repeating: "a", count: 40), workspace: workspace, client: client)
        store.switchProject(workspace)
        XCTAssertEqual(store.knowledge?.coverage?.entries, 0)
        XCTAssertTrue(try XCTUnwrap(store.knowledge).context(query: "orchid").isEmpty)
    }
    func testFailedCanonicalWriteCannotPublishOrCaptureAnAnswer() throws {
        let directory = root(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = store(directory); let library = try enableConversationCapture(store)
        // A directory at the state file's destination makes the atomic canonical write fail.
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("state.json"), withIntermediateDirectories: true)
        XCTAssertThrowsError(try store.acceptAnswer("orchid answer", question: "orchid question", project: store.project, repository: nil))
        XCTAssertTrue(store.saved.chats.isEmpty)
        XCTAssertEqual(library.coverage?.entries, 0)
        XCTAssertTrue(store.answer.isEmpty)
    }
    func testCanonicalLoadFailureDoesNotOpenOrReconcileCache() throws {
        let directory = root(); defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("broken canonical data".utf8).write(to: directory.appendingPathComponent("state.json"))
        let store = store(directory)
        XCTAssertTrue(store.loadFailed)
        XCTAssertNil(store.knowledge)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("Knowledge").path))
    }
    func testRecoveryCreatesCacheOnlyAfterSuccessfulCanonicalRecovery() throws {
        let directory = root(); defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("broken canonical data".utf8).write(to: directory.appendingPathComponent("state.json"))
        let store = store(directory)
        let backup = SavedState(notes: [], chats: [ChatEntry(project: "General", role: "user", text: "restored orchid")])
        store.importBackup(try MemoryBackup.encode(backup))
        XCTAssertFalse(store.loadFailed)
        XCTAssertNotNil(store.knowledge)
        let library = try enableConversationCapture(store)
        XCTAssertFalse(library.context(query: "orchid").isEmpty)
    }
    func testSameNameWorkspaceChangeRejectsStaleImportEpoch() throws {
        let directory = root(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = store(directory)
        let reviewedEpoch = store.workspaceEpoch
        let additions = SavedState(notes: [], chats: [ChatEntry(project: "General", role: "user", text: "stale reviewed chat")])
        store.cancel()
        XCTAssertEqual(store.workspaceEpoch, reviewedEpoch)
        store.switchProject("General")
        XCTAssertNotEqual(store.workspaceEpoch, reviewedEpoch)
        XCTAssertThrowsError(try store.importConversationAdditions(additions, expectedProject: "General", expectedWorkspaceEpoch: reviewedEpoch))
        XCTAssertTrue(store.saved.chats.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("state.json").path))
    }
    func testCredentialSessionEndInvalidatesPriorLibraryAndTool() async throws {
        let directory = root(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = store(directory)
        let credentials = GitHubCredentialStore(onSessionEnded: { store.switchProject("General") })
        let session = try credentials.begin(token: "github_pat_SYNTHETIC_TEST_ONLY_123", directInstallationConfirmed: true)
        let workspace = "GitHub account 123: owner/private"
        store.selectRepository(Repository(id: 7, full_name: "owner/private", default_branch: "main"), commit: String(repeating: "a", count: 40), client: GitHubClient(authentication: session), workspace: workspace)
        let library = try enableConversationCapture(store)
        try store.acceptAnswer("private orchid", question: "orchid question", project: workspace, repository: store.selectedRepository)
        let tool = KnowledgeSearchTool(library: library, maximumCharacters: 500)
        let before = try await tool.call(arguments: .init(query: "orchid"))
        XCTAssertTrue(before.contains("orchid"))
        let oldEpoch = store.workspaceEpoch
        credentials.endSession()
        XCTAssertTrue(library.unavailable)
        XCTAssertNotEqual(store.workspaceEpoch, oldEpoch)
        XCTAssertEqual(store.project, "General")
        let after = try await tool.call(arguments: .init(query: "orchid"))
        XCTAssertFalse(after.contains("private orchid"))
    }
    func testFiveHundredCharacterRecallIncludesTextWithLongProvenance() throws {
        let directory = root(); defer { try? FileManager.default.removeItem(at: directory) }
        let scope = try KnowledgeScope(accountID: "device-local", project: "owner/repo", repository: "owner/repo")
        let cache = try KnowledgeCache(root: directory, scope: scope)
        var settings = KnowledgeSettings(); settings.captureResearch = true; try cache.updateSettings(settings)
        let path = String(repeating: "a", count: 200) + "/" + String(repeating: "b", count: 200) + ".swift"
        let source = try KnowledgeSource.repository("owner/repo", path: path, commit: String(repeating: "c", count: 40))
        try cache.captureResearch(text: "orchid source evidence", source: source)
        let context = try cache.context(query: "orchid", maximumCharacters: 500)
        XCTAssertTrue(context.contains("orchid source evidence"))
        XCTAssertTrue(context.contains(String(repeating: "c", count: 40)))
        XCTAssertLessThanOrEqual(context.count, 500)
        XCTAssertEqual(try cache.entries().first?.source.label, source.label)
    }
    func testConversationImportRejectsWrongScopeWithoutMutation() throws {
        let directory = root(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = store(directory)
        let foreign = SavedState(notes: [], chats: [ChatEntry(project: "other", role: "user", text: "foreign")])
        XCTAssertThrowsError(try store.importConversationAdditions(foreign, expectedProject: "General", expectedWorkspaceEpoch: store.workspaceEpoch))
        let valid = SavedState(notes: [], chats: [ChatEntry(project: "General", role: "user", text: "valid")])
        XCTAssertThrowsError(try store.importConversationAdditions(valid, expectedProject: "other", expectedWorkspaceEpoch: store.workspaceEpoch))
        XCTAssertTrue(store.saved.chats.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("state.json").path))
    }
    func testConversationImportRejectsOversizedAdditionsWithoutMutation() throws {
        let directory = root(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = store(directory)
        let oversized = SavedState(notes: [], chats: [ChatEntry(project: "General", role: "user", text: String(repeating: "x", count: 100_001))])
        XCTAssertThrowsError(try store.importConversationAdditions(oversized, expectedProject: "General", expectedWorkspaceEpoch: store.workspaceEpoch))
        XCTAssertTrue(store.saved.chats.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("state.json").path))
    }
    func testConversationImportRejectsUnexportableMergedCurrentStateWithoutMutation() throws {
        let directory = root(); defer { try? FileManager.default.removeItem(at: directory) }
        let invalidCurrent = SavedState(notes: [MemoryNote(project: "General", text: String(repeating: "x", count: 20_001), source: "legacy")], chats: [])
        let disk = DiskStore(root: directory); try disk.save(invalidCurrent)
        let bytes = try Data(contentsOf: disk.url)
        let store = store(directory)
        let valid = SavedState(notes: [], chats: [ChatEntry(project: "General", role: "user", text: "new chat")])
        XCTAssertThrowsError(try store.importConversationAdditions(valid, expectedProject: "General", expectedWorkspaceEpoch: store.workspaceEpoch))
        XCTAssertEqual(try Data(contentsOf: disk.url), bytes)
        XCTAssertTrue(store.saved.chats.isEmpty)
        XCTAssertEqual(store.saved.notes.first?.text, invalidCurrent.notes.first?.text)
    }
    func testConversationImportPreservesExistingIDsAndIndexesOnlyPersistedAdditions() throws {
        let directory = root(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = store(directory); let library = try enableConversationCapture(store)
        let original = ChatEntry(project: "General", role: "user", text: "original orchid")
        try store.importConversationAdditions(SavedState(notes: [], chats: [original]), expectedProject: "General", expectedWorkspaceEpoch: store.workspaceEpoch)
        var replacement = original; replacement.text = "replacement that must not win"
        let added = ChatEntry(project: "General", role: "assistant", text: "new orchard")
        try store.importConversationAdditions(SavedState(notes: [], chats: [replacement, added]), expectedProject: "General", expectedWorkspaceEpoch: store.workspaceEpoch)
        XCTAssertEqual(store.saved.chats.count, 2)
        XCTAssertEqual(store.saved.chats.first(where: { $0.id == original.id })?.text, original.text)
        XCTAssertFalse(library.context(query: "orchid").isEmpty)
        XCTAssertFalse(library.context(query: "orchard").isEmpty)
        XCTAssertTrue(library.context(query: "replacement").isEmpty)
    }
    func testConversationImportCannotReplaceUnreadableCanonicalState() throws {
        let directory = root(); defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("state.json"); let bytes = Data("broken canonical state".utf8)
        try bytes.write(to: path)
        let store = store(directory)
        let additions = SavedState(notes: [], chats: [ChatEntry(project: "General", role: "user", text: "new chat")])
        XCTAssertThrowsError(try store.importConversationAdditions(additions, expectedProject: "General", expectedWorkspaceEpoch: store.workspaceEpoch))
        XCTAssertEqual(try Data(contentsOf: path), bytes)
        XCTAssertTrue(store.loadFailed)
    }
    #if DEBUG
    func testSyntheticChatFixtureNeverTouchesCanonicalOrKnowledgeDisk() throws {
        let directory = root(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = AssistantStore(root: directory, launchArguments: ["--uitest-chat", "success"])
        XCTAssertNil(store.knowledge)
        store.switchProject("owner/repo")
        store.remember("synthetic note")
        try store.acceptAnswer("synthetic reply", question: "synthetic question", project: store.project, repository: nil)
        store.captureRepositoryRead("synthetic source", repository: "owner/repo", path: "README.md", commit: String(repeating: "a", count: 40), workspace: "owner/repo", client: GitHubClient())
        XCTAssertNil(store.knowledge)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }
    #endif
}
