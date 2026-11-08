import SwiftUI
import UniformTypeIdentifiers
import UIKit

@main @MainActor struct AsterionVeyraApp: App {
    @StateObject private var store: AssistantStore
    @StateObject private var credentials: GitHubCredentialStore
    init() {
        let store = AssistantStore()
        _store = StateObject(wrappedValue: store)
        _credentials = StateObject(wrappedValue: GitHubCredentialStore(onSessionEnded: { [weak store] in
            store?.switchProject("General")
        }))
    }
    var body: some Scene { WindowGroup { MainView().environmentObject(store).environmentObject(credentials) } }
}
struct MainView: View {
    @EnvironmentObject var store: AssistantStore
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var diagnostics = DiagnosticsController()
    var body: some View {
        TabView {
            ChatView().tabItem { Label("Assistant", systemImage: "sparkles") }
            RepositoriesView(onRepositorySelected: { repository, commit, client, workspace in
                store.selectRepository(repository, commit: commit, client: client, workspace: workspace)
            }).tabItem { Label("Projects", systemImage: "folder") }
            MemoryView().tabItem { Label("Memory", systemImage: "brain") }
            AboutView().tabItem { Label("About", systemImage: "info.circle") }
        }
        .environmentObject(diagnostics)
        .task { diagnostics.runIfDue() }
        .onChange(of: scenePhase) { _, phase in if phase == .active { diagnostics.runIfDue() } }
        .tint(.cyan)
        .preferredColorScheme(.dark)
        .alert("Asterion", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) {
            Button("OK") { store.error = nil }
        } message: { Text(store.error ?? "") }
    }
}
struct MemoryView: View {
    @EnvironmentObject var store: AssistantStore
    @State private var note = ""
    @State private var search = ""
    @State private var pendingDelete: UUID?
    @State private var exporting = false
    @State private var importing = false
    @State private var backup = MemoryDocument(data: Data())
    @State private var pendingImport: Data?
    @State private var encryptedTransfer = false
    var body: some View {
        NavigationStack {
            List {
                Section("Save for offline use · \(store.project)") {
                    TextField("A fact, decision or source excerpt", text: $note, axis: .vertical).lineLimit(3...8).accessibilityIdentifier("memoryNoteInput")
                    Button("Remember note") { store.remember(note); if store.error == nil { note = "" } }
                    Text("Review first. Do not save credentials. Notes stay on this device and are retrieved as needed, not permanently learned by the model.").font(.caption)
                }
                Section("Backup all projects") {
                    Button("Encrypted transfer") { encryptedTransfer = true }
                        .accessibilityIdentifier("encryptedTransferOpen")
                    Button("Export complete memory backup") {
                        do { backup = MemoryDocument(data: try store.backupData()); exporting = true }
                        catch { store.error = error.localizedDescription }
                    }
                    Button(store.loadFailed ? "Restore backup and preserve unreadable data" : "Import and merge backup") { importing = true }
                    Text("Exports include all project notes and chats as unencrypted JSON. Store them privately. Import preserves existing records and does not refresh source code.").font(.caption)
                }
                Section("Saved notes") {
                    ForEach(store.saved.notes.filter { $0.project == store.project && (search.isEmpty || $0.text.localizedCaseInsensitiveContains(search)) }) { memory in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(memory.text).textSelection(.enabled)
                            Text(memory.source).font(.caption).foregroundStyle(.secondary)
                            Text(memory.savedAt, style: .date).font(.caption2)
                            HStack {
                                ShareLink("Export", item: memory.text)
                                Spacer()
                                Button("Delete", role: .destructive) { pendingDelete = memory.id }.accessibilityLabel("Delete note: " + String(memory.text.prefix(60)))
                            }
                        }
                    }
                }
            }.searchable(text: $search).navigationTitle("Offline memory")
            .sheet(isPresented: $encryptedTransfer) {
                EncryptedTransferView(backupData: { try store.backupData() }, importBackup: { data in
                    store.error = nil
                    store.importBackup(data)
                    if let error = store.error { store.error = nil; throw AppFailure.message(error) }
                }, isRestoring: store.loadFailed)
            }
            .fileExporter(isPresented: $exporting, document: backup, contentType: .json, defaultFilename: "AsterionVeyra-memory") { result in
                if case .failure(let error) = result { store.error = error.localizedDescription }
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
                do {
                    let url = try result.get()
                    let access = url.startAccessingSecurityScopedResource()
                    defer { if access { url.stopAccessingSecurityScopedResource() } }
                    let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                    guard size <= 5_000_000 else { throw AppFailure.message("Backup exceeds 5 MB.") }
                    let data = try Data(contentsOf: url)
                    _ = try MemoryBackup.decode(data)
                    pendingImport = data
                } catch { store.error = error.localizedDescription }
            }
            .alert(store.loadFailed ? "Restore this backup? The unreadable local file will be preserved separately." : "Merge this backup into local memory? Existing records will be kept.", isPresented: Binding(get: { pendingImport != nil }, set: { if !$0 { pendingImport = nil } }), presenting: pendingImport) { data in
                Button(store.loadFailed ? "Restore backup" : "Merge backup") { store.importBackup(data); pendingImport = nil }
                Button("Cancel", role: .cancel) { pendingImport = nil }
            }
            .alert("Delete this saved note?", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }), presenting: pendingDelete) { id in
                // Capture the presented ID: dismissal can clear the binding before this action runs.
                Button("Delete note", role: .destructive) { store.forget(id); pendingDelete = nil }
                Button("Cancel", role: .cancel) { pendingDelete = nil }
            }
        }
    }
}
struct AboutView: View {
    @EnvironmentObject var store: AssistantStore
    @EnvironmentObject private var diagnostics: DiagnosticsController
    @State private var diagnosticPreview: String?
    @State private var brightness = Double(UIScreen.main.brightness)
    var body: some View {
        NavigationStack {
            List {
                Section("Independent assistant") { Text("Asterion Veyra is a new app, not a clone of dot or ChatGPT. It has its own local conversations and memories.") }
                Section("Works offline") { Text("Saved notes, chat history, retrieved project context and available Apple on-device inference. GitHub discovery and repository tools need internet. No cloud AI requests are made.") }
                Section("Current scope") { Text("Public and explicitly connected private GitHub repositories; bounded model-directed source reads; local note search; encrypted manual memory transfer. GitHub writes, hosted models, automatic cross-device sync and code execution from this iPhone are not implemented. Voice uses turn-taking when on-device recognition is available. Active-audio background operation needs direct-device testing.") }
                Section("Real limits") { Text("Requires iOS 26 and available Apple Intelligence. Context, storage, battery and background execution are finite. The app cannot control arbitrary installed apps or run Xcode. No guarantee of unlimited knowledge or perfect recall.") }
                Section("Private diagnostics") {
                    Text(diagnostics.status).font(.caption)
                    Button("Run safe self-checks") { diagnostics.runChecks() }.disabled(diagnostics.isRunning)
                    Button("Test local model with a greeting") { Task { await diagnostics.runModelCheck() } }.disabled(diagnostics.isRunning || store.busy)
                    if let url = diagnostics.reportURL {
                        Button("Review redacted report") {
                            diagnosticPreview = (try? String(contentsOf: url, encoding: .utf8)) ?? "Report unavailable. Run checks again."
                        }
                        ShareLink("Export diagnostic file", item: url)
                    }
                    Text("Safe checks refresh every three days when the app is opened. Reports contain only app/iOS versions and test statuses, not chats, memories, code, credentials or recordings. Nothing is automatically uploaded to the public repository.").font(.caption)
                }
                Section("Siri and Shortcuts") {
                    Text("A directly installed app exposes Open Asterion Veyra as an App Shortcut. Try Siri after installation; no custom always-listening wake word is used.")
                    Button("Open Shortcuts") { if let url = URL(string: "shortcuts://") { UIApplication.shared.open(url) } }
                    Button("Create a shortcut in the Shortcuts editor") { if let url = URL(string: "shortcuts://create-shortcut") { UIApplication.shared.open(url) } }
                    Text("The editor opens for you to configure and approve workflows involving other apps. This app does not silently add arbitrary shortcuts.").font(.caption)
                }
                Section("Supported phone controls") {
                    Button("Open this app’s Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                    }
                    VStack(alignment: .leading) {
                        Text("Screen brightness")
                        Slider(value: $brightness, in: 0.1...1.0) { editing in
                            if !editing { UIScreen.main.brightness = CGFloat(brightness) }
                        }
                    }
                    Text("These controls run only when you use them. Files, sharing and Siri shortcuts use iOS-provided interfaces. The assistant cannot silently read other apps, change system security settings, or control every iPhone function.").font(.caption)
                }
                Section("Runtime diagnostics") {
                    Text(ProcessInfo.processInfo.operatingSystemVersionString)
                    Text("App bundle: " + (Bundle.main.bundleIdentifier ?? "Unknown"))
                    Text("Version " + (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?") + " (" + (Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?") + ")")
                    Text(store.modelStatus)
                    Text("A container may change the apparent bundle identity. Availability is not proof of successful generation. Test a harmless question and note persistence before relying on this installation.").font(.caption)
                }
                Section("Privacy") { Text("GitHub receives requested usernames, repositories and file paths. Saved data uses iOS protection until first unlock after restart, allowing active background voice to save while locked. It stays in Application Support. Device backups may include it. Uninstalling can delete it. Export important notes before changing devices. Pattern-based secret detection is incomplete.") }
            }.navigationTitle("Capabilities")
            .sheet(isPresented: Binding(get: { diagnosticPreview != nil }, set: { if !$0 { diagnosticPreview = nil } })) {
                NavigationStack {
                    ScrollView { Text(diagnosticPreview ?? "").font(.system(.caption, design: .monospaced)).textSelection(.enabled).padding() }
                    .navigationTitle("Redacted diagnostics")
                    .toolbar { Button("Done") { diagnosticPreview = nil } }
                }
            }
        }
    }
}
