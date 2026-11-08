import XCTest
import Darwin
import SQLite3
@testable import AsterionVeyra

final class KnowledgeImportTests: XCTestCase {
    func testDescriptorReaderAcceptsOnlyBoundedRegularFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("plan.txt")
        try Data("offline orchid".utf8).write(to: file)
        XCTAssertEqual(try KnowledgeSelectedFileReader.read(file), Data("offline orchid".utf8))
        let link = root.appendingPathComponent("link.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        XCTAssertThrowsError(try KnowledgeSelectedFileReader.read(link))
        let fifo = root.appendingPathComponent("pipe.txt")
        XCTAssertEqual(mkfifo(fifo.path, mode_t(0o600)), 0)
        XCTAssertThrowsError(try KnowledgeSelectedFileReader.read(fifo))
        XCTAssertThrowsError(try KnowledgeSelectedFileReader.read(root))
        try Data(repeating: 65, count: KnowledgePolicy.maximumDocumentBytes + 1).write(to: file)
        XCTAssertThrowsError(try KnowledgeSelectedFileReader.read(file))
    }
}

@MainActor final class KnowledgeScopeRegressionTests: XCTestCase {
    func testOfflineReopenUsesSameDatabaseButCannotCaptureDifferentRepository() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let liveScope = try KnowledgeScope(accountID: "github-user-123", project: "workspace", repository: "owner/project")
        let source = try KnowledgeSource.repository("owner/project", path: "README.md", commit: String(repeating: "a", count: 40))
        do {
            let cache = try KnowledgeCache(root: root, scope: liveScope)
            var settings = KnowledgeSettings(); settings.captureResearch = true; try cache.updateSettings(settings)
            try cache.captureResearch(text: "orchid plan", source: source)
        }
        let offlineScope = try KnowledgeScope(accountID: "github-user-123", project: "workspace")
        XCTAssertEqual(liveScope.storageKey, offlineScope.storageKey)
        let offline = try KnowledgeCache(root: root, scope: offlineScope)
        XCTAssertEqual(try offline.search("orchid").count, 1)
        XCTAssertThrowsError(try offline.captureResearch(text: "new research", source: source))
        let changedScope = try KnowledgeScope(accountID: "github-user-123", project: "workspace", repository: "private/other")
        XCTAssertThrowsError(try KnowledgeCache(root: root, scope: changedScope))
    }
}


@MainActor final class KnowledgeIntegrityTests: XCTestCase {
    private func mutate(_ url: URL, sql: String) throws {
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &database), SQLITE_OK)
        defer { sqlite3_close(database) }
        XCTAssertEqual(sqlite3_exec(database, sql, nil, nil, nil), SQLITE_OK)
    }
    func testSearchNeverDisplaysPoisonedIndexText() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let scope = try KnowledgeScope(accountID: "device-local", project: "General")
        let cache = try KnowledgeCache(root: root, scope: scope)
        try cache.importText(Data("orchid safe source".utf8), filename: "plan.txt")
        try mutate(cache.databaseURL, sql: "UPDATE chunks SET text='orchid Authorization: Bearer leaked-secret'")
        let result = try XCTUnwrap(cache.search("orchid").first)
        XCTAssertEqual(result.excerpt, "orchid safe source")
        XCTAssertFalse(result.excerpt.contains("leaked"))
        XCTAssertTrue(try cache.search("leaked").isEmpty)
    }
    func testContextCorruptionClearsPreviouslyDisplayedEntries() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let scope = try KnowledgeScope(accountID: "device-local", project: "General")
        let model = KnowledgeLibraryModel(root: root, scope: scope)
        var settings = KnowledgeSettings(); settings.captureConversations = true
        model.updateSettings(settings, savedState: SavedState(notes: [], chats: [ChatEntry(project: "General", role: "user", text: "orchid plan")]))
        XCTAssertEqual(model.entries.count, 1)
        let url = root.appendingPathComponent(scope.storageKey).appendingPathComponent("knowledge.sqlite3")
        try mutate(url, sql: "UPDATE entries SET payload=x'7b'")
        XCTAssertTrue(model.context(query: "orchid").isEmpty)
        XCTAssertTrue(model.unavailable)
        XCTAssertTrue(model.entries.isEmpty)
    }
    func testNonfiniteClearCutoffFailsClosed() throws {
        for value in ["nan", "inf", "-1"] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let scope = try KnowledgeScope(accountID: "device-local", project: "General")
            let path: URL
            do { path = try KnowledgeCache(root: root, scope: scope).databaseURL }
            try mutate(path, sql: "UPDATE metadata SET value='\(value)' WHERE key='clear_before'")
            XCTAssertThrowsError(try KnowledgeCache(root: root, scope: scope))
        }
    }
}
