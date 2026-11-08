import SwiftUI

struct RepositoriesView: View {
    @EnvironmentObject var store: AssistantStore
    @State private var owner = ""
    @State private var repositories: [Repository] = []
    @State private var page = 1
    @State private var more = false
    @State private var loading = false
    @State private var loadedOwner = ""
    private let client = GitHubClient()
    var body: some View {
        NavigationStack {
            List {
                Section("Connect your public projects") {
                    TextField("GitHub username", text: $owner).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button("Load public repositories") { Task { await load(reset: true) } }.disabled(loading || owner.isEmpty)
                    Text("Read-only access. Private repositories need a separate connection in a future version.").font(.caption).foregroundStyle(.secondary)
                }
                Section("Project workspaces") {
                    Button("General assistant") { store.switchProject("General") }
                    ForEach(repositories) { repository in
                        NavigationLink(value: repository) { Label(repository.full_name, systemImage: "folder.fill") }
                    }
                    if more { Button("Load more") { Task { await load(reset: false) } }.disabled(loading) }
                    if loading { ProgressView() }
                }
                Section("Saved offline workspaces") {
                    ForEach(Array(Set(store.saved.notes.map(\.project) + store.saved.chats.map(\.project))).sorted(), id: \.self) { project in
                        Button(project) { store.switchProject(project) }
                    }
                }
            }.navigationTitle("Project nexus")
            .navigationDestination(for: Repository.self) { repository in RepositoryView(repository: repository) }
        }
    }
    private func load(reset: Bool) async {
        guard !loading else { return }
        loading = true; defer { loading = false }
        do {
            let nextPage = reset ? 1 : page + 1
            let requestedOwner = reset ? owner.trimmingCharacters(in: .whitespacesAndNewlines) : loadedOwner
            let items = try await client.repositories(owner: requestedOwner, page: nextPage)
            if reset { repositories = [] }
            let existing = Set(repositories.map(\.id))
            repositories += items.filter { !existing.contains($0.id) }
            page = nextPage; more = items.count == 50; loadedOwner = requestedOwner
        } catch { store.error = error.localizedDescription }
    }
}
struct RepositoryView: View {
    @EnvironmentObject var store: AssistantStore
    let repository: Repository
    @State private var commit = ""
    @State private var path = ""
    @State private var files: [RepoFile] = []
    @State private var loading = false
    @State private var selected: RepoFile?
    @State private var text = ""
    @State private var showFile = false
    private let client = GitHubClient()
    var body: some View {
        List {
            Section {
                Button("Use this project in Assistant") { store.switchProject(repository.full_name) }
                if !commit.isEmpty { Text("Pinned commit \(commit.prefix(12))").font(.caption.monospaced()) }
                Text(path.isEmpty ? "/" : path).font(.caption)
                Button("Reload folder") { Task { await browse(path) } }.disabled(loading)
                if !path.isEmpty { Button("Parent folder") { Task { await browse(path.split(separator: "/").dropLast().joined(separator: "/")) } }.disabled(loading) }
            }
            if loading { ProgressView() }
            ForEach(files) { file in
                Button {
                    Task {
                        if file.type == "dir" { await browse(file.path) }
                        else { await open(file) }
                    }
                } label: { Label(file.name, systemImage: file.type == "dir" ? "folder" : "doc.text") }
                .disabled(loading || (file.type != "dir" && file.type != "file"))
            }
        }.navigationTitle(repository.full_name.split(separator: "/").last.map(String.init) ?? "Repository")
        .task { if commit.isEmpty { await browse("") } }
        .sheet(isPresented: $showFile) {
            NavigationStack {
                ScrollView { Text(text).font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding() }
                .navigationTitle(selected?.name ?? "Source")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Close") { showFile = false } }
                    ToolbarItem(placement: .primaryAction) {
                        Menu("Use source") {
                            Button("Attach to next question") {
                                store.switchProject(repository.full_name)
                                store.attached = text; store.attachmentSource = sourceLabel
                                showFile = false
                            }
                            Button("Save excerpt for offline use") {
                                store.switchProject(repository.full_name)
                                store.remember(String(text.prefix(20_000)), source: sourceLabel + " (first 20,000 characters)")
                                if store.error == nil { showFile = false }
                            }
                        }
                    }
                }
            }
        }
    }
    private var sourceLabel: String { "\(repository.full_name)/\(selected?.path ?? "") @ \(commit)" }
    private func browse(_ nextPath: String) async {
        guard !loading else { return }; loading = true; defer { loading = false }
        do {
            if commit.isEmpty { commit = try await client.commit(repository) }
            let nextFiles = try await client.directory(repo: repository.full_name, path: nextPath, ref: commit)
            try Task.checkCancellation()
            files = nextFiles.sorted { a, b in
                if (a.type == "dir") != (b.type == "dir") { return a.type == "dir" }
                return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
            path = nextPath
        } catch { if !Task.isCancelled { store.error = error.localizedDescription } }
    }
    private func open(_ file: RepoFile) async {
        guard !loading else { return }; loading = true; defer { loading = false }
        do {
            let source = try await client.text(repo: repository.full_name, file: file, ref: commit)
            try Task.checkCancellation()
            selected = file; text = source; showFile = true
        } catch { if !Task.isCancelled { store.error = error.localizedDescription } }
    }
}
