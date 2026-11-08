import Foundation

/// A pure mapping from existing canonical workspace names. It never opens Keychain, reads
/// a token, contacts GitHub, or treats a display name as an authenticated account identity.
enum KnowledgeWorkspacePolicy {
    static func scope(workspace: String, liveRepository: String? = nil) throws -> KnowledgeScope {
        let prefix = "GitHub account "
        let accountID: String
        if workspace.hasPrefix(prefix) {
            let remainder = String(workspace.dropFirst(prefix.count))
            guard let separator = remainder.range(of: ": ") else { throw KnowledgeFailure.invalidScope }
            let identifier = String(remainder[..<separator.lowerBound])
            let repository = String(remainder[separator.upperBound...])
            guard let numericID = Int(identifier), numericID > 0, String(numericID) == identifier,
                  (try? GitHubRoute.repository(repository)) != nil,
                  liveRepository == nil || liveRepository == repository else { throw KnowledgeFailure.invalidScope }
            accountID = "github-user-\(numericID)"
        } else {
            // Public repository workspaces and ordinary local projects use a separate local
            // identity. A live repository must be the workspace the user actually selected.
            guard liveRepository == nil || liveRepository == workspace else { throw KnowledgeFailure.invalidScope }
            accountID = "device-local"
        }
        return try KnowledgeScope(accountID: accountID, project: workspace, repository: liveRepository)
    }
}

/// Keeps offline retrieval within the same small context envelope as live repository tools.
struct KnowledgePromptBudget: Equatable {
    let initialCharacters: Int
    let recentMessages: Int
    let recentMessageCharacters: Int
    let knowledgeCharactersPerCall: Int
    init(hasRepository: Bool, hasKnowledge: Bool) {
        let constrained = hasRepository || hasKnowledge
        initialCharacters = constrained ? 1_000 : 3_000
        recentMessages = constrained ? 2 : 4
        recentMessageCharacters = constrained ? 300 : 500
        knowledgeCharactersPerCall = hasKnowledge ? 500 : 0
    }
}
