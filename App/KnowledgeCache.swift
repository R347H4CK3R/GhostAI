import Foundation
import CryptoKit
import SQLite3
import Darwin

/// The caller supplies a stable account identifier, never a token or display name.
/// Local conversations use a distinct account such as `device-local`.
struct KnowledgeScope: Equatable, Sendable {
    let accountID: String
    let project: String
    let repository: String?
    var storageKey: String { KnowledgePolicy.digest(accountID + "\u{0}" + project) }
    init(accountID: String, project: String, repository: String? = nil) throws {
        guard !accountID.isEmpty, accountID.utf8.count <= 200, !project.isEmpty, project.utf8.count <= 300,
              KnowledgePolicy.isSafe(accountID), KnowledgePolicy.isSafe(project),
              !accountID.contains("\n"), !project.contains("\n") else { throw KnowledgeFailure.invalidScope }
        if let repository {
            guard (try? GitHubRoute.repository(repository)) != nil, KnowledgePolicy.isSafe(repository) else { throw KnowledgeFailure.invalidScope }
        }
        self.accountID = accountID; self.project = project; self.repository = repository
    }
}

enum KnowledgeFailure: LocalizedError, Equatable {
    case invalidScope, invalidContent, unsupportedFile, oversizedFile, unavailable, corrupt, quota, suppressed, changedSource
    var errorDescription: String? {
        switch self {
        case .invalidScope: return "Select an account and project before using offline knowledge."
        case .invalidContent: return "Content was not cached: it may contain a credential, request header, hidden control, or unsupported text. Secret detection is not complete."
        case .unsupportedFile: return "Select one regular UTF-8 text or source document. Hidden, credential, linked and unsupported files are excluded."
        case .oversizedFile: return "This document exceeds the 256 KiB import limit. Select a smaller text document."
        case .unavailable: return "Offline knowledge is unavailable or the device is locked. Existing data has not been reset."
        case .corrupt: return "Offline knowledge could not be verified. Reads and writes are blocked; the existing file has not been erased."
        case .quota: return "Offline knowledge is full. Nothing was evicted. Delete cached items to make room, then retry."
        case .suppressed: return "This content was previously deleted and will not be indexed again."
        case .changedSource: return "This source identifier already refers to a different saved copy. Refresh with a new source identifier."
        }
    }
}

enum KnowledgeKind: String, Codable, CaseIterable, Hashable, Sendable {
    case conversation, action, research, selectedFile
    var label: String {
        switch self { case .conversation: return "Conversation"; case .action: return "App action"
        case .research: return "Research"; case .selectedFile: return "Selected file" }
    }
}

enum KnowledgeRetention: String, Codable, CaseIterable, Hashable, Sendable {
    case untilDeleted, days30, days90, year
    var days: Int? { switch self { case .untilDeleted: return nil; case .days30: return 30; case .days90: return 90; case .year: return 365 } }
    var label: String { days.map { "Review after \($0) days" } ?? "Keep until I delete" }
}

struct KnowledgeSettings: Codable, Equatable, Sendable {
    var captureConversations = true
    var captureActions = true
    var captureResearch = true
    var retention: KnowledgeRetention = .untilDeleted
}

enum KnowledgeActionKind: String, Codable, CaseIterable, Hashable, Sendable {
    case question, repositoryRead, sourceSaved, proposalReviewed, proposalPublished, fileImported
    var label: String {
        switch self { case .question: return "Question"; case .repositoryRead: return "Repository read"
        case .sourceSaved: return "Source saved"; case .proposalReviewed: return "Proposal reviewed"
        case .proposalPublished: return "Proposal published"; case .fileImported: return "File imported" }
    }
}
enum KnowledgeActionStatus: String, Codable, CaseIterable, Hashable, Sendable { case succeeded, cancelled, failed, uncertain }

/// No arbitrary error, request headers, file-system path or provider response can be a source.
struct KnowledgeSource: Codable, Equatable, Sendable {
    enum Origin: String, Codable, Sendable { case conversation, appAction, selectedFile, repository, web }
    let origin: Origin
    let label: String
    let revision: String?
    let repositoryName: String?
    private init(origin: Origin, label: String, revision: String? = nil, repositoryName: String? = nil) {
        self.origin = origin; self.label = label; self.revision = revision; self.repositoryName = repositoryName
    }
    static func repository(_ repository: String, path: String, commit: String) throws -> Self {
        guard (try? GitHubRoute.repository(repository)) != nil,
              commit.range(of: "^[a-fA-F0-9]{40}$", options: .regularExpression) != nil,
              (try? RepositoryToolPolicy.validatePath(path, allowRoot: false)) != nil,
              !RepositoryToolPolicy.isLikelyCredentialPath(path), KnowledgePolicy.isSafe(repository + path) else {
            throw KnowledgeFailure.invalidContent
        }
        return Self(origin: .repository, label: "\(repository)/\(path) @ \(commit.lowercased())", revision: commit.lowercased(), repositoryName: repository)
    }
    static func web(_ url: URL) throws -> Self {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme == "https", let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              url.absoluteString.utf8.count <= 1_000, KnowledgePolicy.isSafe(url.absoluteString) else {
            throw KnowledgeFailure.invalidContent
        }
        return Self(origin: .web, label: url.absoluteString)
    }
    fileprivate static func conversation(role: String) -> Self { Self(origin: .conversation, label: "In-app \(role) message") }
    fileprivate static let action = Self(origin: .appAction, label: "In-app activity")
    fileprivate static func file(name: String, digest: String) -> Self { Self(origin: .selectedFile, label: name, revision: digest) }
}

