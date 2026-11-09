import SwiftUI
import UIKit

struct ChatView: View {
    var isSelected = true
    @State private var showingPlanning = false
    @EnvironmentObject var store: AssistantStore
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var voice = VoiceController()
    @ObservedObject private var voiceEntry = VoiceEntryRequest.shared
    @FocusState private var composerFocused: Bool
    // Drafts are project-scoped and stay in memory, never in the saved note/chat store.
    @State private var drafts: [String: String] = [:]
    @State private var submittedQuestion: String?
    @State private var failedQuestion: String?
    @State private var inlineError: String?
    @State private var showVoiceSettings = false
    @State private var voiceConversation = false
    @State private var awaitingVoiceReply = false
    @State private var speakReplies = true
    @State private var backgroundVoice = false
    @State private var confirmClear = false
    private let bottomID = "chat-bottom"

    private var draft: Binding<String> {
        Binding(get: { drafts[store.project, default: ""] }, set: { drafts[store.project] = $0 })
    }
    private var chats: [ChatEntry] { store.saved.chats.filter { $0.project == store.project } }
    private var canSend: Bool { !store.busy && !draft.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        NavigationStack {
            transcript
                .safeAreaInset(edge: .bottom, spacing: 0) { composer }
                .navigationTitle("Jarvis")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button { showingPlanning = true } label: { Label("Plan and act", systemImage: "checklist") }
                            .accessibilityIdentifier("planning.open")
                    }
                    ToolbarItem(placement: .principal) {
                        VStack(spacing: 2) {
                            Label("Jarvis", systemImage: "sparkles").font(.subheadline.weight(.semibold))
                            Text(store.connectionState.shortLabel + " · " + store.project).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                                .accessibilityIdentifier("chatConnectionSummary")
                        }.accessibilityElement(children: .combine)
                            .accessibilityIdentifier("chatIdentityAndConnection")
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            if !store.answer.isEmpty { ShareLink("Export answer", item: store.answer) }
                            Button("Voice settings", systemImage: "waveform") { openVoiceSettings() }
                            Button("Clear chat", role: .destructive) { confirmClear = true }
                        } label: { Image(systemName: "ellipsis.circle") }
                        .accessibilityLabel("Chat options")
                    }
                    ToolbarItemGroup(placement: .keyboard) {
                        Spacer()
                        Button("Done") { composerFocused = false }
                            .accessibilityLabel("Dismiss keyboard")
                            .accessibilityIdentifier("chatKeyboardDone")
                    }
                }
                .navigationDestination(isPresented: $showingPlanning) {
                    UnifiedPlanningView(onSubmitQuestion: submitPlannedQuestion)
                }
                .onChange(of: isSelected) { _, selected in if selected { consumeVoiceEntry() } }
                .onChange(of: scenePhase) { _, phase in if phase == .active { consumeVoiceEntry() } }
                .sheet(isPresented: $showVoiceSettings) { voiceSettings }
                .onAppear { consumeVoiceEntry() }
                .onChange(of: voiceEntry.pending) { _, pending in if pending { consumeVoiceEntry() } }
                .confirmationDialog("Delete this project’s chat history?", isPresented: $confirmClear) {
                    Button("Delete chat", role: .destructive) {
                        endVoiceConversation(); store.clearProjectChat()
                        inlineError = nil; failedQuestion = nil; submittedQuestion = nil
                    }
                    Button("Cancel", role: .cancel) {}
                }
                // Receive the error at publication, before ask's task clears busy.
                // onChange can coalesce busy's transitions and observe only false,
                // losing the accepted question needed by "Edit and try again".
                .onReceive(store.$error) { message in
                    guard let message else { return }
                    inlineError = message
                    if store.busy { failedQuestion = submittedQuestion }
                }
                .onChange(of: store.busy) { _, busy in
                    guard !busy else { return }
                    if store.error != nil { failedQuestion = submittedQuestion }
                    guard awaitingVoiceReply else { return }
                    awaitingVoiceReply = false
                    guard voiceConversation, (scenePhase == .active || voice.allowsBackgroundVoice), store.error == nil, !store.answer.isEmpty else {
                        endVoiceConversation(); return
                    }
                    if speakReplies { voice.speak(store.answer) { beginVoiceTurn() } }
                    else { voice.endReplyWindow(); beginVoiceTurn() }
                }
                .onChange(of: voice.state) { _, state in
                    if state == .failed || state == .unavailable || state == .interrupted {
                        inlineError = voice.status
                        voiceConversation = false
                        if awaitingVoiceReply { store.cancel() }
                        awaitingVoiceReply = false
                        voice.allowsBackgroundVoice = false
                    }
                }
                .onChange(of: scenePhase) { _, phase in
                    if !voice.allowsBackgroundVoice && (phase == .background || (phase == .inactive && awaitingVoiceReply)) {
                        if store.busy {
                            failedQuestion = submittedQuestion
                            inlineError = "Request paused when the app left the foreground. Edit and send again when ready."
                            store.cancel()
                        }
                        endVoiceConversation()
                    }
                }
                .onChange(of: store.project) { _, _ in
                    composerFocused = false; endVoiceConversation()
                    inlineError = nil; submittedQuestion = nil; failedQuestion = nil
                }
                .onDisappear { composerFocused = false; endVoiceConversation() }
        }
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    contextSummary
                    if chats.isEmpty && !store.busy {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("What are we working on?").font(.title2.weight(.semibold))
                            Text("Ask a question or work through your project here. Local answers are suggestions; they do not execute code or change GitHub.")
                                .font(.subheadline).foregroundStyle(.secondary)
                        }.padding(.vertical, 20)
                    }
                    ForEach(chats) { chat in
                        message(chat.text, isUser: chat.role == "user", source: store.responseSources[chat.id] ?? "Saved response · source not recorded")
                            .id(chat.id)
                    }
                    if !store.answer.isEmpty && !chats.contains(where: { $0.role == "assistant" && $0.text == store.answer }) {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("Unsaved answer · review before exporting", systemImage: "exclamationmark.triangle")
                                .font(.caption.bold()).foregroundStyle(.orange)
                            Text(store.answer).textSelection(.enabled)
                        }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
                            .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 18))
                    }
                    if store.busy {
                        if let submittedQuestion { message(submittedQuestion, isUser: true) }
                        HStack(spacing: 10) {
                            ProgressView()
                            Text(store.connectionState == .checking ? "Checking live GitHub…" : "Thinking with Apple on device…").font(.subheadline).foregroundStyle(.secondary)
                                .accessibilityIdentifier("chatPendingStatus")
                        }.padding(.vertical, 8)
                    }
                    if let inlineError {
                        VStack(alignment: .leading, spacing: 10) {
                            Label("Couldn’t complete that request", systemImage: "exclamationmark.bubble")
                                .font(.subheadline.weight(.semibold))
                            Text(inlineError).font(.subheadline).textSelection(.enabled)
                                .accessibilityIdentifier("chatInlineError")
                            if let failedQuestion, draft.wrappedValue.isEmpty {
                                Button("Edit and try again") {
                                    draft.wrappedValue = failedQuestion
                                    composerFocused = true
                                }.accessibilityIdentifier("chatRestoreDraft")
                            }
                        }.foregroundStyle(.orange).padding(14)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 18))
                    }
                    Color.clear.frame(height: 1).id(bottomID)
                }.padding(.horizontal, 16).padding(.vertical, 12)
            }
            .accessibilityIdentifier("chatTranscript")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .scrollDismissesKeyboard(.interactively)
            .defaultScrollAnchor(.bottom, for: .initialOffset)
            .onChange(of: store.saved.chats.count) { _, _ in scrollToLatest(proxy) }
            .onChange(of: store.busy) { _, _ in scrollToLatest(proxy) }
            .onChange(of: inlineError) { _, _ in scrollToLatest(proxy) }
            .onChange(of: store.project) { _, _ in scrollToLatest(proxy) }
            // Wait for the keyboard's actual geometry before locating the newest row.
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidShowNotification)) { _ in
                if composerFocused { scrollToLatest(proxy) }
            }
        }
    }

    private var contextSummary: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(store.modelStatus, systemImage: "iphone").font(.caption).foregroundStyle(.secondary)
            Label(store.connectionState.label, systemImage: store.connectionState.symbol)
                .font(.caption).foregroundStyle(store.connectionState.usesSavedOnlyFallback ? Color.orange : Color.secondary)
                .accessibilityIdentifier("chatConnectionStatus")
            if let repository = store.selectedRepository {
                Label("\(repository.repository) @ \(repository.commit.prefix(8))", systemImage: "chevron.left.forwardslash.chevron.right")
                    .font(.caption2).foregroundStyle(.cyan)
            }
            if !store.attached.isEmpty {
                HStack(alignment: .top) {
                    Label("Source: \(store.attachmentSource)\nUses a bounded source excerpt", systemImage: "doc.text")
                        .font(.caption).lineLimit(3)
                    Spacer(minLength: 8)
                    Button("Remove", systemImage: "xmark.circle.fill") { store.attached = ""; store.attachmentSource = "" }
                        .labelStyle(.iconOnly).accessibilityLabel("Remove attached source")
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func message(_ text: String, isUser: Bool, source: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(isUser ? "You" : "Jarvis").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            if !isUser, let source { Text(source).font(.caption2).foregroundStyle(.secondary) }
            Text(text).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(isUser ? Color.cyan.opacity(0.1) : Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 18))
    }

    private var composer: some View {
        VStack(spacing: 8) {
            if voiceConversation || voice.state == .speaking {
                HStack(spacing: 8) {
                    Image(systemName: "waveform").foregroundStyle(.cyan)
                    Text(voiceCallStatus)
                        .font(.caption).lineLimit(2)
                    Spacer(minLength: 4)
                    Button("End call") { endVoiceConversation() }.font(.caption.weight(.semibold))
                }.padding(.horizontal, 6)
            }
            HStack(alignment: .bottom, spacing: 8) {
                Button { openVoiceSettings() } label: {
                    Image(systemName: "phone.fill").font(.title3).frame(width: 44, height: 44)
                }.accessibilityLabel("Voice call and settings").accessibilityHint("Open controls for an on-device voice conversation.").accessibilityIdentifier("chatVoiceSettings")
                TextField("Message Jarvis", text: draft, axis: .vertical)
                    .lineLimit(1...4).padding(.vertical, 12)
                    .focused($composerFocused)
                    .accessibilityLabel("Message Jarvis")
                    .accessibilityHint("Write a message for the selected project. Swipe down in the conversation or use Done to dismiss the keyboard.")
                    .accessibilityIdentifier("chatComposer")
                if store.busy {
                    Button {
                        composerFocused = false
                        endVoiceConversation(); store.cancel()
                        failedQuestion = submittedQuestion
                        inlineError = "Response stopped. You can edit the request and try again."
                    } label: {
                        Image(systemName: "stop.fill").font(.body.weight(.semibold)).frame(width: 44, height: 44)
                    }.accessibilityLabel("Stop generating").accessibilityIdentifier("chatStop")
                } else {
                    Button(action: sendMessage) {
                        Image(systemName: "arrow.up").font(.body.weight(.bold)).frame(width: 40, height: 40)
                            .foregroundStyle(canSend ? Color.black : Color.secondary)
                            .background(canSend ? Color.cyan : Color.white.opacity(0.08), in: Circle())
                            .frame(width: 44, height: 44)
                    }.disabled(!canSend).accessibilityLabel("Send message").accessibilityIdentifier("chatSend")
                }
            }.padding(.horizontal, 6).padding(.vertical, 4)
                .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 26))
                .overlay(RoundedRectangle(cornerRadius: 26).stroke(.white.opacity(0.1), lineWidth: 1))
        }.padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 8)
            .background(.bar)
    }

    private var voiceSettings: some View {
        NavigationStack {
            Form {
                Section {
                    Button {
                        if voiceConversation { endVoiceConversation() }
                        else {
                            composerFocused = false
                            inlineError = nil
                            voiceConversation = true
                            voice.allowsBackgroundVoice = backgroundVoice
                            showVoiceSettings = false
                            beginVoiceTurn()
                        }
                    } label: {
                        Label(voiceConversation ? "End voice call" : "Start voice call", systemImage: voiceConversation ? "phone.down.fill" : "phone.fill")
                            .frame(maxWidth: .infinity)
                    }.buttonStyle(.borderedProminent).controlSize(.large)
                        .tint(voiceConversation ? .red : .cyan)
                        .disabled(store.busy && !voiceConversation)
                        .accessibilityIdentifier("chatStartVoiceCall")
                    Text("Talk back and forth with Jarvis using this device’s microphone and speaker. This is an in-app voice conversation, not a telephone call. Microphone and speech permission are requested when you start.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button {
                        if voice.state == .speaking { endVoiceConversation() }
                        else { endVoiceConversation(); voice.speak(store.answer) }
                    } label: {
                        Label(voice.state == .speaking ? "Stop speech" : "Read latest answer aloud", systemImage: "speaker.wave.2.fill")
                    }.disabled(store.answer.isEmpty || store.busy)
                    Text(voiceCallStatus).font(.caption).foregroundStyle(.secondary)
                }
                Section {
                    Toggle("Speak voice replies", isOn: $speakReplies)
                    Toggle("Continue active voice in background", isOn: $backgroundVoice).disabled(voiceConversation)
                } header: {
                    Text("Conversation")
                } footer: {
                    Text("Background voice is optional for a directly signed installation. Memory remains available after first unlock. iOS or interruptions can stop the session; this is not an always-running agent.")
                }
                Section {
                    Text("Start voice here. Without background voice enabled, leaving the app pauses it. Stop ends microphone and audio use.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.navigationTitle("Voice call").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { showVoiceSettings = false }.accessibilityIdentifier("voiceSettingsDone")
                    }
                }
        }
    }

    private var voiceCallStatus: String {
        if awaitingVoiceReply && store.busy { return "Thinking on device · microphone paused" }
        switch voice.state {
        case .listening:
            return voice.transcript.isEmpty ? "Listening · microphone on" : "Listening: " + voice.transcript
        case .speaking: return "Speaking · microphone paused"
        case .requestingPermission: return "Waiting for microphone and speech permission"
        default: return voice.status
        }
    }

    private func scrollToLatest(_ proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(bottomID, anchor: .bottom) }
    }
    private func consumeVoiceEntry() {
        guard isSelected, scenePhase == .active else { return }
        if voiceEntry.consume() { showingPlanning = false; openVoiceSettings() }
    }
    private func openVoiceSettings() { composerFocused = false; showVoiceSettings = true }
    private func submitPlannedQuestion(_ text: String) -> Bool {
        endVoiceConversation()
        composerFocused = false
        guard store.ask(text) else {
            if let error = store.error { inlineError = error }
            return false
        }
        // Use the same request bookkeeping as typed chat; preserve any typed draft.
        submittedQuestion = text.trimmingCharacters(in: .whitespacesAndNewlines)
        inlineError = nil; failedQuestion = nil
        return true
    }
    private func sendMessage() {
        guard canSend else { return }
        endVoiceConversation()
        let text = draft.wrappedValue
        composerFocused = false
        guard store.ask(text) else {
            if let error = store.error { inlineError = error }
            return
        }
        submittedQuestion = text.trimmingCharacters(in: .whitespacesAndNewlines)
        inlineError = nil; failedQuestion = nil
        draft.wrappedValue = ""
    }
    private func beginVoiceTurn() {
        guard VoicePolicy.shouldListen(conversationEnabled: voiceConversation, foreground: scenePhase == .active, busy: store.busy, allowsBackgroundVoice: voice.allowsBackgroundVoice) else { return }
        voice.startListening { text in
            guard voiceConversation, (scenePhase == .active || voice.allowsBackgroundVoice) else { voice.endReplyWindow(); return }
            awaitingVoiceReply = true
            if store.ask(text) {
                submittedQuestion = text; inlineError = nil; failedQuestion = nil
            } else {
                // A failed voice turn must not overwrite an existing typed draft.
                if draft.wrappedValue.isEmpty { draft.wrappedValue = text }
                endVoiceConversation()
            }
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

