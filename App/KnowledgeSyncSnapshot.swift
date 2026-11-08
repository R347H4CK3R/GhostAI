import Foundation

/// A transport-neutral copy of one validated account/workspace library. This carries no
/// credentials or authorization. Callers must separately approve private-account access.
struct KnowledgeSyncSnapshot: Codable, Equatable, Sendable {
    let accountID: String
    let project: String
    let repository: String?
    let entries: [KnowledgeEntry]
    let suppressedIDs: [String]
    let clearBefore: Date?

    var scope: KnowledgeScope {
        get throws {
            let canonical = try KnowledgeWorkspacePolicy.scope(workspace: project, liveRepository: repository)
            guard canonical.accountID == accountID else { throw KnowledgeFailure.invalidScope }
            return canonical
        }
    }

    @discardableResult func validated() throws -> Self {
        let boundScope = try scope
        guard entries.count <= KnowledgePolicy.maximumRecords,
              suppressedIDs.count <= KnowledgePolicy.maximumTombstones,
              Set(entries.map(\.id)).count == entries.count,
              Set(suppressedIDs).count == suppressedIDs.count else { throw KnowledgeFailure.invalidContent }
        if let clearBefore {
            guard Self.validDate(clearBefore), clearBefore <= Date().addingTimeInterval(300) else {
                throw KnowledgeFailure.invalidContent
            }
        }
        for id in suppressedIDs { guard Self.validID(id) else { throw KnowledgeFailure.invalidContent } }
        var bytes = 0
        for entry in entries {
            try Self.validate(entry, scope: boundScope)
            bytes += entry.byteCount
            guard bytes <= KnowledgePolicy.maximumCacheBytes else { throw KnowledgeFailure.quota }
        }
        return self
    }

    /// The caller supplies the successfully persisted merged canonical state, never a
    /// remote snapshot. Only exact conversation mirrors can replace a stale cached copy.
    func canonicalConversationIDs(in canonicalState: SavedState?) throws -> Set<String> {
        guard let canonicalState else { return [] }
        guard Set(canonicalState.chats.map(\.id)).count == canonicalState.chats.count else { throw KnowledgeFailure.invalidContent }
        let chats = Dictionary(uniqueKeysWithValues: canonicalState.chats.map { ("chat:" + $0.id.uuidString.lowercased(), $0) })
        var result: Set<String> = []
        for entry in entries where entry.kind == .conversation {
            guard let chat = chats[entry.id], chat.project == project,
                  ["user", "assistant"].contains(chat.role), entry.source.origin == .conversation,
                  entry.source.label == "In-app \(chat.role) message", entry.text == chat.text,
                  entry.sourceDate == chat.date else { throw KnowledgeFailure.changedSource }
            result.insert(entry.id)
        }
        return result
    }

    /// Private scopes require an explicitly enabled policy AND an authenticated stable ID.
    /// A label from a remote snapshot can never authorize another account's library.
    func isPermitted(includePrivateWorkspaces: Bool, authenticatedAccountID: String?) -> Bool {
        accountID == "device-local" || (includePrivateWorkspaces && accountID == authenticatedAccountID)
    }

    static func validID(_ id: String) -> Bool {
        if id.hasPrefix("chat:") || id.hasPrefix("action:") {
            guard let suffix = id.split(separator: ":", maxSplits: 1).last,
                  let uuid = UUID(uuidString: String(suffix)) else { return false }
            return id == (id.hasPrefix("chat:") ? "chat:" : "action:") + uuid.uuidString.lowercased()
        }
        return id.range(of: "^(file|research):[a-f0-9]{64}$", options: .regularExpression) != nil
    }

    private static func validDate(_ date: Date) -> Bool {
        date.timeIntervalSince1970.isFinite && date.timeIntervalSince1970 >= 0 && date <= Date.distantFuture
    }