struct KnowledgeEntry: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let kind: KnowledgeKind
    let text: String
    let source: KnowledgeSource
    let sourceDate: Date
    let cachedAt: Date
    let byteCount: Int
    var offlineStatus: String { "Available offline · saved copy, not live" }
    var isAutomatic: Bool { kind != .selectedFile }
}

struct KnowledgeSearchHit: Identifiable, Sendable {
    let entry: KnowledgeEntry
    let excerpt: String
    var id: String { entry.id }
}
struct KnowledgeCaptureReport: Equatable, Sendable {
    var stored = 0
    var rejected = 0
    var suppressed = 0
}
struct KnowledgeCoverage: Sendable {
    let entries: Int
    let sourceBytes: Int
    let databaseBytes: Int
    let totalDatabaseBytes: Int
    let maximumBytes: Int
    let maximumSourceBytes: Int
    let suppressedSources: Int
    let counts: [KnowledgeKind: Int]
    let lastCapture: KnowledgeCaptureReport
    let captureIsFull: Bool
}

enum KnowledgePolicy {
    static let maximumDocumentBytes = 256 * 1_024
    static let maximumCacheBytes = 50 * 1_024 * 1_024
    static let maximumRecords = 10_000
    static let maximumTombstones = 100_000
    static let allowedExtensions = Set(["txt", "md", "markdown", "rst", "swift", "py", "js", "ts", "tsx", "jsx", "kt", "java", "c", "cc", "cpp", "h", "hpp", "css", "html", "json", "csv", "yaml", "yml"])
    static func digest(_ value: String) -> String { SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined() }
    static func isSafe(_ text: String) -> Bool {
        let additional = ["(?i)(?:sk-(?:proj-|ant-)?|xox[baprs]-)[a-z0-9_-]{12,}", "AKIA[0-9A-Z]{16}",
                          "(?im)^\\s*(?:authorization|proxy-authorization|cookie|set-cookie|x-api-key)\\s*:",
                          "(?i)bearer\\s+\\S+", "eyJ[a-zA-Z0-9_-]{12,}\\.[a-zA-Z0-9_-]{12,}\\.[a-zA-Z0-9_-]{12,}",
                          "(?i)(?:https?://)[^\\s/]+:[^\\s/]+@",
                          "(?i)[?&](?:token|key|secret|password|signature|access_token)="]
        return MemorySearch.canSave(text) && !additional.contains { text.range(of: $0, options: .regularExpression) != nil }
            && text.unicodeScalars.allSatisfy {
                (!CharacterSet.controlCharacters.contains($0) || [9, 10, 13].contains($0.value))
                    && !CharacterSet.illegalCharacters.contains($0)
                    && ![0x200B, 0x200E, 0x200F, 0x202A, 0x202B, 0x202C, 0x202D, 0x202E, 0x2060, 0x2066, 0x2067, 0x2068, 0x2069, 0xFEFF].contains($0.value)
            }
    }
    static func validateText(_ text: String) throws {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              text.utf8.count <= maximumDocumentBytes, isSafe(text) else { throw KnowledgeFailure.invalidContent }
    }
    static func validateFilename(_ name: String) throws {
        let url = URL(fileURLWithPath: name)
        guard !name.isEmpty, name.utf8.count <= 255, url.lastPathComponent == name,
              !name.hasPrefix("."), !name.contains("\\"), isSafe(name),
              !name.contains(where: { $0.isNewline }),
              allowedExtensions.contains(url.pathExtension.lowercased()),
              !RepositoryToolPolicy.isLikelyCredentialPath(name),
              !["credential", "password", "secret", "privatekey", "id_rsa", "id_ed25519"].contains(where: { name.lowercased().contains($0) }) else {
            throw KnowledgeFailure.unsupportedFile
        }
    }
    /// Literal words only. No user-supplied FTS operators, quoting or column syntax survives.
    static func searchTokens(_ query: String) -> [String] {
        let words = String(query.prefix(500)).lowercased().split { !$0.isLetter && !$0.isNumber }
        return Array(Array(Set(words.map { String($0.prefix(64)) }.filter { !$0.isEmpty })).sorted().prefix(12))
    }
    static func matchExpression(_ query: String) -> String? {
        let tokens = searchTokens(query)
        return tokens.isEmpty ? nil : tokens.map { "\"\($0)\"" }.joined(separator: " OR ")
    }
    static func excerpt(_ text: String, query: String) -> String? {
        let ranges = searchTokens(query).compactMap { text.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) }
        guard let match = ranges.min(by: { $0.lowerBound < $1.lowerBound }) else { return nil }
        let start = text.index(match.lowerBound, offsetBy: -160, limitedBy: text.startIndex) ?? text.startIndex
        let end = text.index(start, offsetBy: 560, limitedBy: text.endIndex) ?? text.endIndex
        return (start > text.startIndex ? "… " : "") + String(text[start..<end]) + (end < text.endIndex ? " …" : "")
    }
    static func chunks(_ text: String) -> [String] {
        var result: [String] = []; var start = text.startIndex
        while start < text.endIndex {
            let end = text.index(start, offsetBy: 1_200, limitedBy: text.endIndex) ?? text.endIndex
            result.append(String(text[start..<end]))
            if end == text.endIndex { break }
            start = text.index(end, offsetBy: -120)
        }
        return result
    }
}

/// Main-actor confinement keeps SQLite transactions serialized. This cache is optional:
/// failure here must never roll back successful canonical note/chat persistence.
@MainActor final class KnowledgeCache {
    let scope: KnowledgeScope
    let databaseURL: URL
    let maximumBytes: Int
    private let libraryRoot: URL
    private var database: OpaquePointer?
    private var blocked = false
    private var transactionOtherBytes: Int?
    private var insertionLimitApplied = false
    private(set) var settings = KnowledgeSettings()
    private(set) var lastCapture = KnowledgeCaptureReport()
    private(set) var captureIsFull = false
    /// Runs only after a successful transaction that changed persistent records.
    var onMutation: (() -> Void)?

