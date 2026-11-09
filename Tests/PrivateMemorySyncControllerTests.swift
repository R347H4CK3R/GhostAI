import XCTest
import Combine
@testable import AsterionVeyra

private final class SyncTestVault: PrivateMemorySyncVault {
    var value: PrivateMemorySyncSecrets?
    func load() throws -> PrivateMemorySyncSecrets? { value }
    func save(_ value: PrivateMemorySyncSecrets) throws { self.value = value }
    func delete() throws { value = nil }
}
private actor SyncTestServer {
    enum Mode { case normal, conflictOnce, uncertainOnce, holdFetch, vanishAfterSetup }
    let mode: Mode
    var encrypted: Data?
    var revision = 0
    var puts = 0
    var fetches = 0
    var held: CheckedContinuation<Void, Never>?
    var onHeld: (@Sendable () -> Void)?
    init(mode: Mode, encrypted: Data? = nil) { self.mode = mode; self.encrypted = encrypted }
    func setHeldCallback(_ callback: @escaping @Sendable () -> Void) { onHeld = callback }
    func release() { held?.resume(); held = nil }
    func counts() -> (Int, Int) { (puts, fetches) }
    func send(_ request: URLRequest) async throws -> PrivateMemorySyncResponse {
        if request.httpMethod == "PUT" {
            puts += 1
            if mode == .conflictOnce, puts == 1 { return .init(status: 409, data: Data()) }
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
            encrypted = try XCTUnwrap(Data(base64Encoded: XCTUnwrap(body["content"] as? String)))
            revision += 1
            if mode == .uncertainOnce, puts == 1 { throw PrivateMemorySyncFailure.unavailable }
            return .init(status: 200, data: Data("{\"content\":{\"sha\":\"\(String(repeating: "a", count: 40))\",\"path\":\"veyra-memory/v1.sync\"}}".utf8))
        }
        if request.url?.path.contains("/contents/") == true {
            fetches += 1
            if mode == .vanishAfterSetup, fetches > 1 { return .init(status: 404, data: Data()) }
            if mode == .holdFetch { await withCheckedContinuation { held = $0; onHeld?() } }
            guard let encrypted else { return .init(status: 404, data: Data()) }
            let sha = Self.sha(encrypted)
            let payload: [String: Any] = ["type": "file", "path": "veyra-memory/v1.sync", "sha": sha, "size": encrypted.count, "encoding": "base64", "content": encrypted.base64EncodedString()]
            return .init(status: 200, data: try JSONSerialization.data(withJSONObject: payload))
        }
        if request.url?.path == "/user" { return .init(status: 200, data: Data("{\"id\":456,\"login\":\"owner\"}".utf8)) }
        return .init(status: 200, data: Data("{\"id\":123,\"full_name\":\"owner/private-memory\",\"private\":true,\"default_branch\":\"main\",\"archived\":false,\"disabled\":false,\"owner\":{\"id\":456},\"permissions\":{\"push\":true}}".utf8))
    }
    private static func sha(_ data: Data) -> String {
        // Same standard Git object identity as the independent transport fixture.
        Insecure.SHA1.hash(data: Data("blob \(data.count)\0".utf8) + data).map { String(format: "%02x", $0) }.joined()
    }
}
import CryptoKit

