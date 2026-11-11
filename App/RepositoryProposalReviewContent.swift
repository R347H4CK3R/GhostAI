import SwiftUI

/// Complete immutable publication review; this component cannot initiate writes.
struct RepositoryProposalReviewContent: View {
    let review: RepositoryProposalReview

    var body: some View {
        Section("Complete original · \(review.original.utf8.count) bytes") {
            Text(verbatim: review.original.isEmpty ? "[empty file]" : review.original)
                .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("proposal-original-review")
        }
        Section("Complete replacement · \(review.replacement.utf8.count) bytes") {
            Text(verbatim: review.replacement.isEmpty ? "[empty file]" : review.replacement)
                .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("proposal-new-review")
        }
        Section("Exact publication destination") {
            Text(verbatim: review.disclosure).font(.callout).textSelection(.enabled)
            Text("PR title and commit message").font(.caption.bold())
            Text(verbatim: review.title).textSelection(.enabled)
            Text("Complete PR body").font(.caption.bold())
            Text(verbatim: review.pullRequestBody).font(.caption.monospaced()).textSelection(.enabled)
            Text("The full old and new files are shown above, without excerpting. Secret and path checks are conservative heuristics, not a guarantee. Review the actual code and repository permissions before publishing.").font(.caption).foregroundStyle(.orange)
        }
    }
}
