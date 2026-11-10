import XCTest
@testable import AsterionVeyra

final class EditableChecklistTests: XCTestCase {
    private let early = Date(timeIntervalSince1970: 1_700_000_000)
    private let late = Date(timeIntervalSince1970: 1_700_000_060)
    private let empty = SavedState(notes: [], chats: [])
    private func preview(at date: Date? = nil, goal: String = "Ship safely", step: String = "Verify the source", done: Bool = false,
                         filename: String = "Luma.json", sourceID: String = "task-1") throws -> ConversationImportPreview {
        let json: [String: Any] = ["version": 1, "memories": [],
            "tasks": [["id": sourceID, "goal": goal, "text": step, "done": done]]]
        return try ConversationImporter.preview(JSONSerialization.data(withJSONObject: json), kind: .lumaBackup,
            filename: filename, project: "General", importedAt: date ?? early)
    }
    private func selected(_ value: ConversationImportPreview, into state: SavedState? = nil, editable: Bool = true) throws -> SavedState {
        try value.selection(ids: Set(value.groups.map(\.id)), into: state ?? empty,
            acknowledgeRestoringDeleted: true, includeEditableChecklists: editable)
    }
    private func copy(_ state: SavedState) throws -> MemoryNote {
        try XCTUnwrap(state.notes.first { EditableChecklist.decode($0) != nil })
    }
    private func document(_ state: SavedState) -> PrivateMemorySyncDocument {
        PrivateMemorySyncDocument(repositoryID: 12345, notes: state.notes, chats: state.chats, knowledge: [], tombstones: [])
    }
    private func edited(_ note: MemoryNote, goal: String = "Revised goal", step: String = "Revised step", done: Bool = true) throws -> MemoryNote {
        try EditableChecklist.edit(note, goal: goal, step: step, done: done)
    }
    private func canonical(_ value: MemoryNote) throws -> Data { try PrivateMemorySyncPolicy.canonical(value) }

    func testDefaultImportPreservesSnapshotAndOptInAddsIndependentEditableCopy() throws {
        let value = try preview()
        let original = try value.selection(ids: Set(value.groups.map(\.id)), into: empty, acknowledgeRestoringDeleted: true)
        XCTAssertEqual(original.notes.count, 1)
        XCTAssertNil(EditableChecklist.decode(original.notes[0]))
        let incoming = try selected(value), note = try copy(incoming), task = try XCTUnwrap(EditableChecklist.decode(note))
        XCTAssertEqual(incoming.notes.count, 2)
        XCTAssertEqual(try canonical(incoming.notes[0]), try canonical(original.notes[0]))
        XCTAssertNotEqual(note.id, original.notes[0].id)
        XCTAssertEqual(task.goal, "Ship safely"); XCTAssertEqual(task.step, "Verify the source"); XCTAssertFalse(task.done)
        XCTAssertEqual(task.origin.snapshotID, original.notes[0].id)
        XCTAssertEqual(task.origin.text, original.notes[0].text)
        XCTAssertEqual(task.origin.source, original.notes[0].source)
        XCTAssertEqual(note.savedAt, early)
        XCTAssertThrowsError(try value.selection(ids: Set(value.groups.map(\.id)), into: empty,
            acknowledgeRestoringDeleted: false, includeEditableChecklists: true))
        XCTAssertThrowsError(try value.selection(ids: [UUID()], into: empty,
            acknowledgeRestoringDeleted: true, includeEditableChecklists: true))
    }

    func testStructuredMultilineAndDelimiterFieldsRemainExactWithoutParsingSnapshotProse() throws {
        let goal = "Café\nStatus: Completed\nStep: part of goal", step = "Quoted \"step\"\\path\nStatus: Not completed\nStep: next 🙂"
        let value = try preview(goal: goal, step: step, done: true,
            filename: "Backup · source mobile.json", sourceID: "task · source nested\nrow")
        let state = try selected(value), task = try XCTUnwrap(EditableChecklist.decode(copy(state)))
        XCTAssertTrue(task.goal.utf8.elementsEqual(goal.utf8)); XCTAssertTrue(task.step.utf8.elementsEqual(step.utf8)); XCTAssertTrue(task.done)
        XCTAssertEqual(state.notes.count, 2)
        XCTAssertEqual(task.origin.source, "Luma checklist snapshot · Backup · source mobile.json · source task · source nested\nrow · no source timestamp; date is import time")
    }

