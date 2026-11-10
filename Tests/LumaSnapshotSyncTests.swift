import XCTest
@testable import AsterionVeyra

final class LumaSnapshotSyncTests: XCTestCase {
    private let early = Date(timeIntervalSince1970: 1_700_000_000)
    private let late = Date(timeIntervalSince1970: 1_700_000_060)
    private let empty = SavedState(notes: [], chats: [])
    private func document(_ notes: [MemoryNote] = []) -> PrivateMemorySyncDocument {
        PrivateMemorySyncDocument(repositoryID: 12345, notes: notes, chats: [], knowledge: [], tombstones: [])
    }
    private func imported(at date: Date, filename: String = "Luma.json", sourceID: String = "task-1",
                          done: Bool = false) throws -> SavedState {
        let json: [String: Any] = ["version": 1,
            "memories": [["id": "memory-1", "text": "Keep the original dated note", "created": "2026-11-09T09:00:00.123Z"]],
            "tasks": [["id": sourceID, "goal": "Ship safely", "text": "Verify the original", "done": done]]]
        let preview = try ConversationImporter.preview(JSONSerialization.data(withJSONObject: json), kind: .lumaBackup,
            filename: filename, project: "General", importedAt: date)
        return try preview.selection(ids: Set(preview.groups.map(\.id)), into: empty, acknowledgeRestoringDeleted: true)
    }
    private func captured(_ state: SavedState, previous: PrivateMemorySyncDocument? = nil) throws -> PrivateMemorySyncDocument {
        let value = try PrivateMemorySyncMerge.capture(state: state, knowledge: [], previous: previous ?? document(), includePrivateWorkspaces: false)
        return try PrivateMemorySyncDocument.decode(value.encoded(), repositoryID: 12345)
    }
    private func merged(_ left: [MemoryNote], _ right: [MemoryNote], base: PrivateMemorySyncDocument? = nil) throws -> PrivateMemorySyncDocument {
        try PrivateMemorySyncMerge.merge(base: base ?? document(), local: document(left), remote: document(right))
    }

    func testIndependentLumaImportsConvergeWithoutTimestampConflictCopies() throws {
        let first = try imported(at: early), second = try imported(at: late)
        XCTAssertEqual(first.notes.count, 2)
        XCTAssertEqual(first.notes.map(\.id), second.notes.map(\.id))
        XCTAssertEqual(first.notes[1].savedAt, early); XCTAssertEqual(second.notes[1].savedAt, late)
        let local = try captured(first), remote = try captured(second)
        let result = try PrivateMemorySyncMerge.merge(base: document(), local: local, remote: remote)
        XCTAssertEqual(result.notes.count, 2, "An import-time difference must not duplicate a Luma checklist")
        XCTAssertEqual(Set(result.notes.map(\.id)), Set(first.notes.map(\.id)))
        for original in first.notes { XCTAssertEqual(result.notes.first { $0.id == original.id }, original) }
        let reversed = try PrivateMemorySyncMerge.merge(base: document(), local: remote, remote: local)
        XCTAssertEqual(try result.encoded(), try reversed.encoded())
        let stale = try PrivateMemorySyncMerge.merge(base: result, local: result, remote: remote)
        XCTAssertEqual(try stale.encoded(), try result.encoded())
        XCTAssertEqual(local.notes.first { $0.id == first.notes[1].id }?.savedAt, early)
        XCTAssertEqual(remote.notes.first { $0.id == second.notes[1].id }?.savedAt, late, "Merging must not mutate its inputs")
    }

    func testRealContentProvenanceAndWorkspaceConflictsStillPreserveBothVersions() throws {
        let original = try imported(at: early).notes[1]
        var text = original; text.text += "\nA separately edited step"; text.savedAt = late
        var source = original; source.source += " · separately reviewed"; source.savedAt = late
        var project = original; project.project = "Other"; project.savedAt = late
        let renamed = try imported(at: late, filename: "Renamed.json").notes[1]
        for changed in [text, source, project, renamed] {
            let result = try merged([original], [changed])
            XCTAssertEqual(result.notes.count, 2)
            XCTAssertTrue(result.notes.contains { $0.text == original.text && $0.source == original.source && $0.project == original.project && $0.savedAt == original.savedAt })
            XCTAssertTrue(result.notes.contains { $0.text == changed.text && $0.source == changed.source && $0.project == changed.project && $0.savedAt == changed.savedAt })
            XCTAssertEqual(try result.encoded(), try merged([changed], [original]).encoded())
        }
    }

