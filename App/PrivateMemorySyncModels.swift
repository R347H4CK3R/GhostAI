import Foundation
import CryptoKit

enum PrivateMemorySyncFailure: LocalizedError, Equatable {
    case invalid, privateRepository, repositoryChanged, consent, capacity, conflict, authentication, storage, credentials, unavailable, rateLimited, importHistoryUnavailable, recoveryReviewRequired
    var errorDescription: String? {
        switch self {
        case .importHistoryUnavailable: return "Import was not saved because this configured vault’s deletion history is unavailable. Open Private memory sync, reconnect if needed, and complete a sync before importing. This prevents a restored record from disappearing on the next sync."
        case .recoveryReviewRequired: return "Recovered memory is local only and automatic sync remains paused. Review the recovery warning in Private memory sync before resuming."
        case .invalid: return "The encrypted sync data could not be verified. Sync is paused for review."
        case .privateRepository: return "Sync requires your private repository with Contents read/write access. Public repositories are blocked."
        case .repositoryChanged: return "The repository identity, owner, visibility or branch changed. Sync is paused to protect your data."
        case .consent: return "The vault’s private-workspace scope differs from this device’s approved scope. Review the configuration before syncing."
        case .capacity: return "The sync storage limit was reached. Sync is paused rather than truncating records. Review the storage limits and preserve important data before reducing the library."
        case .conflict: return "Two different saved sources have the same identity. Both copies remain on their original devices; sync is paused for review."
        case .authentication: return "GitHub rejected the saved sync credential. Reconnect with a repository-only token."
        case .storage: return "The encrypted sync queue could not be saved or read. Your local memory remains on this device; sync is paused."
        case .credentials: return "The sync credential or recovery passphrase is unavailable in this device’s Keychain. Reconnect to continue."
        case .unavailable: return "GitHub could not be reached securely. Your changes remain on this device and will retry automatically."
        case .rateLimited: return "GitHub limited requests. Your changes remain queued and will retry later."
        }
    }
    var isRetryable: Bool { switch self { case .unavailable, .rateLimited: return true; default: return false } }
}

enum PrivateMemorySyncPolicy {
    static let defaultRepository = ""
    static let path = ["veyra-memory", "v1.sync"]
    // Bounded mobile budget. Larger Contents responses use immutable raw Git blobs.
    static let maximumDocumentBytes = 8 * 1_024 * 1_024
    static let maximumJournalBytes = 17 * 1_024 * 1_024
    static let maximumRecords = 30_000
    static let maximumTombstones = 20_000
    static func permits(_ project: String, privateWorkspaces: Bool) -> Bool {
        privateWorkspaces || !project.hasPrefix("GitHub account ")
    }
    static func canonical<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }
    static func validDate(_ value: Date) -> Bool {
        let seconds = value.timeIntervalSince1970
        return seconds.isFinite && seconds >= 0 && seconds <= 253_402_300_799
    }
    static func validTombstone(_ value: String) -> Bool {
        let parts = value.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, ["note", "chat"].contains(parts[0]), let uuid = UUID(uuidString: String(parts[1])) else { return false }
        return uuid.uuidString.lowercased() == parts[1]
    }
}

struct PrivateMemorySyncConfiguration: Codable, Sendable {
    var version = 1
    var repository: String
    var repositoryID: Int
    var accountID: Int
    var branch: String
    var includePrivateWorkspaces: Bool
    var enabled = true
    var lastSyncedAt: Date?
    var hasObservedRemoteVault = false
    // Optional for compatibility with already saved version-1 configurations.
    var localRecoveryNeedsReview: Bool? = nil
    func validated() throws -> Self {
        guard version == 1, repositoryID > 0, accountID > 0,
              (try? GitHubRoute.repository(repository)) != nil,
              repository.lowercased() != "r347h4ck3r/ghostai", !branch.isEmpty, branch.utf8.count <= 255,
              !branch.contains(where: { $0.isNewline }), KnowledgePolicy.isSafe(branch) else { throw PrivateMemorySyncFailure.invalid }
        return self
    }
}

struct PrivateMemorySyncDocument: Codable, Sendable {
    var version = 1
    var repositoryID: Int
    var notes: [MemoryNote]
    var chats: [ChatEntry]
    var knowledge: [KnowledgeSyncSnapshot]
    var tombstones: [String]
    var includesPrivateWorkspaces = false
    var chatOrder: [UUID] = []