    init(root: URL, scope: KnowledgeScope, maximumBytes: Int = KnowledgePolicy.maximumCacheBytes) throws {
        guard (1_048_576...KnowledgePolicy.maximumCacheBytes).contains(maximumBytes) else { throw KnowledgeFailure.quota }
        self.scope = scope; self.maximumBytes = maximumBytes; libraryRoot = root
        let folder = root.appendingPathComponent(scope.storageKey, isDirectory: true)
        databaseURL = folder.appendingPathComponent("knowledge.sqlite3")
        do {
            try Self.validateExistingDirectory(root)
            try Self.validateExistingDirectory(folder)
            try Self.validateExistingDatabase(databaseURL)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                   attributes: [.protectionKey: FileProtectionType.complete])
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: folder.path)
            var excluded = folder; var values = URLResourceValues(); values.isExcludedFromBackup = true
            try excluded.setResourceValues(values)
            let existed = FileManager.default.fileExists(atPath: databaseURL.path)
            if !existed {
                guard try totalDatabaseBytes() + 65_536 <= maximumBytes - min(2_097_152, maximumBytes / 4) else { throw KnowledgeFailure.quota }
            }
            guard sqlite3_open_v2(databaseURL.path, &database, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX | SQLITE_OPEN_NOFOLLOW, nil) == SQLITE_OK else {
                throw KnowledgeFailure.unavailable
            }
            sqlite3_busy_timeout(database, 1_000)
            if existed {
                guard try scalarText("PRAGMA quick_check") == "ok", try scalarInt("PRAGMA user_version") == 1,
                      try scalarText("SELECT value FROM metadata WHERE key='scope'") == scope.storageKey else { throw KnowledgeFailure.corrupt }
            } else {
                try execute("PRAGMA auto_vacuum=FULL")
                try transaction {
                    try execute("CREATE TABLE metadata (key TEXT PRIMARY KEY NOT NULL, value TEXT NOT NULL)")
                    try execute("CREATE TABLE entries (id TEXT PRIMARY KEY NOT NULL, kind TEXT NOT NULL, source_date REAL NOT NULL, bytes INTEGER NOT NULL, fingerprint TEXT NOT NULL, payload BLOB NOT NULL)")
                    try execute("CREATE INDEX entries_date ON entries(source_date DESC)")
                    try execute("CREATE VIRTUAL TABLE chunks USING fts5(entry_id UNINDEXED, text, tokenize='unicode61 remove_diacritics 2')")
                    try execute("CREATE TABLE suppressed (id TEXT PRIMARY KEY NOT NULL)")
                    try execute("PRAGMA user_version=1")
                    try execute("INSERT INTO metadata VALUES ('scope', ?)", [.text(scope.storageKey)])
                    try execute("INSERT INTO metadata VALUES ('repository', ?)", [.text(scope.repository ?? "")])
                    try writeSettings(KnowledgeSettings())
                    try execute("INSERT INTO metadata VALUES ('clear_before', '0')")
                }
            }
            try execute("PRAGMA journal_mode=DELETE")
            try execute("PRAGMA synchronous=FULL")
            try execute("PRAGMA secure_delete=ON")
            let pageSize = try scalarInt("PRAGMA page_size")
            guard pageSize > 0, try scalarInt("PRAGMA page_count") * pageSize <= maximumBytes else { throw KnowledgeFailure.quota }
            _ = try scalarInt("PRAGMA max_page_count=\(maximumBytes / pageSize)")
            guard let encoded = try scalarText("SELECT value FROM metadata WHERE key='settings'"), let data = encoded.data(using: .utf8),
                  let decoded = try? JSONDecoder().decode(KnowledgeSettings.self, from: data) else { throw KnowledgeFailure.corrupt }
            _ = try clearCutoff()
            settings = decoded
            guard let binding = try scalarText("SELECT value FROM metadata WHERE key='repository'"),
                  binding.isEmpty || ((try? GitHubRoute.repository(binding)) != nil && KnowledgePolicy.isSafe(binding)) else { throw KnowledgeFailure.corrupt }
            if let repository = scope.repository {
                guard binding.isEmpty || binding == repository else { throw KnowledgeFailure.invalidScope }
                if binding.isEmpty {
                    try transaction { try execute("UPDATE metadata SET value=? WHERE key='repository'", [.text(repository)]) }
                }
            }
            try storeSyncScopeDescriptor()
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: databaseURL.path)
        } catch {
            if let database { sqlite3_close(database) }; database = nil
            if let safe = error as? KnowledgeFailure { throw safe }
            throw KnowledgeFailure.unavailable
        }
    }
    deinit { if let database { sqlite3_close(database) } }

    func updateSettings(_ value: KnowledgeSettings) throws {
        guard value != settings else { return }
        try transaction { try writeSettings(value) }; settings = value
    }
    func entries(limit: Int = 500) throws -> [KnowledgeEntry] {
        var result: [KnowledgeEntry] = []
        try query("SELECT payload FROM entries ORDER BY source_date DESC, id LIMIT ?", [.int(min(10_000, max(0, limit)))]) { statement in
            result.append(try decode(statement, column: 0))
        }
        return result
    }
    func coverage() throws -> KnowledgeCoverage {
        var counts: [KnowledgeKind: Int] = [:]
        try query("SELECT kind, count(*) FROM entries GROUP BY kind") { statement in
            guard let kind = KnowledgeKind(rawValue: columnText(statement, 0)) else { throw KnowledgeFailure.corrupt }
            counts[kind] = Int(sqlite3_column_int64(statement, 1))
        }
        return KnowledgeCoverage(entries: counts.values.reduce(0, +), sourceBytes: try scalarInt("SELECT COALESCE(sum(bytes),0) FROM entries"),
                                 databaseBytes: try scalarInt("PRAGMA page_count") * scalarInt("PRAGMA page_size"), totalDatabaseBytes: try totalDatabaseBytes(), maximumBytes: maximumBytes, maximumSourceBytes: (maximumBytes - 262_144) / 4,
                                 suppressedSources: try scalarInt("SELECT count(*) FROM suppressed"), counts: counts, lastCapture: lastCapture, captureIsFull: captureIsFull)
    }
    func search(_ queryText: String, limit: Int = 20) throws -> [KnowledgeSearchHit] {
        guard let expression = KnowledgePolicy.matchExpression(queryText) else { return [] }
        var result: [KnowledgeSearchHit] = []; var seen: Set<String> = []
        // Overfetch bounded chunks, then deduplicate the source. Every database is one scope.
        try query("SELECT entries.payload FROM chunks JOIN entries ON entries.id=chunks.entry_id WHERE chunks MATCH ? ORDER BY bm25(chunks) LIMIT ?",
                  [.text(expression), .int(min(200, max(0, limit) * 8))]) { statement in
            let entry = try decode(statement, column: 0)
            if seen.insert(entry.id).inserted, result.count < min(50, max(0, limit)),
               let excerpt = KnowledgePolicy.excerpt(entry.text, query: queryText) {
                result.append(KnowledgeSearchHit(entry: entry, excerpt: excerpt))
            }
        }
        return result
    }
    func context(query: String, maximumCharacters: Int = 3_000) throws -> String {
        let cap = min(6_000, max(0, maximumCharacters)); guard cap > 0 else { return "" }
        var output = ""
        for hit in try search(query, limit: 6) {
            let label = hit.entry.source.label
            // Retain full provenance in storage/detail view, but reserve room for evidence
            // in small model-tool responses. The suffix keeps pinned revisions visible.
            let renderedLabel = label.count > 160 ? String(label.prefix(95)) + " … " + String(label.suffix(60)) : label
            let value = "\n[Offline \(hit.entry.kind.label); source: \(renderedLabel); saved \(hit.entry.sourceDate.ISO8601Format()); not checked live]\n\(hit.excerpt)\n"
            output += String(value.prefix(max(0, cap - output.count)))
            if output.count >= cap { break }
        }
        return output
    }

    /// Call only after successful canonical persistence, using the entire SavedState, not a
    /// truncated view. Notes stay in the canonical store and are deliberately not duplicated.
    @discardableResult func captureSavedState(_ state: SavedState) throws -> KnowledgeCaptureReport {
        var report = KnowledgeCaptureReport()
        let chats = state.chats.filter { $0.project == scope.project }
        guard Set(chats.map(\.id)).count == chats.count else { throw KnowledgeFailure.invalidContent }
        let identifiers = Set(chats.map { "chat:" + $0.id.uuidString.lowercased() })
        var existing: [String: String] = [:]
        try query("SELECT id, fingerprint FROM entries WHERE kind='conversation'") { statement in
            existing[columnText(statement, 0)] = columnText(statement, 1)
        }
        // Commit canonical deletions independently: a later quota failure while adding new
        // chats must never roll back removal of a conversation the user already deleted.
        let removed = existing.keys.filter { !identifiers.contains($0) }
        if !removed.isEmpty { try transaction { for id in removed { try suppressAndDelete(id) } } }
        guard settings.captureConversations else { lastCapture = report; return report }
        var suppressed: Set<String> = []
        try query("SELECT id FROM suppressed") { suppressed.insert(columnText($0, 0)) }
        let cutoff = try clearCutoff()
        do {
            try transaction {
                for chat in chats {
                    let entry = KnowledgeEntry(id: "chat:" + chat.id.uuidString.lowercased(), kind: .conversation, text: chat.text,
                                               source: .conversation(role: chat.role), sourceDate: chat.date, cachedAt: Date(), byteCount: chat.text.utf8.count)
                    if suppressed.contains(entry.id) || entry.sourceDate.timeIntervalSince1970 <= cutoff { report.suppressed += 1; continue }
                    // Unchanged records need neither repeated secret scanning nor SQL reads.
                    if existing[entry.id] == fingerprint(entry) { continue }
                    guard ["user", "assistant"].contains(chat.role), (try? KnowledgePolicy.validateText(chat.text)) != nil else { report.rejected += 1; continue }
                    if try insert(entry) { report.stored += 1 }
                }
            }
            lastCapture = report
            return report
        } catch { if error as? KnowledgeFailure == .quota { captureIsFull = true }; throw error }
    }
    func captureAction(id: UUID, kind: KnowledgeActionKind, status: KnowledgeActionStatus, date: Date = Date()) throws {
        guard settings.captureActions else { return }
        let text = "\(kind.label): \(status.rawValue)"
        let entry = KnowledgeEntry(id: "action:" + id.uuidString.lowercased(), kind: .action, text: text, source: .action,
                                   sourceDate: date, cachedAt: Date(), byteCount: text.utf8.count)
        try transaction { if !(try isSuppressed(entry)) { _ = try insert(entry) } }
    }
    /// Call only with successful, validated source text. Never pass provider errors/headers.
    /// The caller must revalidate its active account/project immediately before this call.
    func captureResearch(text: String, source: KnowledgeSource, date: Date = Date()) throws {
        guard settings.captureResearch else { return }
        guard [.repository, .web].contains(source.origin),
              source.origin != .repository || source.repositoryName == scope.repository else { throw KnowledgeFailure.invalidScope }
        try KnowledgePolicy.validateText(text)
        let stableID = "research:" + KnowledgePolicy.digest(source.label + "\u{0}" + text)
        let entry = KnowledgeEntry(id: stableID, kind: .research, text: text, source: source,
                                   sourceDate: date, cachedAt: Date(), byteCount: text.utf8.count)
        try transaction {
            if !(try isSuppressed(entry)), try scalarInt("SELECT count(*) FROM entries WHERE id=?", [.text(entry.id)]) == 0 { _ = try insert(entry) }
        }
    }
    /// The UI obtains bytes only from the user's security-scoped document picker.
    /// Content-addressed IDs prevent duplicate or renamed imports from reviving deleted files.
    func importText(_ data: Data, filename: String, date: Date = Date()) throws {
        guard data.count <= KnowledgePolicy.maximumDocumentBytes else { throw KnowledgeFailure.oversizedFile }
        try KnowledgePolicy.validateFilename(filename)
        guard let text = String(data: data, encoding: .utf8) else { throw KnowledgeFailure.unsupportedFile }
        try KnowledgePolicy.validateText(text)
        let digest = KnowledgePolicy.digest(text)
        let entry = KnowledgeEntry(id: "file:" + digest, kind: .selectedFile, text: text, source: .file(name: filename, digest: digest),
                                   sourceDate: date, cachedAt: Date(), byteCount: data.count)
        try transaction {
            guard !(try isSuppressed(entry)) else { throw KnowledgeFailure.suppressed }
            // Same bytes under another filename still refer to the original immutable import.
            if try scalarInt("SELECT count(*) FROM entries WHERE id=?", [.text(entry.id)]) == 0 { _ = try insert(entry) }
        }
    }
    func delete(id: String) throws {
        try transaction { try suppressAndDelete(id) }; captureIsFull = false
    }
    func clear(now: Date = Date()) throws {
        guard now.timeIntervalSince1970.isFinite, now.timeIntervalSince1970 >= 0 else { throw KnowledgeFailure.invalidContent }
        try transaction {
            var ids: [String] = []
            try query("SELECT id FROM entries") { ids.append(columnText($0, 0)) }
            for id in ids { try suppressAndDelete(id) }
            let previous = try clearCutoff()
            try execute("UPDATE metadata SET value=? WHERE key='clear_before'", [.text(String(max(previous, now.timeIntervalSince1970)))])
        }
        captureIsFull = false
    }
    func expiredAutomaticCount(now: Date = Date()) throws -> Int {
        guard let days = settings.retention.days else { return 0 }
        return try scalarInt("SELECT count(*) FROM entries WHERE kind!='selectedFile' AND source_date < ?", [.double(now.addingTimeInterval(-Double(days) * 86_400).timeIntervalSince1970)])
    }
    /// Retention is a review setting, not silent eviction. The UI confirms this deletion.
    func deleteExpiredAutomaticEntries(now: Date = Date()) throws {
        guard let days = settings.retention.days else { return }
        try transaction {
            var ids: [String] = []
            try query("SELECT id FROM entries WHERE kind!='selectedFile' AND source_date < ?", [.double(now.addingTimeInterval(-Double(days) * 86_400).timeIntervalSince1970)]) { ids.append(columnText($0, 0)) }
            for id in ids { try suppressAndDelete(id) }
        }
        captureIsFull = false
    }

    private func insert(_ entry: KnowledgeEntry) throws -> Bool {
        try KnowledgePolicy.validateText(entry.text)
        guard entry.sourceDate.timeIntervalSince1970.isFinite, entry.cachedAt.timeIntervalSince1970.isFinite,
              entry.source.label.utf8.count <= 1_000, KnowledgePolicy.isSafe(entry.source.label) else { throw KnowledgeFailure.invalidContent }
        var existing: KnowledgeEntry?
        try query("SELECT payload FROM entries WHERE id=?", [.text(entry.id)]) { existing = try decode($0, column: 0) }
        if let existing {
            guard existing.text == entry.text, existing.source == entry.source, existing.sourceDate == entry.sourceDate, existing.kind == entry.kind else { throw KnowledgeFailure.changedSource }
            return false
        }
        // Reserve storage for deletion suppression. Never evict intentional memories.
        let bytes = try scalarInt("SELECT COALESCE(sum(bytes),0) FROM entries")
        let usedPages = try scalarInt("PRAGMA page_count") - scalarInt("PRAGMA freelist_count")
        let usedBytes = try usedPages * scalarInt("PRAGMA page_size")
        let deletionReserve = min(2_097_152, maximumBytes / 4)
        guard let otherAllocated = transactionOtherBytes else { throw KnowledgeFailure.unavailable }
        let pageSize = try scalarInt("PRAGMA page_size")
        let insertionPageLimit = (maximumBytes - otherAllocated - deletionReserve) / pageSize
        if !insertionLimitApplied {
            guard insertionPageLimit > 0, try scalarInt("PRAGMA page_count") <= insertionPageLimit else {
                captureIsFull = true; throw KnowledgeFailure.quota
            }
            // FTS can allocate pages while committing. SQLite itself enforces the reserved
            // ceiling, not just our estimate of source/index overhead before insertion.
            _ = try scalarInt("PRAGMA max_page_count=\(insertionPageLimit)")
            insertionLimitApplied = true
        }
        guard otherAllocated + usedBytes + max(entry.byteCount * 12, 8_192) <= maximumBytes - deletionReserve,
              bytes + entry.byteCount <= (maximumBytes - 262_144) / 4,
              try scalarInt("SELECT count(*) FROM entries") < KnowledgePolicy.maximumRecords,
              try scalarInt("SELECT count(*) FROM suppressed") < KnowledgePolicy.maximumTombstones - KnowledgePolicy.maximumRecords else {
            captureIsFull = true; throw KnowledgeFailure.quota
        }
        let data = try JSONEncoder().encode(entry)
        try execute("INSERT INTO entries(id,kind,source_date,bytes,fingerprint,payload) VALUES(?,?,?,?,?,?)",
                    [.text(entry.id), .text(entry.kind.rawValue), .double(entry.sourceDate.timeIntervalSince1970), .int(entry.byteCount), .text(fingerprint(entry)), .data(data)])
        for chunk in KnowledgePolicy.chunks(entry.text) {
            try execute("INSERT INTO chunks(entry_id,text) VALUES(?,?)", [.text(entry.id), .text(chunk)])
        }
        return true
    }
    private func fingerprint(_ entry: KnowledgeEntry) -> String {
        KnowledgePolicy.digest(entry.kind.rawValue + "\u{0}" + entry.source.label + "\u{0}" + String(entry.sourceDate.timeIntervalSince1970) + "\u{0}" + entry.text)
    }
    private func isSuppressed(_ entry: KnowledgeEntry) throws -> Bool {
        if try scalarInt("SELECT count(*) FROM suppressed WHERE id=?", [.text(entry.id)]) > 0 { return true }
        guard entry.isAutomatic else { return false }
        let cutoff = try clearCutoff()
        return entry.sourceDate.timeIntervalSince1970 <= cutoff
    }
    private func clearCutoff() throws -> Double {
        guard let value = try scalarText("SELECT value FROM metadata WHERE key='clear_before'"),
              let cutoff = Double(value), cutoff.isFinite, cutoff >= 0 else {
            blocked = true; throw KnowledgeFailure.corrupt
        }
        return cutoff
    }
    private func suppressAndDelete(_ id: String) throws {
        guard try scalarInt("SELECT count(*) FROM entries WHERE id=?", [.text(id)]) > 0 else { return }
        guard try scalarInt("SELECT count(*) FROM suppressed") < KnowledgePolicy.maximumTombstones else { throw KnowledgeFailure.quota }
        try execute("INSERT OR IGNORE INTO suppressed(id) VALUES(?)", [.text(id)])
        try execute("DELETE FROM chunks WHERE entry_id=?", [.text(id)])
        try execute("DELETE FROM entries WHERE id=?", [.text(id)])
    }
    private func writeSettings(_ settings: KnowledgeSettings) throws {
        let data = try JSONEncoder().encode(settings)
        guard let text = String(data: data, encoding: .utf8) else { throw KnowledgeFailure.unavailable }
        try execute("INSERT OR REPLACE INTO metadata(key,value) VALUES('settings',?)", [.text(text)])
    }
    private func decode(_ statement: OpaquePointer, column: Int32) throws -> KnowledgeEntry {
        let count = Int(sqlite3_column_bytes(statement, column))
        guard count > 0, count <= KnowledgePolicy.maximumDocumentBytes * 6,
              let pointer = sqlite3_column_blob(statement, column),
              let entry = try? JSONDecoder().decode(KnowledgeEntry.self, from: Data(bytes: pointer, count: count)),
              entry.byteCount == entry.text.utf8.count, (try? KnowledgePolicy.validateText(entry.text)) != nil,
              KnowledgePolicy.isSafe(entry.source.label) else { blocked = true; throw KnowledgeFailure.corrupt }
        return entry
    }
    private enum Value { case text(String), int(Int), double(Double), data(Data) }
    private func check(_ result: Int32) throws {
        guard result == SQLITE_OK || result == SQLITE_ROW || result == SQLITE_DONE else {
            if result == SQLITE_FULL { captureIsFull = true; throw KnowledgeFailure.quota }
            if result == SQLITE_CORRUPT || result == SQLITE_NOTADB || result == SQLITE_SCHEMA || result == SQLITE_ERROR { blocked = true; throw KnowledgeFailure.corrupt }
            throw KnowledgeFailure.unavailable
        }
    }
    private func query(_ sql: String, _ bindings: [Value] = [], row: (OpaquePointer) throws -> Void) throws {
        guard !blocked, let database else { throw KnowledgeFailure.corrupt }
        var statement: OpaquePointer?
        try check(sqlite3_prepare_v2(database, sql, -1, &statement, nil))
        guard let statement else { throw KnowledgeFailure.unavailable }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (index, value) in bindings.enumerated() {
            let position = Int32(index + 1)
            switch value {
            case .text(let string): try check(sqlite3_bind_text(statement, position, string, -1, transient))
            case .int(let integer): try check(sqlite3_bind_int64(statement, position, Int64(integer)))
            case .double(let number): try check(sqlite3_bind_double(statement, position, number))
            case .data(let data): try data.withUnsafeBytes { buffer in try check(sqlite3_bind_blob(statement, position, buffer.baseAddress, Int32(buffer.count), transient)) }
            }
        }
        while true {
            let status = sqlite3_step(statement); try check(status)
            if status == SQLITE_DONE { break }
            try row(statement)
        }
    }
    private func execute(_ sql: String, _ bindings: [Value] = []) throws { try query(sql, bindings) { _ in } }
    private func scalarInt(_ sql: String, _ bindings: [Value] = []) throws -> Int {
        var result = 0; try query(sql, bindings) { result = Int(sqlite3_column_int64($0, 0)) }; return result
    }
    private func scalarText(_ sql: String, _ bindings: [Value] = []) throws -> String? {
        var result: String?; try query(sql, bindings) { result = columnText($0, 0) }; return result
    }
    private func columnText(_ statement: OpaquePointer, _ column: Int32) -> String {
        guard let pointer = sqlite3_column_text(statement, column) else { return "" }; return String(cString: pointer)
    }
    private func totalDatabaseBytes() throws -> Int {
        // Enumerate only this cache's hashed scope directories, never user-selected folders.
        let folders = try FileManager.default.contentsOfDirectory(at: libraryRoot, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        var total = 0
        for folder in folders where folder.lastPathComponent.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil {
            let attributes = try folder.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard attributes.isDirectory == true, attributes.isSymbolicLink != true else { throw KnowledgeFailure.corrupt }
            let url = folder.appendingPathComponent("knowledge.sqlite3")
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true, let size = values.fileSize, size >= 0 else { throw KnowledgeFailure.corrupt }
            total += size
        }
        return total
    }
    private func transaction(_ operation: () throws -> Void) throws {
        // All instances live on MainActor. Recompute the global disk allowance before each
        // transaction so another project's cache cannot consume the same remaining bytes.
        let pageSize = try scalarInt("PRAGMA page_size")
        let ownBytes = try scalarInt("PRAGMA page_count") * pageSize
        let otherBytes = max(0, try totalDatabaseBytes() - ownBytes)
        guard pageSize > 0, otherBytes + ownBytes <= maximumBytes else { throw KnowledgeFailure.quota }
        _ = try scalarInt("PRAGMA max_page_count=\((maximumBytes - otherBytes) / pageSize)")
        let changesBefore = sqlite3_total_changes(database)
        try execute("BEGIN IMMEDIATE")
        transactionOtherBytes = otherBytes; insertionLimitApplied = false
        var changed = false
        defer {
            transactionOtherBytes = nil; insertionLimitApplied = false
            if changed { onMutation?() }
        }
        do {
            try operation(); try execute("COMMIT")
            changed = sqlite3_total_changes(database) != changesBefore
        }
        catch {
            // Roll back even after a corruption flag disabled normal statements.
            sqlite3_exec(database, "ROLLBACK", nil, nil, nil)
            throw error
        }
    }
}

