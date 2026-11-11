import SwiftUI
import UniformTypeIdentifiers
import UIKit
import FoundationModels

#if DEBUG
/// Route before constructing the ordinary app's stores, preferences or services.
@main @MainActor enum AsterionDebugAppLauncher {
    static func main() {
        if ChecklistLifecycleUITestFixture.fromLaunchArguments() != nil {
            ChecklistLifecycleUITestApp.main()
        } else {
            AsterionVeyraApp.main()
        }
    }
}
#else
@main
#endif
@MainActor struct AsterionVeyraApp: App {
    @StateObject private var store: AssistantStore
    @StateObject private var credentials: GitHubCredentialStore
    @StateObject private var preferences = AssistantPreferences.forApplication()
    // Shared by all windows: one durable identity, counter and outbox owner.
    @StateObject private var pairedDesktop: PairedDesktopClient
    init() {
        #if DEBUG
        _pairedDesktop = StateObject(wrappedValue: AssistantControlsUITestFixture.pairedDesktop())
        if ChatUITestFixture.fromLaunchArguments() != nil, ProcessInfo.processInfo.arguments.contains("--uitest-open-voice-controls") {
            VoiceEntryRequest.shared.request()
        }
        #else
        _pairedDesktop = StateObject(wrappedValue: PairedDesktopClient())
        #endif
        let store = AssistantStore()
        _store = StateObject(wrappedValue: store)
        _credentials = StateObject(wrappedValue: GitHubCredentialStore(onSessionEnded: { [weak store] in
            store?.switchProject("General")
        }))
    }
    var body: some Scene { WindowGroup { MainView(preferences: preferences).environmentObject(store).environmentObject(credentials).environmentObject(pairedDesktop).environmentObject(preferences) } }
}
struct MainView: View {
    @EnvironmentObject var store: AssistantStore
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var diagnostics = DiagnosticsController()
    @ObservedObject private var preferences: AssistantPreferences
    @State private var selectedTab: String
    @ObservedObject private var voiceEntry = VoiceEntryRequest.shared
    init(preferences: AssistantPreferences) {
        self.preferences = preferences
        _selectedTab = State(initialValue: preferences.value.startScreen.rawValue)
    }
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
        .task {
            diagnostics.runIfDue()
            store.memorySync?.sceneBecameActive()
            if voiceEntry.pending { selectedTab = "assistant" }
        }
        .onChange(of: voiceEntry.pending) { _, pending in if pending { selectedTab = "assistant" } }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                diagnostics.runIfDue()
                store.memorySync?.sceneBecameActive()
            } else {
                store.memorySync?.sceneBecameInactive()
            }
        }
        #if DEBUG
        .modifier(ChecklistVoiceUITestFixture())
        #endif
        .tint(.cyan)
        .preferredColorScheme(.dark)
        .alert(preferences.value.name, isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) {
            Button("OK") { store.error = nil }
        } message: { Text(store.error ?? "") }
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
                Section("Current scope") { Text("Public and explicitly connected private GitHub repositories; bounded model-directed source reads; local note search; encrypted manual memory transfer and opt-in private GitHub memory sync. Separate review screens support optional hosted answers and new-branch draft pull requests. They do not run automatically from model responses. Sync requires explicit private-repository setup and runs while iOS allows the app to work. Other devices need a compatible client and the same recovery passphrase. Arbitrary local code execution is not implemented. Optional paired desktop jobs are bounded and read-only; real device pairing still needs verification. Voice uses turn-taking when on-device recognition is available. Active-audio background operation needs direct-device testing.") }
                Section("Real limits") { Text("Requires iOS 26 and available Apple Intelligence. Context, storage, battery and background execution are finite. The app cannot control arbitrary installed apps or run Xcode. No guarantee of unlimited knowledge or perfect recall.") }
                Section("Paired desktop jobs") {
                    NavigationLink("Review paired desktop setup") { PairedDesktopView() }
                        .accessibilityIdentifier("pairedDesktop.open")
                    Text("Foreground client for explicitly paired, read-only jobs. Memory sync is configured separately. iOS does not allow always-on phone execution.").font(.caption)
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

