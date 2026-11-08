import Foundation
import Combine

/// Owns a single coalesced encrypted outbox. No model/tool can enable sync, change its
/// destination, obtain credentials, or invoke an arbitrary GitHub write through this type.
@MainActor final class PrivateMemorySyncController: ObservableObject {
    @Published private(set) var statusTitle = "Private sync needs setup"
    @Published private(set) var statusDetail = "Notes, chats and eligible saved knowledge stay on this device until you connect your private vault."
    @Published private(set) var isConfigured = false
    @Published private(set) var isEnabled = false
    @Published private(set) var isWorking = false
    @Published private(set) var lastSyncedAt: Date?
    @Published private(set) var pendingChanges = false
    @Published private(set) var configuration: PrivateMemorySyncConfiguration?
    @Published private(set) var unresolvedLegacyLibraries = 0
    @Published private(set) var syncedDocumentBytes: Int?
    func reportUnresolvedLegacyLibraries(_ count: Int) { unresolvedLegacyLibraries = max(0, count) }
    private let disk: PrivateMemorySyncDisk
    private let vault: any PrivateMemorySyncVault
    private let transport: PrivateMemorySyncTransport
    private let currentState: () throws -> SavedState
    private let applyState: (SavedState) throws -> Void
    private let collectKnowledge: (Bool, Int) throws -> [KnowledgeSyncSnapshot]
    private let applyKnowledge: ([KnowledgeSyncSnapshot], Bool, Int) throws -> Void
    private var operation: Task<Void, Never>?
    private var scheduled: Task<Void, Never>?
    private var session: GitHubAuthSession?
    private var generation = UUID()
    private var active = false
    private var blocked = false
    private var retryAfter: Date?
    private var serverRetryAfter: Date?
    private var applying = false
    private var localRevision: UInt64 = 0
    private var verifiedImportHistory: PrivateMemorySyncDocument?
    private var configurationUnreadable = false

    init(root: URL, currentState: @escaping () throws -> SavedState,
         applyState: @escaping (SavedState) throws -> Void,
         collectKnowledge: @escaping (Bool, Int) throws -> [KnowledgeSyncSnapshot],
         applyKnowledge: @escaping ([KnowledgeSyncSnapshot], Bool, Int) throws -> Void,
         vault: any PrivateMemorySyncVault = PrivateMemorySyncKeychain(), transport: PrivateMemorySyncTransport = .live) {
        disk = PrivateMemorySyncDisk(root: root); self.vault = vault; self.transport = transport
        self.currentState = currentState; self.applyState = applyState
        self.collectKnowledge = collectKnowledge; self.applyKnowledge = applyKnowledge
        do {
            configuration = try disk.loadConfiguration()
            if let configuration {
                isConfigured = true; isEnabled = configuration.enabled && configuration.localRecoveryNeedsReview != true; lastSyncedAt = configuration.lastSyncedAt
                statusTitle = configuration.localRecoveryNeedsReview == true ? "Recovered memory is local only" : (isEnabled ? "Ready to sync" : "Private sync paused")
                statusDetail = configuration.localRecoveryNeedsReview == true ? PrivateMemorySyncFailure.recoveryReviewRequired.localizedDescription : "Encrypted notes, chats and saved knowledge use \(configuration.repository). Credentials and settings stay local."
            }
        } catch { configurationUnreadable = true; blocked = true; statusTitle = "Sync needs attention"; statusDetail = PrivateMemorySyncFailure.storage.localizedDescription }
    }
    deinit { operation?.cancel(); scheduled?.cancel(); session?.revoke() }

    /// Synchronous validation uses only already verified history; no Keychain read or
    /// expensive decryption happens on the importing view's main-actor callback.
    func prepareConfirmedImport(_ incoming: SavedState, current: SavedState) throws -> SavedState {
        guard !configurationUnreadable else { throw PrivateMemorySyncFailure.importHistoryUnavailable }
        guard let configuration else { return incoming }
        guard configuration.localRecoveryNeedsReview != true else { throw PrivateMemorySyncFailure.recoveryReviewRequired }
        guard let history = verifiedImportHistory else { throw PrivateMemorySyncFailure.importHistoryUnavailable }
        return try PrivateMemorySyncRestore.prepare(incoming, current: current, history: history)
    }

