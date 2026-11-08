import XCTest
@testable import AsterionVeyra

@MainActor final class KnowledgeCacheTests: XCTestCase {
    private func location() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }
    private func scope(_ project: String = "owner/project", account: String = "github-user-123") throws -> KnowledgeScope {
        try KnowledgeScope(accountID: account, project: project, repository: project)
    }
    private func enabled() -> KnowledgeSettings {
        var settings = KnowledgeSettings()
        settings.captureConversations = true; settings.captureActions = true; settings.captureResearch = true
        return settings
    }

    func testAutomaticCaptureIsDefaultAndNeverCopiesCanonicalNotes() throws {
        let root = location(); defer { try? FileManager.default.removeItem(at: root) }
        let cache = try KnowledgeCache(root: root, scope: scope())
        let saved = SavedState(notes: [MemoryNote(project: "owner/project", text: "note", source: "manual")],
                               chats: [ChatEntry(project: "owner/project", role: "user", text: "Orchid offline plan")])
        XCTAssertEqual(try cache.captureSavedState(saved).stored, 1)
        try cache.updateSettings(enabled())
        XCTAssertEqual(try cache.captureSavedState(saved).stored, 0)
        XCTAssertEqual(try cache.entries().count, 1)
        XCTAssertEqual(try cache.search("orchid").first?.entry.text, "Orchid offline plan")
    }

    func testReopenRetainsSearchAndAccountProjectIsolation() throws {
        let root = location(); defer { try? FileManager.default.removeItem(at: root) }
        do {
            let cache = try KnowledgeCache(root: root, scope: scope())
            try cache.importText(Data("Durable orchid knowledge".utf8), filename: "plan.txt")
        }
        XCTAssertEqual(try KnowledgeCache(root: root, scope: scope()).search("orchid").count, 1)
        XCTAssertTrue(try KnowledgeCache(root: root, scope: scope("other/project")).entries().isEmpty)
        XCTAssertTrue(try KnowledgeCache(root: root, scope: scope(account: "github-user-456")).entries().isEmpty)
    }

    func testDeletionAndClearCannotBeUndoneBySnapshotReindexOrFileImport() throws {
        let root = location(); defer { try? FileManager.default.removeItem(at: root) }
        let cache = try KnowledgeCache(root: root, scope: scope()); try cache.updateSettings(enabled())
        let saved = SavedState(notes: [], chats: [ChatEntry(project: "owner/project", role: "user", text: "orchid")])
        _ = try cache.captureSavedState(saved)
        let id = try XCTUnwrap(cache.entries().first?.id)
        try cache.delete(id: id)
        XCTAssertEqual(try cache.captureSavedState(saved).suppressed, 1)
        let bytes = Data("File orchid".utf8)
        try cache.importText(bytes, filename: "plan.txt")
        try cache.clear()
        XCTAssertEqual(try cache.captureSavedState(saved).stored, 0)
        XCTAssertThrowsError(try cache.importText(bytes, filename: "renamed.txt"))
        XCTAssertTrue(try cache.entries().isEmpty)
    }

    func testCanonicalChatDeletionPrunesCacheAndSuppressesBackupReintroduction() throws {
        let root = location(); defer { try? FileManager.default.removeItem(at: root) }
        let cache = try KnowledgeCache(root: root, scope: scope()); try cache.updateSettings(enabled())
        let saved = SavedState(notes: [], chats: [ChatEntry(project: "owner/project", role: "user", text: "orchid")])
        _ = try cache.captureSavedState(saved)
        _ = try cache.captureSavedState(SavedState(notes: [], chats: []))
        XCTAssertTrue(try cache.search("orchid").isEmpty)
        XCTAssertEqual(try cache.captureSavedState(saved).suppressed, 1)
    }

    func testSecretCredentialsHeadersBinaryAndOversizeInputsAreRejected() throws {
        let root = location(); defer { try? FileManager.default.removeItem(at: root) }
        let cache = try KnowledgeCache(root: root, scope: scope())
        for text in ["password=hidden", "Authorization: Bearer abc", "Cookie: session=abc", "sk-proj-abcdefghijklmnop123456", "key\u{0}binary"] {
            XCTAssertThrowsError(try cache.importText(Data(text.utf8), filename: "notes.txt"))
        }
        XCTAssertThrowsError(try cache.importText(Data("ordinary text".utf8), filename: ".env.txt"))
        XCTAssertThrowsError(try cache.importText(Data(repeating: 65, count: KnowledgePolicy.maximumDocumentBytes + 1), filename: "large.txt"))
        XCTAssertTrue(try cache.entries().isEmpty)
    }

    func testUnsafeChatsAreSkippedWithVisibleCountsAndOtherProjectsAreExcluded() throws {
        let root = location(); defer { try? FileManager.default.removeItem(at: root) }
        let cache = try KnowledgeCache(root: root, scope: scope()); try cache.updateSettings(enabled())
        let report = try cache.captureSavedState(SavedState(notes: [], chats: [
            ChatEntry(project: "owner/project", role: "user", text: "api_key=hidden"),
            ChatEntry(project: "owner/project", role: "error", text: "raw error body"),
            ChatEntry(project: "private/project", role: "user", text: "private orchid")]))
        XCTAssertEqual(report.rejected, 2)
        XCTAssertTrue(try cache.entries().isEmpty)
    }

    func testSearchQuotesOperatorsAndUsesBoundedExcerpts() throws {
        let root = location(); defer { try? FileManager.default.removeItem(at: root) }
        let cache = try KnowledgeCache(root: root, scope: scope())
        try cache.importText(Data((String(repeating: "prefix ", count: 400) + "orchid offline suffix").utf8), filename: "plan.txt")
        XCTAssertEqual(try cache.search("orchid OR (*** \"").count, 1)
        let result = try XCTUnwrap(cache.search("orchid").first)
        XCTAssertTrue(result.excerpt.lowercased().contains("orchid"))
        XCTAssertLessThanOrEqual(result.excerpt.count, 600)
        XCTAssertTrue(try cache.search("unrelated").isEmpty)
        XCTAssertLessThanOrEqual(try cache.context(query: "orchid", maximumCharacters: 200).count, 200)
    }

    func testResearchProvenanceIsImmutableAndNeverClaimsLiveFreshness() throws {
        let root = location(); defer { try? FileManager.default.removeItem(at: root) }
        let cache = try KnowledgeCache(root: root, scope: scope()); try cache.updateSettings(enabled())
        let source = try KnowledgeSource.repository("owner/project", path: "README.md", commit: String(repeating: "a", count: 40))
        try cache.captureResearch(text: "Orchid compiler", source: source)
        let entry = try XCTUnwrap(cache.entries().first)
        XCTAssertTrue(entry.source.label.contains(String(repeating: "a", count: 40)))
        XCTAssertEqual(entry.offlineStatus, "Available offline · saved copy, not live")
        try cache.captureResearch(text: "Orchid compiler", source: source)
        XCTAssertEqual(try cache.entries().count, 1)
        try cache.captureResearch(text: "Changed text", source: source)
        XCTAssertEqual(try cache.entries().count, 2)
        let other = try KnowledgeSource.repository("private/other", path: "README.md", commit: String(repeating: "b", count: 40))
        XCTAssertThrowsError(try cache.captureResearch(text: "Private orchid", source: other))
        try cache.delete(id: entry.id)
        try cache.captureResearch(text: "Orchid compiler", source: source)
        XCTAssertFalse(try cache.entries().contains(where: { $0.id == entry.id }))
        XCTAssertThrowsError(try KnowledgeSource.web(URL(string: "https://example.com/?token=secret")!))
    }

    func testActionSchemaContainsOnlyClosedKindsAndStatuses() throws {
        let root = location(); defer { try? FileManager.default.removeItem(at: root) }
        let cache = try KnowledgeCache(root: root, scope: scope()); try cache.updateSettings(enabled())
        try cache.captureAction(id: UUID(), kind: .repositoryRead, status: .succeeded)
        XCTAssertEqual(try cache.entries().first?.text, "Repository read: succeeded")
    }

    func testRetentionRequiresExplicitDeletionAndPreservesSelectedFiles() throws {
        let root = location(); defer { try? FileManager.default.removeItem(at: root) }
        let cache = try KnowledgeCache(root: root, scope: scope())
        var settings = enabled(); settings.retention = .days30; try cache.updateSettings(settings)
        let old = Date(timeIntervalSinceNow: -40 * 86_400)
        try cache.captureAction(id: UUID(), kind: .question, status: .succeeded, date: old)
        try cache.importText(Data("Intentional memory".utf8), filename: "manual.txt", date: old)
        XCTAssertEqual(try cache.expiredAutomaticCount(), 1)
        XCTAssertEqual(try cache.entries().count, 2)
        try cache.deleteExpiredAutomaticEntries()
        XCTAssertEqual(try cache.entries().map(\.kind), [.selectedFile])
    }

    func testQuotaRejectsNewRecordsWithoutEvictingExistingKnowledge() throws {
        let root = location(); defer { try? FileManager.default.removeItem(at: root) }
        let cache = try KnowledgeCache(root: root, scope: scope(), maximumBytes: 1_048_576)
        try cache.importText(Data("Keep orchid".utf8), filename: "keep.txt")
        var rejected = false
        for index in 0..<100 {
            do { try cache.importText(Data(("\(index) " + String(repeating: "bounded knowledge ", count: 5_000)).utf8), filename: "plan.txt") }
            catch KnowledgeFailure.quota { rejected = true; break }
        }
        XCTAssertTrue(rejected)
        XCTAssertEqual(try cache.search("orchid").count, 1)
        let id = try XCTUnwrap(cache.search("orchid").first?.entry.id)
        XCTAssertNoThrow(try cache.delete(id: id))
        XCTAssertLessThanOrEqual(try cache.coverage().databaseBytes, 1_048_576)
    }

    func testCorruptionFailsClosedAndPreservesBytes() throws {
        let root = location(); defer { try? FileManager.default.removeItem(at: root) }
        var path: URL!
        do { path = try KnowledgeCache(root: root, scope: scope()).databaseURL }
        let bytes = Data("not a database".utf8); try bytes.write(to: path)
        XCTAssertThrowsError(try KnowledgeCache(root: root, scope: scope()))
        XCTAssertEqual(try Data(contentsOf: path), bytes)
    }
}

