import SwiftUI
import UniformTypeIdentifiers
import UIKit
import FoundationModels

@main @MainActor struct AsterionVeyraApp: App {
    @StateObject private var store: AssistantStore
    @StateObject private var credentials: GitHubCredentialStore
    // Shared by all windows: one durable identity, counter and outbox owner.
    @StateObject private var pairedDesktop = PairedDesktopClient()
    init() {
        let store = AssistantStore()
        _store = StateObject(wrappedValue: store)
        _credentials = StateObject(wrappedValue: GitHubCredentialStore(onSessionEnded: { [weak store] in
            store?.switchProject("General")
        }))
    }
    var body: some Scene { WindowGroup { MainView().environmentObject(store).environmentObject(credentials).environmentObject(pairedDesktop) } }
}
struct MainView: View {
    @EnvironmentObject var store: AssistantStore
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var diagnostics = DiagnosticsController()
    @State private var selectedTab = "assistant"
    @ObservedObject private var voiceEntry = VoiceEntryRequest.shared
    var body: some View {
        TabView(selection: $selectedTab) {
            ChatView(isSelected: selectedTab == "assistant").tabItem { Label("Assistant", systemImage: "sparkles") }.tag("assistant")
            RepositoriesView(onRepositorySelected: { repository, commit, client, workspace in
                store.selectRepository(repository, commit: commit, client: client, workspace: workspace)
            }).tabItem { Label("Projects", systemImage: "folder") }.tag("projects")
            MemoryView().tabItem { Label("Memory", systemImage: "brain") }.tag("memory")
            HostedAssistantView().tabItem { Label("Hosted", systemImage: "cloud") }.tag("hosted")
            AboutView(onOpenIntegration: { selectedTab = $0 }).tabItem { Label("About", systemImage: "info.circle") }.tag("about")
        }
        .environmentObject(diagnostics)
        .task { diagnostics.runIfDue(); if voiceEntry.pending { selectedTab = "assistant" } }
        .onChange(of: voiceEntry.pending) { _, pending in if pending { selectedTab = "assistant" } }
        .onChange(of: scenePhase) { _, phase in if phase == .active { diagnostics.runIfDue() } }
        .tint(.cyan)
        .preferredColorScheme(.dark)
        .alert("Jarvis", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) {
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
    @State private var conversationImport: ConversationImportRoute?
    var body: some View {
        NavigationStack {
            List {
                Section("Save for offline use · \(store.project)") {
                    TextField("A fact, decision or source excerpt", text: $note, axis: .vertical).lineLimit(3...8).accessibilityIdentifier("memoryNoteInput")
                    Button("Remember note") { store.remember(note); if store.error == nil { note = "" } }
                    Text("Review first. Do not save credentials. Notes stay on this device and are retrieved as needed, not permanently learned by the model.").font(.caption)
                }
                Section("Offline knowledge") {
                    if let knowledge = store.knowledge {
                        KnowledgeStatusRow(model: knowledge, savedState: store.saved)
                    } else {
                        Text(store.loadFailed ? "Restore canonical memory before opening the library." : "Offline library is unavailable in this session.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    if let issue = store.knowledgeIssue { Text(issue).font(.footnote).foregroundStyle(.orange) }
                }
                Section("Import chosen conversations") {
                    Button("Import conversations or memories") {
                        guard !store.loadFailed, conversationImport == nil else { return }
                        // Capture approval scope and preview state once, at the user's tap.
                        conversationImport = ConversationImportRoute(project: store.project,
                            workspaceEpoch: store.workspaceEpoch, savedState: store.saved)
                    }
                    .disabled(store.loadFailed)
                    .accessibilityIdentifier("conversationImport.open")
                    Text("Preview a conversation export or memory file you select, then confirm what to add to this workspace. No ChatGPT account is connected. Nothing is saved before your confirmation.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Backup all projects") {
                    Button("Encrypted transfer") { encryptedTransfer = true }
                        .accessibilityIdentifier("encryptedTransferOpen")
                    Button("Export chats and notes backup") {
                        do { backup = MemoryDocument(data: try store.backupData()); exporting = true }
                        catch { store.error = error.localizedDescription }
                    }
                    Button(store.loadFailed ? "Restore backup and preserve unreadable data" : "Import and merge backup") { importing = true }
                    Text("Exports include all project notes and chats as unencrypted JSON. Store them privately. Import preserves existing records and does not refresh source code. This backup does not include the separate offline knowledge library, imported files or action cache.").font(.caption)
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
            .sheet(item: $conversationImport) { route in
                NavigationStack {
                    ConversationImportView(project: route.project, savedState: route.savedState) { additions in
                        try route.apply(additions, to: store)
                    }
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Close") { conversationImport = nil }
                                .accessibilityIdentifier("conversationImport.close")
                        }
                    }
                }.id(route.id)
            }
            .onChange(of: store.workspaceEpoch) { _, epoch in
                if let route = conversationImport, route.workspaceEpoch != epoch { conversationImport = nil }
            }
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
    /// The sheet owns an immutable destination and snapshot, never a live approval binding.
    struct ConversationImportRoute: Identifiable {
        let id = UUID()
        let project: String
        let workspaceEpoch: UUID
        let savedState: SavedState

        @MainActor func apply(_ additions: SavedState, to store: AssistantStore) throws {
            try store.importConversationAdditions(additions, expectedProject: project,
                                                  expectedWorkspaceEpoch: workspaceEpoch)
        }
    }
    private struct KnowledgeStatusRow: View {
        @ObservedObject var model: KnowledgeLibraryModel
        let savedState: SavedState
        var body: some View {
            NavigationLink {
                KnowledgeLibraryView(model: model, savedState: savedState)
            } label: {
                VStack(alignment: .leading, spacing: 5) {
                    Label("Search and manage offline knowledge", systemImage: "books.vertical")
                    Text(status).font(.caption).foregroundStyle(.secondary)
                }
            }.accessibilityIdentifier("knowledge.open")
            if let message = model.message { Text(message).font(.footnote).foregroundStyle(.orange) }
        }
        private var status: String {
            if model.unavailable { return "Library unavailable · existing data preserved" }
            let enabled = [model.settings.captureConversations, model.settings.captureActions, model.settings.captureResearch].filter { $0 }.count
            let capture = enabled == 0 ? "Automatic capture off" : "\(enabled) of 3 capture types enabled"
            let count = model.coverage?.entries ?? 0
            return "\(capture) · \(count) saved items" + (model.coverage?.captureIsFull == true ? " · full" : "")
        }
    }

}
struct AboutView: View {
    var onOpenIntegration: ((String) -> Void)? = nil
    @State private var showIntegrations = false
    @EnvironmentObject var store: AssistantStore
    @EnvironmentObject private var diagnostics: DiagnosticsController
    @State private var diagnosticPreview: String?
    @State private var brightness = Double(UIScreen.main.brightness)
    private var localModelAvailable: Bool {
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }
    private func openIntegration(_ tab: String) {
        showIntegrations = false
        onOpenIntegration?(tab)
    }
    var body: some View {
        NavigationStack {
            List {
                Section("App updates") {
                    NavigationLink("Check for app updates") { AppUpdatesView() }
                        .accessibilityIdentifier("updates.open")
                }
                Section("Independent assistant") { Text("Jarvis combines this app’s native assistant with everyday planning and reviewed Luma imports. It is independent of ChatGPT, with its own local conversations and memories.") }
                Section("Works offline") { Text("Saved notes, chat history, retrieved project context and available Apple on-device inference. GitHub discovery and repository tools need internet. Local Assistant and voice stay on-device. The separate Hosted screen sends only the request you explicitly review to OpenAI and may incur API charges.") }
                Section("Current scope") { Text("Public and explicitly connected private GitHub repositories; bounded model-directed source reads; local note search; encrypted manual memory transfer. Separate review screens support optional hosted answers and new-branch draft pull requests. They do not run automatically from model responses. Automatic cross-device memory sync and arbitrary local code execution are not implemented. Optional paired desktop jobs are a development preview with native verification pending. Voice uses turn-taking when on-device recognition is available. Active-audio background operation needs direct-device testing.") }
                Section("Real limits") { Text("Requires iOS 26 and available Apple Intelligence. Context, storage, battery and background execution are finite. The app cannot control arbitrary installed apps or run Xcode. No guarantee of unlimited knowledge or perfect recall.") }
                Section("Paired desktop jobs") {
                    NavigationLink("Review paired desktop setup") { PairedDesktopView() }
                        .accessibilityIdentifier("pairedDesktop.open")
                    Text("Development foreground client for explicitly paired, read-only jobs. No automatic memory sync or always-on phone execution.").font(.caption)
                }
                Section("Integrations") {
                    Button("Review integrations and permissions") { showIntegrations = true }
                        .accessibilityIdentifier("openIntegrations")
                    Text("See bundled tools, data destinations and setup. No accounts are connected or requests sent by opening this catalog.").font(.caption)
                }
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
                    Text("A directly installed app exposes Open Jarvis and Open voice controls as App Shortcuts. Try Siri after installation; no custom always-listening wake word is used.")
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
            .sheet(isPresented: $showIntegrations) {
                IntegrationsView(runtime: IntegrationRuntimeSnapshot(network: .unknown,
                    localModelAvailable: localModelAvailable,
                    memoryAvailable: !store.loadFailed), navigation: IntegrationNavigation(
                    openAssistant: { openIntegration("assistant") }, openMemory: { openIntegration("memory") },
                    openProjects: { openIntegration("projects") }, openHosted: { openIntegration("hosted") }))
            }
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

