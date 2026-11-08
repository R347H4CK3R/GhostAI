import Foundation

struct RepositoryProposalProgress: Codable, Equatable, Sendable {
    enum Status: Codable, Equatable, Sendable {
        case notStarted, inFlight, confirmed(String), rejected, uncertain
        var label: String {
            switch self {
            case .notStarted: return "not sent"
            case .inFlight: return "request in progress"
            case .confirmed(let value): return "confirmed: " + value
            case .rejected: return "rejected by GitHub"
            case .uncertain: return "UNKNOWN; inspect GitHub before acting"
            }
        }
    }
    var blob: Status = .notStarted
    var tree: Status = .notStarted
    var commit: Status = .notStarted
    var branch: Status = .notStarted
    var pullRequest: Status = .notStarted
    var summary: String {
        "Blob: \(blob.label)\nTree: \(tree.label)\nCommit: \(commit.label)\nBranch: \(branch.label)\nDraft PR: \(pullRequest.label)"
    }
    var hasUncertainWrite: Bool { [blob, tree, commit, branch, pullRequest].contains(.uncertain) }
}

struct RepositoryProposalResult: Sendable {
    enum Outcome: Equatable, Sendable { case completed, stopped, cancelled, uncertain }
    let outcome: Outcome
    let progress: RepositoryProposalProgress
    let repository: String
    let branch: String
    let message: String
    let pullRequestURL: URL?
}