@MainActor extension KnowledgeCache {
    func syncSnapshot() throws -> KnowledgeSyncSnapshot {
        let descriptor = try syncScopeDescriptor()
        var suppressed: [String] = []
        try query("SELECT id FROM suppressed ORDER BY id") { suppressed.append(columnText($0, 0)) }
        let cutoff = try clearCutoff()
        return try KnowledgeSyncSnapshot(accountID: descriptor.accountID, project: descriptor.project,
                                         repository: descriptor.repository, entries: entries(limit: KnowledgePolicy.maximumRecords),
                                         suppressedIDs: suppressed, clearBefore: cutoff > 0 ? Date(timeIntervalSince1970: cutoff) : nil).validated()
    }

    /// Deletions are monotonic and committed before additions, so quota/conflict failures
    /// cannot undo a deletion that another device already confirmed.
    func applySyncSnapshot(_ incoming: KnowledgeSyncSnapshot, canonicalState: SavedState? = nil) throws {
        let incoming = try incoming.validated()
        let canonicalIDs = try incoming.canonicalConversationIDs(in: canonicalState)
        let incomingScope = try incoming.scope
        guard incomingScope.storageKey == scope.storageKey,
              incomingScope.accountID == scope.accountID, incomingScope.project == scope.project else { throw KnowledgeFailure.invalidScope }
        let local = try syncScopeDescriptor()
        guard incoming.repository == nil || local.repository == nil || incoming.repository == local.repository else {
            throw KnowledgeFailure.invalidScope
        }
        try transaction {
            if local.repository == nil, let repository = incoming.repository {
                try execute("UPDATE metadata SET value=? WHERE key='repository'", [.text(repository)])
            }
            if let remoteCutoff = incoming.clearBefore?.timeIntervalSince1970, remoteCutoff > (try clearCutoff()) {
                try execute("UPDATE metadata SET value=? WHERE key='clear_before'", [.text(String(remoteCutoff))])
            }
            let cutoff = Date(timeIntervalSince1970: try clearCutoff())
            let deleted = Set(incoming.suppressedIDs)
            for entry in try entries(limit: KnowledgePolicy.maximumRecords) where deleted.contains(entry.id) || entry.predatesSyncClear(cutoff) {
                try suppressAndDelete(entry.id)
            }
        }
        // A full union may exceed the marker budget. Preserve the cutoff and deletions
        // of locally present copies first; fail visibly rather than truncating history.
        try transaction {
            for id in incoming.suppressedIDs { try retainSuppression(id) }
            let cutoff = Date(timeIntervalSince1970: try clearCutoff())
            // Preserve IDs for previously unseen stale imports as well. A later snapshot
            // cannot revive an old file by presenting a different cache timestamp.
            for entry in incoming.entries where entry.predatesSyncClear(cutoff) { try retainSuppression(entry.id) }
        }
        try storeSyncScopeDescriptor()
        try transaction {
            for entry in incoming.entries where !(try isSuppressed(entry)) {
                try insertSyncedEntry(entry, isCanonicalConversation: canonicalIDs.contains(entry.id))
            }
        }
        captureIsFull = false
    }

