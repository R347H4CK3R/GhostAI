import Foundation

/// Display names never replace canonical workspace identities or authorization scope.
struct WorkspaceDisplay {
    let title: String
    let subtitle: String

    init(_ workspace: String) {
        var repository = workspace
        var account: String?
        let prefix = "GitHub account "
        if workspace.hasPrefix(prefix) {
            let remainder = String(workspace.dropFirst(prefix.count))
            guard let separator = remainder.range(of: ": "),
                  (try? KnowledgeWorkspacePolicy.scope(workspace: workspace)) != nil else {
                title = workspace; subtitle = "Saved workspace"; return
            }
            account = String(remainder[..<separator.lowerBound])
            repository = String(remainder[separator.upperBound...])
        }
        if let (owner, name) = try? GitHubRoute.repository(repository) {
            title = name
            subtitle = owner + (account.map { " · Account \($0)" } ?? "")
        } else {
            title = workspace
            subtitle = workspace == "General" ? "Your everyday workspace" : "Saved workspace"
        }
    }
}

struct SavedWorkspaceSummary: Identifiable {
    let id: String
    let noteCount: Int
    let messageCount: Int
    let updatedAt: Date?
}

enum LibraryPresentation {
    static func matches(_ query: String, in values: [String]) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || values.contains {
            $0.range(of: trimmed, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }

    static func notes(_ notes: [MemoryNote], project: String, query: String) -> [MemoryNote] {
        notes.filter { $0.project == project && matches(query, in: [$0.text, $0.source]) }.sorted {
            $0.savedAt == $1.savedAt ? $0.id.uuidString < $1.id.uuidString : $0.savedAt > $1.savedAt
        }
    }

    static func workspaces(state: SavedState, current: String, query: String) -> [SavedWorkspaceSummary] {
        let notes = Dictionary(grouping: state.notes, by: \.project)
        let chats = Dictionary(grouping: state.chats, by: \.project)
        let names = Set(notes.keys).union(chats.keys).union(["General", current])
        return names.filter { matches(query, in: [$0]) }.map { name in
            SavedWorkspaceSummary(id: name, noteCount: notes[name]?.count ?? 0,
                messageCount: chats[name]?.count ?? 0,
                updatedAt: ((notes[name] ?? []).map(\.savedAt) + (chats[name] ?? []).map(\.date)).max())
        }.sorted {
            if ($0.id == current) != ($1.id == current) { return $0.id == current }
            let first = $0.updatedAt ?? .distantPast, second = $1.updatedAt ?? .distantPast
            if first != second { return first > second }
            return $0.id.localizedStandardCompare($1.id) == .orderedAscending
        }
    }

    static func repositories(_ repositories: [Repository], query: String) -> [Repository] {
        repositories.filter { matches(query, in: [$0.full_name, $0.default_branch]) }.sorted {
            let first = WorkspaceDisplay($0.full_name).title, second = WorkspaceDisplay($1.full_name).title
            if first != second { return first.localizedStandardCompare(second) == .orderedAscending }
            return $0.full_name == $1.full_name ? $0.id < $1.id : $0.full_name < $1.full_name
        }
    }
}