    static func empty(repositoryID: Int, privateWorkspaces: Bool = false) -> Self {
        var value = Self(repositoryID: repositoryID, notes: [], chats: [], knowledge: [], tombstones: [])
        value.includesPrivateWorkspaces = privateWorkspaces; return value
    }
    func normalized() -> Self {
        var value = self
        value.notes.sort { $0.id.uuidString < $1.id.uuidString }
        let positions = Dictionary(uniqueKeysWithValues: (chatOrder.isEmpty ? chats.map(\.id) : chatOrder).enumerated().map { ($0.element, $0.offset) })
        value.chats.sort { positions[$0.id, default: Int.max] < positions[$1.id, default: Int.max] }
        value.chatOrder = value.chats.map(\.id)
        value.tombstones.sort()
        value.knowledge = knowledge.map { item in
            KnowledgeSyncSnapshot(accountID: item.accountID, project: item.project, repository: item.repository,
                                  entries: item.entries.sorted { $0.id < $1.id }, suppressedIDs: item.suppressedIDs.sorted(), clearBefore: item.clearBefore)
        }.sorted { $0.accountID + "\0" + $0.project < $1.accountID + "\0" + $1.project }
        return value
    }
    func validate() throws {
        guard version == 1, repositoryID > 0,
              notes.count + chats.count + knowledge.reduce(0, { $0 + $1.entries.count }) <= PrivateMemorySyncPolicy.maximumRecords,
              tombstones.count <= PrivateMemorySyncPolicy.maximumTombstones,
              Set(tombstones).count == tombstones.count, tombstones.allSatisfy(PrivateMemorySyncPolicy.validTombstone),
              knowledge.count <= 256, Set(chatOrder).count == chatOrder.count,
              chatOrder.isEmpty || Set(chatOrder) == Set(chats.map(\.id)) else { throw PrivateMemorySyncFailure.invalid }
        _ = try MemoryBackup.encode(SavedState(notes: notes, chats: chats))
        let deleted = Set(tombstones)
        for note in notes {
            guard !deleted.contains("note:" + note.id.uuidString.lowercased()),
                  PrivateMemorySyncPolicy.permits(note.project, privateWorkspaces: includesPrivateWorkspaces),
                  KnowledgePolicy.isSafe(note.project + "\n" + note.text + "\n" + note.source),
                  PrivateMemorySyncPolicy.validDate(note.savedAt) else { throw PrivateMemorySyncFailure.invalid }
        }
        for chat in chats {
            guard !deleted.contains("chat:" + chat.id.uuidString.lowercased()),
                  PrivateMemorySyncPolicy.permits(chat.project, privateWorkspaces: includesPrivateWorkspaces),
                  KnowledgePolicy.isSafe(chat.project + "\n" + chat.text),
                  PrivateMemorySyncPolicy.validDate(chat.date) else { throw PrivateMemorySyncFailure.invalid }
        }
        var scopes = Set<String>()
        for snapshot in knowledge {
            _ = try snapshot.validated()
            let scope = try snapshot.scope
            guard scopes.insert(scope.storageKey).inserted,
                  PrivateMemorySyncPolicy.permits(snapshot.project, privateWorkspaces: includesPrivateWorkspaces) else { throw PrivateMemorySyncFailure.invalid }
        }
    }
    func encoded() throws -> Data {
        try validate()
        let data = try PrivateMemorySyncPolicy.canonical(normalized())
        guard data.count <= PrivateMemorySyncPolicy.maximumDocumentBytes else { throw PrivateMemorySyncFailure.capacity }
        return data
    }
    static func decode(_ data: Data, repositoryID: Int) throws -> Self {
        guard data.count <= PrivateMemorySyncPolicy.maximumDocumentBytes else { throw PrivateMemorySyncFailure.capacity }
        let value: Self
        do { value = try JSONDecoder().decode(Self.self, from: data) } catch { throw PrivateMemorySyncFailure.invalid }
        guard value.repositoryID == repositoryID else { throw PrivateMemorySyncFailure.repositoryChanged }
        try value.validate(); return value.normalized()
    }
}

struct PrivateMemorySyncJournal: Codable, Sendable {
    var version = 1
    var base: PrivateMemorySyncDocument
    // One coalesced full snapshot, not an unbounded operation log. Persist before any PUT.
    var pending: PrivateMemorySyncDocument?
    var attempts = 0
    var retryAfter: Date?
    var serverRetryAfter: Date?
    func validate(repositoryID: Int) throws {
        guard version == 1, (0...100).contains(attempts), base.repositoryID == repositoryID,
              pending == nil || pending?.repositoryID == repositoryID else { throw PrivateMemorySyncFailure.invalid }
        _ = try base.encoded(); if let pending { _ = try pending.encoded() }
        if let retryAfter, !PrivateMemorySyncPolicy.validDate(retryAfter) { throw PrivateMemorySyncFailure.invalid }
        if let serverRetryAfter, !PrivateMemorySyncPolicy.validDate(serverRetryAfter) { throw PrivateMemorySyncFailure.invalid }
    }
}