    private func insertSyncedEntry(_ entry: KnowledgeEntry, isCanonicalConversation: Bool) throws {
        var existing: KnowledgeEntry?
        try query("SELECT payload FROM entries WHERE id=?", [.text(entry.id)]) { existing = try decode($0, column: 0) }
        guard let existing else { _ = try insert(entry); return }
        if isCanonicalConversation, existing.kind == .conversation, entry.kind == .conversation,
           existing.text != entry.text || existing.source != entry.source || existing.sourceDate != entry.sourceDate {
            // This is a mirror repair after canonical conflict resolution, not a user
            // deletion. Replace the row and FTS chunks atomically without a tombstone.
            try execute("DELETE FROM chunks WHERE entry_id=?", [.text(entry.id)])
            try execute("DELETE FROM entries WHERE id=?", [.text(entry.id)])
            _ = try insert(entry)
            return
        }
        let merged = try existing.mergedSyncCopy(entry)
        guard merged != existing else { return }
        // Text and ID are unchanged, so FTS chunks are already correct. The merge cannot
        // grow filenames; only earliest observation timestamps/provenance are reconciled.
        try execute("UPDATE entries SET source_date=?, fingerprint=?, payload=? WHERE id=?",
                    [.double(merged.sourceDate.timeIntervalSince1970), .text(fingerprint(merged)),
                     .data(try JSONEncoder().encode(merged)), .text(merged.id)])
    }

