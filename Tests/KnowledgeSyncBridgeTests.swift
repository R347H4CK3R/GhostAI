import XCTest
import SQLite3
@testable import AsterionVeyra

@MainActor final class KnowledgeSyncBridgeTests: XCTestCase {
    private func root() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }
    private func scope(_ project: String = "General", repository: String? = nil) throws -> KnowledgeScope {
        try KnowledgeWorkspacePolicy.scope(workspace: project, liveRepository: repository)
    }
    private func replaceMetadata(_ cache: KnowledgeCache, key: String, value: String?) throws {
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(cache.databaseURL.path, &database), SQLITE_OK)
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        let sql = value == nil ? "DELETE FROM metadata WHERE key=?" : "UPDATE metadata SET value=? WHERE key=?"
        XCTAssertEqual(sqlite3_prepare_v2(database, sql, -1, &statement, nil), SQLITE_OK)
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        if let value { sqlite3_bind_text(statement, 1, value, -1, transient) }
        sqlite3_bind_text(statement, value == nil ? 1 : 2, key, -1, transient)
        XCTAssertEqual(sqlite3_step(statement), SQLITE_DONE)
    }

    func testNewLibrariesCaptureAutomaticallyAndPersistedOptOutIsPreserved() throws {
        let directory = root(); defer { try? FileManager.default.removeItem(at: directory) }
        let cache = try KnowledgeCache(root: directory, scope: scope())
        XCTAssertTrue(cache.settings.captureConversations)
        XCTAssertTrue(cache.settings.captureActions)
        XCTAssertTrue(cache.settings.captureResearch)
        var disabled = cache.settings
        disabled.captureConversations = false; disabled.captureActions = false; disabled.captureResearch = false
        disabled.retention = .days90
        try cache.updateSettings(disabled)
        let reopened = try KnowledgeCache(root: directory, scope: scope())
        XCTAssertEqual(reopened.settings, disabled)
    }

    func testRoundTripRetainsProvenanceAndMissingIDTombstoneWinsOnEveryDevice() throws {
        let a = root(), b = root(); defer { try? FileManager.default.removeItem(at: a); try? FileManager.default.removeItem(at: b) }
        let source = try KnowledgeCache(root: a, scope: scope())
        let target = try KnowledgeCache(root: b, scope: scope())
        try source.importText(Data("orchid research".utf8), filename: "plan.txt")
        let original = try source.syncSnapshot()
        let id = try XCTUnwrap(original.entries.first?.id)
        let deletion = KnowledgeSyncSnapshot(accountID: "device-local", project: "General", repository: nil,
                                             entries: [], suppressedIDs: [id], clearBefore: nil)
        try target.applySyncSnapshot(deletion)
        try target.applySyncSnapshot(original)
        XCTAssertTrue(try target.entries().isEmpty)
        XCTAssertEqual(try target.syncSnapshot().suppressedIDs, [id])
        try source.applySyncSnapshot(target.syncSnapshot())
        XCTAssertTrue(try source.entries().isEmpty)
        let reopened = try KnowledgeCache(root: b, scope: scope())
        try reopened.applySyncSnapshot(original)
        XCTAssertTrue(try reopened.entries().isEmpty)
    }

    func testClearCutoffPreventsPreviouslyUnseenOldAutomaticContentButKeepsNewContent() throws {
        let a = root(), b = root(); defer { try? FileManager.default.removeItem(at: a); try? FileManager.default.removeItem(at: b) }
        let source = try KnowledgeCache(root: a, scope: scope()), target = try KnowledgeCache(root: b, scope: scope())
        let cutoff = Date(timeIntervalSince1970: 2_000_000)
        try source.captureAction(id: UUID(), kind: .question, status: .succeeded, date: cutoff.addingTimeInterval(-10))
        let old = try source.syncSnapshot()
        try target.clear(now: cutoff)
        try target.applySyncSnapshot(old)
        XCTAssertTrue(try target.entries().isEmpty)
        try source.applySyncSnapshot(target.syncSnapshot())
        XCTAssertTrue(try source.entries().isEmpty)
        try source.captureAction(id: UUID(), kind: .sourceSaved, status: .succeeded, date: cutoff.addingTimeInterval(10))
        try target.applySyncSnapshot(source.syncSnapshot())
        XCTAssertEqual(try target.entries().count, 1)
        XCTAssertEqual(try target.syncSnapshot().clearBefore, cutoff)
    }

    func testSyncedClearRejectsUnseenOldFilesButAllowsNewlySelectedContent() throws {
        let a = root(), b = root(); defer { try? FileManager.default.removeItem(at: a); try? FileManager.default.removeItem(at: b) }
        let source = try KnowledgeCache(root: a, scope: scope()), target = try KnowledgeCache(root: b, scope: scope())
        let cutoff = Date(timeIntervalSinceNow: -60)
        try source.importText(Data("old unseen file".utf8), filename: "old.txt", date: cutoff.addingTimeInterval(-100))
        let old = try XCTUnwrap(source.entries().first)
        let historical = KnowledgeEntry(id: old.id, kind: old.kind, text: old.text, source: old.source,
                                        sourceDate: old.sourceDate, cachedAt: cutoff.addingTimeInterval(-10), byteCount: old.byteCount)
        let stale = KnowledgeSyncSnapshot(accountID: "device-local", project: "General", repository: nil,
                                          entries: [historical], suppressedIDs: [], clearBefore: nil)
        try target.clear(now: cutoff)
        try target.applySyncSnapshot(stale)
        XCTAssertTrue(try target.entries().isEmpty)
        XCTAssertTrue(try target.syncSnapshot().suppressedIDs.contains(old.id))
        try source.importText(Data("new selected file".utf8), filename: "new.txt", date: cutoff.addingTimeInterval(-100))
        try target.applySyncSnapshot(source.syncSnapshot())
        XCTAssertEqual(try target.entries().map(\.text), ["new selected file"])
    }

    func testConfirmedRetentionDeletionPropagatesWithoutChangingOtherDeviceSettings() throws {
        let a = root(), b = root(); defer { try? FileManager.default.removeItem(at: a); try? FileManager.default.removeItem(at: b) }
        let source = try KnowledgeCache(root: a, scope: scope()), target = try KnowledgeCache(root: b, scope: scope())
        var settings = source.settings; settings.retention = .days30; try source.updateSettings(settings)
        try source.captureAction(id: UUID(), kind: .question, status: .succeeded, date: Date(timeIntervalSinceNow: -40 * 86_400))
        let stale = try source.syncSnapshot()
        try target.applySyncSnapshot(stale)
        try source.deleteExpiredAutomaticEntries()
        try target.applySyncSnapshot(source.syncSnapshot())
        try target.applySyncSnapshot(stale)
        XCTAssertTrue(try target.entries().isEmpty)
        XCTAssertEqual(target.settings.retention, .untilDeleted)
    }

    func testIndependentResearchAndFileDuplicatesConvergeWithoutBlockingNewEntries() throws {
        let a = root(), b = root(); defer { try? FileManager.default.removeItem(at: a); try? FileManager.default.removeItem(at: b) }
        let source = try KnowledgeCache(root: a, scope: scope("owner/repo", repository: "owner/repo"))
        let target = try KnowledgeCache(root: b, scope: scope("owner/repo", repository: "owner/repo"))
        let provenance = try KnowledgeSource.repository("owner/repo", path: "README.md", commit: String(repeating: "a", count: 40))
        let earlier = Date(timeIntervalSince1970: 1_000), later = earlier.addingTimeInterval(60)
        try source.captureResearch(text: "shared source", source: provenance, date: earlier)
        try target.captureResearch(text: "shared source", source: provenance, date: later)
        try source.importText(Data("shared file".utf8), filename: "a.txt", date: earlier)
        try target.importText(Data("shared file".utf8), filename: "z.txt", date: later)
        try source.importText(Data("new source".utf8), filename: "new.txt")
        try target.applySyncSnapshot(source.syncSnapshot())
        try source.applySyncSnapshot(target.syncSnapshot())
        XCTAssertEqual(try target.entries().count, 3)
        XCTAssertEqual(try source.syncSnapshot(), try target.syncSnapshot())
        XCTAssertEqual(try target.entries().first(where: { $0.text == "shared file" })?.source.label, "a.txt")
        XCTAssertEqual(try target.entries().first(where: { $0.text == "shared source" })?.sourceDate, earlier)
    }

    func testImmutableConversationConflictFailsWithoutUndoingRemoteDeletion() throws {
        let a = root(), b = root(); defer { try? FileManager.default.removeItem(at: a); try? FileManager.default.removeItem(at: b) }
        let source = try KnowledgeCache(root: a, scope: scope()), target = try KnowledgeCache(root: b, scope: scope())
        let chat = ChatEntry(project: "General", role: "user", text: "original conversation")
        var changed = chat; changed.text = "different conversation"
        _ = try source.captureSavedState(SavedState(notes: [], chats: [changed]))
        _ = try target.captureSavedState(SavedState(notes: [], chats: [chat]))
        try target.importText(Data("delete this file".utf8), filename: "remove.txt")
        let removed = try XCTUnwrap(target.entries().first(where: { $0.kind == .selectedFile }))
        let incoming = KnowledgeSyncSnapshot(accountID: "device-local", project: "General", repository: nil,
                                             entries: try source.entries(), suppressedIDs: [removed.id], clearBefore: nil)
        XCTAssertThrowsError(try target.applySyncSnapshot(incoming)) { XCTAssertEqual($0 as? KnowledgeFailure, .changedSource) }
        XCTAssertEqual(try target.entries().map(\.text), [chat.text])
        XCTAssertTrue(try target.syncSnapshot().suppressedIDs.contains(removed.id))
    }

    func testAdditionQuotaFailureCannotRollBackRemoteDeletion() throws {
        let a = root(), b = root(); defer { try? FileManager.default.removeItem(at: a); try? FileManager.default.removeItem(at: b) }
        let source = try KnowledgeCache(root: a, scope: scope())
        let target = try KnowledgeCache(root: b, scope: scope(), maximumBytes: 1_048_576)
        try target.importText(Data("delete this copy".utf8), filename: "old.txt")
        let old = try XCTUnwrap(target.entries().first)
        try source.importText(Data(String(repeating: "large source ", count: 10_000).utf8), filename: "large.txt")
        let incoming = KnowledgeSyncSnapshot(accountID: "device-local", project: "General", repository: nil,
                                             entries: try source.entries(), suppressedIDs: [old.id], clearBefore: nil)
        XCTAssertThrowsError(try target.applySyncSnapshot(incoming)) { XCTAssertEqual($0 as? KnowledgeFailure, .quota) }
        XCTAssertTrue(try target.entries().isEmpty)
        XCTAssertTrue(try target.syncSnapshot().suppressedIDs.contains(old.id))
    }

    func testTombstoneUnionQuotaFailurePreservesClearAndExistingCopyDeletion() throws {
        let directory = root(); defer { try? FileManager.default.removeItem(at: directory) }
        let cache = try KnowledgeCache(root: directory, scope: scope())
        try cache.captureAction(id: UUID(), kind: .question, status: .succeeded, date: Date(timeIntervalSince1970: 1_000))
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(cache.databaseURL.path, &database), SQLITE_OK)
        let sql = "WITH RECURSIVE numbers(n) AS (SELECT 1 UNION ALL SELECT n+1 FROM numbers WHERE n < 99999) INSERT INTO suppressed(id) SELECT 'file:' || printf('%064x', n) FROM numbers"
        XCTAssertEqual(sqlite3_exec(database, sql, nil, nil, nil), SQLITE_OK)
        sqlite3_close(database)
        let cutoff = Date(timeIntervalSince1970: 2_000)
        let incoming = KnowledgeSyncSnapshot(accountID: "device-local", project: "General", repository: nil, entries: [],
                                             suppressedIDs: ["research:" + String(repeating: "d", count: 64)], clearBefore: cutoff)
        XCTAssertThrowsError(try cache.applySyncSnapshot(incoming)) { XCTAssertEqual($0 as? KnowledgeFailure, .quota) }
        XCTAssertTrue(try cache.entries().isEmpty)
        XCTAssertEqual(try cache.syncSnapshot().clearBefore, cutoff)
    }

    func testUntrustedSnapshotRejectsScopeSpoofingSourceMismatchAndSecretsBeforeMutation() throws {
        let directory = root(); defer { try? FileManager.default.removeItem(at: directory) }
        let cache = try KnowledgeCache(root: directory, scope: scope("owner/repo", repository: "owner/repo"))
        let source = try KnowledgeSource.repository("owner/repo", path: "README.md", commit: String(repeating: "a", count: 40))
        try cache.captureResearch(text: "orchid", source: source)
        let good = try cache.syncSnapshot()
        let entry = try XCTUnwrap(good.entries.first)
        let spoof = KnowledgeSyncSnapshot(accountID: "device-local", project: "GitHub account 123: owner/repo", repository: "owner/repo", entries: [entry], suppressedIDs: [], clearBefore: nil)
        XCTAssertThrowsError(try spoof.validated())
        let wrongRepository = KnowledgeSyncSnapshot(accountID: "device-local", project: "owner/other", repository: "owner/other", entries: [entry], suppressedIDs: [], clearBefore: nil)
        XCTAssertThrowsError(try wrongRepository.validated())
        let secret = KnowledgeEntry(id: entry.id, kind: entry.kind, text: "Authorization: Bearer unsafe", source: entry.source, sourceDate: entry.sourceDate, cachedAt: entry.cachedAt, byteCount: 28)
        let poisoned = KnowledgeSyncSnapshot(accountID: good.accountID, project: good.project, repository: good.repository, entries: [secret], suppressedIDs: [entry.id], clearBefore: nil)
        XCTAssertThrowsError(try cache.applySyncSnapshot(poisoned))
        XCTAssertEqual(try cache.entries(), [entry])
    }

    func testCatalogFindsFileOnlyScopesAndPrivateScopesRequireMatchingVerifiedAccount() throws {
        let directory = root(); defer { try? FileManager.default.removeItem(at: directory) }
        let local = try KnowledgeCache(root: directory, scope: scope("file only"))
        try local.importText(Data("local orchid".utf8), filename: "local.txt")
        let privateProject = "GitHub account 123: owner/private"
        let privateCache = try KnowledgeCache(root: directory, scope: scope(privateProject, repository: "owner/private"))
        try privateCache.importText(Data("private orchid".utf8), filename: "private.txt")
        let excluded = try KnowledgeLibraryModel.collectSyncSnapshots(root: directory, knownProjects: [], includePrivateWorkspaces: false)
        XCTAssertEqual(excluded.map(\.project), ["file only"])
        let unverified = try KnowledgeLibraryModel.collectSyncSnapshots(root: directory, knownProjects: [], includePrivateWorkspaces: true)
        XCTAssertEqual(unverified.map(\.project), ["file only"])
        let wrongAccount = try KnowledgeLibraryModel.collectSyncSnapshots(root: directory, knownProjects: [], includePrivateWorkspaces: true, authenticatedAccountID: "github-user-456")
        XCTAssertEqual(wrongAccount.map(\.project), ["file only"])
        let authorized = try KnowledgeLibraryModel.collectSyncSnapshots(root: directory, knownProjects: [], includePrivateWorkspaces: true, authenticatedAccountID: "github-user-123")
        XCTAssertEqual(Set(authorized.map(\.project)), Set(["file only", privateProject]))
        let destination = root(); defer { try? FileManager.default.removeItem(at: destination) }
        try KnowledgeLibraryModel.applySyncSnapshots(authorized, root: destination, includePrivateWorkspaces: true, authenticatedAccountID: "github-user-456")
        let imported = try KnowledgeLibraryModel.collectSyncSnapshots(root: destination, knownProjects: [], includePrivateWorkspaces: true, authenticatedAccountID: "github-user-456")
        XCTAssertEqual(imported.map(\.project), ["file only"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent(privateCache.scope.storageKey).path))
    }

    func testLegacyDiscoveryUsesOnlyKnownScopesAndRejectsCatalogHashTampering() throws {
        let directory = root(); defer { try? FileManager.default.removeItem(at: directory) }
        let cache = try KnowledgeCache(root: directory, scope: scope("legacy"))
        try cache.importText(Data("legacy orchid".utf8), filename: "legacy.txt")
        try replaceMetadata(cache, key: "sync_scope", value: nil)
        XCTAssertTrue(try KnowledgeLibraryModel.collectSyncSnapshots(root: directory, knownProjects: [], includePrivateWorkspaces: false).isEmpty)
        let legacy = try KnowledgeLibraryModel.collectSyncSnapshots(root: directory, knownProjects: ["legacy"], includePrivateWorkspaces: false)
        XCTAssertEqual(legacy.map(\.project), ["legacy"])
        let tampered = KnowledgeSyncSnapshot(accountID: "device-local", project: "another", repository: nil, entries: [], suppressedIDs: [], clearBefore: nil)
        let encoded = String(decoding: try JSONEncoder().encode(tampered), as: UTF8.self)
        try replaceMetadata(cache, key: "sync_scope", value: encoded)
        XCTAssertThrowsError(try KnowledgeLibraryModel.collectSyncSnapshots(root: directory, knownProjects: [], includePrivateWorkspaces: false))
    }

    func testDanglingDatabaseAndRootSymlinksCannotCreateOutsideTheLibrary() throws {
        let directory = root(), outside = root(); defer { try? FileManager.default.removeItem(at: directory); try? FileManager.default.removeItem(at: outside) }
        let selected = try scope()
        let folder = directory.appendingPathComponent(selected.storageKey)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let target = outside.appendingPathComponent("unexpected.sqlite3")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("knowledge.sqlite3"), withDestinationURL: target)
        XCTAssertThrowsError(try KnowledgeCache(root: directory, scope: selected))
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
        let linkedRoot = root(); defer { try? FileManager.default.removeItem(at: linkedRoot) }
        try FileManager.default.createSymbolicLink(at: linkedRoot, withDestinationURL: outside.appendingPathComponent("missing"))
        XCTAssertThrowsError(try KnowledgeCache(root: linkedRoot, scope: selected))
        XCTAssertFalse(FileManager.default.fileExists(atPath: outside.appendingPathComponent("missing").path))
    }

    func testLegacyCoverageCountsUnknownHashesWithoutExportingOrGuessingScopes() throws {
        let directory = root(); defer { try? FileManager.default.removeItem(at: directory) }
        let unknown = try KnowledgeCache(root: directory, scope: scope("forgotten project"))
        try unknown.importText(Data("legacy copy".utf8), filename: "old.txt")
        try replaceMetadata(unknown, key: "sync_scope", value: nil)
        var count = -1
        let missing = try KnowledgeLibraryModel.collectSyncSnapshots(root: directory, knownProjects: [], includePrivateWorkspaces: false,
                                                                     onUnresolvedLegacyScopes: { count = $0 })
        XCTAssertEqual(count, 1)
        XCTAssertTrue(missing.isEmpty)
        let recovered = try KnowledgeLibraryModel.collectSyncSnapshots(root: directory, knownProjects: ["forgotten project"], includePrivateWorkspaces: false,
                                                                       onUnresolvedLegacyScopes: { count = $0 })
        XCTAssertEqual(count, 0)
        XCTAssertEqual(recovered.map(\.project), ["forgotten project"])
    }

    func testExcludedKnownPrivateLegacyScopeIsNotMisreportedAsUnidentified() throws {
        let directory = root(); defer { try? FileManager.default.removeItem(at: directory) }
        let project = "GitHub account 123: owner/private"
        let known = try KnowledgeCache(root: directory, scope: scope(project))
        try known.importText(Data("private legacy copy".utf8), filename: "private.txt")
        try replaceMetadata(known, key: "sync_scope", value: nil)
        var count = -1
        let snapshots = try KnowledgeLibraryModel.collectSyncSnapshots(root: directory, knownProjects: [project], includePrivateWorkspaces: false,
                                                                       onUnresolvedLegacyScopes: { count = $0 })
        XCTAssertEqual(count, 0)
        XCTAssertTrue(snapshots.isEmpty)
    }

    func testCanonicalConflictWinnerCanReplaceMirrorWithoutSuppressingWinnerOrCopy() throws {
        let a = root(), b = root(); defer { try? FileManager.default.removeItem(at: a); try? FileManager.default.removeItem(at: b) }
        let source = try KnowledgeCache(root: a, scope: scope()), target = try KnowledgeCache(root: b, scope: scope())
        let loser = ChatEntry(project: "General", role: "user", text: "loser preserved as copy")
        var winner = loser; winner.text = "canonical winner"
        var copy = loser; copy.id = UUID()
        _ = try target.captureSavedState(SavedState(notes: [], chats: [loser]))
        let canonical = SavedState(notes: [], chats: [winner, copy])
        _ = try source.captureSavedState(canonical)
        try target.applySyncSnapshot(source.syncSnapshot(), canonicalState: canonical)
        XCTAssertEqual(Set(try target.entries().map(\.text)), Set([winner.text, copy.text]))
        XCTAssertTrue(try target.syncSnapshot().suppressedIDs.isEmpty)
        XCTAssertEqual(try target.search("canonical winner").first?.entry.text, winner.text)
        XCTAssertEqual(try target.search("loser preserved").first?.entry.id, "chat:" + copy.id.uuidString.lowercased())
    }

    func testCanonicalMirrorReplacementRejectsWrongProjectRoleDateAndMissingID() throws {
        let a = root(), b = root(); defer { try? FileManager.default.removeItem(at: a); try? FileManager.default.removeItem(at: b) }
        let source = try KnowledgeCache(root: a, scope: scope()), target = try KnowledgeCache(root: b, scope: scope())
        let original = ChatEntry(project: "General", role: "user", text: "original")
        var winner = original; winner.text = "winner"
        _ = try target.captureSavedState(SavedState(notes: [], chats: [original]))
        _ = try source.captureSavedState(SavedState(notes: [], chats: [winner]))
        let snapshot = try source.syncSnapshot()
        var wrongProject = winner; wrongProject.project = "Other"
        var wrongRole = winner; wrongRole.role = "assistant"
        var wrongDate = winner; wrongDate.date = winner.date.addingTimeInterval(1)
        var wrongID = winner; wrongID.id = UUID()
        for invalid in [wrongProject, wrongRole, wrongDate, wrongID] {
            XCTAssertThrowsError(try target.applySyncSnapshot(snapshot, canonicalState: SavedState(notes: [], chats: [invalid])))
            XCTAssertEqual(try target.entries().map(\.text), [original.text])
        }
        XCTAssertThrowsError(try target.applySyncSnapshot(snapshot)) { XCTAssertEqual($0 as? KnowledgeFailure, .changedSource) }
    }

    func testCanonicalWinnerCannotOverrideAnExistingDeletionMarker() throws {
        let a = root(), b = root(); defer { try? FileManager.default.removeItem(at: a); try? FileManager.default.removeItem(at: b) }
        let source = try KnowledgeCache(root: a, scope: scope()), target = try KnowledgeCache(root: b, scope: scope())
        let chat = ChatEntry(project: "General", role: "user", text: "canonical but deleted cache")
        let canonical = SavedState(notes: [], chats: [chat])
        _ = try source.captureSavedState(canonical)
        try target.applySyncSnapshot(source.syncSnapshot())
        try target.delete(id: "chat:" + chat.id.uuidString.lowercased())
        try target.applySyncSnapshot(source.syncSnapshot(), canonicalState: canonical)
        XCTAssertTrue(try target.entries().isEmpty)
    }

    func testModelNotifiesOnlyAfterCommittedChangesAndStopsAfterInvalidation() throws {
        let directory = root(); defer { try? FileManager.default.removeItem(at: directory) }
        var notifications = 0
        let selected = try scope()
        let model = KnowledgeLibraryModel(root: directory, scope: selected, onMutation: { notifications += 1 })
        let initial = notifications
        model.refresh()
        XCTAssertEqual(notifications, initial)
        let id = UUID(), date = Date()
        model.captureAction(id: id, kind: .question, status: .succeeded, expectedScope: selected, date: date)
        XCTAssertEqual(notifications, initial + 1)
        model.captureAction(id: id, kind: .question, status: .succeeded, expectedScope: selected, date: date)
        XCTAssertEqual(notifications, initial + 1)
        model.invalidate()
        model.captureAction(kind: .question, status: .succeeded, expectedScope: selected)
        XCTAssertEqual(notifications, initial + 1)
    }
}
