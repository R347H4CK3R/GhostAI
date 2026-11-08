import SwiftUI
import UniformTypeIdentifiers
import UIKit

@main struct AsterionVeyraApp: App {
    @StateObject private var store = AssistantStore()
    var body: some Scene { WindowGroup { MainView().environmentObject(store) } }
}
struct MainView: View {
    @EnvironmentObject var store: AssistantStore
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var diagnostics = DiagnosticsController()
    var body: some View {
        TabView {
            ChatView().tabItem { Label("Assistant", systemImage: "sparkles") }
            RepositoriesView().tabItem { Label("Projects", systemImage: "folder") }
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
struct ChatView: View {
    @EnvironmentObject var store: AssistantStore
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var voice = VoiceController()
    @State private var voiceConversation = false
    @State private var awaitingVoiceReply = false
    @State private var speakReplies = true
    @State private var backgroundVoice = false
    @State private var question = ""
    @State private var confirmClear = false
    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 14) {
                    ZStack {
                        Circle().fill(LinearGradient(colors: [.cyan.opacity(0.25), .purple.opacity(0.3)], startPoint: .topLeading, endPoint: .bottomTrailing))
                        Circle().stroke(.cyan.opacity(0.7), lineWidth: 1).padding(5)
                        Image(systemName: "sparkles").font(.title).foregroundStyle(.cyan)
                    }.frame(width: 58, height: 58)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("ASTERION VEYRA").font(.caption.weight(.bold)).tracking(3).foregroundStyle(.cyan)
                        Text(store.project).font(.headline).lineLimit(1)
                        Text("LOCAL INTELLIGENCE · YOUR PROJECTS").font(.system(size: 8, weight: .semibold)).tracking(1).foregroundStyle(.secondary)
                    }
                }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
                .background(LinearGradient(colors: [.cyan.opacity(0.1), .purple.opacity(0.12)], startPoint: .leading, endPoint: .trailing), in: RoundedRectangle(cornerRadius: 20))
                Text(store.modelStatus).font(.caption).foregroundStyle(.secondary)
                if !store.attached.isEmpty {
                    HStack {
                        Text("Source: \(store.attachmentSource)\nUses first 3,000 characters").font(.caption).lineLimit(3)
                        Spacer()
                        Button("Clear") { store.attached = ""; store.attachmentSource = "" }
                    }
                }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        ForEach(store.saved.chats.filter { $0.project == store.project }) { chat in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(chat.role == "user" ? "You" : "Asterion · proposed answer").font(.caption.bold()).foregroundStyle(.secondary)
                                Text(chat.text).textSelection(.enabled)
                            }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                            .background(chat.role == "user" ? Color.cyan.opacity(0.1) : Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 16))
                        }
                        if !store.answer.isEmpty && !store.saved.chats.contains(where: { $0.project == store.project && $0.role == "assistant" && $0.text == store.answer }) {
                            VStack(alignment: .leading, spacing: 6) {
                                Label("Unsaved answer · review before exporting", systemImage: "exclamationmark.triangle").font(.caption.bold()).foregroundStyle(.orange)
                                Text(store.answer).textSelection(.enabled)
                            }.padding(12).background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
                        }
                        if store.busy { ProgressView("Thinking on device…") }
                    }
                }
                TextField("Ask about this project", text: $question, axis: .vertical).lineLimit(2...5).textFieldStyle(.roundedBorder)
                HStack {
                    Button("Send") { endVoiceConversation(); store.ask(question) }.buttonStyle(.borderedProminent).disabled(store.busy || question.isEmpty)
                    if store.busy { Button("Stop") { endVoiceConversation(); store.cancel() } }
                    Spacer()
                    if !store.answer.isEmpty { ShareLink("Export answer", item: store.answer) }
                }
                HStack {
                    Button {
                        if voiceConversation { endVoiceConversation() }
                        else { voiceConversation = true; voice.allowsBackgroundVoice = backgroundVoice; beginVoiceTurn() }
                    } label: {
                        Label(voiceConversation ? "End voice" : "Voice conversation", systemImage: voiceConversation ? "mic.slash.fill" : "mic.fill")
                    }.disabled(store.busy && !voiceConversation)
                    Spacer()
                    Button {
                        if voice.state == .speaking { endVoiceConversation() }
                        else { endVoiceConversation(); voice.speak(store.answer) }
                    } label: { Image(systemName: voice.state == .speaking ? "speaker.slash.fill" : "speaker.wave.2.fill") }
                    .accessibilityLabel(voice.state == .speaking ? "Stop speech" : "Read latest answer aloud")
                    .disabled(store.answer.isEmpty || store.busy)
                }
                Toggle("Speak voice replies", isOn: $speakReplies).font(.caption)
                Toggle("Continue active voice in background", isOn: $backgroundVoice).font(.caption)
                    .disabled(voiceConversation)
                Text("Background voice is optional for a directly signed installation. Memory remains available after first unlock. iOS or interruptions can stop the session; this is not an always-running agent.").font(.caption2).foregroundStyle(.secondary)
                Text(voice.status).font(.caption).foregroundStyle(voice.state == .listening ? Color.cyan : Color.secondary)
                if voice.state == .listening && !voice.transcript.isEmpty {
                    Text(voice.transcript).font(.caption).lineLimit(3)
                }
                Text("Start voice here. Without background voice enabled, leaving the app pauses it. Stop ends microphone and audio use.").font(.caption2).foregroundStyle(.secondary)
                Text("Answers are suggestions. This version cannot execute code or change GitHub.").font(.caption2).foregroundStyle(.secondary)
            }.padding().navigationTitle("Asterion")
            .onChange(of: store.busy) { _, busy in
                guard !busy, awaitingVoiceReply else { return }
                awaitingVoiceReply = false
                guard voiceConversation, (scenePhase == .active || voice.allowsBackgroundVoice), store.error == nil, !store.answer.isEmpty else {
                    endVoiceConversation(); return
                }
                if speakReplies { voice.speak(store.answer) { beginVoiceTurn() } }
                else { voice.endReplyWindow(); beginVoiceTurn() }
            }
            .onChange(of: voice.state) { _, state in
                if state == .failed || state == .unavailable || state == .interrupted {
                    voiceConversation = false
                    if awaitingVoiceReply { store.cancel() }
                    awaitingVoiceReply = false
                    voice.allowsBackgroundVoice = false
                }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .background && !voice.allowsBackgroundVoice { endVoiceConversation() }
            }
            .onChange(of: store.project) { _, _ in endVoiceConversation() }
            .onDisappear { endVoiceConversation() }
            .toolbar { Button("Clear chat", role: .destructive) { confirmClear = true } }
            .confirmationDialog("Delete this project’s chat history?", isPresented: $confirmClear) {
                Button("Delete chat", role: .destructive) { store.clearProjectChat() }
                Button("Cancel", role: .cancel) {}
            }
        }
    }
    private func beginVoiceTurn() {
        guard VoicePolicy.shouldListen(conversationEnabled: voiceConversation, foreground: scenePhase == .active, busy: store.busy, allowsBackgroundVoice: voice.allowsBackgroundVoice) else { return }
        voice.startListening { text in
            guard voiceConversation, (scenePhase == .active || voice.allowsBackgroundVoice) else { voice.endReplyWindow(); return }
            question = text
            awaitingVoiceReply = true
            store.ask(text)
            if !store.busy { endVoiceConversation() }
        }
    }
    private func endVoiceConversation() {
        voiceConversation = false
        if awaitingVoiceReply { store.cancel() }
        awaitingVoiceReply = false
        voice.stop()
        voice.allowsBackgroundVoice = false
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
    var body: some View {
        NavigationStack {
            List {
                Section("Save for offline use · \(store.project)") {
                    TextField("A fact, decision or source excerpt", text: $note, axis: .vertical).lineLimit(3...8).accessibilityIdentifier("memoryNoteInput")
                    Button("Remember note") { store.remember(note); if store.error == nil { note = "" } }
                    Text("Review first. Do not save credentials. Notes stay on this device and are retrieved as needed, not permanently learned by the model.").font(.caption)
                }
                Section("Backup all projects") {
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
            .confirmationDialog(store.loadFailed ? "Restore this backup? The unreadable local file will be preserved separately." : "Merge this backup into local memory? Existing records will be kept.", isPresented: Binding(get: { pendingImport != nil }, set: { if !$0 { pendingImport = nil } })) {
                Button(store.loadFailed ? "Restore backup" : "Merge backup") { if let data = pendingImport { store.importBackup(data) }; pendingImport = nil }
                Button("Cancel", role: .cancel) { pendingImport = nil }
            }
            .confirmationDialog("Delete this saved note?", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })) {
                Button("Delete note", role: .destructive) { if let id = pendingDelete { store.forget(id) }; pendingDelete = nil }
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
                Section("Works offline") { Text("Saved notes, chat history, retrieved project context and available Apple on-device inference. GitHub discovery and fresh source need internet. No cloud AI requests are made.") }
                Section("Current scope") { Text("Public GitHub repositories; source explanation and proposed edits; local note search. Private repositories, GitHub writes, hosted models, automatic cross-device sync and autonomous code execution are not implemented. Voice uses explicit turn-taking when on-device recognition is available. Optional active-audio background operation needs direct-device testing.") }
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