enum PrivateMemorySyncMerge {
    static func capture(state: SavedState, knowledge: [KnowledgeSyncSnapshot], previous: PrivateMemorySyncDocument,
                        includePrivateWorkspaces: Bool) throws -> PrivateMemorySyncDocument {
        var result = PrivateMemorySyncDocument.empty(repositoryID: previous.repositoryID, privateWorkspaces: includePrivateWorkspaces)
        result.notes = state.notes.filter { PrivateMemorySyncPolicy.permits($0.project, privateWorkspaces: includePrivateWorkspaces) && KnowledgePolicy.isSafe($0.project + "\n" + $0.text + "\n" + $0.source) }
        result.chats = state.chats.filter { PrivateMemorySyncPolicy.permits($0.project, privateWorkspaces: includePrivateWorkspaces) && KnowledgePolicy.isSafe($0.project + "\n" + $0.text) }
        result.knowledge = try knowledge.filter { PrivateMemorySyncPolicy.permits($0.project, privateWorkspaces: includePrivateWorkspaces) }.map { try $0.validated() }
        var deleted = Set(previous.tombstones)
        let notes = Set(result.notes.map(\.id)), chats = Set(result.chats.map(\.id))
        for value in previous.notes where !notes.contains(value.id) { deleted.insert("note:" + value.id.uuidString.lowercased()) }
        for value in previous.chats where !chats.contains(value.id) { deleted.insert("chat:" + value.id.uuidString.lowercased()) }
        result.notes.removeAll { deleted.contains("note:" + $0.id.uuidString.lowercased()) }
        result.chats.removeAll { deleted.contains("chat:" + $0.id.uuidString.lowercased()) }
        result.tombstones = Array(deleted)
        result.chatOrder = result.chats.map(\.id)
        _ = try result.encoded(); return result.normalized()
    }
    static func merge(base: PrivateMemorySyncDocument, local: PrivateMemorySyncDocument, remote: PrivateMemorySyncDocument) throws -> PrivateMemorySyncDocument {
        guard base.repositoryID == local.repositoryID, local.repositoryID == remote.repositoryID else { throw PrivateMemorySyncFailure.repositoryChanged }
        guard local.includesPrivateWorkspaces == remote.includesPrivateWorkspaces else { throw PrivateMemorySyncFailure.consent }
        try base.validate(); try local.validate(); try remote.validate()
        var result = PrivateMemorySyncDocument.empty(repositoryID: local.repositoryID, privateWorkspaces: local.includesPrivateWorkspaces)
        let deleted = Set(base.tombstones + local.tombstones + remote.tombstones)
        result.tombstones = Array(deleted)
        result.notes = try mergeRecords(base: base.notes, local: local.notes, remote: remote.notes,
            key: { $0.id }, kind: "note", deleted: deleted, replacingID: { value, id in var copy = value; copy.id = id; return copy })
        result.chats = try mergeRecords(base: base.chats, local: local.chats, remote: remote.chats,
            key: { $0.id }, kind: "chat", deleted: deleted, replacingID: { value, id in var copy = value; copy.id = id; return copy })
        result.chats = try orderChats(result.chats, sources: [base.chats, local.chats, remote.chats])
        result.chatOrder = result.chats.map(\.id)
        result.knowledge = try mergeKnowledge(reconcileMirrors(local.knowledge, chats: result.chats),
                                              reconcileMirrors(remote.knowledge, chats: result.chats))
        _ = try result.encoded(); return result.normalized()
    }
    private static func mergeRecords<T: Codable>(base: [T], local: [T], remote: [T], key: (T) -> UUID, kind: String,
                                                  deleted: Set<String>, replacingID: (T, UUID) -> T) throws -> [T] {
        let b = Dictionary(uniqueKeysWithValues: base.map { (key($0), $0) })
        let l = Dictionary(uniqueKeysWithValues: local.map { (key($0), $0) })
        let r = Dictionary(uniqueKeysWithValues: remote.map { (key($0), $0) })
        var result: [UUID: T] = [:]
        for id in Set(l.keys).union(r.keys).sorted(by: { $0.uuidString < $1.uuidString }) {
            guard !deleted.contains(kind + ":" + id.uuidString.lowercased()) else { continue }
            guard let left = l[id] else { result[id] = r[id]; continue }
            guard let right = r[id] else { result[id] = left; continue }
            // Importers can assign different fallback dates to the same stable chat ID.
            // Timestamp-only differences are not two conversations or conflicting edits.
            if let lc = left as? ChatEntry, let rc = right as? ChatEntry,
               lc.project == rc.project, lc.role == rc.role, lc.text == rc.text {
                var merged = lc; merged.date = min(lc.date, rc.date)
                if let value = merged as? T { result[id] = value; continue }
            }
            // Independently imported/restored Luma snapshots and typed editable
            // copies have the
            // same identity and provenance, but a device-local fallback import time.
            // Match exact UTF-8, not String's canonical Unicode equivalence, so
            // provenance bytes and encoded results cannot depend on device order.
            // Preserve genuine edits, other note kinds and existing conflict copies.
            if let ln = left as? MemoryNote, let rn = right as? MemoryNote,
               ln.project.utf8.elementsEqual(rn.project.utf8),
               ln.text.utf8.elementsEqual(rn.text.utf8), ln.source.utf8.elementsEqual(rn.source.utf8),
               (LumaBackupImport.usesChecklistImportTime(ln) || EditableChecklist.usesImportTime(ln)) {
                var merged = ln; merged.savedAt = min(ln.savedAt, rn.savedAt)
                if let value = merged as? T { result[id] = value; continue }
            }
            let ld = try PrivateMemorySyncPolicy.canonical(left), rd = try PrivateMemorySyncPolicy.canonical(right)
            if ld == rd { result[id] = left; continue }
            if let original = b[id] {
                let bd = try PrivateMemorySyncPolicy.canonical(original)
                if bd == ld { result[id] = right; continue }
                if bd == rd { result[id] = left; continue }
            }
            // Stable winner and stable copy identity make concurrent merge order converge.
            let ordered = ld.lexicographicallyPrecedes(rd) ? [(left, ld), (right, rd)] : [(right, rd), (left, ld)]
            result[id] = ordered[0].0
            let conflictID = try conflictID(kind: kind, originalID: id, canonical: ordered[1].1)
            if !deleted.contains(kind + ":" + conflictID.uuidString.lowercased()) {
                let copy = replacingID(ordered[1].0, conflictID)
                if let existing = l[conflictID] ?? r[conflictID], try PrivateMemorySyncPolicy.canonical(existing) != PrivateMemorySyncPolicy.canonical(copy) { throw PrivateMemorySyncFailure.conflict }
                result[conflictID] = copy
            }
        }
        return Array(result.values)
    }
    private static func conflictID(kind: String, originalID: UUID, canonical: Data) throws -> UUID {
        var bytes = Array(SHA256.hash(data: Data((kind + ":" + originalID.uuidString.lowercased()).utf8) + canonical).prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x50; bytes[8] = (bytes[8] & 0x3f) | 0x80
        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        let value = "\(hex.prefix(8))-\(hex.dropFirst(8).prefix(4))-\(hex.dropFirst(12).prefix(4))-\(hex.dropFirst(16).prefix(4))-\(hex.dropFirst(20))"
        guard let id = UUID(uuidString: value), id != originalID else { throw PrivateMemorySyncFailure.conflict }
        return id
    }
    /// Resolve only this original identity and this exact conflict payload, never another
    /// unrelated conversation which merely happens to contain the same text.
    private static func resolvedChat(_ original: ChatEntry, in merged: [UUID: ChatEntry]) throws -> ChatEntry? {
        if let same = merged[original.id], same.project == original.project,
           same.role == original.role, same.text == original.text { return same }
        let copyID = try conflictID(kind: "chat", originalID: original.id, canonical: PrivateMemorySyncPolicy.canonical(original))
        guard let copy = merged[copyID], copy.project == original.project, copy.role == original.role,
              copy.text == original.text, copy.date == original.date else { return nil }
        return copy
    }
    /// Preserve each device/import's source order, including equal-date user/assistant
    /// turns. Independent concurrent sequences use stable date/ID tie breaks. If sources
    /// explicitly disagree about ordering, the same deterministic cycle break converges.
    private static func orderChats(_ merged: [ChatEntry], sources: [[ChatEntry]]) throws -> [ChatEntry] {
        let byID = Dictionary(uniqueKeysWithValues: merged.map { ($0.id, $0) })
        var outgoing: [UUID: Set<UUID>] = [:], incoming: [UUID: Set<UUID>] = [:]
        for source in sources {
            let sequence = try source.compactMap { try resolvedChat($0, in: byID)?.id }
            for (before, after) in zip(sequence, sequence.dropFirst()) where before != after {
                outgoing[before, default: []].insert(after); incoming[after, default: []].insert(before)
            }
        }
        var remaining = Set(byID.keys), result: [ChatEntry] = []
        func earlier(_ lhs: UUID, _ rhs: UUID) -> Bool {
            let l = byID[lhs]!, r = byID[rhs]!
            return l.date == r.date ? lhs.uuidString < rhs.uuidString : l.date < r.date
        }
        var ready = remaining.filter { incoming[$0, default: []].isEmpty }.sorted { earlier($1, $0) }
        while !remaining.isEmpty {
            let next: UUID
            if let first = ready.popLast() { next = first }
            else if let first = remaining.min(by: earlier) { next = first }
            else { break }
            guard remaining.remove(next) != nil, let chat = byID[next] else { continue }
            result.append(chat)
            var added = false
            for following in outgoing[next, default: []] {
                incoming[following]?.remove(next)
                if remaining.contains(following), incoming[following, default: []].isEmpty {
                    ready.append(following); added = true
                }
            }
            if added { ready.sort { earlier($1, $0) } }
        }
        return result
    }
    private static func reconcileMirrors(_ snapshots: [KnowledgeSyncSnapshot], chats: [ChatEntry]) throws -> [KnowledgeSyncSnapshot] {
        let byID = Dictionary(uniqueKeysWithValues: chats.map { ($0.id, $0) })
        return try snapshots.map { snapshot in
            var suppressed = Set(snapshot.suppressedIDs)
            let entries = try snapshot.entries.compactMap { entry -> KnowledgeEntry? in
                guard entry.kind == .conversation else { return entry }
                guard let originalID = UUID(uuidString: String(entry.id.dropFirst("chat:".count))) else { throw PrivateMemorySyncFailure.invalid }
                let role = entry.source.label == "In-app user message" ? "user" : "assistant"
                let original = ChatEntry(id: originalID, project: snapshot.project, role: role, text: entry.text, date: entry.sourceDate)
                let match = try resolvedChat(original, in: byID)
                guard let chat = match else {
                    // A one-sided edit can keep the canonical ID while changing its text.
                    // Drop that stale mirror without tombstoning the surviving winner.
                    let survives = chats.contains { "chat:" + $0.id.uuidString.lowercased() == entry.id && $0.project == snapshot.project }
                    if !survives { suppressed.insert(entry.id) }
                    return nil
                }
                return KnowledgeEntry(id: "chat:" + chat.id.uuidString.lowercased(), kind: entry.kind, text: entry.text,
                    source: entry.source, sourceDate: chat.date, cachedAt: entry.cachedAt, byteCount: entry.byteCount)
            }
            return KnowledgeSyncSnapshot(accountID: snapshot.accountID, project: snapshot.project, repository: snapshot.repository,
                entries: entries, suppressedIDs: Array(suppressed), clearBefore: snapshot.clearBefore)
        }
    }
    private static func mergeKnowledge(_ local: [KnowledgeSyncSnapshot], _ remote: [KnowledgeSyncSnapshot]) throws -> [KnowledgeSyncSnapshot] {
        var scopes: [String: KnowledgeSyncSnapshot] = [:]
        for value in local + remote {
            let key = try value.scope.storageKey
            guard let old = scopes[key] else { scopes[key] = value; continue }
            let suppressed = Set(old.suppressedIDs + value.suppressedIDs)
            let cutoff = [old.clearBefore, value.clearBefore].compactMap { $0 }.max()
            var entries: [String: KnowledgeEntry] = [:]
            for entry in old.entries + value.entries {
                guard !suppressed.contains(entry.id), cutoff.map({ (entry.kind == .selectedFile ? entry.cachedAt : entry.sourceDate) > $0 }) ?? true else { continue }
                if let prior = entries[entry.id] {
                    entries[entry.id] = try prior.mergedSyncCopy(entry)
                } else { entries[entry.id] = entry }
            }
            scopes[key] = KnowledgeSyncSnapshot(accountID: old.accountID, project: old.project, repository: old.repository ?? value.repository,
                entries: Array(entries.values), suppressedIDs: Array(suppressed), clearBefore: cutoff)
        }
        return Array(scopes.values)
    }
}
