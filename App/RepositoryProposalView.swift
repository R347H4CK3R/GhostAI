import SwiftUI

private struct RepositoryProposalPublicationConsent {
    let review: RepositoryProposalReview
    let approval: RepositoryProposalApproval
    let token: String
    let directInstallationConfirmed: Bool
}

/// Integrate from an already selected repository. This screen never receives a read token,
/// changes the read connection, starts a request automatically or restores a write credential.
struct RepositoryProposalView: View {
    let repository: Repository
    let immutableCommit: String
    let readClient: GitHubClient
    @Environment(\.scenePhase) private var scenePhase
    @State private var path = ""
    @State private var source: RepositoryProposalSource?
    @State private var replacement = ""
    @State private var title = ""
    @State private var review: RepositoryProposalReview?
    @State private var fullReviewConfirmed = false
    @State private var destinationConfirmed = false
    @State private var directInstallationConfirmed = false
    @State private var token = ""
    @State private var tokenEntryExpiry: Task<Void, Never>?
    @State private var selectionChanged = false
    @State private var sourceReaderID: ObjectIdentifier?
    @State private var recoveryReceipts: [RepositoryProposalReceipt] = []
    @State private var receiptsReady = false
    private let receiptStore = RepositoryProposalReceiptStore.device
    @State private var pendingConsent: RepositoryProposalPublicationConsent?
    @State private var loading = false
    @State private var publishing = false
    @State private var error: String?
    @State private var result: RepositoryProposalResult?
    @State private var generation = UUID()
    @State private var loadTask: Task<Void, Never>?
    @State private var publicationTask: Task<Void, Never>?
    @State private var publisher: RepositoryProposalPublisher?
    @State private var writeAuthorization: RepositoryProposalAuthorization?

    init(repository: Repository, immutableCommit: String, readClient: GitHubClient) {
        self.repository = repository; self.immutableCommit = immutableCommit; self.readClient = readClient
    }