    private static func validate(_ entry: KnowledgeEntry, scope: KnowledgeScope) throws {
        try KnowledgePolicy.validateText(entry.text)
        guard validID(entry.id), entry.byteCount == entry.text.utf8.count,
              validDate(entry.sourceDate), validDate(entry.cachedAt),
              entry.source.label.utf8.count <= 1_000, KnowledgePolicy.isSafe(entry.source.label) else {
            throw KnowledgeFailure.invalidContent
        }
        switch entry.kind {
        case .conversation:
            guard entry.id.hasPrefix("chat:"), entry.source.origin == .conversation,
                  ["In-app user message", "In-app assistant message"].contains(entry.source.label),
                  entry.source.revision == nil, entry.source.repositoryName == nil else { throw KnowledgeFailure.invalidContent }
        case .action:
            let permitted = KnowledgeActionKind.allCases.flatMap { kind in
                KnowledgeActionStatus.allCases.map { "\(kind.label): \($0.rawValue)" }
            }
            guard entry.id.hasPrefix("action:"), entry.source.origin == .appAction,
                  entry.source.label == "In-app activity", entry.source.revision == nil,
                  entry.source.repositoryName == nil, permitted.contains(entry.text) else { throw KnowledgeFailure.invalidContent }
        case .selectedFile:
            let digest = KnowledgePolicy.digest(entry.text)
            try KnowledgePolicy.validateFilename(entry.source.label)
            guard entry.id == "file:" + digest, entry.source.origin == .selectedFile,
                  entry.source.revision == digest, entry.source.repositoryName == nil else { throw KnowledgeFailure.invalidContent }
        case .research:
            guard entry.id == "research:" + KnowledgePolicy.digest(entry.source.label + "\u{0}" + entry.text) else {
                throw KnowledgeFailure.invalidContent
            }
            switch entry.source.origin {
            case .web:
                guard let url = URL(string: entry.source.label), try KnowledgeSource.web(url) == entry.source else {
                    throw KnowledgeFailure.invalidContent
                }
            case .repository:
                guard let repository = scope.repository, entry.source.repositoryName == repository,
                      let revision = entry.source.revision,
                      entry.source.label.hasPrefix(repository + "/"), entry.source.label.hasSuffix(" @ " + revision) else {
                    throw KnowledgeFailure.invalidScope
                }
                let path = String(entry.source.label.dropFirst(repository.count + 1).dropLast(revision.count + 3))
                guard try KnowledgeSource.repository(repository, path: path, commit: revision) == entry.source else {
                    throw KnowledgeFailure.invalidContent
                }
            default: throw KnowledgeFailure.invalidContent
            }
        }
    }
}

extension KnowledgeEntry {
    /// Content-addressed sources may be observed independently on several devices. Their
    /// earliest observation and deterministic filename converge without changing text or
    /// pinned source identity. UUID chat/action records retain strict immutability.
    func mergedSyncCopy(_ other: KnowledgeEntry) throws -> KnowledgeEntry {
        guard id == other.id, kind == other.kind, text == other.text, byteCount == other.byteCount else {
            throw KnowledgeFailure.changedSource
        }
        let mergedSource: KnowledgeSource
        let mergedDate: Date
        switch kind {
        case .selectedFile:
            guard source.origin == .selectedFile, other.source.origin == .selectedFile,
                  source.revision != nil, source.revision == other.source.revision,
                  source.repositoryName == nil, other.source.repositoryName == nil else { throw KnowledgeFailure.changedSource }
            // Shorter names avoid increasing stored payload size; lexical order breaks ties.
            let lhs = (source.label.utf8.count, source.label)
            let rhs = (other.source.label.utf8.count, other.source.label)
            mergedSource = lhs <= rhs ? source : other.source
            mergedDate = min(sourceDate, other.sourceDate)
        case .research:
            guard source == other.source else { throw KnowledgeFailure.changedSource }
            mergedSource = source; mergedDate = min(sourceDate, other.sourceDate)
        case .conversation, .action:
            guard source == other.source, sourceDate == other.sourceDate else { throw KnowledgeFailure.changedSource }
            mergedSource = source; mergedDate = sourceDate
        }
        return KnowledgeEntry(id: id, kind: kind, text: text, source: mergedSource, sourceDate: mergedDate,
                              cachedAt: min(cachedAt, other.cachedAt), byteCount: byteCount)
    }

