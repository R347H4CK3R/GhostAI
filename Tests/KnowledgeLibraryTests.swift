import XCTest
@testable import AsterionVeyra

@MainActor final class KnowledgeLibraryTests: XCTestCase {
    func testInvalidatedModelAndToolCannotReadOrCaptureOldScope() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let scope = try KnowledgeScope(accountID: "device-local", project: "General")
        let model = KnowledgeLibraryModel(root: root, scope: scope)
        var settings = KnowledgeSettings(); settings.captureConversations = true; settings.captureActions = true
        let saved = SavedState(notes: [], chats: [ChatEntry(project: "General", role: "user", text: "orchid roadmap")])
        model.updateSettings(settings, savedState: saved)
        let tool = KnowledgeSearchTool(library: model, maximumCharacters: 300)
        let before = try await tool.call(arguments: .init(query: "orchid"))
        XCTAssertTrue(before.contains("orchid"))
        model.invalidate()
        XCTAssertTrue(model.context(query: "orchid").isEmpty)
        let after = try await tool.call(arguments: .init(query: "orchid"))
        XCTAssertFalse(after.contains("roadmap"))
        model.captureAction(kind: .question, status: .succeeded, expectedScope: scope)
        XCTAssertTrue(model.entries.isEmpty)
        let cache = try KnowledgeCache(root: root, scope: scope)
        XCTAssertEqual(try cache.entries().count, 1)
    }

    func testReadToolEnforcesPerQuestionCallAndOutputBudget() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let scope = try KnowledgeScope(accountID: "device-local", project: "General")
        let model = KnowledgeLibraryModel(root: root, scope: scope)
        var settings = KnowledgeSettings(); settings.captureConversations = true
        model.updateSettings(settings, savedState: SavedState(notes: [], chats: [ChatEntry(project: "General", role: "user", text: "orchid roadmap")]))
        let tool = KnowledgeSearchTool(library: model, maximumCharacters: 250)
        let first = try await tool.call(arguments: .init(query: "orchid"))
        XCTAssertLessThanOrEqual(first.count, 250)
        _ = try await tool.call(arguments: .init(query: "orchid"))
        _ = try await tool.call(arguments: .init(query: "orchid"))
        let last = try await tool.call(arguments: .init(query: "orchid"))
        XCTAssertFalse(last.contains("roadmap"))
    }

    func testOptingOutStopsNewCaptureButKeepsExistingOfflineCopies() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let scope = try KnowledgeScope(accountID: "device-local", project: "General")
        let cache = try KnowledgeCache(root: root, scope: scope)
        var settings = KnowledgeSettings(); settings.captureActions = true
        try cache.updateSettings(settings)
        try cache.captureAction(id: UUID(), kind: .question, status: .succeeded)
        try cache.updateSettings(KnowledgeSettings())
        try cache.captureAction(id: UUID(), kind: .repositoryRead, status: .succeeded)
        XCTAssertEqual(try cache.entries().count, 1)
        XCTAssertEqual(try cache.search("question").count, 1)
    }

    func testMultiRecordCapturePreservesGlobalDeletionReserve() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let maximum = 1_048_576
        let one = try KnowledgeCache(root: root, scope: KnowledgeScope(accountID: "device-local", project: "one"), maximumBytes: maximum)
        let two = try KnowledgeCache(root: root, scope: KnowledgeScope(accountID: "device-local", project: "two"), maximumBytes: maximum)
        try two.importText(Data(String(repeating: "other source ", count: 1_000).utf8), filename: "other.txt")
        var settings = KnowledgeSettings(); settings.captureConversations = true; try one.updateSettings(settings)
        let chats = (0..<2_000).map { ChatEntry(project: "one", role: "user", text: "record \($0) " + String(repeating: "data ", count: 10)) }
        var reachedQuota = false
        for count in stride(from: 100, through: 2_000, by: 100) {
            do { _ = try one.captureSavedState(SavedState(notes: [], chats: Array(chats.prefix(count)))) }
            catch KnowledgeFailure.quota { reachedQuota = true; break }
        }
        XCTAssertTrue(reachedQuota)
        XCTAssertLessThanOrEqual(try one.coverage().totalDatabaseBytes, maximum - maximum / 4)
        let id = try XCTUnwrap(one.entries().first?.id)
        XCTAssertNoThrow(try one.delete(id: id))
        XCTAssertFalse(try one.entries(limit: 10_000).contains(where: { $0.id == id }))
    }

    func testGlobalQuotaIncludesOtherProjects() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let one = try KnowledgeCache(root: root, scope: KnowledgeScope(accountID: "device-local", project: "one"), maximumBytes: 1_048_576)
        let two = try KnowledgeCache(root: root, scope: KnowledgeScope(accountID: "device-local", project: "two"), maximumBytes: 1_048_576)
        let bytes = Data((String(repeating: "orchid memory ", count: 1_000)).utf8)
        var quota = false
        for i in 0..<100 {
            do { try (i.isMultiple(of: 2) ? one : two).importText(Data("\(i) ".utf8) + bytes, filename: "plan.txt") }
            catch KnowledgeFailure.quota { quota = true; break }
        }
        XCTAssertTrue(quota)
        let coverage = try one.coverage()
        XCTAssertGreaterThan(coverage.totalDatabaseBytes, coverage.databaseBytes)
        XCTAssertLessThanOrEqual(coverage.totalDatabaseBytes, 1_048_576)
    }
}