    private var locked: Bool { publishing || result != nil || selectionChanged || !receiptsReady || !recoveryReceipts.isEmpty }
    var body: some View {
        Form {
            Section("One reviewed file · draft PR only") {
                Text(verbatim: repository.full_name).font(.headline)
                Text("Base: \(repository.default_branch)\nPinned commit: \(immutableCommit)").font(.caption.monospaced()).textSelection(.enabled)
                Text("Choose one existing source or documentation file. No base-branch edit, merge, force push or deletion. Executables, automation, configuration, credential and security-sensitive paths are excluded.").font(.caption)
                Text("Proposals are optional and use a separate write credential. Offline Assistant and read-only browsing stay separate.").font(.caption).foregroundStyle(.secondary)
            }
            if !receiptsReady {
                Section("Recovery status unavailable") {
                    Text("Publication stays blocked until prior local receipts can be checked.").font(.caption)
                    Button("Reload local recovery status") { refreshReceipts() }
                }
            }
            if result == nil {
                ForEach(recoveryReceipts) { receipt in recoverySection(receipt) }
            }
            if let result { resultSection(result) }
            else {
                sourceSection
                if source != nil { editSection }
                if let review {
                    reviewSection(review)
                    credentialSection
                    confirmationSection(review)
                }
            }
            if loading {
                Section { ProgressView("Verifying the pinned file"); Button("Cancel loading") { cancelLoading() } }
            }
            if publishing {
                Section {
                    ProgressView("Publishing one step at a time")
                    Text("Cancellation cannot undo content already sent. If a response is lost, this attempt stops without retrying.").font(.caption)
                    Button("Stop publication", role: .destructive) { cancelPublication() }
                }
            }
            if let error { Section { Text(error).foregroundStyle(.red) } }
        }
        .navigationTitle("Review a proposal")
        .task { refreshReceipts() }
        .privacySensitive()
        .overlay {
            if scenePhase != .active {
                Color(.systemBackground).ignoresSafeArea()
                    .overlay { Label("Proposal hidden", systemImage: "lock.shield") }
            }
        }
        .alert("Publish this draft pull request?", isPresented: Binding(
            get: { pendingConsent != nil }, set: { if !$0 { pendingConsent = nil } }
        ), presenting: pendingConsent) { consent in
            Button("Publish reviewed draft PR") { startPublication(consent) }
                .accessibilityIdentifier("proposal-confirm-publish")
            Button("Cancel", role: .cancel) { pendingConsent = nil; token = ""; clearAcknowledgments() }
        } message: { consent in
            Text(consent.review.disclosure + "\n\nYour separate fine-grained token will be sent only to api.github.com. A stolen token can expose or change every repository it can access. Authorize this exact destination and data only in a directly installed app.")
        }
        .onChange(of: path) { _, _ in
            cancelLoading(); source = nil; replacement = ""; invalidateReview()
        }
        .onChange(of: Data(replacement.utf8)) { _, _ in invalidateReview() }
        .onChange(of: Data(title.utf8)) { _, _ in invalidateReview() }
        .onChange(of: token) { _, value in credentialEdited(value) }
        .onChange(of: fullReviewConfirmed) { _, value in if !value { pendingConsent = nil } }
        .onChange(of: destinationConfirmed) { _, value in if !value { pendingConsent = nil } }
        .onChange(of: repository) { _, _ in stopForSelectionChange() }
        .onChange(of: immutableCommit) { _, _ in stopForSelectionChange() }
        .onChange(of: ObjectIdentifier(readClient)) { _, _ in stopForSelectionChange() }
        .onChange(of: directInstallationConfirmed) { _, value in
            pendingConsent = nil; clearAcknowledgments()
            if !value { token = ""; writeAuthorization?.revoke() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background {
                cancelLoading(); cancelPublication()
                tokenEntryExpiry?.cancel(); tokenEntryExpiry = nil
                token = ""; pendingConsent = nil; directInstallationConfirmed = false; clearAcknowledgments()
            }
        }
        .onDisappear {
            cancelLoading(); cancelPublication()
            tokenEntryExpiry?.cancel(); tokenEntryExpiry = nil
            token = ""; pendingConsent = nil; review = nil; source = nil; replacement = ""
        }
    }

    private var sourceSection: some View {
        Section("Select the existing file") {
            TextField("Relative path, for example docs/guide.md", text: $path)
                .textInputAutocapitalization(.never).autocorrectionDisabled().disabled(locked || loading)
                .accessibilityIdentifier("proposal-path")
            Button("Load and verify original") { loadOriginal() }.disabled(locked || loading || path.isEmpty)
                .accessibilityIdentifier("proposal-load-original")
            Text("Reads only the selected immutable tree and blob using your current read connection. No write token is sent at this step.").font(.caption).foregroundStyle(.secondary)
        }
    }
    private var editSection: some View {
        Section("Your replacement source") {
            TextField("Draft PR title and commit message", text: $title).disabled(locked || loading)
                .accessibilityIdentifier("proposal-title")
            TextEditor(text: $replacement).font(.system(.caption, design: .monospaced))
                .frame(minHeight: 220).disabled(locked || loading)
                .accessibilityIdentifier("proposal-replacement")
            Text("\(replacement.utf8.count) of \(RepositoryProposalPolicy.maximumTextBytes) UTF-8 bytes. Supply the complete replacement file, not a patch. No model edits are applied automatically.").font(.caption)
            Button("Prepare complete review") { prepareReview() }.disabled(locked || loading)
                .accessibilityIdentifier("proposal-prepare-review")
        }
    }
    private func reviewSection(_ review: RepositoryProposalReview) -> some View {
        RepositoryProposalReviewContent(review: review)
    }
    private var credentialSection: some View {
        Section("Separate write token · direct installation only") {
            Label("Never enter credentials in Strata or another host. Its host may read the token and source. This app cannot reliably detect that environment.", systemImage: "exclamationmark.shield.fill")
                .font(.callout).foregroundStyle(.orange)
            Text("Create your own fine-grained GitHub personal access token, restricted to this selected repository, with Contents: Read and write and Pull requests: Read and write. Choose a short expiration. These rights can change repository code; the app cannot reduce an over-permissioned token’s rights.").font(.caption)
            Toggle("I am using a directly installed app", isOn: $directInstallationConfirmed).disabled(locked)
                .accessibilityIdentifier("proposal-direct-install")
            if directInstallationConfirmed {
                SecureField("Separate fine-grained write token", text: $token)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().privacySensitive().disabled(locked)
                    .accessibilityIdentifier("proposal-write-token")
            }
            Text("Sent only to https://api.github.com after the final publication confirmation. Token entry clears after 15 minutes without editing. The write session lasts at most 15 minutes. Kept in memory only, never Keychain, backups, chat or diagnostics. Revoked locally on completion, stop, background or dismiss; revoke it on GitHub yourself when no longer needed.").font(.caption).foregroundStyle(.secondary)
        }
    }
    private func confirmationSection(_ review: RepositoryProposalReview) -> some View {
        Section("Approve exactly this proposal") {
            Toggle("I reviewed the complete original and replacement, title and PR body", isOn: $fullReviewConfirmed).disabled(locked)
                .accessibilityIdentifier("proposal-review-toggle")
            Toggle("I authorize publication to this repository and new branch, including possible public exposure and automation", isOn: $destinationConfirmed).disabled(locked)
                .accessibilityIdentifier("proposal-destination-toggle")
            Button("Confirm publication destination") { preparePublication(review) }
                .disabled(locked || !fullReviewConfirmed || !destinationConfirmed || !directInstallationConfirmed || token.isEmpty)
                .accessibilityIdentifier("proposal-confirm-destination")
        }
    }
    private func resultSection(_ result: RepositoryProposalResult) -> some View {
        Section("Publication status") {
            Text(result.message).font(.headline)
            Text("Repository: \(result.repository)\nProposed branch: \(result.branch)").font(.caption.monospaced()).textSelection(.enabled)
            Text(result.progress.summary).font(.caption.monospaced()).textSelection(.enabled)
            if let url = result.pullRequestURL { Link("Open verified draft pull request", destination: url) }
            ShareLink("Save or share this status", item: result.message + "\n" + result.repository + "\n" + result.branch + "\n" + result.progress.summary)
            Text("This attempt is closed. No requests are retried or objects deleted. Inspect GitHub before starting another proposal, especially for an UNKNOWN result. A minimal local receipt survives app restart. It contains repository/branch/base identifiers and stage status, never source, title or token.").font(.caption).foregroundStyle(.secondary)
        }
    }

    private func recoverySection(_ receipt: RepositoryProposalReceipt) -> some View {
        Section("Previous publication requires inspection") {
            Text("A saved attempt was interrupted or left partial work. Nothing will be retried. Inspect GitHub before preparing another proposal.").font(.headline)
            Text(receipt.summary).font(.caption.monospaced()).textSelection(.enabled)
            if let url = receipt.repositoryURL { Link("Inspect repository on GitHub", destination: url) }
            if let url = receipt.branchURL { Link("Inspect the proposed branch", destination: url) }
            if let url = receipt.pullRequestURL { Link("Inspect confirmed draft PR", destination: url) }
            ShareLink("Save or share recovery status", item: receipt.summary)
            Text("If the branch is missing, inspect recent repository activity and PRs too: an unknown request is not evidence of failure. This screen cannot undo or replay it.").font(.caption)
            Button("I inspected GitHub; close this attempt locally") { acknowledgeInspection(receipt) }
                .accessibilityIdentifier("proposal-acknowledge-recovery")
            Text("This records your inspection without deleting the receipt or changing GitHub. Any later proposal starts with a fresh source, review and branch.").font(.caption).foregroundStyle(.secondary)
        }
    }
    private func refreshReceipts() {
        do {
            recoveryReceipts = try receiptStore.load().filter { $0.repositoryID == repository.id && $0.requiresInspection }
            receiptsReady = true
        } catch { receiptsReady = false; self.error = (error as? RepositoryProposalFailure ?? .receiptUnavailable).localizedDescription }
    }
    private func acknowledgeInspection(_ receipt: RepositoryProposalReceipt) {
        guard !publishing else { return }
        do {
            // The store compares and records inspection atomically, and rejects active ownership.
            try receiptStore.acknowledgeInspection(receipt)
            source = nil; sourceReaderID = nil; replacement = ""; title = ""; invalidateReview()
            token = ""; error = nil; refreshReceipts()
        } catch { receiptsReady = false; self.error = (error as? RepositoryProposalFailure ?? .receiptUnavailable).localizedDescription }
    }
    private func credentialEdited(_ value: String) {
        pendingConsent = nil; clearAcknowledgments()
        tokenEntryExpiry?.cancel(); tokenEntryExpiry = nil
        guard !value.isEmpty else { return }
        tokenEntryExpiry = Task {
            do { try await Task.sleep(nanoseconds: 15 * 60 * 1_000_000_000) }
            catch { return }
            guard !Task.isCancelled else { return }
            token = ""; pendingConsent = nil; clearAcknowledgments()
            error = "The unused write-token entry expired. Enter it again only when you are ready to publish."
        }
    }
    private func stopForSelectionChange() {
        // Do not discard an in-flight attempt's result. Cancel it and keep its final ledger visible.
        selectionChanged = true; cancelLoading(); cancelPublication()
        source = nil; sourceReaderID = nil; replacement = ""; title = ""; invalidateReview()
        tokenEntryExpiry?.cancel(); tokenEntryExpiry = nil
        token = ""; directInstallationConfirmed = false
        error = "The repository, pinned commit or read connection changed. This screen is closed to new requests. Reopen it for the current selection; inspect any prior publication status first."
    }
    private func clearAcknowledgments() { fullReviewConfirmed = false; destinationConfirmed = false }
    private func invalidateReview() { review = nil; pendingConsent = nil; clearAcknowledgments() }
    private func cancelLoading() {
        generation = UUID(); loadTask?.cancel(); loadTask = nil; loading = false
    }
    private func cancelPublication() {
        writeAuthorization?.revoke()
        publicationTask?.cancel()
        if let publisher { Task { await publisher.cancel() } }
    }
    private func loadOriginal() {
        guard !locked, !loading else { return }
        invalidateReview(); source = nil; error = nil
        let requestedPath = path
        let id = UUID(); generation = id; loading = true
        loadTask = Task {
            do {
                let loaded = try await RepositoryProposalSource.load(repository: repository, immutableCommit: immutableCommit, path: requestedPath,
                    reader: .github(client: readClient, repository: repository.full_name))
                guard generation == id, !Task.isCancelled else { return }
                source = loaded; sourceReaderID = ObjectIdentifier(readClient); replacement = loaded.original; loading = false; loadTask = nil
            } catch {
                guard generation == id else { return }
                self.error = (error as? RepositoryProposalFailure ?? .readFailed).localizedDescription
                loading = false; loadTask = nil
            }
        }
    }
    private func prepareReview() {
        guard !locked, let source, source.repository == repository, source.immutableCommit == immutableCommit.lowercased(), sourceReaderID == ObjectIdentifier(readClient) else { return }
        do {
            try readClient.validateSession()
            review = try RepositoryProposalReview(source: source, replacement: replacement, title: title)
            clearAcknowledgments(); pendingConsent = nil; error = nil
        } catch { self.error = (error as? RepositoryProposalFailure ?? .readFailed).localizedDescription }
    }
    private func preparePublication(_ review: RepositoryProposalReview) {
        guard !locked, directInstallationConfirmed, source == review.source,
              review.source.repository == repository, review.source.immutableCommit == immutableCommit.lowercased(), sourceReaderID == ObjectIdentifier(readClient),
              review.matchesDraft(replacement: replacement, title: title), self.review == review else { invalidateReview(); return }
        do {
            try readClient.validateSession()
            pendingConsent = RepositoryProposalPublicationConsent(review: review,
                approval: try review.approve(fullReviewConfirmed: fullReviewConfirmed, destinationConfirmed: destinationConfirmed),
                token: token, directInstallationConfirmed: directInstallationConfirmed)
        } catch { self.error = (error as? RepositoryProposalFailure ?? .consentChanged).localizedDescription }
    }
    private func startPublication(_ consent: RepositoryProposalPublicationConsent) {
        guard !locked, scenePhase == .active, consent.directInstallationConfirmed, directInstallationConfirmed, fullReviewConfirmed, destinationConfirmed,
              let current = review, current == consent.review, source == current.source,
              current.source.repository == repository, current.source.immutableCommit == immutableCommit.lowercased(), sourceReaderID == ObjectIdentifier(readClient),
              current.matchesDraft(replacement: replacement, title: title), token == consent.token else {
            token = ""; pendingConsent = nil; clearAcknowledgments(); error = RepositoryProposalFailure.consentChanged.localizedDescription; return
        }
        do {
            try readClient.validateSession()
            let auth = try RepositoryProposalAuthorization(token: consent.token, repositoryID: repository.id, directInstallationConfirmed: true)
            let writer = RepositoryProposalPublisher(review: current, authorization: auth)
            writeAuthorization = auth; publisher = writer; publishing = true; error = nil
            pendingConsent = nil; token = ""; clearAcknowledgments()
            publicationTask = Task {
                let completed = await writer.publish(approval: consent.approval, currentReview: current)
                result = completed; publishing = false; writeAuthorization = nil; publicationTask = nil
            }
        } catch {
            token = ""; pendingConsent = nil; clearAcknowledgments()
            self.error = (error as? RepositoryProposalFailure ?? .credentialEnded).localizedDescription
        }
    }
}
