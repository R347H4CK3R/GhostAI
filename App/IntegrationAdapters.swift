import Foundation

// These are declarations for existing app features, not new transports. Their screens
// continue to own execution, credentials and user confirmation independently of this catalog.
struct AppleLocalModelIntegration: IntegrationAdapter {
    static let descriptor = IntegrationDescriptor(id: "apple.local-model", version: .init(major: 1, minor: 0, patch: 0),
        name: "Apple on-device assistant", summary: "Answers using the available Apple Foundation Models system model.",
        symbol: "apple.intelligence", setup: "Requires supported hardware, iOS 26, Apple Intelligence and downloaded model assets. No account or key is inherited from ChatGPT.",
        dataDisclosure: "Inference stays on device. The Assistant can use bounded local notes, recent conversation, selected source, indexed offline knowledge and their provenance. Optional GitHub tools have their own network boundary.",
        operations: [.init(id: "answer", name: "Answer a question", access: .read, resourceKind: .project,
            recipient: .onDevice, dataScopes: [.question, .projectNotes, .selectedSource, .recentConversation, .cachedKnowledge, .repositoryIdentity, .repositoryPath, .pinnedRevision], consent: .explicitUserAction)])
}

struct OfflineMemoryIntegration: IntegrationAdapter {
    static let descriptor = IntegrationDescriptor(id: "local.memory", version: .init(major: 1, minor: 0, patch: 0),
        name: "Offline project memory", summary: "Search saved project notes and indexed offline knowledge, and save notes you choose to remember.",
        symbol: "brain", setup: "Uses this app's saved memory. New offline libraries capture eligible conversations, research and fixed activity summaries automatically; existing capture preferences are preserved. Imports and deletion remain explicit. The separate knowledge library is not included in manual chat/note backups. Private GitHub sync has separate reviewed setup and scope.",
        dataDisclosure: "These search/save operations run locally. If private GitHub sync is explicitly configured, eligible notes, chats and saved knowledge are also sent encrypted to the reviewed private repository. Private GitHub workspaces need separate scope consent. Device backups can include local files; manual exports remain separate actions. Notes are retrieved, not permanently trained into a model.",
        operations: [
            .init(id: "search_notes", name: "Search selected project notes", access: .read, resourceKind: .project,
                recipient: .onDevice, dataScopes: [.projectNotes], consent: .userStartedRead, modelCallable: true),
            .init(id: "search_cached_knowledge", name: "Search selected workspace offline knowledge", access: .read, resourceKind: .project,
                recipient: .onDevice, dataScopes: [.cachedKnowledge], consent: .userStartedRead, modelCallable: true),
            .init(id: "save_note", name: "Save a user-selected note", access: .write, resourceKind: .project,
                recipient: .onDevice, dataScopes: [.projectNotes], consent: .explicitUserAction)
        ])
}

struct GitHubReadIntegration: IntegrationAdapter {
    static let descriptor = IntegrationDescriptor(id: "github.read", version: .init(major: 1, minor: 1, patch: 0),
        name: "GitHub source reading", summary: "Read directories and regular text files, or find literal text within one file, in a selected repository at a pinned commit.",
        symbol: "chevron.left.forwardslash.chevron.right", setup: "Public repositories need no token. Private repositories need an explicit read connection in Projects. A read token never grants proposal publication.",
        dataDisclosure: "GitHub receives the repository, requested path and immutable Git object IDs. A private read session sends its credential only to the fixed GitHub API origin. Your notes, chats and local file-search query are not sent.",
        operations: [
            .init(id: "list_tree", name: "List a pinned directory", access: .read, resourceKind: .repository,
                recipient: .githubAPI, dataScopes: [.repositoryIdentity, .repositoryPath, .pinnedRevision, .optionalReadCredential],
                consent: .userStartedRead, modelCallable: true, allowsRootPath: true),
            .init(id: "read_text", name: "Read one pinned text file", access: .read, resourceKind: .repository,
                recipient: .githubAPI, dataScopes: [.repositoryIdentity, .repositoryPath, .pinnedRevision, .optionalReadCredential],
                consent: .userStartedRead, modelCallable: true),
            .init(id: "search_text", name: "Find literal text within one pinned file", access: .read, resourceKind: .repository,
                recipient: .githubAPI, dataScopes: [.repositoryIdentity, .repositoryPath, .pinnedRevision, .optionalReadCredential],
                consent: .userStartedRead, modelCallable: true)
        ])
}

struct OpenAIHostedIntegration: IntegrationAdapter {
    static let descriptor = IntegrationDescriptor(id: "openai.hosted", version: .init(major: 1, minor: 0, patch: 0),
        name: "Optional OpenAI hosted answers", summary: "Send one explicitly reviewed request to the official Responses endpoint.",
        symbol: "cloud", setup: "Open Hosted in a directly installed app, supply an existing API key and choose a model available to that account. The key is session-only. Separate API billing can apply; ChatGPT subscriptions and plugins are not inherited.",
        dataDisclosure: "OpenAI receives only the question, context you enter, chosen model ID and session credential for the reviewed request. No automatic notes, history, repository attachments or tools are included. Review provider terms and possible charges in Hosted.",
        operations: [.init(id: "answer", name: "Send a reviewed question", access: .send, resourceKind: .hostedRequest,
            recipient: .openAIResponses, dataScopes: [.question, .explicitContext, .modelIdentifier, .hostedCredential], consent: .reviewEachRequest)])
}

struct GitHubProposalIntegration: IntegrationAdapter {
    static let descriptor = IntegrationDescriptor(id: "github.proposals", version: .init(major: 1, minor: 0, patch: 0),
        name: "GitHub draft proposals", summary: "Review one existing file change and publish it on a new branch with a draft pull request.",
        symbol: "arrow.triangle.pull", setup: "Select a repository and pinned source in Projects, open a proposal, then review the exact file, diff and destination. Publication needs a separate session write credential and direct-install confirmation. No default write grant.",
        dataDisclosure: "GitHub receives the reviewed replacement file, repository, base commit, new branch and draft PR metadata, plus the separate write credential. The destination repository's existing access rules apply. No merge, base-branch edit, force push or automatic publication.",
        operations: [.init(id: "publish_draft", name: "Publish a reviewed draft PR", access: .write, resourceKind: .proposal,
            recipient: .githubAPI, dataScopes: [.repositoryIdentity, .repositoryPath, .pinnedRevision, .reviewedReplacement, .proposalMetadata, .writeCredential],
            consent: .reviewEachWrite)])
}
