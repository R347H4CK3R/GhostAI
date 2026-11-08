import SwiftUI

private struct GitHubConnectionConsent {
    let token: String
    let restoreSaved: Bool
    let rememberOnDevice: Bool
    let directInstallationConfirmed: Bool
}

private struct RepositorySelection: Hashable {
    let repository: Repository
    let connectionID: UUID?
}

struct RepositoriesView: View {
    @EnvironmentObject var store: AssistantStore
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var credentials: GitHubCredentialStore
    var onRepositorySelected: ((Repository, String, GitHubClient, String) -> Void)? = nil
    @State private var owner = ""
    @State private var repositories: [Repository] = []
    @State private var page = 1
    @State private var more = false
    @State private var loading = false
    @State private var loadedOwner = ""
    @State private var navigation: [RepositorySelection] = []
    @State private var generation = UUID()
    @State private var token = ""
    @State private var directInstallationConfirmed = false
    @State private var rememberOnDevice = false
    @State private var pendingConsent: GitHubConnectionConsent?
    @State private var connecting = false
    @State private var connectionAttempt = UUID()
    @State private var connectionTask: Task<Void, Never>?
    private let publicClient = GitHubClient()

    var body: some View {
        NavigationStack(path: $navigation) {
            List {
                if let connection = credentials.connection {
                    Section("Connected GitHub account") {
                        Label(connection.account.login, systemImage: "lock.shield")
                        Button("Load accessible repositories") { Task { await load(reset: true) } }.disabled(loading)
                        Text("Read-only session. Ends after eight hours, app exit or sign-out. Each repository is pinned to a commit.").font(.caption)
                    }
                } else {
                    publicProjects
                    privateConnection
                }
                Section {
                    Button("Sign out and remove saved token", role: .destructive) { signOut() }
                    Text("Sign-out cancels requests and clears current source context. Saved offline notes and conversations remain until you delete them under Memory or Assistant.").font(.caption).foregroundStyle(.secondary)
                }
                Section("Project workspaces") {
                    Button("General assistant") { store.switchProject("General") }
                    ForEach(repositories) { repository in
                        NavigationLink(value: RepositorySelection(repository: repository, connectionID: credentials.connection?.id)) {
                            Label(repository.full_name, systemImage: credentials.connection == nil ? "folder.fill" : "lock.doc")
                        }
                    }
                    if more { Button("Load more") { Task { await load(reset: false) } }.disabled(loading) }
                    if loading { ProgressView() }
                }
                Section("Saved offline workspaces") {
                    ForEach(Array(Set(store.saved.notes.map(\.project) + store.saved.chats.map(\.project))).sorted(), id: \.self) { project in
                        Button(project) { store.switchProject(project) }
                    }
                }
            }
            .navigationTitle("Project nexus")
            .navigationDestination(for: RepositorySelection.self) { selection in
                if let id = selection.connectionID {
                    if let connection = credentials.connection, connection.id == id {
                        RepositoryView(repository: selection.repository, client: connection.client,
                                       workspace: connection.workspace(for: selection.repository.full_name), onRepositorySelected: onRepositorySelected)
                    } else { Text("This GitHub session ended. Return to Projects and connect again.") }
                } else if credentials.connection == nil {
                    RepositoryView(repository: selection.repository, client: publicClient,
                                   workspace: selection.repository.full_name, onRepositorySelected: onRepositorySelected)
                } else { Text("The connection changed. Return to Projects.") }
            }
            .alert("Use this GitHub token?", isPresented: Binding(
                get: { pendingConsent != nil },
                set: { if !$0 { pendingConsent = nil; token = "" } }
            ), presenting: pendingConsent) { consent in
                // Use the presented snapshot: SwiftUI can clear the binding before the button runs.
                Button("Connect to api.github.com") { startConnection(consent) }
                    .accessibilityIdentifier("github-confirm-connect")
                Button("Cancel", role: .cancel) { pendingConsent = nil; token = "" }
                    .accessibilityIdentifier("github-cancel-connect")
            } message: { consent in
                Text("The token will be sent only to https://api.github.com for read-only requests. A stolen token could expose every repository it can access. Use selected repositories and Contents: Read-only. " + (consent.restoreSaved || consent.rememberOnDevice ? "You also authorize storing it in this device’s non-synchronizing Keychain until you sign out." : "It will stay in memory for this session only.") + " Do not proceed in Strata or another app host.")
            }
        }
        .onChange(of: credentials.connection?.id) { _, _ in resetBrowser() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background {
                if connecting { cancelConnection() }
                token = ""; pendingConsent = nil; directInstallationConfirmed = false
            }
            if phase == .active { credentials.endExpiredSession() }
        }
        .onDisappear { token = ""; pendingConsent = nil }
    }

