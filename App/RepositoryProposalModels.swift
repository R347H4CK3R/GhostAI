import Foundation
import CryptoKit

/// No server body, request, token, arbitrary URL or upstream error is included in these errors.
enum RepositoryProposalFailure: LocalizedError, Equatable {
    case invalidScope, invalidPath, unsafeFile, unsafeText, invalidTitle, sourceMismatch
    case consentChanged, directInstallRequired, invalidToken, credentialEnded, readFailed, invalidResponse
    case baseChanged, denied, uncertain, cancelled, receiptUnavailable, previousAttempt, receiptChanged, receiptCapacity

    var errorDescription: String? {
        switch self {
        case .invalidScope: return "Select a valid repository, base branch and immutable 40-character commit."
        case .invalidPath: return "Choose one existing source or documentation file. Hidden paths, traversal, automation, configuration and security-sensitive paths are excluded."
        case .unsafeFile: return "Only existing, non-executable regular text files up to 30 KB are eligible. Links and submodules are excluded."
        case .unsafeText: return "Text contains a possible secret, hidden control character or exceeds 30 KB. It cannot be published here."
        case .invalidTitle: return "Use a nonempty plain title up to 120 bytes, without mentions, controls or possible secrets."
        case .sourceMismatch: return "The original source did not match its pinned Git blob. Reload the source before reviewing."
        case .consentChanged: return "The proposal or approval changed. Review the complete current proposal and confirm its destination again."
        case .directInstallRequired: return "Write credentials require a directly installed app. Never enter them in Strata or another host."
        case .invalidToken: return "Enter a fine-grained GitHub token. Classic tokens and whitespace are not accepted."
        case .credentialEnded: return "The separate write credential has expired or was revoked. No fallback credential was used."
        case .readFailed: return "The pinned source could not be read securely. No write was attempted."
        case .invalidResponse: return "GitHub returned an unsupported or inconsistent response."
        case .baseChanged: return "The repository or base branch changed since selection. Reload it and review a new proposal."
        case .denied: return "GitHub rejected the request. No automatic retry or cleanup was made."
        case .uncertain: return "A write may have reached GitHub, but its result could not be verified. Stop here and inspect GitHub before taking further action."
        case .receiptChanged: return "The saved publication is still active or its status changed. Review its final status before recording your inspection."
        case .receiptCapacity: return "The local recovery receipt limit was reached. Publication is blocked and existing records are retained. Export the needed statuses before managing local storage."
        case .receiptUnavailable: return "The local recovery receipt could not be read or saved. Publication is blocked. Save any displayed status and inspect GitHub before trying a new proposal."
        case .previousAttempt: return "A previous publication receipt requires inspection, or this exact attempt already ran. No request was replayed. Inspect GitHub and the saved status first."
        case .cancelled: return "Publication was cancelled. Confirmed work remains on GitHub; nothing was deleted."
        }
    }
}

enum RepositoryProposalPolicy {
    static let maximumTextBytes = 30_000
    static let maximumResponseBytes = 180_000

    static func validateScope(_ repository: Repository, commit: String) throws {
        guard repository.id > 0, repository.full_name.utf8.count <= 200, MemorySearch.canSave(repository.full_name),
              (try? GitHubRoute.repository(repository.full_name)) != nil,
              RepositoryToolPolicy.isObjectSHA(commit) else { throw RepositoryProposalFailure.invalidScope }
        try validateBranch(repository.default_branch)
    }

    static func validateBranch(_ branch: String) throws {
        guard !branch.isEmpty, branch.utf8.count <= 200, !branch.contains(".."),
              !branch.contains("@{"), !branch.hasSuffix("."),
              branch.split(separator: "/", omittingEmptySubsequences: false).allSatisfy({
                  !$0.isEmpty && !$0.hasPrefix(".") && !$0.hasSuffix(".lock")
              }), branch.utf8.allSatisfy({ byte in
                  (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte)
                    || [45, 46, 47, 95].contains(byte)
              }), MemorySearch.canSave(branch) else { throw RepositoryProposalFailure.invalidScope }
    }

