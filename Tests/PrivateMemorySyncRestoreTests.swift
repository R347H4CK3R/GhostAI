import XCTest
@testable import AsterionVeyra

final class PrivateMemorySyncRestoreTests: XCTestCase {
    private let note = MemoryNote(id: UUID(uuidString: "12345678-1234-4234-8234-123456789012")!, project: "General", text: "Explicitly selected restoration", source: "Synthetic backup")
    private var incoming: SavedState { SavedState(notes: [note], chats: []) }
    private var deleted: PrivateMemorySyncDocument {
        var value = PrivateMemorySyncDocument.empty(repositoryID: 123)
        value.tombstones = ["note:" + note.id.uuidString.lowercased()]
        return value
    }
    func testExplicitRestorationUsesStableNewIdentityAndKeepsOldTombstone() throws {
        let current = SavedState(notes: [], chats: [])
        let result = try PrivateMemorySyncRestore.prepare(incoming, current: current, history: deleted)
        XCTAssertNotEqual(result.notes.first?.id, note.id)
        XCTAssertEqual(result.notes.first?.text, note.text)
        let repeated = try PrivateMemorySyncRestore.prepare(incoming, current: result, history: deleted)
        XCTAssertEqual(result.notes.first?.id, repeated.notes.first?.id)
        XCTAssertEqual(MemoryBackup.merge(repeated, into: result).notes.count, 1)
        let captured = try PrivateMemorySyncMerge.capture(state: result, knowledge: [], previous: deleted, includePrivateWorkspaces: false)
        let merged = try PrivateMemorySyncMerge.merge(base: deleted, local: captured, remote: deleted)
        XCTAssertEqual(merged.notes.count, 1)
        XCTAssertEqual(merged.tombstones, deleted.tombstones)
    }
    func testDeletingRestoredCopyAdvancesToAnotherIdentity() throws {
        let current = SavedState(notes: [], chats: [])
        let first = try PrivateMemorySyncRestore.prepare(incoming, current: current, history: deleted)
        var nextHistory = deleted
        nextHistory.tombstones.append("note:" + first.notes[0].id.uuidString.lowercased())
        let next = try PrivateMemorySyncRestore.prepare(incoming, current: current, history: nextHistory)
        XCTAssertNotEqual(next.notes[0].id, first.notes[0].id)
        XCTAssertNotEqual(next.notes[0].id, note.id)
        XCTAssertEqual(nextHistory.tombstones.count, 2)
    }
    func testUnflushedLocalDeletionIsRespectedByExplicitImport() throws {
        var history = PrivateMemorySyncDocument.empty(repositoryID: 123)
        history.notes = [note]
        let result = try PrivateMemorySyncRestore.prepare(incoming, current: SavedState(notes: [], chats: []), history: history)
        XCTAssertNotEqual(result.notes[0].id, note.id)
    }
    func testFirstImportAndExistingLiveIdentityAreUnchanged() throws {
        let empty = PrivateMemorySyncDocument.empty(repositoryID: 123)
        let first = try PrivateMemorySyncRestore.prepare(incoming, current: SavedState(notes: [], chats: []), history: empty)
        XCTAssertEqual(first.notes[0].id, note.id)
        var history = empty; history.notes = [note]
        let repeated = try PrivateMemorySyncRestore.prepare(incoming, current: incoming, history: history)
        XCTAssertEqual(repeated.notes[0].id, note.id)
    }
    func testObservedRemoteMarkersAreRetainedWithoutTreatingRemoteContentAsLocalDeletion() throws {
        var remote = deleted
        let remoteOnly = MemoryNote(project: "General", text: "Remote content not yet downloaded", source: "Synthetic vault")
        remote.notes = [remoteOnly]
        let empty = PrivateMemorySyncDocument.empty(repositoryID: 123)
        let history = try PrivateMemorySyncRestore.addingRemoteMarkers(remote, to: empty)
        XCTAssertEqual(history.tombstones, remote.tombstones)
        XCTAssertTrue(history.notes.isEmpty)
        let restored = try PrivateMemorySyncRestore.prepare(incoming, current: SavedState(notes: [], chats: []), history: history)
        XCTAssertNotEqual(restored.notes[0].id, note.id)
        XCTAssertFalse(history.tombstones.contains("note:" + remoteOnly.id.uuidString.lowercased()))
    }
    func testChatsPreserveSequenceContentAndSourceDatesWhenRestored() throws {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let question = ChatEntry(project: "General", role: "user", text: "Question", date: date)
        let answer = ChatEntry(project: "General", role: "assistant", text: "Answer", date: date)
        var history = PrivateMemorySyncDocument.empty(repositoryID: 123)
        history.tombstones = [question, answer].map { "chat:" + $0.id.uuidString.lowercased() }
        let result = try PrivateMemorySyncRestore.prepare(SavedState(notes: [], chats: [question, answer]), current: SavedState(notes: [], chats: []), history: history)
        XCTAssertEqual(result.chats.map(\.text), ["Question", "Answer"])
        XCTAssertEqual(result.chats.map(\.date), [date, date])
        XCTAssertNotEqual(result.chats.map(\.id), [question.id, answer.id])
    }
}