    /// File capture time distinguishes an old synced import from a newly selected file
    /// whose source date happens to be old. Explicit ID tombstones always take priority.
    func predatesSyncClear(_ cutoff: Date?) -> Bool {
        guard let cutoff else { return false }
        return (isAutomatic ? sourceDate : cachedAt) <= cutoff
    }
}

@MainActor extension KnowledgeLibraryModel {
    /// Legacy caches are located only through canonical known project names. Newly opened
    /// libraries also retain a validated descriptor, so file/research-only projects survive.
    static func collectSyncSnapshots(root: URL, knownProjects: [String], includePrivateWorkspaces: Bool,
                                     authenticatedAccountID: String? = nil,
                                     onUnresolvedLegacyScopes: ((Int) -> Void)? = nil) throws -> [KnowledgeSyncSnapshot] {
        var scopes: [String: KnowledgeScope] = [:]
        var knownScopeKeys: Set<String> = []
        for project in Set(knownProjects) {
            let scope = try KnowledgeWorkspacePolicy.scope(workspace: project)
            knownScopeKeys.insert(scope.storageKey)
            let descriptor = KnowledgeSyncSnapshot(accountID: scope.accountID, project: scope.project, repository: nil,
                                                   entries: [], suppressedIDs: [], clearBefore: nil)
            guard descriptor.isPermitted(includePrivateWorkspaces: includePrivateWorkspaces, authenticatedAccountID: authenticatedAccountID) else { continue }
            scopes[scope.storageKey] = scope
        }
        var unresolved = 0
        for scope in try KnowledgeCache.discoveredSyncScopes(root: root, includePrivateWorkspaces: includePrivateWorkspaces,
                                                             authenticatedAccountID: authenticatedAccountID, knownScopeKeys: knownScopeKeys,
                                                             onUnresolvedLegacyScopes: { unresolved = $0 }) {
            scopes[scope.storageKey] = scope
        }
        var result: [KnowledgeSyncSnapshot] = []
        for scope in scopes.values.sorted(by: { $0.storageKey < $1.storageKey }) {
            let path = root.appendingPathComponent(scope.storageKey).appendingPathComponent("knowledge.sqlite3")
            guard FileManager.default.fileExists(atPath: path.path) else { continue }
            result.append(try KnowledgeCache(root: root, scope: scope).syncSnapshot())
        }
        onUnresolvedLegacyScopes?(unresolved)
        return result
    }

    static func applySyncSnapshots(_ snapshots: [KnowledgeSyncSnapshot], root: URL, includePrivateWorkspaces: Bool,
                                   authenticatedAccountID: String? = nil, canonicalState: SavedState? = nil) throws {
        // Validate the entire batch before opening or mutating any scope.
        let verified = try snapshots.map { try $0.validated() }
        let keys = try verified.map { try $0.scope.storageKey }
        guard Set(keys).count == keys.count else { throw KnowledgeFailure.invalidScope }
        let permitted = verified.filter { $0.isPermitted(includePrivateWorkspaces: includePrivateWorkspaces,
                                                        authenticatedAccountID: authenticatedAccountID) }
        for snapshot in permitted { _ = try snapshot.canonicalConversationIDs(in: canonicalState) }
        for snapshot in permitted {
            let cache = try KnowledgeCache(root: root, scope: snapshot.scope)
            try cache.applySyncSnapshot(snapshot, canonicalState: canonicalState)
        }
    }
}