    /// New databases retain only canonical scope metadata, not a full library manifest.
    /// Existing caches remain discoverable through known SavedState project names.
    private func syncScopeDescriptor() throws -> KnowledgeSyncSnapshot {
        let repository = try scalarText("SELECT value FROM metadata WHERE key='repository'")
        return try KnowledgeSyncSnapshot(accountID: scope.accountID, project: scope.project,
                                         repository: repository.flatMap { $0.isEmpty ? nil : $0 },
                                         entries: [], suppressedIDs: [], clearBefore: nil).validated()
    }

    private func storeSyncScopeDescriptor() throws {
        // Low-level callers may use noncanonical local test/migration scopes. They remain
        // local: the bridge never invents a trusted identity from their arbitrary labels.
        guard let descriptor = try? syncScopeDescriptor() else { return }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let text = String(decoding: try encoder.encode(descriptor), as: UTF8.self)
        guard try scalarText("SELECT value FROM metadata WHERE key='sync_scope'") != text else { return }
        try transaction { try execute("INSERT OR REPLACE INTO metadata(key,value) VALUES('sync_scope',?)", [.text(text)]) }
    }

    private func retainSuppression(_ id: String) throws {
        guard KnowledgeSyncSnapshot.validID(id) else { throw KnowledgeFailure.invalidContent }
        if try scalarInt("SELECT count(*) FROM suppressed WHERE id=?", [.text(id)]) == 0 {
            guard try scalarInt("SELECT count(*) FROM suppressed") < KnowledgePolicy.maximumTombstones else { throw KnowledgeFailure.quota }
            try execute("INSERT INTO suppressed(id) VALUES(?)", [.text(id)])
        }
        try execute("DELETE FROM chunks WHERE entry_id=?", [.text(id)])
        try execute("DELETE FROM entries WHERE id=?", [.text(id)])
    }