@MainActor final class PrivateMemorySyncRestoreIntegrationTests: XCTestCase {
    func testConfiguredHistoryUnavailableBlocksBackupWithoutSaving() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let disk = PrivateMemorySyncDisk(root: root.appendingPathComponent("PrivateMemorySync"))
        try disk.saveConfiguration(.init(repository: "owner/private-memory", repositoryID: 123, accountID: 456, branch: "main", includePrivateWorkspaces: false))
        let store = AssistantStore(root: root, launchArguments: [])
        let incoming = SavedState(notes: [MemoryNote(project: "General", text: "Do not report a false restore", source: "Synthetic backup")], chats: [])
        store.importBackup(try MemoryBackup.encode(incoming))
        XCTAssertTrue(store.saved.notes.isEmpty)
        XCTAssertEqual(store.error, PrivateMemorySyncFailure.importHistoryUnavailable.localizedDescription)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("state.json").path))
    }
    func testConfiguredUnreadableRecoveryPausesSyncAndRequiresReview() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let disk = PrivateMemorySyncDisk(root: root.appendingPathComponent("PrivateMemorySync"))
        try disk.saveConfiguration(.init(repository: "owner/private-memory", repositoryID: 123, accountID: 456, branch: "main", includePrivateWorkspaces: false))
        let queueBytes = Data("preserve the encrypted queue without resetting it".utf8)
        try queueBytes.write(to: disk.journalURL)
        let stateURL = root.appendingPathComponent("state.json")
        let original = Data("preserve unreadable canonical state".utf8); try original.write(to: stateURL)
        let store = AssistantStore(root: root, launchArguments: [])
        XCTAssertTrue(store.loadFailed)
        store.importBackup(try MemoryBackup.encode(SavedState(notes: [], chats: [])))
        XCTAssertFalse(store.loadFailed)
        XCTAssertTrue(store.saved.notes.isEmpty)
        let preserved = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).filter { $0.lastPathComponent.hasPrefix("unreadable-") }
        XCTAssertEqual(preserved.count, 1)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(preserved.first)), original)
        XCTAssertEqual(try Data(contentsOf: disk.journalURL), queueBytes)
        let config = try XCTUnwrap(disk.loadConfiguration())
        XCTAssertFalse(config.enabled); XCTAssertEqual(config.localRecoveryNeedsReview, true)
        let controller = try XCTUnwrap(store.memorySync)
        controller.resume() // No review means no Keychain access or automatic resume.
        XCTAssertFalse(controller.isEnabled)
        XCTAssertEqual(try disk.loadConfiguration()?.localRecoveryNeedsReview, true)
    }
}