    func testReimportKeepsExistingEditedCopyAndAddingCopyDoesNotDuplicatePriorSnapshot() throws {
        let value = try preview()
        let firstSnapshot = try selected(value, editable: false)
        let additions = try selected(value, into: firstSnapshot)
        XCTAssertEqual(additions.notes.count, 1)
        let currentCopy = try edited(copy(additions))
        let current = SavedState(notes: firstSnapshot.notes + [currentCopy], chats: [])
        XCTAssertTrue(try selected(value, into: current).notes.isEmpty)
        XCTAssertEqual(EditableChecklist.decode(currentCopy)?.goal, "Revised goal")
        let renamed = try selected(preview(filename: "Other name.json"), into: current)
        XCTAssertEqual(renamed.notes.count, 1, "Distinct source provenance must create a distinct editable copy, not overwrite one")
        XCTAssertNotEqual(try copy(renamed).id, currentCopy.id)
    }

    func testAmbiguousLegacySnapshotBodyCannotCollapseDistinctStructuredEditableCopies() throws {
        let first = try preview(goal: "a\nStatus: Not completed\nStep: b", step: "c")
        let second = try preview(goal: "a", step: "b\nStatus: Not completed\nStep: c")
        let a = try selected(first), b = try selected(second)
        XCTAssertEqual(a.notes[0].text, b.notes[0].text, "The legacy snapshot format is intentionally unchanged")
        XCTAssertEqual(a.notes[0].id, b.notes[0].id)
        let ac = try copy(a), bc = try copy(b)
        XCTAssertNotEqual(ac.id, bc.id, "Structured fields, not an ambiguous flattened body, identify the editable version")
        let changedA = try edited(ac, goal: "Reviewed first", step: "Keep the first edit")
        let current = SavedState(notes: [a.notes[0], changedA], chats: [])
        let additions = try selected(second, into: current)
        XCTAssertEqual(additions.notes.count, 1, "The distinct second version must not disappear during sequential import")
        let combined = MemoryBackup.merge(additions, into: current)
        XCTAssertEqual(combined.notes.count, 3)
        XCTAssertEqual(Set(combined.notes.compactMap { EditableChecklist.decode($0)?.goal }), ["Reviewed first", "a"])
        XCTAssertTrue(try selected(first, into: combined).notes.isEmpty)
        XCTAssertTrue(try selected(second, into: combined).notes.isEmpty)
    }

    func testEditingAHistoricalConflictCannotBeOverwrittenByRegeneratedConflictPayload() throws {
        for sortsBefore in [true, false] {
            var fixture: (PrivateMemorySyncDocument, MemoryNote, MemoryNote)?
            // Exercise both UUID processing orders without depending on one hash constant.
            for index in 0..<64 {
                let seed = try copy(selected(preview(goal: "Initial", sourceID: "task-\(index)")))
                let alpha = try edited(seed, goal: "Alpha", step: "Verify the source", done: false)
                let zulu = try edited(seed, goal: "Zulu", step: "Verify the source", done: false)
                let prior = try PrivateMemorySyncMerge.merge(base: document(SavedState(notes: [seed], chats: [])),
                    local: document(SavedState(notes: [alpha], chats: [])), remote: document(SavedState(notes: [zulu], chats: [])))
                let primary = try XCTUnwrap(prior.notes.first { $0.id == seed.id })
                let conflict = try XCTUnwrap(prior.notes.first { $0.id != seed.id })
                if (conflict.id.uuidString < primary.id.uuidString) == sortsBefore {
                    fixture = (prior, primary, conflict); break
                }
            }
            let (prior, primary, conflict) = try XCTUnwrap(fixture)
            XCTAssertEqual(EditableChecklist.decode(primary)?.goal, "Alpha")
            XCTAssertEqual(EditableChecklist.decode(conflict)?.goal, "Zulu")
            let local = document(SavedState(notes: [try edited(primary, goal: "Zulu", step: "Verify the source", done: false), conflict], chats: []))
            let echo = try edited(conflict, goal: "Echo", step: "Verify the source", done: false)
            let remote = document(SavedState(notes: [try edited(primary, goal: "Mike", step: "Verify the source", done: false), echo], chats: []))
            let forward = try PrivateMemorySyncMerge.merge(base: prior, local: local, remote: remote)
            XCTAssertEqual(Set(forward.notes.compactMap { EditableChecklist.decode($0)?.goal }), ["Echo", "Mike", "Zulu"])
            XCTAssertEqual(try canonical(XCTUnwrap(forward.notes.first { $0.id == echo.id })), try canonical(echo))
            let reverse = try PrivateMemorySyncMerge.merge(base: prior, local: remote, remote: local)
            XCTAssertEqual(try forward.encoded(), try reverse.encoded())
            let repeated = try PrivateMemorySyncMerge.merge(base: forward, local: forward, remote: reverse)
            XCTAssertEqual(try repeated.encoded(), try forward.encoded())
            let stale = try PrivateMemorySyncMerge.merge(base: prior, local: forward, remote: prior)
            XCTAssertEqual(try stale.encoded(), try forward.encoded())
            let preservedZulu = try XCTUnwrap(forward.notes.first { EditableChecklist.decode($0)?.goal == "Zulu" })
            XCTAssertNotEqual(preservedZulu.id, echo.id)
            var deletion = remote
            deletion.tombstones = ["note:" + preservedZulu.id.uuidString.lowercased()]
            let afterDeletion = try PrivateMemorySyncMerge.merge(base: prior, local: local, remote: deletion)
            XCTAssertEqual(Set(afterDeletion.notes.compactMap { EditableChecklist.decode($0)?.goal }), ["Echo", "Mike"])
            XCTAssertEqual(afterDeletion.tombstones, deletion.tombstones)
        }
    }