    private var publicProjects: some View {
        Section("Connect your public projects") {
            TextField("GitHub username", text: $owner).textInputAutocapitalization(.never).autocorrectionDisabled()
            Button("Load public repositories") { Task { await load(reset: true) } }.disabled(loading || connecting || owner.isEmpty)
            Text("Anonymous read-only browsing needs no token.").font(.caption).foregroundStyle(.secondary)
        }
    }
    private var privateConnection: some View {
        Section("Private GitHub · direct installation only") {
            Label("Do not enter tokens in Strata or another hosted app. Its host may read credentials and private code. This app cannot reliably detect that environment.", systemImage: "exclamationmark.shield.fill")
                .font(.callout).foregroundStyle(.orange)
            Text("Create your own fine-grained token at GitHub Settings → Developer settings → Personal access tokens. Choose only the repositories needed, Contents: Read-only, and a short expiration. The app never creates tokens and cannot reduce an over-permissioned token’s rights.").font(.caption)
            Toggle("I am using a directly installed app", isOn: $directInstallationConfirmed).disabled(connecting)
                .accessibilityIdentifier("github-direct-install-toggle")
            SecureField("Fine-grained GitHub token", text: $token)
                .textInputAutocapitalization(.never).autocorrectionDisabled().privacySensitive().disabled(connecting)
                .accessibilityIdentifier("github-token-field")
            Toggle("Remember in this device’s Keychain", isOn: $rememberOnDevice).disabled(connecting || !directInstallationConfirmed)
            Text("Off by default. No iCloud Keychain sync, chat memory, diagnostic logs or app backup export. Saved credentials are never loaded automatically.").font(.caption).foregroundStyle(.secondary)
            Button("Connect private GitHub") { prepareConsent(restoreSaved: false) }
                .disabled(connecting || !directInstallationConfirmed || token.isEmpty)
                .accessibilityIdentifier("github-connect-button")
            Button("Use saved token on this device") { prepareConsent(restoreSaved: true) }
                .disabled(connecting || !directInstallationConfirmed)
            if connecting {
                ProgressView("Checking GitHub account")
                Button("Cancel connection") { cancelConnection() }
            }
        }
    }

    private func resetBrowser() {
        generation = UUID(); navigation = []; repositories = []; page = 1
        more = false; loading = false; loadedOwner = ""
    }
    private func cancelConnection() {
        connectionAttempt = UUID(); connectionTask?.cancel(); connectionTask = nil
        connecting = false; token = ""; pendingConsent = nil; credentials.endSession()
    }
    private func signOut() {
        cancelConnection(); resetBrowser(); store.switchProject("General")
        rememberOnDevice = false; directInstallationConfirmed = false
        do { try credentials.signOut() }
        catch { store.error = GitHubRequestPolicy.safeError(error, authenticated: true).localizedDescription }
    }
    private func prepareConsent(restoreSaved: Bool) {
        pendingConsent = GitHubConnectionConsent(token: restoreSaved ? "" : token, restoreSaved: restoreSaved,
            rememberOnDevice: rememberOnDevice, directInstallationConfirmed: directInstallationConfirmed)
        token = ""
    }
    private func startConnection(_ consent: GitHubConnectionConsent) {
        guard !connecting else { return }
        resetBrowser(); store.switchProject("General")
        token = ""; pendingConsent = nil
        let shouldRemember = consent.restoreSaved || consent.rememberOnDevice
        do {
            let session: GitHubAuthSession
            if consent.restoreSaved { session = try credentials.beginSaved(directInstallationConfirmed: consent.directInstallationConfirmed) }
            else { session = try credentials.begin(token: consent.token, directInstallationConfirmed: consent.directInstallationConfirmed) }
            connecting = true
            let attempt = UUID(); connectionAttempt = attempt
            connectionTask = Task {
                defer { if connectionAttempt == attempt { connecting = false; connectionTask = nil } }
                do {
                    let account = try await GitHubClient(authentication: session).account()
                    try Task.checkCancellation()
                    guard connectionAttempt == attempt else { return }
                    try credentials.complete(session: session, account: account, rememberOnDevice: shouldRemember)
                } catch {
                    guard connectionAttempt == attempt else { return }
                    credentials.endSession()
                    if !Task.isCancelled { store.error = GitHubRequestPolicy.safeError(error, authenticated: true).localizedDescription }
                }
            }
        } catch { store.error = GitHubRequestPolicy.safeError(error, authenticated: true).localizedDescription }
    }
    private func load(reset: Bool) async {
        guard !loading, !connecting else { return }
        if reset { resetBrowser() }
        let requestGeneration = generation
        let connection = credentials.connection
        let requestedOwner = reset ? owner.trimmingCharacters(in: .whitespacesAndNewlines) : loadedOwner
        let nextPage = reset ? 1 : page + 1
        loading = true
        defer { if generation == requestGeneration { loading = false } }
        do {
            let items: [Repository]
            if let connection { items = try await connection.client.repositories(page: nextPage) }
            else { items = try await publicClient.repositories(owner: requestedOwner, page: nextPage) }
            try Task.checkCancellation()
            guard generation == requestGeneration, credentials.connection?.id == connection?.id else { return }
            let existing = Set(repositories.map(\.id))
            repositories += items.filter { !existing.contains($0.id) }
            page = nextPage; more = items.count == 50; loadedOwner = requestedOwner
        } catch {
            if generation == requestGeneration && !Task.isCancelled {
                store.error = GitHubRequestPolicy.safeError(error, authenticated: connection != nil).localizedDescription
            }
        }
    }
}

