#if DEBUG
import SwiftUI
import Foundation

/// Synthetic review display only. The launcher selects this before constructing
/// ordinary stores/services. No disk, credential, GitHub client or publisher exists.
enum RepositoryProposalReviewUITestFixture {
    static var isEnabled: Bool { ProcessInfo.processInfo.arguments.contains("--uitest-proposal-review") }
    static let original = "let greeting = \"Hello\"\r\nprint(greeting)\n"
    static let replacement = "let greeting = \"Hello, Jarvis\"\nprint(greeting)\n"

    static func review() async throws -> RepositoryProposalReview {
        let pinned = String(repeating: "a", count: 40)
        let blob = RepositoryProposalPolicy.blobSHA(original)
        let file = RepoFile(name: "Welcome.swift", path: "Welcome.swift", type: "file", sha: blob, size: original.utf8.count)
        let reader = RepositoryToolReader(tree: { sha, cap in
            guard sha == pinned, cap >= 100 else { throw RepositoryProposalFailure.invalidResponse }
            return ([file], 100)
        }, text: { entry, cap in
            guard entry == file, cap >= original.utf8.count else { throw RepositoryProposalFailure.invalidResponse }
            return (original, original.utf8.count)
        })
        let source = try await RepositoryProposalSource.load(repository: Repository(id: 42, full_name: "example/project", default_branch: "main"),
            immutableCommit: pinned, path: "Welcome.swift", reader: reader)
        return try RepositoryProposalReview(source: source, replacement: replacement, title: "Update the sample greeting")
    }
}

@MainActor struct RepositoryProposalReviewUITestApp: App {
    var body: some Scene { WindowGroup { RepositoryProposalReviewUITestHost() } }
}

private struct RepositoryProposalReviewUITestHost: View {
    @State private var review: RepositoryProposalReview?
    @State private var failed = false
    var body: some View {
        NavigationStack {
            Form {
                if let review { RepositoryProposalReviewContent(review: review) }
                else if failed { Text("Synthetic review failed to load") }
                else { ProgressView("Preparing synthetic review") }
            }.navigationTitle("Synthetic proposal review")
        }.task {
            do { review = try await RepositoryProposalReviewUITestFixture.review() }
            catch { failed = true }
        }
    }
}
#endif