    static func validatePath(_ path: String) throws {
        do { try RepositoryToolPolicy.validatePath(path, allowRoot: false) }
        catch { throw RepositoryProposalFailure.invalidPath }
        let parts = path.lowercased().split(separator: "/").map(String.init)
        let leaf = parts.last ?? ""
        let allowedExtensions = ["md", "txt", "rst", "swift", "py", "js", "ts", "tsx", "jsx", "kt", "java", "c", "cc", "cpp", "h", "hpp", "css", "scss", "html"]
        let sensitiveFragments = ["credential", "password", "secret", "auth", "security", "permission", "entitlement", "keychain", "token", "signing", "certificate", "firewall", "oauth", "accesscontrol", "keystore", "privatekey", "session", "payment", "wallet", "encrypt", "decrypt", "crypto", "tls", "ssl", "ssh", "vault", "login", "logout", "identity", "accesscontrol", "trust", "keyring", "privatekey"]
        let excludedDirectories = ["scripts", "deploy", "deployment", "infra", "infrastructure", "terraform", "ci", "hooks"]
        let excludedLeaves = ["package.swift", "manifest.swift", "setup.py", "conftest.py", "manage.py", "codeowners", "cmakelists.txt", "requirements.txt", "pipfile", "procfile", "jenkinsfile", "agents.md", "claude.md", "gemini.md"]
        guard !path.contains(".."), parts.allSatisfy({ !$0.hasPrefix(".") }),
              path.utf8.allSatisfy({ byte in
                  (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte)
                    || [45, 46, 47, 95].contains(byte)
              }), let ext = leaf.split(separator: ".").last.map(String.init), allowedExtensions.contains(ext),
              !excludedLeaves.contains(leaf), !leaf.hasPrefix("requirements"), !parts.contains(where: { excludedDirectories.contains($0) }),
              !parts.contains(where: { part in sensitiveFragments.contains(where: { part.contains($0) }) }),
              !RepositoryToolPolicy.isLikelyCredentialPath(path) else { throw RepositoryProposalFailure.invalidPath }
    }

    static func validateText(_ text: String) throws {
        let additionalSecrets = ["(?i)sk-(?:proj-|ant-)?[a-z0-9_-]{16,}", "AKIA[0-9A-Z]{16}", "(?i)bearer\\s+[a-z0-9._-]{16,}", "(?i)xox[baprs]-[a-z0-9-]{10,}", "eyJ[a-zA-Z0-9_-]{12,}\\.[a-zA-Z0-9_-]{12,}\\.[a-zA-Z0-9_-]{12,}"]
        guard text.utf8.count <= maximumTextBytes, MemorySearch.canSave(text),
              text.unicodeScalars.allSatisfy({ scalar in
                  (!CharacterSet.controlCharacters.contains(scalar) || [9, 10, 13].contains(scalar.value))
                    && !CharacterSet.illegalCharacters.contains(scalar)
                    && ![0x200B, 0x200C, 0x200D, 0x200E, 0x200F, 0x202A, 0x202B, 0x202C, 0x202D, 0x202E, 0x2060, 0x2066, 0x2067, 0x2068, 0x2069, 0xFEFF].contains(scalar.value)
              }), !additionalSecrets.contains(where: { text.range(of: $0, options: .regularExpression) != nil }) else { throw RepositoryProposalFailure.unsafeText }
    }

    static func validateTitle(_ title: String) throws {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, title.utf8.count <= 120,
              title.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }),
              !title.contains("@"), (try? validateText(title)) != nil else { throw RepositoryProposalFailure.invalidTitle }
    }

    /// Git SHA-1 is an object identity check, not encryption or a credential hash.
    static func blobSHA(_ text: String) -> String {
        let bytes = Data(text.utf8)
        let object = Data("blob \(bytes.count)\0".utf8) + bytes
        return Insecure.SHA1.hash(data: object).map { String(format: "%02x", $0) }.joined()
    }
}

/// This value can only be obtained by reading and verifying a selected immutable tree/blob.
struct RepositoryProposalSource: Equatable, Sendable {
    let repository: Repository
    let immutableCommit: String
    let path: String
    let blobSHA: String
    let original: String
    private init(repository: Repository, immutableCommit: String, path: String, blobSHA: String, original: String) {
        self.repository = repository; self.immutableCommit = immutableCommit; self.path = path
        self.blobSHA = blobSHA; self.original = original
    }