struct RepositoryView: View {
    @EnvironmentObject var store: AssistantStore
    let repository: Repository
    let client: GitHubClient
    let workspace: String
    var onRepositorySelected: ((Repository, String, GitHubClient, String) -> Void)? = nil
    @State private var commit = ""
    @State private var path = ""
    @State private var files: [RepoFile] = []
    @State private var loading = false
    @State private var selected: RepoFile?
    @State private var text = ""
    @State private var showFile = false
    @State private var generation = UUID()

    var body: some View {
        List {
            Section {
                Button("Use this project in Assistant") { selectWorkspace() }.disabled(commit.isEmpty || loading)
                if !commit.isEmpty { Text("Pinned commit \(commit.prefix(12))").font(.caption.monospaced()) }
                Text(path.isEmpty ? "/" : path).font(.caption)
                Button("Reload folder") { Task { await browse(path) } }.disabled(loading)
                if !path.isEmpty { Button("Parent folder") { Task { await browse(path.split(separator: "/").dropLast().joined(separator: "/")) } }.disabled(loading) }
            }
            if loading { ProgressView() }
            ForEach(files) { file in
                Button {
                    Task { if file.type == "dir" { await browse(file.path) } else { await open(file) } }
                } label: { Label(file.name, systemImage: file.type == "dir" ? "folder" : "doc.text") }
                .disabled(loading || (file.type != "dir" && !file.isRegularFile))
            }
        }.navigationTitle(repository.full_name.split(separator: "/").last.map(String.init) ?? "Repository")
        .task { if commit.isEmpty { await browse("") } }
        .onDisappear { generation = UUID(); loading = false }
        .sheet(isPresented: $showFile, onDismiss: { text = "" }) {
            NavigationStack {
                ScrollView { Text(text).font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding() }.privacySensitive()
                .navigationTitle(selected?.name ?? "Source")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Close") { showFile = false; text = "" } }
                    ToolbarItem(placement: .primaryAction) {
                        Menu("Use source") {
                            Button("Attach to next question") {
                                guard safeSource(), selectWorkspace() else { return }
                                store.attached = text; store.attachmentSource = sourceLabel
                                showFile = false; text = ""
                            }
                            Button("Save excerpt for offline use") {
                                guard safeSource(), selectWorkspace() else { return }
                                store.remember(String(text.prefix(20_000)), source: sourceLabel + " (first 20,000 characters)")
                                if store.error == nil { showFile = false; text = "" }
                            }
                        }
                    }
                }
            }
        }
    }
    private var sourceLabel: String { "\(repository.full_name)/\(selected?.path ?? "") @ \(commit)" }
    private func safeSource() -> Bool {
        guard MemorySearch.canSave(text) else { store.error = "Possible credential in source. Remove it before attaching or saving."; return false }
        return true
    }
    @discardableResult private func selectWorkspace() -> Bool {
        do { try client.validateSession() }
        catch { store.error = GitHubRequestPolicy.safeError(error, authenticated: true).localizedDescription; return false }
        guard !commit.isEmpty else { return false }
        if let onRepositorySelected { onRepositorySelected(repository, commit, client, workspace) }
        else { store.switchProject(workspace) }
        return true
    }
    private func browse(_ nextPath: String) async {
        guard !loading else { return }; loading = true
        let requestGeneration = generation
        defer { if generation == requestGeneration { loading = false } }
        do {
            let pinned = commit.isEmpty ? try await client.commit(repository) : commit
            let nextFiles = try await client.directory(repo: repository.full_name, path: nextPath, ref: pinned)
            try Task.checkCancellation(); try client.validateSession()
            guard generation == requestGeneration else { return }
            commit = pinned
            files = nextFiles.sorted { a, b in
                if (a.type == "dir") != (b.type == "dir") { return a.type == "dir" }
                return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
            path = nextPath
        } catch { if generation == requestGeneration && !Task.isCancelled { store.error = GitHubRequestPolicy.safeError(error, authenticated: true).localizedDescription } }
    }
    private func open(_ file: RepoFile) async {
        guard !loading else { return }; loading = true
        let requestGeneration = generation
        defer { if generation == requestGeneration { loading = false } }
        do {
            let source = try await client.text(repo: repository.full_name, file: file, ref: commit)
            try Task.checkCancellation(); try client.validateSession()
            guard generation == requestGeneration else { return }
            selected = file; text = source; showFile = true
        } catch { if generation == requestGeneration && !Task.isCancelled { store.error = GitHubRequestPolicy.safeError(error, authenticated: true).localizedDescription } }
    }
}