    func testUnrelatedNotesAndLegacyConflictCopiesKeepDateConflictBehavior() throws {
        let state = try imported(at: early)
        let task = state.notes[1]
        var ordinary = task; ordinary.source = "User note"
        var dated = state.notes[0]; dated.savedAt = early
        var legacy = task; legacy.id = UUID(uuidString: "12345678-1234-5234-8234-123456789012")!
        var userIdentity = task; userIdentity.id = UUID(uuidString: "12345678-1234-4234-8234-123456789012")!
        var missingMarker = task; missingMarker.source = "Luma checklist snapshot · Luma.json · source task-1"
        var missingHeader = task; missingHeader.text = "Ordinary note with a copied provenance label"
        for original in [ordinary, dated, legacy, userIdentity, missingMarker, missingHeader] {
            var later = original; later.savedAt = late
            let result = try merged([original], [later])
            XCTAssertEqual(result.notes.count, 2, "Only current-format checklist import times may reconcile")
            XCTAssertEqual(Set(result.notes.map(\.savedAt)), [early, late])
        }
    }

    func testDifferentIDsAndPreviouslySavedConflictCopiesAreNotRemoved() throws {
        let original = try imported(at: early).notes[1]
        var copy = original; copy.id = UUID(uuidString: "12345678-1234-5234-8234-123456789012")!; copy.savedAt = late
        let result = try merged([original, copy], [original, copy], base: document([original, copy]))
        XCTAssertEqual(result.notes.count, 2)
        XCTAssertEqual(result.notes.first { $0.id == original.id }, original)
        XCTAssertEqual(result.notes.first { $0.id == copy.id }, copy)
        XCTAssertEqual(try merged([original], [copy]).encoded(), try result.encoded())
    }

    func testTombstoneDefeatsAnIndependentlyImportedStaleChecklist() throws {
        let first = try imported(at: early), second = try imported(at: late)
        let base = try captured(first)
        let local = try captured(SavedState(notes: [first.notes[0]], chats: []), previous: base)
        let result = try PrivateMemorySyncMerge.merge(base: base, local: local, remote: captured(second))
        XCTAssertEqual(result.notes, [first.notes[0]])
        XCTAssertEqual(result.tombstones, ["note:" + first.notes[1].id.uuidString.lowercased()])
    }

    func testExplicitRestorationsConvergeWithoutRemovingOriginalTombstone() throws {
        let first = try imported(at: early), second = try imported(at: late)
        var history = document(); history.tombstones = ["note:" + first.notes[1].id.uuidString.lowercased()]
        let restoredFirst = try PrivateMemorySyncRestore.prepare(first, current: empty, history: history)
        let restoredSecond = try PrivateMemorySyncRestore.prepare(second, current: empty, history: history)
        XCTAssertNotEqual(restoredFirst.notes[1].id, first.notes[1].id)
        XCTAssertEqual(restoredFirst.notes[1].id, restoredSecond.notes[1].id)
        let result = try PrivateMemorySyncMerge.merge(base: history, local: captured(restoredFirst, previous: history), remote: captured(restoredSecond, previous: history))
        XCTAssertEqual(result.notes.count, 2)
        XCTAssertEqual(result.notes.first { $0.id == restoredFirst.notes[1].id }, restoredFirst.notes[1])
        XCTAssertEqual(result.tombstones, history.tombstones)
        XCTAssertFalse(result.notes.contains { $0.id == first.notes[1].id })
    }

    func testDelimiterContainingProvenanceDoesNotNeedAmbiguousSourceParsing() throws {
        let filename = "Backup · source mobile.json", sourceID = "task · source nested"
        let first = try imported(at: early, filename: filename, sourceID: sourceID)
        let second = try imported(at: late, filename: filename, sourceID: sourceID)
        let result = try merged(first.notes, second.notes)
        XCTAssertEqual(result.notes.count, 2)
        XCTAssertEqual(result.notes.first { $0.id == first.notes[1].id }, first.notes[1])
    }

    func testChangedCompletionStatusRemainsASeparateSnapshot() throws {
        let first = try imported(at: early), second = try imported(at: late, done: true)
        XCTAssertNotEqual(first.notes[1].id, second.notes[1].id)
        let result = try merged(first.notes, second.notes)
        XCTAssertEqual(result.notes.count, 3)
        XCTAssertEqual(result.notes.first { $0.id == first.notes[1].id }, first.notes[1])
        XCTAssertEqual(result.notes.first { $0.id == second.notes[1].id }, second.notes[1])
    }
}
