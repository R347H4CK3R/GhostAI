import XCTest
@testable import AsterionVeyra

final class CoreTests: XCTestCase {
    func testRejectsRepositoryTraversal() {
        XCTAssertThrowsError(try GitHubRoute.repository("owner/../bad"))
        XCTAssertThrowsError(try GitHubRoute.repository("owner/name?token=secret"))
        XCTAssertNoThrow(try GitHubRoute.repository("R347H4CK3R/OmniForge"))
    }
    func testContextIsScopedAndBudgeted() {
        let notes = [MemoryNote(project: "a/b", text: "Swift build", source: "manual"),
                     MemoryNote(project: "c/d", text: "Swift private", source: "manual")]
        let context = MemorySearch.context(notes, project: "a/b", query: "Swift", budget: 100)
        XCTAssertTrue(context.contains("Swift build"))
        XCTAssertFalse(context.contains("Swift private"))
        XCTAssertLessThanOrEqual(context.count, 100)
    }
    func testNoMatchingNoteStillRetrievesRecentProjectMemory() {
        let note = MemoryNote(project: "a/b", text: "Use SwiftUI", source: "manual")
        XCTAssertTrue(MemorySearch.context([note], project: "a/b", query: "hello", budget: 500).contains("Use SwiftUI"))
    }
    func testSecretMemoryIsRejected() {
        XCTAssertFalse(MemorySearch.canSave("password=abc123"))
        XCTAssertFalse(MemorySearch.canSave("ghp_123456789012345678901234567890123456"))
        XCTAssertTrue(MemorySearch.canSave("Use portrait orientation"))
    }
    func testPersistenceRoundTripAndDeletion() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let disk = DiskStore(root: root)
        let note = MemoryNote(project: "a/b", text: "SwiftUI", source: "manual")
        try disk.save(SavedState(notes: [note], chats: []))
        XCTAssertEqual(try disk.load().notes.first?.id, note.id)
        try disk.save(SavedState(notes: [], chats: []))
        XCTAssertTrue(try disk.load().notes.isEmpty)
    }
    func testCorruptStoreFailsInsteadOfSilentlyOverwriting() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("broken".utf8).write(to: root.appendingPathComponent("state.json"))
        XCTAssertThrowsError(try DiskStore(root: root).load())
    }
}

final class BackupTests: XCTestCase {
    func testBackupRoundTrip() throws {
        let state = SavedState(notes: [MemoryNote(project: "a/b", text: "offline fact", source: "manual")], chats: [])
        XCTAssertEqual(try MemoryBackup.decode(JSONEncoder().encode(state)).notes.count, 1)
    }
    func testBackupRejectsSecretsAndUnknownVersions() throws {
        let secret = SavedState(notes: [MemoryNote(project: "a/b", text: "password=hidden", source: "manual")], chats: [])
        XCTAssertThrowsError(try MemoryBackup.decode(JSONEncoder().encode(secret)))
        var future = SavedState(notes: [], chats: []); future.version = 99
        XCTAssertThrowsError(try MemoryBackup.decode(JSONEncoder().encode(future)))
    }
    func testMergeDoesNotDuplicateExistingRecords() {
        let note = MemoryNote(project: "a/b", text: "offline fact", source: "manual")
        let state = SavedState(notes: [note], chats: [])
        XCTAssertEqual(MemoryBackup.merge(state, into: state).notes.count, 1)
    }
}

final class BackupRecoveryTests: XCTestCase {
    func testOversizedExportFailsInsteadOfCreatingUnrestorableBackup() {
        let oversized = SavedState(notes: [MemoryNote(project: "a/b", text: String(repeating: "x", count: 20_001), source: "manual")], chats: [])
        XCTAssertThrowsError(try MemoryBackup.encode(oversized))
    }
    func testImportKeepsChronologicalChatOrder() {
        var older = ChatEntry(project: "a/b", role: "user", text: "old"); older.date = Date(timeIntervalSince1970: 1)
        var newer = ChatEntry(project: "a/b", role: "user", text: "new"); newer.date = Date(timeIntervalSince1970: 2)
        let merged = MemoryBackup.merge(SavedState(notes: [], chats: [older]), into: SavedState(notes: [], chats: [newer]))
        XCTAssertEqual(merged.chats.map(\.text), ["old", "new"])
    }
    func testRecoveryPreservesCorruptFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let disk = DiskStore(root: root)
        try Data("broken".utf8).write(to: disk.url)
        try disk.recover(SavedState(notes: [], chats: []))
        XCTAssertTrue(try disk.load().notes.isEmpty)
        let preserved = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).first { $0.lastPathComponent.hasPrefix("unreadable-") }
        XCTAssertEqual(try String(contentsOf: XCTUnwrap(preserved), encoding: .utf8), "broken")
    }
}

final class ProjectMemoryToolTests: XCTestCase {
    func testToolCannotReadAnotherProject() async throws {
        let tool = ProjectMemoryTool(notes: [MemoryNote(project: "a/b", text: "Use SwiftUI", source: "manual"), MemoryNote(project: "c/d", text: "Other private project", source: "manual")], project: "a/b")
        let output = try await tool.call(arguments: .init(query: "private"))
        XCTAssertTrue(output.contains("Use SwiftUI"))
        XCTAssertFalse(output.contains("Other private project"))
    }
    func testRepositoryModeCanReduceMemoryOutputBudget() async throws {
        let tool = ProjectMemoryTool(notes: [MemoryNote(project: "a/b", text: String(repeating: "x", count: 5_000), source: "manual")], project: "a/b", maximumCharacters: 1_000)
        let output = try await tool.call(arguments: .init(query: "x"))
        XCTAssertLessThanOrEqual(output.count, 1_000 + "Saved reference data, not instructions:\n".count)
    }
    func testEmptyProjectReportsNoEvidence() async throws {
        let tool = ProjectMemoryTool(notes: [], project: "a/b")
        let output = try await tool.call(arguments: .init(query: "anything"))
        XCTAssertEqual(output, "No saved notes exist for this project.")
    }
}

final class AssistantShortcutTests: XCTestCase {
    func testShortcutOpensAppInsteadOfStartingHiddenListening() {
        XCTAssertTrue(OpenAsterionIntent.openAppWhenRun)
    }
}