    static func load(repository: Repository, immutableCommit: String, path: String, reader: RepositoryToolReader) async throws -> Self {
        try RepositoryProposalPolicy.validateScope(repository, commit: immutableCommit)
        try RepositoryProposalPolicy.validatePath(path)
        do {
            try Task.checkCancellation(); try reader.checkAccess()
            let components = path.split(separator: "/").map(String.init)
            var tree = immutableCommit.lowercased()
            var totalBytes = 0
            for (index, component) in components.enumerated() {
                try Task.checkCancellation(); try reader.checkAccess()
                let cap = min(120_000, 900_000 - totalBytes)
                guard cap > 0 else { throw RepositoryProposalFailure.invalidResponse }
                let result = try await reader.tree(tree, cap)
                guard (0...cap).contains(result.responseBytes), result.files.count <= 2_000 else { throw RepositoryProposalFailure.invalidResponse }
                totalBytes += result.responseBytes
                var seen = Set<String>()
                for entry in result.files {
                    guard entry.name == entry.path, !entry.path.contains("/"), ![".", ".."].contains(entry.path),
                          !entry.path.isEmpty, RepositoryToolPolicy.isObjectSHA(entry.sha), seen.insert(entry.path).inserted else { throw RepositoryProposalFailure.invalidResponse }
                }
                guard let entry = result.files.first(where: { $0.path == component }), entry.target == nil,
                      entry.submodule_git_url == nil else { throw RepositoryProposalFailure.unsafeFile }
                if index < components.count - 1 {
                    guard entry.type == "dir" else { throw RepositoryProposalFailure.unsafeFile }
                    tree = entry.sha
                } else {
                    guard entry.isRegularFile, let size = entry.size, (0...RepositoryProposalPolicy.maximumTextBytes).contains(size) else { throw RepositoryProposalFailure.unsafeFile }
                    let value = try await reader.text(entry, 90_000)
                    try Task.checkCancellation(); try reader.checkAccess()
                    guard (0...90_000).contains(value.responseBytes), value.text.utf8.count == size,
                          RepositoryProposalPolicy.blobSHA(value.text) == entry.sha.lowercased() else { throw RepositoryProposalFailure.sourceMismatch }
                    try RepositoryProposalPolicy.validateText(value.text)
                    return Self(repository: repository, immutableCommit: immutableCommit.lowercased(), path: path, blobSHA: entry.sha.lowercased(), original: value.text)
                }
            }
            throw RepositoryProposalFailure.unsafeFile
        } catch {
            if error is CancellationError { throw RepositoryProposalFailure.cancelled }
            if let safe = error as? RepositoryProposalFailure { throw safe }
            throw RepositoryProposalFailure.readFailed
        }
    }
}

/// Immutable publication data. Editing anything creates a different ID and branch and requires new approval.
struct RepositoryProposalReview: Equatable, Identifiable, Sendable {
    let id: UUID
    let source: RepositoryProposalSource
    let replacement: String
    let changes: RepositoryProposalDiff
    let title: String
    let branch: String
    var original: String { source.original }
    var pullRequestBody: String {
        "User-reviewed replacement of `\(source.path)`.\n\nPinned source commit: \(source.immutableCommit)\n\nCreated as a draft by Asterion Veyra after explicit file and destination review. No merge or base-branch update was requested."
    }
    var disclosure: String {
        "Send the replacement text, file path, PR title/body, commit message and Git metadata to https://api.github.com for \(source.repository.full_name) (repository ID \(source.repository.id)). Base: \(source.repository.default_branch), pinned at \(source.immutableCommit). New branch: \(branch). Commit message: \(title). Create one draft pull request.\n\nThis may be a public repository: anyone can read public code, commit history and PRs. Private content is visible to repository collaborators and GitHub. Branch creation can trigger repository automation and notifications. Draft does not mean private. GitHub retains Git objects and history; cancellation does not erase previously sent content. No base-branch write, merge, deletion or force update will be made."
    }

    init(source: RepositoryProposalSource, replacement: String, title: String) throws {
        try RepositoryProposalPolicy.validateText(replacement)
        try RepositoryProposalPolicy.validateTitle(title)
        guard !replacement.utf8.elementsEqual(source.original.utf8) else { throw RepositoryProposalFailure.sourceMismatch }
        let id = UUID()
        self.id = id; self.source = source; self.replacement = replacement; self.title = title
        changes = try RepositoryProposalDiff(original: source.original, replacement: replacement)
        branch = "veyra-proposal/" + id.uuidString.lowercased()
    }

    /// Swift String equality normalizes Unicode. Approval must bind actual bytes.
    func matchesDraft(replacement: String, title: String) -> Bool {
        self.replacement.utf8.elementsEqual(replacement.utf8) && self.title.utf8.elementsEqual(title.utf8)
    }

    func approve(fullReviewConfirmed: Bool, destinationConfirmed: Bool) throws -> RepositoryProposalApproval {
        guard fullReviewConfirmed, destinationConfirmed else { throw RepositoryProposalFailure.consentChanged }
        return RepositoryProposalApproval(review: self)
    }
}

struct RepositoryProposalApproval: Sendable {
    fileprivate let review: RepositoryProposalReview
    fileprivate init(review: RepositoryProposalReview) { self.review = review }
    func matches(_ review: RepositoryProposalReview) -> Bool { self.review == review }
}