@MainActor final class PrivateMemorySyncControllerTests: XCTestCase {
    private let passphrase = "synthetic shared recovery words"
    private func setupDisk(_ root: URL) throws {
        let disk = PrivateMemorySyncDisk(root: root)
        try disk.saveJournal(PrivateMemorySyncJournal(base: .empty(repositoryID: 123), pending: nil), passphrase: passphrase)
        try disk.saveConfiguration(.init(repository: "owner/private-memory", repositoryID: 123, accountID: 456, branch: "main", includePrivateWorkspaces: false))
    }
    private func vault() -> SyncTestVault {
        let value = SyncTestVault(); value.value = .init(token: "github_pat_SYNTHETIC_NOT_A_REAL_CREDENTIAL", passphrase: passphrase); return value
    }
    func testFreshInstallationWithoutSyncDirectoryStaysUnconfigured() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let controller = PrivateMemorySyncController(root: root, currentState: { SavedState(notes: [], chats: []) }, applyState: { _ in XCTFail("No sync should apply") }, collectKnowledge: { _, _ in [] }, applyKnowledge: { _, _, _ in }, vault: SyncTestVault())
        XCTAssertFalse(controller.isConfigured); XCTAssertFalse(controller.isEnabled)
        XCTAssertEqual(controller.statusTitle, "Private sync needs setup")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    func testUnreadableConfigurationAndMissingQueueCannotCreateANewBaseline() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let disk = PrivateMemorySyncDisk(root: root)
        try disk.saveConfiguration(.init(repository: "owner/private-memory", repositoryID: 123, accountID: 456, branch: "main", includePrivateWorkspaces: false))
        let corrupted = Data("unreadable configuration must remain preserved".utf8)
        try corrupted.write(to: disk.configurationURL)
        let emptyVault = SyncTestVault(), server = SyncTestServer(mode: .normal)
        let controller = PrivateMemorySyncController(root: root, currentState: { SavedState(notes: [], chats: []) }, applyState: { _ in XCTFail("Missing history must not apply") }, collectKnowledge: { _, _ in [] }, applyKnowledge: { _, _, _ in }, vault: emptyVault, transport: .init { request, _, _ in try await server.send(request) })
        XCTAssertTrue(controller.statusDetail.contains("readConfiguration"))
        XCTAssertTrue(controller.statusDetail.contains("decode"))
        XCTAssertFalse(controller.statusDetail.contains(root.path))
        controller.sceneBecameActive()
        defer { controller.sceneBecameInactive() }
        do {
            try await controller.setup(repo: "owner/private-memory", token: "github_pat_SYNTHETIC_NOT_A_REAL_CREDENTIAL", passphrase: passphrase, includePrivateWorkspaces: false, directInstallationConfirmed: true)
            XCTFail("An unreadable prior configuration is not a new installation")
        } catch { XCTAssertEqual(error as? PrivateMemorySyncFailure, .storage) }
        XCTAssertEqual(try Data(contentsOf: disk.configurationURL), corrupted)
        XCTAssertFalse(FileManager.default.fileExists(atPath: disk.journalURL.path))
        XCTAssertNil(emptyVault.value)
        XCTAssertFalse(controller.isConfigured); XCTAssertFalse(controller.isEnabled)
        let counts = await server.counts(); XCTAssertEqual(counts.0, 0)
    }
    func testRecoveryReviewWithoutCredentialsPersistsPauseAndAllowsExplicitReconnect() async throws {
        for disconnectFirst in [false, true] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            try setupDisk(root)
            let disk = PrivateMemorySyncDisk(root: root)
            var config = try XCTUnwrap(disk.loadConfiguration())
            config.enabled = false; config.localRecoveryNeedsReview = true; try disk.saveConfiguration(config)
            let emptyVault = SyncTestVault(), server = SyncTestServer(mode: .normal)
            let controller = PrivateMemorySyncController(root: root, currentState: { SavedState(notes: [], chats: []) }, applyState: { _ in }, collectKnowledge: { _, _ in [] }, applyKnowledge: { _, _, _ in }, vault: emptyVault, transport: .init { request, _, _ in try await server.send(request) })
            if disconnectFirst {
                controller.disconnect()
                XCTAssertFalse(controller.isConfigured)
                XCTAssertEqual(controller.configuration?.localRecoveryNeedsReview, true)
            }
            controller.resume(afterLocalRecoveryReview: true)
            let reviewed = try XCTUnwrap(disk.loadConfiguration())
            XCTAssertNil(reviewed.localRecoveryNeedsReview)
            XCTAssertFalse(reviewed.enabled)
            XCTAssertNil(controller.configuration?.localRecoveryNeedsReview)
            XCTAssertFalse(controller.isEnabled); XCTAssertFalse(controller.isConfigured)
            let beforeReconnect = await server.counts()
            XCTAssertEqual(beforeReconnect.0, 0); XCTAssertEqual(beforeReconnect.1, 0)
            controller.sceneBecameActive()
            try await controller.setup(repo: "owner/private-memory", token: "github_pat_SYNTHETIC_NOT_A_REAL_CREDENTIAL", passphrase: passphrase, includePrivateWorkspaces: false, directInstallationConfirmed: true)
            XCTAssertTrue(controller.isConfigured)
            XCTAssertTrue(controller.isEnabled) // Enabled only by the separately authorized setup.
            XCTAssertNotNil(emptyVault.value)
            XCTAssertNil(try disk.loadConfiguration()?.localRecoveryNeedsReview)
            controller.sceneBecameInactive()
        }
    }
    func testConflictRefetchesAndPreservesTheNewestLocalSave() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try setupDisk(root)
        let server = SyncTestServer(mode: .conflictOnce)
        var state = SavedState(notes: [MemoryNote(project: "General", text: "Local decision", source: "User note")], chats: [])
        let controller = PrivateMemorySyncController(root: root, currentState: { state }, applyState: { state = $0 }, collectKnowledge: { _, _ in [] }, applyKnowledge: { _, _, _ in }, vault: vault(), transport: .init { request, _, _ in try await server.send(request) })
        let completed = expectation(description: "Sync after CAS refetch")
        let observation = controller.$statusTitle.sink { if $0 == "Private memory is up to date" { completed.fulfill() } }
        defer { observation.cancel(); controller.sceneBecameInactive() }
        controller.sceneBecameActive()
        await fulfillment(of: [completed], timeout: 30)
        let counts = await server.counts(); XCTAssertEqual(counts.0, 2); XCTAssertEqual(counts.1, 2)
        XCTAssertEqual(state.notes.map(\.text), ["Local decision"])
        XCTAssertFalse(controller.pendingChanges)
    }
    func testUncertainWriteIsReadBackInsteadOfDuplicated() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try setupDisk(root)
        let server = SyncTestServer(mode: .uncertainOnce)
        var state = SavedState(notes: [MemoryNote(project: "General", text: "Durable queued note", source: "User note")], chats: [])
        let controller = PrivateMemorySyncController(root: root, currentState: { state }, applyState: { state = $0 }, collectKnowledge: { _, _ in [] }, applyKnowledge: { _, _, _ in }, vault: vault(), transport: .init { request, _, _ in try await server.send(request) })
        let queued = expectation(description: "Uncertain result queued"), complete = expectation(description: "Read-back converged")
        var sawQueued = false
        let observation = controller.$statusTitle.sink {
            if $0 == "Changes queued for retry", !sawQueued { sawQueued = true; queued.fulfill() }
            if $0 == "Private memory is up to date" { complete.fulfill() }
        }
        defer { observation.cancel(); controller.sceneBecameInactive() }
        controller.sceneBecameActive()
        await fulfillment(of: [queued], timeout: 30)
        // Pause invalidates the old operation; explicit resume reads back the uncertain
        // result immediately instead of blindly retrying that PUT after the cooldown.
        controller.pause(); controller.resume()
        await fulfillment(of: [complete], timeout: 30)
        let counts = await server.counts(); XCTAssertEqual(counts.0, 1)
        XCTAssertEqual(state.notes.count, 1)
    }
    func testLocalEditDuringFetchIsIncludedInsteadOfOverwritten() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try setupDisk(root)
        let server = SyncTestServer(mode: .holdFetch)
        let held = expectation(description: "Awaiting remote response")
        await server.setHeldCallback { held.fulfill() }
        var state = SavedState(notes: [MemoryNote(project: "General", text: "Before await", source: "User note")], chats: [])
        let controller = PrivateMemorySyncController(root: root, currentState: { state }, applyState: { state = $0 }, collectKnowledge: { _, _ in [] }, applyKnowledge: { _, _, _ in }, vault: vault(), transport: .init { request, _, _ in try await server.send(request) })
        let complete = expectation(description: "Latest local edit synchronized")
        let observation = controller.$statusTitle.sink { if $0 == "Private memory is up to date" { complete.fulfill() } }
        defer { observation.cancel(); controller.sceneBecameInactive() }
        controller.sceneBecameActive(); await fulfillment(of: [held], timeout: 30)
        state.notes.append(MemoryNote(project: "General", text: "Saved during network wait", source: "User note"))
        controller.localStateChanged(); await server.release()
        await fulfillment(of: [complete], timeout: 30)
        XCTAssertEqual(Set(state.notes.map(\.text)), ["Before await", "Saved during network wait"])
        let journal = try XCTUnwrap(PrivateMemorySyncDisk(root: root).loadJournal(passphrase: passphrase, repositoryID: 123))
        XCTAssertEqual(Set(journal.base.notes.map(\.text)), ["Before await", "Saved during network wait"])
    }
    func testBackgroundCancellationRejectsLateDownloadedState() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try setupDisk(root)
        let remote = PrivateMemorySyncDocument(repositoryID: 123, notes: [MemoryNote(project: "General", text: "Remote only", source: "User note")], chats: [], knowledge: [], tombstones: [])
        let encrypted = try EncryptedMemoryTransfer.encryptSyncPayload(remote.encoded(), passphrase: passphrase)
        let server = SyncTestServer(mode: .holdFetch, encrypted: encrypted)
        let held = expectation(description: "Remote response held")
        await server.setHeldCallback { held.fulfill() }
        let applied = expectation(description: "Late remote state must not apply"); applied.isInverted = true
        let controller = PrivateMemorySyncController(root: root, currentState: { SavedState(notes: [], chats: []) }, applyState: { _ in applied.fulfill() }, collectKnowledge: { _, _ in [] }, applyKnowledge: { _, _, _ in }, vault: vault(), transport: .init { request, _, _ in try await server.send(request) })
        controller.sceneBecameActive(); await fulfillment(of: [held], timeout: 30)
        controller.sceneBecameInactive(); await server.release()
        await fulfillment(of: [applied], timeout: 0.3)
        let counts = await server.counts(); XCTAssertEqual(counts.0, 0)
    }
    func testVaultSeenDuringSetupCannotBeRecreatedAfterFirstSync404() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var remote = PrivateMemorySyncDocument.empty(repositoryID: 123)
        remote.tombstones = ["note:12345678-1234-4234-8234-123456789012"]
        let encrypted = try EncryptedMemoryTransfer.encryptSyncPayload(remote.encoded(), passphrase: passphrase)
        let server = SyncTestServer(mode: .vanishAfterSetup, encrypted: encrypted)
        let local = SavedState(notes: [MemoryNote(project: "General", text: "Do not recreate a deleted vault", source: "User note")], chats: [])
        let controller = PrivateMemorySyncController(root: root, currentState: { local }, applyState: { _ in XCTFail("A vanished vault cannot apply") }, collectKnowledge: { _, _ in [] }, applyKnowledge: { _, _, _ in }, vault: vault(), transport: .init { request, _, _ in try await server.send(request) })
        let blocked = expectation(description: "Observed vault disappeared")
        let observation = controller.$statusTitle.sink { if $0 == "Sync needs attention" { blocked.fulfill() } }
        defer { observation.cancel(); controller.sceneBecameInactive() }
        controller.sceneBecameActive()
        try await controller.setup(repo: "owner/private-memory", token: "github_pat_SYNTHETIC_NOT_A_REAL_CREDENTIAL", passphrase: passphrase, includePrivateWorkspaces: false, directInstallationConfirmed: true)
        await fulfillment(of: [blocked], timeout: 30)
        XCTAssertTrue(try XCTUnwrap(PrivateMemorySyncDisk(root: root).loadConfiguration()).hasObservedRemoteVault)
        let counts = await server.counts(); XCTAssertEqual(counts.0, 0); XCTAssertEqual(counts.1, 2)
    }
    func testMissingCanonicalOwnerFailsClosedWithoutEmptyDeletionSnapshot() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try setupDisk(root)
        let server = SyncTestServer(mode: .normal)
        let controller = PrivateMemorySyncController(root: root, currentState: { throw PrivateMemorySyncFailure.storage }, applyState: { _ in XCTFail("Owner unavailable") }, collectKnowledge: { _, _ in [] }, applyKnowledge: { _, _, _ in }, vault: vault(), transport: .init { request, _, _ in try await server.send(request) })
        let blocked = expectation(description: "Missing owner blocked")
        let observation = controller.$statusTitle.sink { if $0 == "Sync needs attention" { blocked.fulfill() } }
        defer { observation.cancel(); controller.sceneBecameInactive() }
        controller.sceneBecameActive(); await fulfillment(of: [blocked], timeout: 30)
        let counts = await server.counts(); XCTAssertEqual(counts.0, 0); XCTAssertEqual(counts.1, 0)
        let journal = try XCTUnwrap(PrivateMemorySyncDisk(root: root).loadJournal(passphrase: passphrase, repositoryID: 123))
        XCTAssertNil(journal.pending)
    }
    func testConfiguredVaultWithMissingQueueDoesNotResurrectRemoteMemory() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let disk = PrivateMemorySyncDisk(root: root)
        var config = PrivateMemorySyncConfiguration(repository: "owner/private-memory", repositoryID: 123, accountID: 456, branch: "main", includePrivateWorkspaces: false)
        config.lastSyncedAt = Date(); config.hasObservedRemoteVault = true
        try disk.saveConfiguration(config) // Deliberately no queue: deletion history lost.
        let server = SyncTestServer(mode: .normal)
        let controller = PrivateMemorySyncController(root: root, currentState: { SavedState(notes: [], chats: []) }, applyState: { _ in XCTFail("Must not resurrect") }, collectKnowledge: { _, _ in [] }, applyKnowledge: { _, _, _ in }, vault: vault(), transport: .init { request, _, _ in try await server.send(request) })
        let blocked = expectation(description: "Missing queue blocked")
        let observation = controller.$statusTitle.sink { if $0 == "Sync needs attention" { blocked.fulfill() } }
        defer { observation.cancel(); controller.sceneBecameInactive() }
        controller.sceneBecameActive(); await fulfillment(of: [blocked], timeout: 30)
        let counts = await server.counts(); XCTAssertEqual(counts.0, 0); XCTAssertEqual(counts.1, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: disk.journalURL.path))
    }
    func testCorruptJournalBlocksBeforeAnyNetworkAndDisconnectRemovesCredential() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try setupDisk(root); try Data("corrupt queue".utf8).write(to: PrivateMemorySyncDisk(root: root).journalURL)
        let vault = vault(), server = SyncTestServer(mode: .normal)
        let controller = PrivateMemorySyncController(root: root, currentState: { SavedState(notes: [], chats: []) }, applyState: { _ in XCTFail("Must not apply") }, collectKnowledge: { _, _ in [] }, applyKnowledge: { _, _, _ in }, vault: vault, transport: .init { request, _, _ in try await server.send(request) })
        let blocked = expectation(description: "Corrupt journal blocked")
        let observation = controller.$statusTitle.sink { if $0 == "Sync needs attention" { blocked.fulfill() } }
        defer { observation.cancel(); controller.sceneBecameInactive() }
        controller.sceneBecameActive(); await fulfillment(of: [blocked], timeout: 30)
        let counts = await server.counts(); XCTAssertEqual(counts.0, 0); XCTAssertEqual(counts.1, 0)
        controller.disconnect(); XCTAssertNil(vault.value); XCTAssertFalse(controller.isConfigured)
        XCTAssertTrue(FileManager.default.fileExists(atPath: PrivateMemorySyncDisk(root: root).journalURL.path))
    }
}