@MainActor final class KnowledgeDeletionRegressionTests: XCTestCase {
    func testOverTenThousandCanonicalChatsStillReconcileDeletions() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = try KnowledgeCache(root: root, scope: KnowledgeScope(accountID: "device-local", project: "General"), maximumBytes: 1_048_576)
        var settings = KnowledgeSettings(); settings.captureConversations = true; try cache.updateSettings(settings)
        let old = ChatEntry(project: "General", role: "user", text: "deleted orchid")
        _ = try cache.captureSavedState(SavedState(notes: [], chats: [old]))
        let large = (0..<10_001).map { ChatEntry(project: "General", role: "user", text: "new message \($0)") }
        XCTAssertThrowsError(try cache.captureSavedState(SavedState(notes: [], chats: large)))
        XCTAssertTrue(try cache.search("orchid").isEmpty)
    }
    func testNewCaptureQuotaFailureCannotRestoreDeletedCanonicalChats() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let scope = try KnowledgeScope(accountID: "device-local", project: "General")
        let cache = try KnowledgeCache(root: root, scope: scope, maximumBytes: 1_048_576)
        var settings = KnowledgeSettings(); settings.captureConversations = true
        try cache.updateSettings(settings)
        let old = ChatEntry(project: "General", role: "user", text: "deleted orchid")
        _ = try cache.captureSavedState(SavedState(notes: [], chats: [old]))
        let large = ChatEntry(project: "General", role: "user", text: String(repeating: "large source ", count: 10_000))
        XCTAssertThrowsError(try cache.captureSavedState(SavedState(notes: [], chats: [large])))
        XCTAssertTrue(try cache.search("orchid").isEmpty)
        XCTAssertEqual(try cache.captureSavedState(SavedState(notes: [], chats: [old])).suppressed, 1)
    }
}
