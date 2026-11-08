import Foundation

/// Minimal recovery metadata, never a credential, file path, source body, PR title or PR body.
struct RepositoryProposalReceipt: Codable, Equatable, Identifiable, Sendable {
    let version: Int
    let id: UUID
    let repositoryID: Int
    let repository: String
    let branch: String
    let baseBranch: String
    let baseCommit: String
    let createdAt: Date
    var updatedAt: Date
    var outcome: Outcome
    var progress: RepositoryProposalProgress
    var inspectedAt: Date?
    enum Outcome: String, Codable, Sendable { case running, completed, stopped, cancelled, uncertain }

    var requiresInspection: Bool {
        guard inspectedAt == nil, outcome != .completed else { return false }
        return [progress.blob, progress.tree, progress.commit, progress.branch, progress.pullRequest].contains { status in
            switch status {
            case .inFlight, .confirmed, .uncertain: return true
            case .notStarted, .rejected: return false
            }
        }
    }
    var summary: String {
        "Repository: \(repository) (ID \(repositoryID))\nBranch: \(branch)\nBase: \(baseBranch) at \(baseCommit)\nSaved outcome: \(outcome.rawValue)\n\(progress.summary)\nThis is saved state, not a running background job. Any saved in-progress request is UNKNOWN and may have completed remotely. This attempt will never be replayed."
    }
    var repositoryURL: URL? { URL(string: "https://github.com/" + repository) }
    var pullRequestURL: URL? {
        guard case .confirmed(let number) = progress.pullRequest else { return nil }
        return URL(string: "https://github.com/" + repository + "/pull/" + number)
    }
    var branchURL: URL? { URL(string: "https://github.com/" + repository + "/tree/" + branch) }

    func validated() throws -> Self {
        let selected = Repository(id: repositoryID, full_name: repository, default_branch: baseBranch)
        guard version == 1, branch == "veyra-proposal/" + id.uuidString.lowercased(),
              (try? RepositoryProposalPolicy.validateScope(selected, commit: baseCommit)) != nil,
              createdAt.timeIntervalSince1970.isFinite, updatedAt.timeIntervalSince1970.isFinite else { throw RepositoryProposalFailure.receiptUnavailable }
        for status in [progress.blob, progress.tree, progress.commit] {
            if case .confirmed(let sha) = status, !RepositoryToolPolicy.isObjectSHA(sha) { throw RepositoryProposalFailure.receiptUnavailable }
        }
        if case .confirmed(let value) = progress.branch, value != branch { throw RepositoryProposalFailure.receiptUnavailable }
        if case .confirmed(let value) = progress.pullRequest {
            guard let number = Int(value), number > 0, String(number) == value else { throw RepositoryProposalFailure.receiptUnavailable }
        }
        if outcome == .completed {
            for status in [progress.blob, progress.tree, progress.commit, progress.branch, progress.pullRequest] {
                guard case .confirmed = status else { throw RepositoryProposalFailure.receiptUnavailable }
            }
        }
        return self
    }
}

/// All operations are synchronous: an atomic, exclusive write-ahead claim finishes before a POST.
/// A lease is process-local ownership, not a credential. Restart loses ownership but retains the receipt.
struct RepositoryProposalReceiptStore: Sendable {
    var load: @Sendable () throws -> [RepositoryProposalReceipt]
    var claim: @Sendable (RepositoryProposalReceipt) throws -> UUID
    var update: @Sendable (RepositoryProposalReceipt, UUID) throws -> Void
    var release: @Sendable (UUID, UUID) -> Void
    var acknowledgeInspection: @Sendable (RepositoryProposalReceipt) throws -> Void

    static var device: Self {
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return Self(load: { throw RepositoryProposalFailure.receiptUnavailable },
                        claim: { _ in throw RepositoryProposalFailure.receiptUnavailable },
                        update: { _, _ in throw RepositoryProposalFailure.receiptUnavailable }, release: { _, _ in },
                        acknowledgeInspection: { _ in throw RepositoryProposalFailure.receiptUnavailable })
        }
        return disk(directory: support.appendingPathComponent("RepositoryProposalReceipts", isDirectory: true))
    }

    static func disk(directory: URL) -> Self {
        let access = RepositoryProposalReceiptDisk(directory: directory)
        return Self(load: { try access.load() }, claim: { try access.claim($0) }, update: { try access.update($0, lease: $1) },
                    release: { access.release(id: $0, lease: $1) }, acknowledgeInspection: { try access.acknowledgeInspection($0) })
    }
}

private final class RepositoryProposalReceiptDisk: @unchecked Sendable {
    private let directory: URL
    // One process-wide lock covers all instances, including separate SwiftUI windows/coordinators.
    private static let lock = NSLock()
    private struct Claim { let lease: UUID; let repositoryID: Int }
    private static var owners: [String: [UUID: Claim]] = [:]
    private var key: String { directory.standardizedFileURL.path }
    init(directory: URL) { self.directory = directory }

