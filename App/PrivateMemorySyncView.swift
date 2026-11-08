import SwiftUI

struct PrivateMemorySyncView: View {
    @ObservedObject var controller: PrivateMemorySyncController
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var repository = PrivateMemorySyncPolicy.defaultRepository
    @State private var token = ""
    @State private var passphrase = ""
    @State private var repeatedPassphrase = ""
    @State private var directInstallation = false
    @State private var includePrivate = false
    @State private var recoverySaved = false
    @State private var approved = false
    @State private var message: String?
    @State private var connecting: Task<Void, Never>?
    @State private var confirmDisconnect = false
    @State private var confirmRecoveryResume = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label(controller.statusTitle, systemImage: controller.isWorking ? "arrow.triangle.2.circlepath" : "lock.icloud")
                        .font(.headline).accessibilityIdentifier("privateSync.status")
                    Text(controller.statusDetail).font(.footnote).foregroundStyle(.secondary)
                    if controller.unresolvedLegacyLibraries > 0 {
                        Text("\(controller.unresolvedLegacyLibraries) older libraries remain only on this device. Open their original projects to include them.")
                            .font(.footnote).foregroundStyle(.orange)
                    }
                    if let bytes = controller.syncedDocumentBytes {
                        LabeledContent("Synced document", value: ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .binary) + " / 8 MiB")
                    }
                    if controller.pendingChanges { Label("Local changes are waiting to sync", systemImage: "clock") }
                    if let date = controller.lastSyncedAt { LabeledContent("Last successful sync", value: date.formatted(date: .abbreviated, time: .shortened)) }
                }
                if controller.configuration?.localRecoveryNeedsReview == true {
                    Section("Review local recovery") {
                        Text("Your backup was recovered locally with sync paused. Review the effect on recovered and remote records before reconnecting automatic sync. This review is available even after disconnecting this device.")
                            .font(.footnote).foregroundStyle(.orange)
                        Button("Review recovery before resuming…") { confirmRecoveryResume = true }
                            .accessibilityIdentifier("privateSync.reviewRecovery")
                    }
                }
                if controller.isConfigured {
                    Section("Private destination") {
                        Text(controller.configuration?.repository ?? repository).textSelection(.enabled)
                        Text("The numeric repository and owner identities are pinned. A visibility, owner or branch change pauses transfers.")
                            .font(.caption).foregroundStyle(.secondary)
                        Button("Sync now") { controller.syncNow() }.disabled(controller.isWorking || !controller.isEnabled)
                        if controller.configuration?.localRecoveryNeedsReview != true {
                            Button(controller.isEnabled ? "Pause automatic sync" : "Resume automatic sync") {
                                if controller.isEnabled { controller.pause() } else { controller.resume() }
                            }
                        }
                        Button("Disconnect this device…", role: .destructive) { confirmDisconnect = true }
                    }
                } else {
                    Section("Connect your private vault") {
                        TextField("owner/private-repository", text: $repository).textInputAutocapitalization(.never).autocorrectionDisabled()
                            .disabled(controller.configuration != nil)
                        SecureField("Repository-only fine-grained GitHub token", text: $token).textInputAutocapitalization(.never).autocorrectionDisabled()
                        Text("Create a fine-grained token in GitHub for only this private repository, with Contents: Read and write. Metadata read access is also required. The app cannot create tokens or choose their lifetime for you.")
                            .font(.caption).foregroundStyle(.secondary)
                        Link("Open GitHub fine-grained token settings", destination: URL(string: "https://github.com/settings/personal-access-tokens/new")!)
                        Toggle("This app is directly installed, not running inside Strata or another host", isOn: $directInstallation)
                    }
                    Section("Encryption and recovery") {
                        SecureField("Shared recovery passphrase (12+ characters)", text: $passphrase).textInputAutocapitalization(.never).autocorrectionDisabled()
                        SecureField("Repeat recovery passphrase", text: $repeatedPassphrase).textInputAutocapitalization(.never).autocorrectionDisabled()
                        Text("Use the same strong passphrase on each device. Encryption happens before upload with AES-256-GCM and PBKDF2-SHA256. The token and passphrase stay in this device’s Keychain, not in GitHub or your app backup. The encrypted queue may be included in device backups; its contents still require this passphrase. Losing the passphrase means losing access to the encrypted vault. Changing it here does not rotate an existing vault’s key.")
                            .font(.caption).foregroundStyle(.secondary)
                        Toggle("I saved the recovery passphrase somewhere safe outside this repository", isOn: $recoverySaved)
                    }
                    Section("Review what will be shared") {
                        Text("Automatic encrypted uploads and downloads will use \(repository). Included: app notes and chats, saved research, selected text-file copies and fixed app activity summaries from eligible workspaces.")
                            .font(.footnote)
                        Toggle("Also sync private GitHub workspaces belonging to this verified GitHub account", isOn: $includePrivate)
                            .disabled(controller.configuration != nil)
                        Text("Private repository workspaces remain local unless this is enabled. Other GitHub accounts are always excluded. Settings, credentials, arbitrary device files, attachments not already imported, and detected secrets are never synced. Secret detection is not a guarantee.")
                            .font(.caption).foregroundStyle(.secondary)
                        Toggle("Allow automatic sync to this private repository and save its token and passphrase on this device", isOn: $approved)
                        Button("Connect and enable automatic sync") { connect() }
                            .disabled(!canConnect).accessibilityIdentifier("privateSync.connect")
                    }
                }
                Section("What automatic means") {
                    Text("Sync runs at launch, while the app is active, after local changes and when connectivity returns. Offline changes stay local and retry with backoff. iOS may suspend the app; continuous background sync cannot be guaranteed. Open the app on each device to finish syncing.")
                    Text("The encrypted document is limited to 8 MiB and the local encrypted queue to 17 MiB. Capacity or validation failures pause syncing without silently dropping records. Use manual encrypted backups as additional protection; manual chat/note exports do not include the knowledge library.")
                    Text("Deleting a record removes it from the current synced view and keeps a deletion marker. Earlier encrypted copies can remain in GitHub commit history, clones and backups. Disconnecting does not erase the remote vault, and the app never rewrites Git history automatically.")
                }.font(.footnote).foregroundStyle(.secondary)
                if let message { Section { Text(message).foregroundStyle(.orange).font(.footnote) } }
            }
            .disabled(connecting != nil)
            .navigationTitle("Private memory sync")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { clearSecrets(); dismiss() } } }
            .onAppear {
                if let config = controller.configuration { repository = config.repository; includePrivate = config.includePrivateWorkspaces }
                controller.sceneBecameActive()
            }
            .onDisappear { connecting?.cancel(); connecting = nil; controller.cancelSetup(); clearSecrets() }
            .onChange(of: scenePhase) { _, phase in if phase != .active { connecting?.cancel(); controller.cancelSetup(); clearSecrets() } }
            .alert("Resume sync after local recovery?", isPresented: $confirmRecoveryResume) {
                Button("Resume with existing sync deletion rules", role: .destructive) { controller.resume(afterLocalRecoveryReview: true) }
                Button("Keep recovery local", role: .cancel) { }
            } message: {
                Text("Save another backup first if you need to keep every recovered item. Resuming uses the existing vault and queue: recovered IDs already deleted from the vault can disappear again, and previously synced records omitted from the recovered backup can be deleted on other devices. No old deletion markers are cleared. Cancel leaves automatic sync paused and your recovered data available locally.")
            }
            .confirmationDialog("Disconnect this device?", isPresented: $confirmDisconnect, titleVisibility: .visible) {
                Button("Remove this device’s sync credentials", role: .destructive) { controller.disconnect() }
                Button("Cancel", role: .cancel) { }
            } message: { Text("Local memory and the encrypted queue are kept. GitHub data and its history remain. Reconnecting requires the same vault and original recovery passphrase.") }
        }
    }
    private var canConnect: Bool {
        !controller.isWorking && connecting == nil && directInstallation && recoverySaved && approved &&
        !token.isEmpty && passphrase.count >= 12 && passphrase == repeatedPassphrase && !repository.isEmpty
    }
    private func connect() {
        let selectedRepository = repository.trimmingCharacters(in: .whitespacesAndNewlines)
        let selectedToken = token, selectedPassphrase = passphrase
        let selectedPrivateScope = includePrivate, selectedInstallation = directInstallation
        clearSecrets(); message = nil
        connecting = Task {
            do {
                try await controller.setup(repo: selectedRepository, token: selectedToken, passphrase: selectedPassphrase,
                    includePrivateWorkspaces: selectedPrivateScope, directInstallationConfirmed: selectedInstallation)
            } catch is CancellationError { }
            catch { message = controller.statusDetail }
            connecting = nil
        }
    }
    private func clearSecrets() { token = ""; passphrase = ""; repeatedPassphrase = "" }
}