    /// Explicit setup consent includes this device-only credential storage and recurring
    /// writes to the verified repository. Validation happens before storing credentials.
    func setup(repo: String, token: String, passphrase: String, includePrivateWorkspaces: Bool,
               directInstallationConfirmed: Bool) async throws {
        guard directInstallationConfirmed else { throw GitHubAccessError.directInstallRequired }
        guard !isWorking else { throw PrivateMemorySyncFailure.unavailable }
        guard passphrase.count >= 12, passphrase.utf8.count <= 4096,
              !passphrase.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw EncryptedMemoryTransfer.Failure.passphrase }
        invalidate(); let id = generation
        let auth = try GitHubAuthSession(token: token)
        session = auth; isWorking = true
        defer { auth.revoke(); if generation == id { session = nil; isWorking = false } }
        do {
            let client = PrivateMemorySyncClient(auth: auth, transport: transport)
            var config = try await client.verifySetup(repository: repo, includePrivateWorkspaces: includePrivateWorkspaces)
            try check(id)
            if let previous = configuration {
                guard previous.repositoryID == config.repositoryID, previous.repository == config.repository,
                      previous.accountID == config.accountID, previous.branch == config.branch else { throw PrivateMemorySyncFailure.repositoryChanged }
                guard previous.includePrivateWorkspaces == includePrivateWorkspaces else { throw PrivateMemorySyncFailure.consent }
                config.lastSyncedAt = previous.lastSyncedAt
                config.hasObservedRemoteVault = previous.hasObservedRemoteVault
                config.localRecoveryNeedsReview = previous.localRecoveryNeedsReview
            }
            let remote = try await client.fetch(config); try check(id)
            var remoteDocument: PrivateMemorySyncDocument?
            if let encrypted = remote.encrypted {
                config.hasObservedRemoteVault = true
                let decoded = try await decode(encrypted, passphrase: passphrase, repositoryID: config.repositoryID)
                try check(id); try validateScope(decoded, configuration: config)
                remoteDocument = decoded
            }
            let disk = self.disk, repositoryID = config.repositoryID
            let restored = try await Task.detached(priority: .utility) { try disk.loadJournal(passphrase: passphrase, repositoryID: repositoryID) }.value
            try check(id)
            let empty = PrivateMemorySyncDocument.empty(repositoryID: config.repositoryID, privateWorkspaces: includePrivateWorkspaces)
            guard (configuration == nil && !configurationUnreadable) || restored != nil else { throw PrivateMemorySyncFailure.storage }
            var journal = restored ?? PrivateMemorySyncJournal(base: empty, pending: nil)
            try validateScope(journal.base, configuration: config)
            if let pending = journal.pending { try validateScope(pending, configuration: config) }
            if let remoteDocument {
                // Persist observed deletion IDs even before the first full sync. Keep
                // remote content out of a new device's baseline to avoid false deletions.
                journal.base = try PrivateMemorySyncRestore.addingRemoteMarkers(remoteDocument, to: journal.base)
                if let pending = journal.pending { journal.pending = try PrivateMemorySyncRestore.addingRemoteMarkers(remoteDocument, to: pending) }
            }
            let importHistory = journal.pending ?? journal.base
            // A new device starts with an empty baseline, even if a remote vault exists.
            // Otherwise its empty local state would be mistaken for a mass deletion.
            try await save(journal, passphrase: passphrase, id: id); try check(id)
            config.enabled = false; try disk.saveConfiguration(config)
            do {
                try vault.save(PrivateMemorySyncSecrets(token: token, passphrase: passphrase))
                config.enabled = config.localRecoveryNeedsReview != true; try disk.saveConfiguration(config)
            } catch {
                // Disabled configuration is durable before storing credentials. A failed
                // setup can never leave a newly authorized unattended sync running.
                try? vault.delete(); throw PrivateMemorySyncFailure.storage
            }
            verifiedImportHistory = importHistory
            configuration = config; configurationUnreadable = false; isConfigured = true; isEnabled = config.enabled; blocked = false; retryAfter = nil
            statusTitle = config.localRecoveryNeedsReview == true ? "Recovered memory is local only" : "Private sync connected"
            statusDetail = config.localRecoveryNeedsReview == true ? PrivateMemorySyncFailure.recoveryReviewRequired.localizedDescription : "The next sync will merge encrypted notes, chats and eligible saved knowledge."
            pendingChanges = true
        } catch {
            if generation == id { statusTitle = "Setup did not complete"; statusDetail = safeMessage(error) }
            throw error
        }
        // The setup task has finished its revocable network session; use a fresh one.
        session = nil; isWorking = false
        if active { schedule(after: 0) }
    }
    func localStateChanged() {
        guard !applying else { return }
        localRevision &+= 1
        pendingChanges = true
        if isEnabled, !blocked { schedule(after: 2) }
    }
    func sceneBecameActive() { active = true; if isEnabled, !blocked { syncNow(force: false) } }
    func sceneBecameInactive() {
        active = false; invalidate(); isWorking = false
        if isEnabled { statusTitle = "Waiting for app activity"; statusDetail = "Local saves continue. Sync resumes when the app is active and unlocked; iOS can suspend background work." }
    }
    func networkBecameAvailable() { if active, isEnabled, !blocked { schedule(after: 1) } }
    func syncNow(force: Bool = true) {
        guard active, isEnabled, isConfigured, operation == nil, !isWorking,
              configuration?.localRecoveryNeedsReview != true else { return }
        if let serverRetryAfter, serverRetryAfter > Date() {
            statusTitle = "Changes queued for retry"; statusDetail = "GitHub’s retry window is still active. Sync will resume automatically afterward."
            schedule(after: serverRetryAfter.timeIntervalSinceNow); return
        }
        if force { blocked = false; retryAfter = nil }
        guard !blocked else { return }
        if !force, let retryAfter, retryAfter > Date() { schedule(after: retryAfter.timeIntervalSinceNow); return }
        scheduled?.cancel(); scheduled = nil
        let id = generation
        operation = Task { [weak self] in
            guard let self else { return }
            await self.performSync(id: id, force: force)
            if self.generation == id {
                self.operation = nil
                if self.active, self.isEnabled, !self.blocked { self.schedule(after: self.pendingChanges ? 3 : 60) }
            }
        }
    }
    func pause() {
        invalidate(); isWorking = false
        guard var config = configuration else { return }
        config.enabled = false
        do { try disk.saveConfiguration(config); configuration = config; isEnabled = false
            statusTitle = "Private sync paused"; statusDetail = "Local data and the encrypted queue are preserved. Nothing is uploaded until you resume."
        } catch { blocked = true; isEnabled = false; statusTitle = "Pause could not be saved"; statusDetail = "Sync is stopped in this session. Reopen settings and retry Pause before closing the app." }
    }
    func resume(afterLocalRecoveryReview: Bool = false) {
        guard var config = configuration else { return }
        do {
            guard config.localRecoveryNeedsReview != true || afterLocalRecoveryReview else { throw PrivateMemorySyncFailure.recoveryReviewRequired }
            if afterLocalRecoveryReview {
                // Record the explicit review before touching credentials. Missing or
                // removed credentials must not trap recovery behind an invisible gate.
                invalidate(); isWorking = false; isEnabled = false
                config.localRecoveryNeedsReview = nil; config.enabled = false
                try disk.saveConfiguration(config)
                configuration = config
            }
            guard try vault.load() != nil else { isConfigured = false; throw PrivateMemorySyncFailure.credentials }
            config.enabled = true; try disk.saveConfiguration(config)
            configuration = config; isConfigured = true; isEnabled = true; blocked = false; retryAfter = nil
            syncNow()
        } catch { statusTitle = "Reconnect private sync"; statusDetail = safeMessage(error) }
    }
    func disconnect() {
        pause()
        do {
            try vault.delete(); isConfigured = false; isEnabled = false; blocked = false
            statusTitle = "Private sync disconnected"
            statusDetail = "This device’s sync credentials were removed. Local memory, the encrypted queue and GitHub history are preserved. Reconnect to the same vault with the original passphrase."
        } catch { statusTitle = "Credential removal needs attention"; statusDetail = safeMessage(error) }
    }
    func cancelSetup() { if isWorking, operation == nil { invalidate(); isWorking = false; statusTitle = "Setup cancelled" } }
    private func invalidate() {
        generation = UUID(); operation?.cancel(); operation = nil; scheduled?.cancel(); scheduled = nil; session?.revoke(); session = nil
    }
    private func check(_ id: UUID) throws { try Task.checkCancellation(); guard generation == id, active else { throw CancellationError() } }
    private func schedule(after seconds: TimeInterval) {
        guard active, isEnabled, !blocked, operation == nil else { return }
        scheduled?.cancel()
        let delay = max(seconds, max(retryAfter?.timeIntervalSinceNow ?? 0, 0))
        scheduled = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(min(delay, 86_400) * 1_000_000_000))
            guard !Task.isCancelled else { return }; self?.scheduled = nil; self?.syncNow(force: false)
        }
    }
    private func performSync(id: UUID, force: Bool) async {
        guard var config = configuration else { return }
        isWorking = true; statusTitle = "Syncing encrypted memory"; statusDetail = "Verifying the private repository and merging saved changes."
        var journal: PrivateMemorySyncJournal?
        var secrets: PrivateMemorySyncSecrets?
        var operationSession: GitHubAuthSession?
        defer { operationSession?.revoke(); if generation == id { session = nil; isWorking = false } }
        do {
            guard let stored = try vault.load() else { isConfigured = false; throw PrivateMemorySyncFailure.credentials }
            secrets = stored
            let disk = self.disk, repositoryID = config.repositoryID
            journal = try await Task.detached(priority: .utility) { try disk.loadJournal(passphrase: stored.passphrase, repositoryID: repositoryID) }.value
            try check(id)
            // Setup writes the journal before enabling a configuration. Its absence is
            // lost deletion history, never permission to invent an empty baseline.
            guard let loadedJournal = journal else { throw PrivateMemorySyncFailure.storage }
            verifiedImportHistory = loadedJournal.pending ?? loadedJournal.base
            if let next = journal?.serverRetryAfter, next > Date() {
                serverRetryAfter = next; retryAfter = max(next, journal?.retryAfter ?? next)
                pendingChanges = journal?.pending != nil; statusTitle = "Changes queued for retry"
                statusDetail = "GitHub’s retry window is still active. Sync will resume automatically afterward."; return
            }
            if !force, let next = journal?.retryAfter, next > Date() {
                retryAfter = next; pendingChanges = journal?.pending != nil; statusTitle = "Changes queued"; statusDetail = "Automatic retry is scheduled after GitHub’s cooldown."; return
            }
            let auth = try GitHubAuthSession(token: stored.token); session = auth; operationSession = auth
            let client = PrivateMemorySyncClient(auth: auth, transport: transport)
            for _ in 0..<3 {
                try check(id)
                guard var queue = journal else { throw PrivateMemorySyncFailure.storage }
                try validateScope(queue.base, configuration: config)
                if let pending = queue.pending { try validateScope(pending, configuration: config) }
                let local = try capture(previous: queue.pending ?? queue.base, configuration: config)
                queue.pending = local; journal = queue; pendingChanges = true
                try await save(queue, passphrase: stored.passphrase, id: id); try check(id)
                let fetched = try await client.fetch(config); try check(id)
                let remote: PrivateMemorySyncDocument
                if let encrypted = fetched.encrypted {
                    config.hasObservedRemoteVault = true
                    try disk.saveConfiguration(config); configuration = config
                    remote = try await decode(encrypted, passphrase: stored.passphrase, repositoryID: config.repositoryID)
                }
                else {
                    // A disappearing existing vault is not permission to recreate it. Its
                    // deletion history might have been lost; stop instead of resurrecting.
                    guard queue.base.notes.isEmpty, queue.base.chats.isEmpty, queue.base.knowledge.isEmpty,
                          queue.base.tombstones.isEmpty, config.lastSyncedAt == nil, !config.hasObservedRemoteVault else { throw PrivateMemorySyncFailure.repositoryChanged }
                    remote = .empty(repositoryID: config.repositoryID, privateWorkspaces: config.includePrivateWorkspaces)
                }
                try check(id); try validateScope(remote, configuration: config)
                verifiedImportHistory = try PrivateMemorySyncRestore.addingRemoteMarkers(remote, to: queue.pending ?? queue.base)
                let current = try capture(previous: local, configuration: config)
                var merged = try PrivateMemorySyncMerge.merge(base: queue.base, local: current, remote: remote)
                merged = try suppressDeletedChatMirrors(in: merged)
                // Apply canonical memory first. If cache application fails later, the next
                // merge sees these durable canonical records and never treats them as lost.
                applying = true
                do {
                    try applyState(stateForApplication(merged, configuration: config))
                    try applyKnowledge(merged.knowledge, config.includePrivateWorkspaces, config.accountID)
                    applying = false
                } catch { applying = false; throw error }
                queue.base = remote; queue.pending = merged; journal = queue
                verifiedImportHistory = merged
                try await save(queue, passphrase: stored.passphrase, id: id); try check(id)
                let raw = try merged.encoded()
                if fetched.encrypted == nil || raw != (try remote.encoded()) {
                    let encrypted = try await Task.detached(priority: .utility) { try EncryptedMemoryTransfer.encryptSyncPayload(raw, passphrase: stored.passphrase) }.value
                    try check(id)
                    let committed = try await client.put(encrypted, configuration: config, expectedSHA: fetched.sha)
                    try check(id)
                    if !committed { continue }
                }
                queue.base = merged; queue.pending = nil; queue.attempts = 0; queue.retryAfter = nil; queue.serverRetryAfter = nil
                let capturedRevision = localRevision
                let latest = try capture(previous: merged, configuration: config)
                if try latest.encoded() != merged.encoded() { queue.pending = latest }
                journal = queue
                verifiedImportHistory = queue.pending ?? queue.base
                try await save(queue, passphrase: stored.passphrase, id: id); try check(id)
                config.lastSyncedAt = Date(); config.hasObservedRemoteVault = true; try disk.saveConfiguration(config)
                configuration = config; lastSyncedAt = config.lastSyncedAt; retryAfter = nil; serverRetryAfter = nil
                pendingChanges = queue.pending != nil || localRevision != capturedRevision
                syncedDocumentBytes = raw.count
                statusTitle = pendingChanges ? "New changes queued" : (unresolvedLegacyLibraries > 0 ? "Eligible memory synced" : "Private memory is up to date")
                statusDetail = unresolvedLegacyLibraries > 0
                    ? "\(unresolvedLegacyLibraries) older libraries remain only on this device. Open their original projects to include them."
                    : "Encrypted notes, chats, saved research, selected text files and activity copies are included within the approved scope. Credentials and device settings are excluded."
                return
            }
            throw PrivateMemorySyncFailure.unavailable
        } catch is CancellationError { return }
        catch {
            guard generation == id else { return }
            let serverCooldown = error as? PrivateMemorySyncCooldown
            let failure = (error as? PrivateMemorySyncFailure) ?? (serverCooldown == nil ? nil : .rateLimited)
            let retryable = failure?.isRetryable == true
            pendingChanges = true; blocked = !retryable
            if retryable, var queue = journal, let secrets {
                queue.attempts = min(queue.attempts + 1, 100)
                let minimum: Double = failure == .rateLimited ? 300 : 30
                let delay = min(3600, minimum * pow(2, Double(min(queue.attempts - 1, 7)))) + Double.random(in: 0...15)
                queue.serverRetryAfter = serverCooldown?.until; serverRetryAfter = serverCooldown?.until
                queue.retryAfter = max(Date().addingTimeInterval(delay), serverCooldown?.until ?? Date()); retryAfter = queue.retryAfter
                do { try await save(queue, passphrase: secrets.passphrase, id: id) }
                catch { blocked = true; statusTitle = "Sync queue needs attention"; statusDetail = PrivateMemorySyncFailure.storage.localizedDescription; return }
            }
            guard generation == id else { return }
            statusTitle = retryable ? "Changes queued for retry" : "Sync needs attention"
            statusDetail = safeMessage(error)
        }
    }
    private func capture(previous: PrivateMemorySyncDocument, configuration: PrivateMemorySyncConfiguration) throws -> PrivateMemorySyncDocument {
        var state = try currentState()
        state.notes = state.notes.filter { permittedProject($0.project, configuration: configuration) }
        state.chats = state.chats.filter { permittedProject($0.project, configuration: configuration) }
        let knowledge = try collectKnowledge(configuration.includePrivateWorkspaces, configuration.accountID)
        return try PrivateMemorySyncMerge.capture(state: state, knowledge: knowledge, previous: previous,
            includePrivateWorkspaces: configuration.includePrivateWorkspaces)
    }
    private func permittedProject(_ project: String, configuration: PrivateMemorySyncConfiguration) -> Bool {
        guard project.hasPrefix("GitHub account ") else { return true }
        guard configuration.includePrivateWorkspaces, let scope = try? KnowledgeWorkspacePolicy.scope(workspace: project) else { return false }
        return scope.accountID == "github-user-\(configuration.accountID)"
    }
    private func validateScope(_ value: PrivateMemorySyncDocument, configuration: PrivateMemorySyncConfiguration) throws {
        guard value.includesPrivateWorkspaces == configuration.includePrivateWorkspaces,
              value.notes.allSatisfy({ permittedProject($0.project, configuration: configuration) }),
              value.chats.allSatisfy({ permittedProject($0.project, configuration: configuration) }),
              value.knowledge.allSatisfy({ permittedProject($0.project, configuration: configuration) }) else { throw PrivateMemorySyncFailure.consent }
    }
    private func stateForApplication(_ document: PrivateMemorySyncDocument, configuration: PrivateMemorySyncConfiguration) throws -> SavedState {
        let current = try currentState()
        let privateNotes = current.notes.filter { !permittedProject($0.project, configuration: configuration) || !KnowledgePolicy.isSafe($0.project + "\n" + $0.text + "\n" + $0.source) }
        let privateChats = current.chats.filter { !permittedProject($0.project, configuration: configuration) || !KnowledgePolicy.isSafe($0.project + "\n" + $0.text) }
        let state = SavedState(notes: document.notes + privateNotes, chats: (document.chats + privateChats).enumerated().sorted { $0.element.date == $1.element.date ? $0.offset < $1.offset : $0.element.date < $1.element.date }.map(\.element))
        guard Set(state.notes.map(\.id)).count == state.notes.count, Set(state.chats.map(\.id)).count == state.chats.count else { throw PrivateMemorySyncFailure.conflict }
        return state
    }
    private func suppressDeletedChatMirrors(in document: PrivateMemorySyncDocument) throws -> PrivateMemorySyncDocument {
        var result = document
        let deleted = Set(document.tombstones.filter { $0.hasPrefix("chat:") })
        result.knowledge = document.knowledge.map { snapshot in
            let suppressed = Set(snapshot.suppressedIDs).union(deleted)
            return KnowledgeSyncSnapshot(accountID: snapshot.accountID, project: snapshot.project, repository: snapshot.repository,
                entries: snapshot.entries.filter { !suppressed.contains($0.id) }, suppressedIDs: Array(suppressed), clearBefore: snapshot.clearBefore)
        }
        _ = try result.encoded(); return result
    }
    private func decode(_ data: Data, passphrase: String, repositoryID: Int) async throws -> PrivateMemorySyncDocument {
        try await Task.detached(priority: .utility) {
            try PrivateMemorySyncDocument.decode(EncryptedMemoryTransfer.decryptSyncPayload(data, passphrase: passphrase), repositoryID: repositoryID)
        }.value
    }
    private func save(_ journal: PrivateMemorySyncJournal, passphrase: String, id: UUID) async throws {
        let encrypted = try await Task.detached(priority: .utility) {
            try PrivateMemorySyncDisk.encryptJournal(journal, passphrase: passphrase)
        }.value
        // Crypto may finish after cancellation. Only the still-current main-actor operation
        // can commit the bytes, so an old task cannot overwrite a new queue/configuration.
        try check(id)
        try disk.writeEncryptedJournal(encrypted)
    }
    private func safeMessage(_ error: Error) -> String {
        if error is PrivateMemorySyncCooldown { return PrivateMemorySyncFailure.rateLimited.localizedDescription }
        if let known = error as? PrivateMemorySyncFailure { return known.localizedDescription }
        if let known = error as? EncryptedMemoryTransfer.Failure { return known.localizedDescription }
        if let known = error as? GitHubAccessError { return known.localizedDescription }
        if let known = error as? KnowledgeFailure { return known.localizedDescription }
        return PrivateMemorySyncFailure.storage.localizedDescription
    }
}
