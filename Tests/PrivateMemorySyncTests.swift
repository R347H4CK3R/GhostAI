import XCTest
@testable import AsterionVeyra

final class PrivateMemorySyncTests: XCTestCase {
    private let repositoryID = 12345
    private let passphrase = "synthetic shared recovery words"
    private func note(_ text: String = "Remember the synthetic decision") -> MemoryNote {
        MemoryNote(id: UUID(uuidString: "12345678-1234-4234-8234-123456789012")!, project: "General", text: text, source: "User note", savedAt: Date(timeIntervalSince1970: 1_700_000_000))
    }
    private func document(_ notes: [MemoryNote]) -> PrivateMemorySyncDocument {
        PrivateMemorySyncDocument(repositoryID: repositoryID, notes: notes, chats: [], knowledge: [], tombstones: [])
    }
    func testConcurrentEditPreservesBothVersionsAndConverges() throws {
        let base = document([note("Original")]), local = document([note("Local revision")]), remote = document([note("Remote revision")])
        let a = try PrivateMemorySyncMerge.merge(base: base, local: local, remote: remote)
        let b = try PrivateMemorySyncMerge.merge(base: base, local: remote, remote: local)
        XCTAssertEqual(Set(a.notes.map(\.text)), ["Local revision", "Remote revision"])
        XCTAssertEqual(Set(a.notes.map(\.id)), Set(b.notes.map(\.id)))
        XCTAssertEqual(try a.encoded(), try b.encoded())
        let again = try PrivateMemorySyncMerge.merge(base: a, local: a, remote: b)
        XCTAssertEqual(again.notes.count, 2)
    }
    func testOneSidedEditDoesNotCreateConflictCopy() throws {
        let base = document([note("Original")]), local = document([note("Changed")])
        let result = try PrivateMemorySyncMerge.merge(base: base, local: local, remote: base)
        XCTAssertEqual(result.notes.map(\.text), ["Changed"])
    }
    func testDeletionTombstoneDefeatsAStaleDevice() throws {
        let base = document([note()])
        let local = try PrivateMemorySyncMerge.capture(state: SavedState(notes: [], chats: []), knowledge: [], previous: base, includePrivateWorkspaces: false)
        XCTAssertEqual(local.tombstones, ["note:" + note().id.uuidString.lowercased()])
        let result = try PrivateMemorySyncMerge.merge(base: base, local: local, remote: base)
        XCTAssertTrue(result.notes.isEmpty)
        XCTAssertEqual(result.tombstones, local.tombstones)
    }
    func testExcludesPrivateWorkspacesAndUnsafeTextBeforeEncryption() throws {
        var privateNote = note(); privateNote.id = UUID(); privateNote.project = "GitHub account 42: owner/private"
        var unsafe = note("Authorization: Bearer synthetic-unsafe-content"); unsafe.id = UUID()
        let result = try PrivateMemorySyncMerge.capture(state: SavedState(notes: [note(), privateNote, unsafe], chats: []), knowledge: [], previous: document([]), includePrivateWorkspaces: false)
        XCTAssertEqual(result.notes.count, 1)
        XCTAssertEqual(result.notes[0].project, "General")
    }
    func testIndependentPythonEnvelopeUsesTheSameWireFormat() throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "private-memory-sync-v1", withExtension: "json"))
        struct Fixture: Decodable { let passphrase: String; let encryptedBase64: String }
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
        let raw = try EncryptedMemoryTransfer.decryptSyncPayload(XCTUnwrap(Data(base64Encoded: fixture.encryptedBase64)), passphrase: fixture.passphrase)
        let document = try PrivateMemorySyncDocument.decode(raw, repositoryID: repositoryID)
        XCTAssertEqual(document.notes.first?.text, "Synthetic cross-platform memory")
        XCTAssertEqual(document.tombstones, ["chat:22345678-1234-4234-8234-123456789012"])
    }
    func testEqualDateConversationSourceOrderSurvivesFirstSync() throws {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let first = ChatEntry(id: UUID(uuidString: "ffffffff-ffff-4fff-8fff-ffffffffffff")!, project: "General", role: "user", text: "First question", date: date)
        let second = ChatEntry(id: UUID(uuidString: "11111111-1111-4111-8111-111111111111")!, project: "General", role: "assistant", text: "First answer", date: date)
        let third = ChatEntry(id: UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")!, project: "General", role: "user", text: "Second question", date: date)
        let base = document([])
        let local = try PrivateMemorySyncMerge.capture(state: SavedState(notes: [], chats: [first, second, third]), knowledge: [], previous: base, includePrivateWorkspaces: false)
        let result = try PrivateMemorySyncMerge.merge(base: base, local: local, remote: base)
        let roundTrip = try PrivateMemorySyncDocument.decode(result.encoded(), repositoryID: repositoryID)
        XCTAssertEqual(roundTrip.chats.map(\.id), [first.id, second.id, third.id])
        XCTAssertEqual(roundTrip.chatOrder, [first.id, second.id, third.id])
    }
    func testImportedChatFallbackDateDifferencesConvergeWithoutCopies() throws {
        var first = ChatEntry(project: "General", role: "user", text: "Same imported message", date: Date(timeIntervalSince1970: 1_700_000_000))
        let original = first; first.date.addTimeInterval(30)
        var local = document([]), remote = document([])
        local.chats = [original]; remote.chats = [first]
        let result = try PrivateMemorySyncMerge.merge(base: document([]), local: local, remote: remote)
        XCTAssertEqual(result.chats.count, 1); XCTAssertEqual(result.chats[0].date, original.date)
    }
    func testConflictingChatsRemapKnowledgeMirrorsToPreservedCopies() throws {
        let first = ChatEntry(project: "General", role: "user", text: "First interpretation", date: Date(timeIntervalSince1970: 1_700_000_000))
        var second = first; second.text = "Other interpretation"
        let source = try JSONDecoder().decode(KnowledgeSource.self, from: Data("{\"origin\":\"conversation\",\"label\":\"In-app user message\"}".utf8))
        func snapshot(_ chat: ChatEntry) -> KnowledgeSyncSnapshot {
            let entry = KnowledgeEntry(id: "chat:" + chat.id.uuidString.lowercased(), kind: .conversation, text: chat.text, source: source, sourceDate: chat.date, cachedAt: chat.date, byteCount: chat.text.utf8.count)
            return KnowledgeSyncSnapshot(accountID: "device-local", project: "General", repository: nil, entries: [entry], suppressedIDs: [], clearBefore: nil)
        }
        var local = document([]), remote = document([])
        local.chats = [first]; local.knowledge = [snapshot(first)]
        remote.chats = [second]; remote.knowledge = [snapshot(second)]
        let result = try PrivateMemorySyncMerge.merge(base: document([]), local: local, remote: remote)
        XCTAssertEqual(result.chats.count, 2)
        XCTAssertEqual(Set(result.knowledge[0].entries.map(\.id)), Set(result.chats.map { "chat:" + $0.id.uuidString.lowercased() }))
        XCTAssertTrue(result.knowledge[0].suppressedIDs.isEmpty)
    }
    func testSyncCiphertextAuthenticatesAndIsSeparateFromManualBackup() throws {
        let raw = try document([note()]).encoded()
        let encrypted = try EncryptedMemoryTransfer.encryptSyncPayload(raw, passphrase: passphrase)
        XCTAssertNil(encrypted.range(of: Data(note().text.utf8)))
        XCTAssertEqual(try EncryptedMemoryTransfer.decryptSyncPayload(encrypted, passphrase: passphrase), raw)
        XCTAssertThrowsError(try EncryptedMemoryTransfer.decrypt(encrypted, passphrase: passphrase))
        var tampered = encrypted; tampered[tampered.count - 1] ^= 1
        XCTAssertThrowsError(try EncryptedMemoryTransfer.decryptSyncPayload(tampered, passphrase: passphrase))
        XCTAssertThrowsError(try EncryptedMemoryTransfer.decryptSyncPayload(encrypted, passphrase: "wrong shared recovery words"))
    }
    func testRemoteDocumentMustMatchPinnedRepositoryAndLimits() throws {
        let raw = try document([note()]).encoded()
        XCTAssertThrowsError(try PrivateMemorySyncDocument.decode(raw, repositoryID: repositoryID + 1))
        XCTAssertThrowsError(try PrivateMemorySyncDocument.decode(Data(repeating: 0, count: PrivateMemorySyncPolicy.maximumDocumentBytes + 1), repositoryID: repositoryID))
        var invalid = document([note(), note()])
        XCTAssertThrowsError(try invalid.encoded())
        invalid = document([]); invalid.tombstones = ["note:not-a-uuid"]
        XCTAssertThrowsError(try invalid.encoded())
    }
    func testPrivateRepositoryVerificationRejectsPublicMovedOrDifferentOwner() throws {
        let configuration = PrivateMemorySyncConfiguration(repository: "owner/private-memory", repositoryID: repositoryID, accountID: 77, branch: "main", includePrivateWorkspaces: false)
        func metadata(id: Int = 12345, privateRepo: Bool = true, name: String = "owner/private-memory", owner: Int = 77) -> PrivateMemorySyncRepository {
            .init(id: id, full_name: name, `private`: privateRepo, default_branch: "main", archived: false, disabled: false, owner: .init(id: owner), permissions: .init(push: true))
        }
        XCTAssertNoThrow(try metadata().validate(configuration))
        XCTAssertThrowsError(try metadata(privateRepo: false).validate(configuration))
        XCTAssertThrowsError(try metadata(id: 999).validate(configuration))
        XCTAssertThrowsError(try metadata(name: "owner/renamed").validate(configuration))
        XCTAssertThrowsError(try metadata(owner: 999).validate(configuration))
    }
    func testQueueStorageRejectsSymlinkRootAndLeaf() throws {
        let container = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: container) }
        let real = container.appendingPathComponent("real"), linked = container.appendingPathComponent("linked")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: real)
        let config = PrivateMemorySyncConfiguration(repository: "owner/private-memory", repositoryID: repositoryID, accountID: 77, branch: "main", includePrivateWorkspaces: false)
        XCTAssertThrowsError(try PrivateMemorySyncDisk(root: linked).saveConfiguration(config))
        XCTAssertThrowsError(try PrivateMemorySyncDisk(root: linked.appendingPathComponent("nested")).loadConfiguration())
        let outside = container.appendingPathComponent("untouched.json")
        try Data("untouched".utf8).write(to: outside)
        let disk = PrivateMemorySyncDisk(root: real)
        try FileManager.default.createSymbolicLink(at: disk.configurationURL, withDestinationURL: outside)
        XCTAssertThrowsError(try disk.loadConfiguration())
        XCTAssertThrowsError(try disk.saveConfiguration(config))
        XCTAssertEqual(try String(contentsOf: outside), "untouched")
    }
    func testPrivateScopeMismatchDoesNotDeleteTheRemoteScope() throws {
        let local = document([])
        var remote = document([]); remote.includesPrivateWorkspaces = true
        XCTAssertThrowsError(try PrivateMemorySyncMerge.merge(base: local, local: local, remote: remote)) { error in
            XCTAssertEqual(error as? PrivateMemorySyncFailure, .consent)
        }
    }
    func testQueueIsOneCoalescedEncryptedDocumentAndSurvivesReopen() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let disk = PrivateMemorySyncDisk(root: root)
        let configuration = PrivateMemorySyncConfiguration(repository: "owner/private-memory", repositoryID: repositoryID, accountID: 77, branch: "main", includePrivateWorkspaces: false)
        var journal = PrivateMemorySyncJournal(base: document([]), pending: document([note()]))
        try disk.saveJournal(journal, passphrase: passphrase)
        journal.pending = document([note("Newest coalesced revision")])
        try disk.saveJournal(journal, passphrase: passphrase)
        let loaded = try disk.loadJournal(passphrase: passphrase, repositoryID: repositoryID)
        XCTAssertEqual(loaded?.pending?.notes.map(\.text), ["Newest coalesced revision"])
        let bytes = try Data(contentsOf: disk.journalURL)
        XCTAssertNil(bytes.range(of: Data("Newest coalesced revision".utf8)))
        try disk.saveConfiguration(configuration)
        XCTAssertEqual(try disk.loadConfiguration()?.repositoryID, repositoryID)
    }
}