/// Sequential, single-use state machine. No update-ref, delete, force, merge or replay operation exists.
/// Cancellation cannot undo a sent request; every ambiguous write stops the entire attempt.
actor RepositoryProposalPublisher {
    private let review: RepositoryProposalReview
    private let authorization: RepositoryProposalAuthorization
    private let transport: RepositoryProposalTransport
    private let receipts: RepositoryProposalReceiptStore
    private let createdAt = Date()
    private var receiptLease: UUID?
    private var attempted = false
    private var cancelled = false
    private var progress = RepositoryProposalProgress()
    private var result: RepositoryProposalResult?
    private var activeRequest: Task<RepositoryProposalResponse, Error>?

    init(review: RepositoryProposalReview, authorization: RepositoryProposalAuthorization, transport: RepositoryProposalTransport = .live, receipts: RepositoryProposalReceiptStore = .device) {
        self.review = review; self.authorization = authorization; self.transport = transport; self.receipts = receipts
    }
    func cancel() {
        cancelled = true
        authorization.revoke()
        activeRequest?.cancel()
    }
    func currentProgress() -> RepositoryProposalProgress { progress }

    func publish(approval: RepositoryProposalApproval, currentReview: RepositoryProposalReview) async -> RepositoryProposalResult {
        if let result { return result }
        guard !attempted else { return makeResult(.stopped, message: "This attempt is already running. No second request was started.") }
        attempted = true
        defer {
            authorization.revoke()
            if let receiptLease { receipts.release(review.id, receiptLease) }
        }
        do {
            guard approval.matches(review), currentReview == review,
                  authorization.repositoryID == review.source.repository.id else { throw RepositoryProposalFailure.consentChanged }
            try checkActive()
            let prior = try receipts.load()
            guard !prior.contains(where: { $0.id == review.id || ($0.repositoryID == review.source.repository.id && $0.requiresInspection) }) else { throw RepositoryProposalFailure.previousAttempt }
            let rootTree = try await preflight()
            // This last read is immediately before the first mutation. A moving base requires new review.
            try await verifyBase()
            try checkActive()
            let blob = try await mutate(.blob, route: ["git", "blobs"], payload: ["content": Data(review.replacement.utf8).base64EncodedString(), "encoding": "base64"]) { data in
                let value = try JSONDecoder().decode(ObjectID.self, from: data)
                guard value.sha == RepositoryProposalPolicy.blobSHA(self.review.replacement) else { throw RepositoryProposalFailure.invalidResponse }
                return value.sha
            }
            let tree = try await mutate(.tree, route: ["git", "trees"], payload: ["base_tree": rootTree, "tree": [["path": review.source.path, "mode": "100644", "type": "blob", "sha": blob]]]) { data in
                let value = try JSONDecoder().decode(ObjectID.self, from: data)
                guard RepositoryToolPolicy.isObjectSHA(value.sha) else { throw RepositoryProposalFailure.invalidResponse }
                return value.sha
            }
            let commit = try await mutate(.commit, route: ["git", "commits"], payload: ["message": review.title, "tree": tree, "parents": [review.source.immutableCommit]]) { data in
                let value = try JSONDecoder().decode(CreatedCommit.self, from: data)
                guard RepositoryToolPolicy.isObjectSHA(value.sha), value.tree.sha == tree,
                      value.parents.map(\.sha) == [self.review.source.immutableCommit] else { throw RepositoryProposalFailure.invalidResponse }
                return value.sha
            }
            _ = try await mutate(.branch, route: ["git", "refs"], payload: ["ref": "refs/heads/" + review.branch, "sha": commit]) { data in
                let value = try JSONDecoder().decode(Reference.self, from: data)
                guard value.ref == "refs/heads/" + self.review.branch, value.object.sha == commit,
                      value.object.type == "commit" else { throw RepositoryProposalFailure.invalidResponse }
                return self.review.branch
            }
            let number = try await mutate(.pullRequest, route: ["pulls"], payload: ["title": review.title, "head": review.branch, "base": review.source.repository.default_branch, "body": review.pullRequestBody, "draft": true, "maintainer_can_modify": false]) { data in
                let value = try JSONDecoder().decode(CreatedPull.self, from: data)
                guard value.number > 0, value.draft, value.state == "open", value.head.ref == self.review.branch,
                      value.head.sha == commit, value.base.ref == self.review.source.repository.default_branch,
                      value.head.repo.id == self.review.source.repository.id, value.base.repo.id == self.review.source.repository.id else { throw RepositoryProposalFailure.invalidResponse }
                return String(value.number)
            }
            // Build a verified ordinary GitHub link; never trust a URL from a response body.
            let url = URL(string: "https://github.com/" + review.source.repository.full_name + "/pull/" + number)
            let final = makeResult(.completed, message: "The new branch and draft pull request were confirmed. The base branch was not changed.", url: url)
            try persist(.completed)
            result = final
            return final
        } catch {
            let safe = error as? RepositoryProposalFailure
            let outcome: RepositoryProposalResult.Outcome
            var message: String
            if progress.hasUncertainWrite {
                outcome = .uncertain; message = RepositoryProposalFailure.uncertain.localizedDescription
            } else if cancelled || Task.isCancelled || error is CancellationError || safe == .cancelled {
                outcome = .cancelled; message = RepositoryProposalFailure.cancelled.localizedDescription
            } else {
                outcome = .stopped; message = (safe ?? .invalidResponse).localizedDescription
            }
            if receiptLease != nil {
                let savedOutcome: RepositoryProposalReceipt.Outcome
                switch outcome {
                case .completed: savedOutcome = .completed
                case .stopped: savedOutcome = .stopped
                case .cancelled: savedOutcome = .cancelled
                case .uncertain: savedOutcome = .uncertain
                }
                do { try persist(savedOutcome) }
                catch { message += " The write-ahead receipt may still show an in-progress request. Save this displayed status; no further request was sent." }
            }
            let final = makeResult(outcome, message: message)
            result = final
            return final
        }
    }

    private func persist(_ outcome: RepositoryProposalReceipt.Outcome) throws {
        let receipt = RepositoryProposalReceipt(version: 1, id: review.id, repositoryID: review.source.repository.id,
            repository: review.source.repository.full_name, branch: review.branch, baseBranch: review.source.repository.default_branch,
            baseCommit: review.source.immutableCommit, createdAt: createdAt, updatedAt: Date(), outcome: outcome,
            progress: progress, inspectedAt: nil)
        do {
            if let receiptLease { try receipts.update(receipt, receiptLease) }
            else { receiptLease = try receipts.claim(receipt) }
        } catch {
            if let safe = error as? RepositoryProposalFailure { throw safe }
            throw RepositoryProposalFailure.receiptUnavailable
        }
    }

    private func checkActive() throws {
        guard !cancelled, !Task.isCancelled else { throw RepositoryProposalFailure.cancelled }
        _ = try authorization.authorizationValue()
    }
    private func makeResult(_ outcome: RepositoryProposalResult.Outcome, message: String, url: URL? = nil) -> RepositoryProposalResult {
        RepositoryProposalResult(outcome: outcome, progress: progress, repository: review.source.repository.full_name,
                                 branch: review.branch, message: message, pullRequestURL: url)
    }

    private func preflight() async throws -> String {
        let repository = try await read([], as: RemoteRepository.self)
        guard repository.id == review.source.repository.id, repository.full_name == review.source.repository.full_name,
              repository.default_branch == review.source.repository.default_branch else { throw RepositoryProposalFailure.baseChanged }
        try await verifyBase()
        let pinned = try await read(["git", "commits", review.source.immutableCommit], as: PinnedCommit.self)
        guard pinned.sha == review.source.immutableCommit, RepositoryToolPolicy.isObjectSHA(pinned.tree.sha) else { throw RepositoryProposalFailure.sourceMismatch }
        let rootTree = pinned.tree.sha
        var treeID = rootTree
        let parts = review.source.path.split(separator: "/").map(String.init)
        for (index, part) in parts.enumerated() {
            let tree = try await read(["git", "trees", treeID], as: GitTree.self)
            guard tree.sha == treeID, !tree.truncated, tree.tree.count <= 2_000,
                  Set(tree.tree.map(\.path)).count == tree.tree.count,
                  tree.tree.allSatisfy({ !$0.path.isEmpty && !$0.path.contains("/") && ![".", ".."].contains($0.path) && RepositoryToolPolicy.isObjectSHA($0.sha) }),
                  let entry = tree.tree.first(where: { $0.path == part }) else { throw RepositoryProposalFailure.sourceMismatch }
            if index < parts.count - 1 {
                guard entry.mode == "040000", entry.type == "tree" else { throw RepositoryProposalFailure.unsafeFile }
                treeID = entry.sha
            } else {
                guard entry.mode == "100644", entry.type == "blob", entry.sha == review.source.blobSHA,
                      entry.size == review.original.utf8.count else { throw RepositoryProposalFailure.unsafeFile }
            }
        }
        let blob = try await read(["git", "blobs", review.source.blobSHA], as: GitBlob.self)
        guard blob.sha == review.source.blobSHA, blob.encoding == "base64", blob.size == review.original.utf8.count,
              let bytes = Data(base64Encoded: blob.content, options: .ignoreUnknownCharacters),
              bytes.count == blob.size, let original = String(data: bytes, encoding: .utf8), original == review.original,
              RepositoryProposalPolicy.blobSHA(original) == blob.sha else { throw RepositoryProposalFailure.sourceMismatch }
        return rootTree
    }
    private func verifyBase() async throws {
        let parts = review.source.repository.default_branch.split(separator: "/").map(String.init)
        let base = try await read(["git", "ref", "heads"] + parts, as: Reference.self)
        guard base.ref == "refs/heads/" + review.source.repository.default_branch,
              base.object.type == "commit", base.object.sha == review.source.immutableCommit else { throw RepositoryProposalFailure.baseChanged }
    }

    private func request(route: [String], method: String, payload: [String: Any]? = nil) throws -> URLRequest {
        try checkActive()
        let (owner, repository) = try GitHubRoute.repository(review.source.repository.full_name)
        let url = try GitHubRoute.url(["repos", owner, repository] + route)
        try RepositoryProposalNetworkPolicy.validate(url) // Before any credential attachment.
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 25)
        request.httpMethod = method
        request.httpShouldHandleCookies = false
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue(try authorization.authorizationValue(), forHTTPHeaderField: "Authorization")
        if let payload {
            request.httpBody = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return request
    }
    private func perform(_ request: URLRequest) async throws -> RepositoryProposalResponse {
        let send = transport.send
        let auth = authorization
        let task = Task { try await send(request, RepositoryProposalPolicy.maximumResponseBytes, auth) }
        activeRequest = task
        defer { activeRequest = nil }
        let response = try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
        guard response.url == request.url, response.data.count <= RepositoryProposalPolicy.maximumResponseBytes else { throw RepositoryProposalFailure.invalidResponse }
        try RepositoryProposalNetworkPolicy.validate(response.url)
        if response.status == 401 { authorization.revoke() }
        return response
    }
    private func read<Value: Decodable>(_ route: [String], as: Value.Type) async throws -> Value {
        let response = try await perform(request(route: route, method: "GET"))
        try checkActive()
        guard response.status == 200 else { throw RepositoryProposalFailure.denied }
        do { return try JSONDecoder().decode(Value.self, from: response.data) }
        catch { throw RepositoryProposalFailure.invalidResponse }
    }

    private enum Stage { case blob, tree, commit, branch, pullRequest }
    private func mark(_ stage: Stage, _ status: RepositoryProposalProgress.Status) {
        switch stage {
        case .blob: progress.blob = status
        case .tree: progress.tree = status
        case .commit: progress.commit = status
        case .branch: progress.branch = status
        case .pullRequest: progress.pullRequest = status
        }
    }
    private func mutate(_ stage: Stage, route: [String], payload: [String: Any], validate: (Data) throws -> String) async throws -> String {
        // Validation and credential checks happen BEFORE marking a request as possibly sent.
        let request = try request(route: route, method: "POST", payload: payload)
        mark(stage, .inFlight)
        do { try persist(.running) }
        catch {
            mark(stage, .notStarted) // The transport has not been invoked.
            throw error
        }
        do {
            let response = try await perform(request)
            guard response.status == 201 else {
                // 4xx definitive rejection is retained. 3xx/5xx may conceal a partial write.
                if (400...499).contains(response.status), response.status != 408 {
                    mark(stage, .rejected)
                    try persist(.running)
                    throw RepositoryProposalFailure.denied
                }
                throw RepositoryProposalFailure.uncertain
            }
            let confirmed = try validate(response.data)
            mark(stage, .confirmed(confirmed))
            try persist(.running)
            return confirmed
        } catch {
            if error as? RepositoryProposalFailure == .receiptUnavailable { throw RepositoryProposalFailure.receiptUnavailable }
            if error as? RepositoryProposalFailure == .denied { throw RepositoryProposalFailure.denied }
            mark(stage, .uncertain)
            try? persist(.uncertain)
            throw RepositoryProposalFailure.uncertain
        }
    }

    private struct ObjectID: Decodable { let sha: String }
    private struct RemoteRepository: Decodable { let id: Int; let full_name: String; let default_branch: String }
    private struct PinnedCommit: Decodable { let sha: String; let tree: ObjectID }
    private struct CreatedCommit: Decodable { let sha: String; let tree: ObjectID; let parents: [ObjectID] }
    private struct Reference: Decodable {
        let ref: String
        let object: GitObject
        struct GitObject: Decodable { let sha: String; let type: String }
    }
    private struct GitTree: Decodable {
        let sha: String; let truncated: Bool; let tree: [Entry]
        struct Entry: Decodable { let path: String; let mode: String; let type: String; let sha: String; let size: Int? }
    }
    private struct GitBlob: Decodable { let sha: String; let content: String; let encoding: String; let size: Int }
    private struct CreatedPull: Decodable {
        let number: Int; let draft: Bool; let state: String; let head: Head; let base: Base
        struct RepoID: Decodable { let id: Int }
        struct Head: Decodable { let ref: String; let sha: String; let repo: RepoID }
        struct Base: Decodable { let ref: String; let repo: RepoID }
    }
}