    private static func validateExistingDirectory(_ folder: URL) throws {
        try validateExistingItem(folder, expectedType: mode_t(S_IFDIR))
    }
    private static func validateExistingDatabase(_ url: URL) throws {
        try validateExistingItem(url, expectedType: mode_t(S_IFREG))
    }
    private static func validateExistingItem(_ url: URL, expectedType: mode_t) throws {
        // lstat sees dangling links too; fileExists follows them and would permit SQLite
        // CREATE to create the link target outside the intended library.
        var information = stat()
        guard lstat(url.path, &information) == 0 else {
            if errno == ENOENT { return }
            throw KnowledgeFailure.unavailable
        }
        guard information.st_mode & mode_t(S_IFMT) == expectedType else { throw KnowledgeFailure.corrupt }
    }

    static func discoveredSyncScopes(root: URL, includePrivateWorkspaces: Bool,
                                     authenticatedAccountID: String?, knownScopeKeys: Set<String> = [],
                                     onUnresolvedLegacyScopes: ((Int) -> Void)? = nil) throws -> [KnowledgeScope] {
        guard FileManager.default.fileExists(atPath: root.path) else { onUnresolvedLegacyScopes?(0); return [] }
        try validateExistingDirectory(root)
        let folders = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        var result: [KnowledgeScope] = []
        var unresolved = 0
        for folder in folders where folder.lastPathComponent.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil {
            try validateExistingDirectory(folder)
            let url = folder.appendingPathComponent("knowledge.sqlite3")
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            try validateExistingDatabase(url)
            guard let descriptor = try readSyncScopeDescriptor(url) else {
                if !knownScopeKeys.contains(folder.lastPathComponent) { unresolved += 1 }
                continue
            }
            let verified = try descriptor.validated()
            let scope = try verified.scope
            guard scope.storageKey == folder.lastPathComponent, verified.entries.isEmpty,
                  verified.suppressedIDs.isEmpty, verified.clearBefore == nil else { throw KnowledgeFailure.corrupt }
            guard verified.isPermitted(includePrivateWorkspaces: includePrivateWorkspaces, authenticatedAccountID: authenticatedAccountID) else { continue }
            result.append(scope)
        }
        onUnresolvedLegacyScopes?(unresolved)
        return result
    }

    private static func readSyncScopeDescriptor(_ url: URL) throws -> KnowledgeSyncSnapshot? {
        var database: OpaquePointer?
        guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX | SQLITE_OPEN_NOFOLLOW, nil) == SQLITE_OK else {
            if let database { sqlite3_close(database) }; throw KnowledgeFailure.unavailable
        }
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "SELECT value FROM metadata WHERE key='sync_scope'", -1, &statement, nil) == SQLITE_OK else {
            throw KnowledgeFailure.corrupt
        }
        defer { sqlite3_finalize(statement) }
        let result = sqlite3_step(statement)
        if result == SQLITE_DONE { return nil }
        guard result == SQLITE_ROW, let value = sqlite3_column_text(statement, 0),
              sqlite3_column_bytes(statement, 0) <= 4_096 else { throw KnowledgeFailure.corrupt }
        let data = Data(bytes: value, count: Int(sqlite3_column_bytes(statement, 0)))
        guard let descriptor = try? JSONDecoder().decode(KnowledgeSyncSnapshot.self, from: data) else { throw KnowledgeFailure.corrupt }
        return descriptor
    }
}