    func load() throws -> [RepositoryProposalReceipt] {
        Self.lock.lock(); defer { Self.lock.unlock() }
        return try readUnlocked()
    }
    func claim(_ receipt: RepositoryProposalReceipt) throws -> UUID {
        Self.lock.lock(); defer { Self.lock.unlock() }
        _ = try receipt.validated()
        let existing = try readUnlocked()
        guard existing.count < 500 else { throw RepositoryProposalFailure.receiptCapacity }
        guard !existing.contains(where: { $0.id == receipt.id || ($0.repositoryID == receipt.repositoryID && $0.requiresInspection) }),
              !(Self.owners[key]?.values.contains(where: { $0.repositoryID == receipt.repositoryID }) ?? false) else { throw RepositoryProposalFailure.previousAttempt }
        try writeUnlocked(receipt)
        let lease = UUID()
        Self.owners[key, default: [:]][receipt.id] = Claim(lease: lease, repositoryID: receipt.repositoryID)
        return lease
    }
    func update(_ receipt: RepositoryProposalReceipt, lease: UUID) throws {
        Self.lock.lock(); defer { Self.lock.unlock() }
        guard Self.owners[key]?[receipt.id]?.lease == lease,
              let previous = try readUnlocked().first(where: { $0.id == receipt.id }), previous.inspectedAt == nil,
              previous.repositoryID == receipt.repositoryID, previous.repository == receipt.repository,
              previous.branch == receipt.branch, previous.baseBranch == receipt.baseBranch,
              previous.baseCommit == receipt.baseCommit, previous.createdAt == receipt.createdAt,
              receipt.inspectedAt == nil else { throw RepositoryProposalFailure.receiptUnavailable }
        try writeUnlocked(receipt)
    }
    func release(id: UUID, lease: UUID) {
        Self.lock.lock(); defer { Self.lock.unlock() }
        guard Self.owners[key]?[id]?.lease == lease else { return }
        Self.owners[key]?.removeValue(forKey: id)
        if Self.owners[key]?.isEmpty == true { Self.owners.removeValue(forKey: key) }
    }
    func acknowledgeInspection(_ expected: RepositoryProposalReceipt) throws {
        Self.lock.lock(); defer { Self.lock.unlock() }
        guard Self.owners[key]?[expected.id] == nil,
              var current = try readUnlocked().first(where: { $0.id == expected.id }), current == expected,
              current.requiresInspection else { throw RepositoryProposalFailure.receiptChanged }
        current.inspectedAt = Date(); current.updatedAt = Date()
        try writeUnlocked(current)
    }

    private func readUnlocked() throws -> [RepositoryProposalReceipt] {
        do {
            let manager = FileManager.default
            guard manager.fileExists(atPath: directory.path) else { return [] }
            let folder = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard folder.isDirectory == true, folder.isSymbolicLink != true else { throw RepositoryProposalFailure.receiptUnavailable }
            let files = try manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey], options: [])
            guard files.count <= 500 else { throw RepositoryProposalFailure.receiptCapacity }
            return try files.map { file in
                let metadata = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
                guard file.pathExtension == "json", let expectedID = UUID(uuidString: file.deletingPathExtension().lastPathComponent),
                      metadata.isRegularFile == true, metadata.isSymbolicLink != true,
                      let size = metadata.fileSize, (1...16_000).contains(size) else { throw RepositoryProposalFailure.receiptUnavailable }
                let data = try Data(contentsOf: file, options: [])
                guard data.count <= 16_000 else { throw RepositoryProposalFailure.receiptUnavailable }
                let receipt = try JSONDecoder().decode(RepositoryProposalReceipt.self, from: data).validated()
                guard receipt.id == expectedID else { throw RepositoryProposalFailure.receiptUnavailable }
                return receipt
            }.sorted { $0.createdAt > $1.createdAt }
        } catch {
            if let safe = error as? RepositoryProposalFailure { throw safe }
            throw RepositoryProposalFailure.receiptUnavailable
        }
    }

    private func writeUnlocked(_ receipt: RepositoryProposalReceipt) throws {
        do {
            _ = try receipt.validated()
            let manager = FileManager.default
            try manager.createDirectory(at: directory, withIntermediateDirectories: true,
                attributes: [.protectionKey: FileProtectionType.complete])
            let folder = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard folder.isDirectory == true, folder.isSymbolicLink != true else { throw RepositoryProposalFailure.receiptUnavailable }
            var excluded = URLResourceValues(); excluded.isExcludedFromBackup = true
            var directoryURL = directory; try directoryURL.setResourceValues(excluded)
            let data = try JSONEncoder().encode(receipt)
            guard data.count <= 16_000 else { throw RepositoryProposalFailure.receiptUnavailable }
            var file = directory.appendingPathComponent(receipt.id.uuidString.lowercased() + ".json")
            if manager.fileExists(atPath: file.path) {
                let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard values.isRegularFile == true, values.isSymbolicLink != true else { throw RepositoryProposalFailure.receiptUnavailable }
            }
            try data.write(to: file, options: [.atomic, .completeFileProtection])
            try file.setResourceValues(excluded)
        } catch { throw RepositoryProposalFailure.receiptUnavailable }
    }
}