    func testEditsPreserveIdentityOriginalProvenanceAndCreationDate() throws {
        let state = try selected(preview()), original = try copy(state)
        let changed = try edited(original, goal: "  Café\nnext  ", step: "Step\nwith delimiters: · source ", done: true)
        let before = try XCTUnwrap(EditableChecklist.decode(original)), after = try XCTUnwrap(EditableChecklist.decode(changed))
        XCTAssertEqual(changed.id, original.id); XCTAssertEqual(changed.source, original.source)
        XCTAssertEqual(changed.project, original.project); XCTAssertEqual(changed.savedAt, original.savedAt)
        XCTAssertEqual(try PrivateMemorySyncPolicy.canonical(after.origin), try PrivateMemorySyncPolicy.canonical(before.origin))
        XCTAssertEqual(after.goal, "  Café\nnext  "); XCTAssertTrue(after.done)
        XCTAssertEqual(state.notes[0].text, before.origin.text)
        XCTAssertEqual(EditableChecklist.decode(original)?.goal, "Ship safely")
    }

    func testStrictRecognitionRetainsUnknownMalformedAndUnsafeEnvelopesAsOrdinaryNotes() throws {
        let original = try copy(selected(preview()))
        let suffix = String(original.text.dropFirst(EditableChecklist.header.count))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(suffix.utf8)) as? [String: Any])
        let mutations: [(String, Any)] = [("version", 2), ("unknown", "retain me"), ("done", 1), ("goal", ""),
            ("step", String(repeating: "🙂", count: 201)), ("goal", "api_key=synthetic"), ("goal", "\u{202E}hidden")]
        for (key, value) in mutations {
            var changed = object; changed[key] = value
            var note = original
            note.text = EditableChecklist.header + String(decoding: try JSONSerialization.data(withJSONObject: changed, options: [.sortedKeys, .withoutEscapingSlashes]), as: UTF8.self)
            XCTAssertNil(EditableChecklist.decode(note), "Reject malformed or future subtype without dropping its note")
            if key != "goal" || !["api_key=synthetic", "\u{202E}hidden"].contains(value as? String ?? "") {
                let backup = try MemoryBackup.encode(SavedState(notes: [note], chats: []))
                XCTAssertEqual(try MemoryBackup.decode(backup).notes[0].text, note.text)
            }
        }
        for suffix in ["{\"version\":1,\"version\":2}", "{", String(repeating: "x", count: 20_001)] {
            var note = original; note.text = EditableChecklist.header + suffix
            XCTAssertNil(EditableChecklist.decode(note))
        }
        var wrongSource = original; wrongSource.source = "User note"
        XCTAssertNil(EditableChecklist.decode(wrongSource))
        var unsupported = object; unsupported["origin"] = ["snapshotID": UUID().uuidString, "text": "original", "source": "source", "future": true]
        var note = original; note.text = EditableChecklist.header + String(decoding: try JSONSerialization.data(withJSONObject: unsupported, options: [.sortedKeys]), as: UTF8.self)
        XCTAssertNil(EditableChecklist.decode(note))
    }

    func testEditingBoundsUseUTF16AndRejectUnsafeDecodedFieldsWithoutMutatingOriginal() throws {
        let original = try copy(selected(preview()))
        for (goal, step) in [(" ", "step"), (String(repeating: "🙂", count: 151), "step"), ("goal", "\n"),
                             ("goal", String(repeating: "🙂", count: 201)), ("goal", "password=synthetic"), ("\u{0}", "step")] {
            XCTAssertThrowsError(try edited(original, goal: goal, step: step))
        }
        let maximum = try edited(original, goal: String(repeating: "🙂", count: 150), step: String(repeating: "🙂", count: 200))
        XCTAssertEqual(EditableChecklist.decode(maximum)?.goal.utf16.count, 300)
        XCTAssertEqual(EditableChecklist.decode(original)?.goal, "Ship safely")
    }

    func testIndependentCopiesReconcileImportDatesWithoutLosingExactProvenance() throws {
        let first = try selected(preview(at: early)), second = try selected(preview(at: late))
        let a = try PrivateMemorySyncMerge.merge(base: document(empty), local: document(first), remote: document(second))
        let b = try PrivateMemorySyncMerge.merge(base: document(empty), local: document(second), remote: document(first))
        XCTAssertEqual(a.notes.count, 2)
        XCTAssertEqual(try a.encoded(), try b.encoded())
        XCTAssertEqual(try copy(SavedState(notes: a.notes, chats: [])).savedAt, early)
        let replay = try PrivateMemorySyncMerge.merge(base: a, local: a, remote: document(second))
        XCTAssertEqual(try replay.encoded(), try a.encoded())
        let composed = try selected(preview(filename: "Caf\u{00E9}.json")), decomposed = try selected(preview(filename: "Cafe\u{0301}.json"))
        XCTAssertNotEqual(try copy(composed).id, try copy(decomposed).id)
    }

    func testOneSidedAndConcurrentEditsKeepAllRealVersionsAndConflictCopiesEditable() throws {
        let state = try selected(preview()), note = try copy(state), snapshot = state.notes[0]
        let local = SavedState(notes: [snapshot, try edited(note, goal: "Local goal", done: false)], chats: [])
        let remote = SavedState(notes: [snapshot, try edited(note, goal: "Remote goal", done: true)], chats: [])
        let single = try PrivateMemorySyncMerge.merge(base: document(state), local: document(local), remote: document(state))
        XCTAssertEqual(single.notes.count, 2); XCTAssertEqual(EditableChecklist.decode(try copy(SavedState(notes: single.notes, chats: [])))?.goal, "Local goal")
        let merged = try PrivateMemorySyncMerge.merge(base: document(state), local: document(local), remote: document(remote))
        let reversed = try PrivateMemorySyncMerge.merge(base: document(state), local: document(remote), remote: document(local))
        XCTAssertEqual(try merged.encoded(), try reversed.encoded()); XCTAssertEqual(merged.notes.count, 3)
        XCTAssertEqual(Set(merged.notes.compactMap { EditableChecklist.decode($0)?.goal }), ["Local goal", "Remote goal"])
        XCTAssertEqual(try canonical(XCTUnwrap(merged.notes.first { $0.id == snapshot.id })), try canonical(snapshot))
        for note in merged.notes where EditableChecklist.decode(note) != nil { XCTAssertNoThrow(try edited(note)) }
        let replay = try PrivateMemorySyncMerge.merge(base: merged, local: merged, remote: reversed)
        XCTAssertEqual(try replay.encoded(), try merged.encoded())
    }

    func testDeletionAndExplicitRestorationPreserveMarkersAndNeverRestoreOriginalImplicitly() throws {
        let initial = try selected(preview()), note = try copy(initial), snapshot = initial.notes[0]
        let deleted = try PrivateMemorySyncMerge.capture(state: SavedState(notes: [snapshot], chats: []), knowledge: [], previous: document(initial), includePrivateWorkspaces: false)
        let merged = try PrivateMemorySyncMerge.merge(base: document(initial), local: deleted, remote: document(initial))
        XCTAssertEqual(merged.notes.count, 1); XCTAssertEqual(merged.tombstones, ["note:" + note.id.uuidString.lowercased()])
        let restored = try PrivateMemorySyncRestore.prepare(initial, current: SavedState(notes: [snapshot], chats: []), history: merged)
        let restoredCopy = try copy(restored)
        XCTAssertNotEqual(restoredCopy.id, note.id)
        let changed = try edited(restoredCopy)
        let current = SavedState(notes: [snapshot, changed], chats: [])
        let repeated = try PrivateMemorySyncRestore.prepare(initial, current: current, history: merged)
        let kept = MemoryBackup.merge(repeated, into: current)
        XCTAssertEqual(kept.notes.count, 2); XCTAssertEqual(try canonical(copy(kept)), try canonical(changed))
        let withoutSnapshot = SavedState(notes: [changed], chats: [])
        XCTAssertEqual(try edited(copy(withoutSnapshot)).id, changed.id)
        XCTAssertEqual(withoutSnapshot.notes.count, 1)
    }

    func testCanonicalDiskAndBothEncryptedFormatsRetainEditableCopiesAsExistingNotes() throws {
        let state = try selected(preview()), directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let disk = DiskStore(root: directory); try disk.save(state)
        XCTAssertEqual(try canonical(copy(disk.load())), try canonical(copy(state)))
        let raw = try MemoryBackup.encode(state)
        for format in [EncryptedMemoryTransfer.Format.mobileBackup, .desktopNotes] {
            let encrypted = try EncryptedMemoryTransfer.encrypt(backupData: raw, passphrase: "synthetic checklist transfer words", format: format)
            let result = try EncryptedMemoryTransfer.decrypt(encrypted, passphrase: "synthetic checklist transfer words")
            XCTAssertEqual(try canonical(copy(MemoryBackup.decode(result.backupData))), try canonical(copy(state)))
        }
        let outer = try XCTUnwrap(JSONSerialization.jsonObject(with: raw) as? [String: Any])
        XCTAssertEqual(Set(outer.keys), ["version", "notes", "chats"])
        XCTAssertEqual((outer["version"] as? NSNumber)?.intValue, 1)
    }

    func testOptInCapacityRejectsWholeAdditionInsteadOfSavingOnlySnapshot() throws {
        let state = SavedState(notes: (0..<9999).map { MemoryNote(project: "General", text: "Existing \($0)", source: "User note", savedAt: early) }, chats: [])
        XCTAssertNoThrow(try selected(preview(), into: state, editable: false))
        XCTAssertThrowsError(try selected(preview(), into: state, editable: true))
        XCTAssertEqual(state.notes.count, 9999)
    }

    func testRestoredCopiesConvergeButLegacyConflictCopyDatesKeepExistingBehavior() throws {
        let first = try selected(preview(at: early)), second = try selected(preview(at: late))
        var history = document(empty)
        history.tombstones = first.notes.map { "note:" + $0.id.uuidString.lowercased() }
        let a = try PrivateMemorySyncRestore.prepare(first, current: empty, history: history)
        let b = try PrivateMemorySyncRestore.prepare(second, current: empty, history: history)
        let result = try PrivateMemorySyncMerge.merge(base: history, local: document(a), remote: document(b))
        XCTAssertEqual(result.notes.count, 2)
        XCTAssertEqual(Set(result.tombstones), Set(history.tombstones))
        XCTAssertEqual(try copy(SavedState(notes: result.notes, chats: [])).id, try copy(a).id)
        var conflict = try copy(first)
        conflict.id = UUID(uuidString: "12345678-1234-5234-8234-123456789012")!
        var laterConflict = conflict; laterConflict.savedAt = late
        let retained = try PrivateMemorySyncMerge.merge(base: document(empty),
            local: document(SavedState(notes: [conflict], chats: [])), remote: document(SavedState(notes: [laterConflict], chats: [])))
        XCTAssertEqual(retained.notes.count, 2)
    }

    @MainActor func testEditCapacityFailureCannotPublishOrPersistAChangedCopy() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var state = try selected(preview(goal: "G", step: "S"))
        // Fill a real valid canonical backup to 100 bytes below its byte limit.
        // ASCII filler gives an exact independent byte increment, not a mock capacity check.
        state.notes += (0..<240).map { _ in MemoryNote(project: "General", text: String(repeating: "a", count: 20_000), source: "User note", savedAt: early) }
        while true {
            let remaining = 4_999_900 - (try JSONEncoder().encode(state)).count
            if remaining <= 200 { break }
            let new = MemoryNote(project: "General", text: "", source: "User note", savedAt: early)
            state.notes.append(new)
            let room = 4_999_900 - (try JSONEncoder().encode(state)).count
            guard room >= 0 else { XCTFail("Fixture exceeded its own budget"); return }
            state.notes[state.notes.count - 1].text = String(repeating: "a", count: min(20_000, room))
        }
        let original = try copy(state)
        let before = try MemoryBackup.encode(state)
        XCTAssertLessThanOrEqual(before.count, 5_000_000)
        XCTAssertGreaterThan(before.count, 4_999_600)
        try DiskStore(root: root).save(state)
        let store = AssistantStore(root: root, launchArguments: [], networkMonitor: ChecklistTestNetworkMonitor())
        XCTAssertThrowsError(try store.saveChecklist(original, goal: String(repeating: "g", count: 300),
            step: String(repeating: "s", count: 400), done: false, expectedWorkspaceEpoch: store.workspaceEpoch))
        XCTAssertEqual(try canonical(copy(store.saved)), try canonical(original))
        XCTAssertEqual(try canonical(copy(DiskStore(root: root).load())), try canonical(original))
    }

    @MainActor func testStoreSavePersistsAndStaleOrDeletedReviewsCannotOverwriteOrRestore() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let state = try selected(preview()), original = try copy(state)
        try DiskStore(root: root).save(state)
        let store = AssistantStore(root: root, launchArguments: [], networkMonitor: ChecklistTestNetworkMonitor())
        let epoch = store.workspaceEpoch
        for field in 0..<4 {
            var stale = original
            switch field {
            case 0: stale.savedAt = late
            case 1: stale.source += " altered"
            case 2: stale.project = "Other"
            default: stale.id = UUID()
            }
            XCTAssertThrowsError(try store.saveChecklist(stale, goal: "No", step: "No", done: true, expectedWorkspaceEpoch: epoch))
        }
        try store.saveChecklist(original, goal: "Saved edit", step: "Verified step", done: true, expectedWorkspaceEpoch: epoch)
        XCTAssertEqual(EditableChecklist.decode(try copy(store.saved))?.goal, "Saved edit")
        XCTAssertEqual(try canonical(copy(DiskStore(root: root).load())), try canonical(copy(store.saved)))
        XCTAssertThrowsError(try store.saveChecklist(original, goal: "Stale edit", step: "No", done: false, expectedWorkspaceEpoch: epoch))
        let latest = try copy(store.saved)
        store.switchProject("Other"); store.switchProject("General")
        XCTAssertThrowsError(try store.saveChecklist(latest, goal: "Old workspace", step: "No", done: false, expectedWorkspaceEpoch: epoch))
        store.forget(latest.id)
        XCTAssertThrowsError(try store.saveChecklist(latest, goal: "Deleted", step: "No", done: false, expectedWorkspaceEpoch: store.workspaceEpoch))
        XCTAssertNil(store.saved.notes.first { $0.id == latest.id })
        XCTAssertEqual(try canonical(store.saved.notes[0]), try canonical(state.notes[0]))
    }

    @MainActor func testUnicodeEquivalentStaleReviewAndFailedPersistenceLeaveSavedDataUntouched() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let preserved = root.appendingPathExtension("preserved")
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: preserved) }
        let state = try selected(preview(goal: "Caf\u{00E9}")), original = try copy(state)
        try DiskStore(root: root).save(state)
        let store = AssistantStore(root: root, launchArguments: [], networkMonitor: ChecklistTestNetworkMonitor())
        var stale = original; stale.text = stale.text.replacingOccurrences(of: "Caf\u{00E9}", with: "Cafe\u{0301}")
        XCTAssertEqual(stale, original); XCTAssertNotEqual(try canonical(stale), try canonical(original))
        XCTAssertThrowsError(try store.saveChecklist(stale, goal: "No", step: "No", done: false, expectedWorkspaceEpoch: store.workspaceEpoch))
        try FileManager.default.moveItem(at: root, to: preserved)
        try Data("Block canonical write without deleting originals".utf8).write(to: root)
        XCTAssertThrowsError(try store.saveChecklist(original, goal: "Unsaved", step: "No", done: false, expectedWorkspaceEpoch: store.workspaceEpoch))
        XCTAssertEqual(try canonical(copy(store.saved)), try canonical(original))
        XCTAssertEqual(try canonical(copy(DiskStore(root: preserved).load())), try canonical(original))
    }
}

private final class ChecklistTestNetworkMonitor: AssistantNetworkMonitoring {
    func start(_ receive: @escaping @Sendable (AssistantNetworkPath) -> Void) {}
    func cancel() {}
}
