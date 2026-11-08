import Foundation

struct MemoryNote: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    var project: String
    var text: String
    var source: String
    var savedAt = Date()
}
struct ChatEntry: Identifiable, Codable {
    var id = UUID()
    var project: String
    var role: String
    var text: String
    var date = Date()
}
struct SavedState: Codable {
    var version = 1
    var notes: [MemoryNote]
    var chats: [ChatEntry]
}
enum AppFailure: LocalizedError {
    case message(String)
    var errorDescription: String? { if case let .message(s) = self { return s }; return nil }
}
enum MemorySearch {
    // A warning layer, not a complete secret detector. The user reviews every saved note.
    static func canSave(_ text: String) -> Bool {
        let patterns = ["gh[pousr]_", "github_pat_", "-----BEGIN .*PRIVATE KEY", "(?i)(password|api[_ -]?key|access[_ -]?token|secret)\\s*[:=]\\s*\\S+"]
        return !patterns.contains { text.range(of: $0, options: .regularExpression) != nil }
    }
    static func context(_ notes: [MemoryNote], project: String, query: String, budget: Int) -> String {
        let words = Set(query.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { $0.count > 2 })
        let candidates = notes.filter { $0.project == project }.sorted { a, b in
            let scoreA = words.filter { a.text.lowercased().contains($0) }.count
            let scoreB = words.filter { b.text.lowercased().contains($0) }.count
            return scoreA == scoreB ? a.savedAt > b.savedAt : scoreA > scoreB
        }
        var result = ""
        for note in candidates {
            let entry = "\n[Saved \(note.savedAt.ISO8601Format()); source: \(note.source)]\n\(note.text)\n"
            let remaining = max(0, budget - result.count)
            guard remaining > 0 else { break }
            result += String(entry.prefix(remaining))
        }
        return result
    }
}
struct DiskStore {
    let root: URL
    var url: URL { root.appendingPathComponent("state.json") }
    func load() throws -> SavedState {
        guard FileManager.default.fileExists(atPath: url.path) else { return SavedState(notes: [], chats: []) }
        let result = try JSONDecoder().decode(SavedState.self, from: Data(contentsOf: url))
        guard result.version == 1 else { throw AppFailure.message("Unsupported memory format. Existing data has not been changed.") }
        return result
    }
    func recover(_ state: SavedState) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            let preserved = root.appendingPathComponent("unreadable-" + UUID().uuidString + ".json")
            try FileManager.default.copyItem(at: url, to: preserved)
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: preserved.path)
        }
        try save(state)
    }
    func save(_ state: SavedState) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try JSONEncoder().encode(state).write(to: url, options: [.atomic, .completeFileProtection])
    }
}
enum GitHubRoute {
    static func repository(_ value: String) throws -> (String, String) {
        let parts = value.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2, parts.allSatisfy({ $0.range(of: "^[A-Za-z0-9_.-]+$", options: .regularExpression) != nil && $0 != "." && $0 != ".." }) else {
            throw AppFailure.message("Enter a repository as owner/name.")
        }
        return (parts[0], parts[1])
    }
    static func url(_ components: [String], query: [URLQueryItem] = []) throws -> URL {
        guard components.allSatisfy({ !$0.contains("/") && $0 != "." && $0 != ".." && !$0.isEmpty }) else { throw AppFailure.message("Invalid GitHub path.") }
        var result = URLComponents()
        result.scheme = "https"; result.host = "api.github.com"
        result.path = "/" + components.joined(separator: "/")
        result.queryItems = query.isEmpty ? nil : query
        guard let url = result.url else { throw AppFailure.message("Invalid GitHub URL.") }
        return url
    }
}

enum MemoryBackup {
    static func encode(_ state: SavedState) throws -> Data {
        let data = try JSONEncoder().encode(state)
        _ = try decode(data) // Every successful full export must be accepted by our importer.
        return data
    }
    static func decode(_ data: Data) throws -> SavedState {
        guard data.count <= 5_000_000 else { throw AppFailure.message("Backup exceeds the 5 MB import limit.") }
        let state = try JSONDecoder().decode(SavedState.self, from: data)
        guard state.version == 1, state.notes.count <= 10_000, state.chats.count <= 10_000,
              Set(state.notes.map(\.id)).count == state.notes.count,
              Set(state.chats.map(\.id)).count == state.chats.count else {
            throw AppFailure.message("Invalid, duplicate, oversized or unsupported backup records.")
        }
        for note in state.notes {
            guard !note.project.isEmpty, note.project.count <= 300, note.source.count <= 2_000,
                  note.text.count <= 20_000, MemorySearch.canSave(note.text), MemorySearch.canSave(note.source) else {
                throw AppFailure.message("Backup contains an invalid note or a possible credential.")
            }
        }
        for chat in state.chats {
            guard !chat.project.isEmpty, chat.project.count <= 300, ["user", "assistant"].contains(chat.role),
                  chat.text.count <= 100_000, MemorySearch.canSave(chat.text) else {
                throw AppFailure.message("Backup contains an invalid conversation or a possible credential.")
            }
        }
        return state
    }
    static func merge(_ incoming: SavedState, into current: SavedState) -> SavedState {
        // Keep the current record on duplicate ID; imports never overwrite existing records.
        let noteIDs = Set(current.notes.map(\.id)); let chatIDs = Set(current.chats.map(\.id))
        return SavedState(notes: current.notes + incoming.notes.filter { !noteIDs.contains($0.id) },
                          chats: (current.chats + incoming.chats.filter { !chatIDs.contains($0.id) }).sorted {
                              $0.date == $1.date ? $0.id.uuidString < $1.id.uuidString : $0.date < $1.date
                          })
    }
}
