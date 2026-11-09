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
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @EnvironmentObject private var credentials: GitHubCredentialStore
    var onRepositorySelected: ((Repository, String, GitHubClient, String) -> Void)? = nil
    @State private var owner = ""
    @State private var search = ""
    @State private var searchPresented = false
    @State private var collection: ProjectCollection = .all
    @State private var inspectedWorkspace: SavedWorkspaceSummary?
    private enum ProjectCollection: String, CaseIterable { case all = "All", saved = "Saved", github = "GitHub" }
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
                if search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Section {
                        LibraryOverview(eyebrow: "YOUR WORKSPACES", title: "Pick up where you left off",
                            subtitle: "Keep each project’s conversations, notes and source context together.", symbol: "square.stack.3d.up")
                        HStack(alignment: .top, spacing: 12) {
                            LibraryItemIcon(symbol: "checkmark.circle")
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Current workspace").font(.caption).foregroundStyle(.secondary)
                                Text(WorkspaceDisplay(store.project).title).font(.headline).fixedSize(horizontal: false, vertical: true)
                                Text(WorkspaceDisplay(store.project).subtitle).font(.caption).foregroundStyle(.secondary)
                            }
                        }.padding(.vertical, 4).accessibilityElement(children: .combine)
                    }
                }
                Section {
                    Picker("Project collection", selection: $collection) {
                        ForEach(ProjectCollection.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }.pickerStyle(.segmented).accessibilityIdentifier("projects.collection")
                }.listRowBackground(Color.clear).listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                connectionSection
                if collection != .github { savedProjects }
                if collection != .saved { githubProjects }
                if credentials.connection == nil {
                    publicProjects
                    privateConnection
                }
                Section {
                    DisclosureGroup("Session and saved credentials") {
                        Button("Sign out and remove saved token", role: .destructive) { signOut() }
                        Text("Sign-out cancels requests and clears current source context. Your saved notes and conversations remain in Memory and Assistant until you delete them.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .contentMargins(.bottom, 32, for: .scrollContent)
            .scrollDismissesKeyboard(.interactively)
            .searchable(text: $search, isPresented: $searchPresented,
                        placement: .navigationBarDrawer(displayMode: .always), prompt: "Search projects, owners or branches")
            .navigationTitle("Projects")
            .sheet(item: $inspectedWorkspace) { project in
                NavigationStack {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            Text(project.id).textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                            Text("\(project.noteCount) notes · \(project.messageCount) messages")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                    }
                    .navigationTitle("Workspace details")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Close") { inspectedWorkspace = nil }
                                .accessibilityIdentifier("projects.workspace.details.close")
                        }
                    }
                }
            }
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

    private var savedWorkspaces: [SavedWorkspaceSummary] {
        LibraryPresentation.workspaces(state: store.saved, current: store.project, query: search)
    }
    private var matchingRepositories: [Repository] {
        LibraryPresentation.repositories(repositories, query: search)
    }
    private var savedProjects: some View {
        Section {
            ForEach(savedWorkspaces) { project in
                Button {
                    store.switchProject(project.id)
                    searchPresented = false
                    search = ""
                } label: {
                    HStack(alignment: .top, spacing: 12) {
                        if !dynamicTypeSize.isAccessibilitySize {
                            LibraryItemIcon(symbol: project.id == "General" ? "sparkles" : "folder")
                        }
                        VStack(alignment: .leading, spacing: 5) {
                            Text(WorkspaceDisplay(project.id).title).font(.headline).foregroundStyle(.primary)
                                .lineLimit(3).truncationMode(.middle)
                                .fixedSize(horizontal: false, vertical: true)
                            Text(WorkspaceDisplay(project.id).subtitle).font(.caption).foregroundStyle(.secondary)
                                .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : nil)
                                .fixedSize(horizontal: false, vertical: true)
                            if !dynamicTypeSize.isAccessibilitySize {
                                Text("\(project.noteCount) notes · \(project.messageCount) messages")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            if dynamicTypeSize.isAccessibilitySize && project.id == store.project {
                                Label("Selected", systemImage: "checkmark.circle.fill")
                                    .font(.caption).foregroundStyle(.cyan).accessibilityHidden(true)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        if !dynamicTypeSize.isAccessibilitySize {
                            Spacer(minLength: 4)
                            if project.id == store.project {
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(.cyan).accessibilityHidden(true)
                            }
                        }
                    }.padding(.vertical, 6)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(project.id)
                .accessibilityValue(project.id == store.project ? "Selected" : "\(project.noteCount) notes, \(project.messageCount) messages")
                .accessibilityHint("Switch the Assistant and Memory to this saved workspace")
                .contextMenu {
                    Button("Show full workspace name") { inspectedWorkspace = project }
                }
                .privacySensitive()
            }
            if savedWorkspaces.isEmpty {
                LibraryEmptyState(title: "No matching workspaces", detail: "Try a project name or owner. Search stays on this device.", symbol: "magnifyingglass")
            }
        } header: { Text("Saved workspaces · \(savedWorkspaces.count)") }
        footer: { Text("Saved notes and conversations are available offline. Opening a saved workspace does not reconnect its live repository.") }
    }
    private var githubProjects: some View {
        Section {
            ForEach(matchingRepositories) { repository in
                NavigationLink(value: RepositorySelection(repository: repository, connectionID: credentials.connection?.id)) {
                    HStack(alignment: .top, spacing: 12) {
                        LibraryItemIcon(symbol: "chevron.left.forwardslash.chevron.right")
                        VStack(alignment: .leading, spacing: 5) {
                            Text(WorkspaceDisplay(repository.full_name).title).font(.headline)
                                .fixedSize(horizontal: false, vertical: true)
                            Text(WorkspaceDisplay(repository.full_name).subtitle).font(.subheadline).foregroundStyle(.secondary)
                            Label(repository.default_branch, systemImage: "arrow.triangle.branch")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }.padding(.vertical, 6)
                }
                .accessibilityLabel(repository.full_name)
                .accessibilityHint("Browse source, then choose this project for the Assistant")
                .privacySensitive()
            }
            if repositories.isEmpty && !loading {
                LibraryEmptyState(title: "Your repositories, one place", detail: "Load public repositories or connect your GitHub account below. Browsing requires an internet connection.", symbol: "network")
            } else if matchingRepositories.isEmpty && !loading {
                LibraryEmptyState(title: "No matching repositories", detail: "Search the loaded names, owners or branches. More repositories may be available on the next page.", symbol: "magnifyingglass")
            }
            if more {
                Button { Task { await load(reset: false) } } label: { Label("Load more repositories", systemImage: "arrow.down.circle") }
                    .disabled(loading)
            }
            if loading { ProgressView("Loading repositories…") }
        } header: { Text("GitHub repositories · \(matchingRepositories.count)") }
    }
    @ViewBuilder private var connectionSection: some View {
        if let connection = credentials.connection {
            Section("GitHub connection") {
                Label(connection.account.login, systemImage: "lock.shield").font(.headline)
                Button { Task { await load(reset: true) } } label: {
                    Label(repositories.isEmpty ? "Load accessible repositories" : "Refresh repositories", systemImage: "arrow.clockwise")
                }.disabled(loading)
                DisclosureGroup("Read-only session details") {
                    Text("This session ends after eight hours, app exit or sign-out. Each opened repository is pinned to a commit; saved copies are not live source.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
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
                if !commit.isEmpty {
                    NavigationLink("Review a repository edit") {
                        RepositoryProposalView(repository: repository, immutableCommit: commit, readClient: client)
                    }.disabled(loading)
                }
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
        let readCommit = commit
        defer { if generation == requestGeneration { loading = false } }
        do {
            let source = try await client.text(repo: repository.full_name, file: file, ref: readCommit)
            try Task.checkCancellation(); try client.validateSession()
            guard generation == requestGeneration else { return }
            selected = file; text = source; showFile = true
            store.captureRepositoryRead(source, repository: repository.full_name, path: file.path,
                                        commit: readCommit, workspace: workspace, client: client)
        } catch { if generation == requestGeneration && !Task.isCancelled { store.error = GitHubRequestPolicy.safeError(error, authenticated: true).localizedDescription } }
    }
}
