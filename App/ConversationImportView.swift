import SwiftUI
import UniformTypeIdentifiers

/// Embed in the existing Memory navigation stack. Root integration owns the active
/// account/project, successful canonical state loading, atomic save and optional indexing.
struct ConversationImportView: View {
    let project: String
    let savedState: SavedState
    let onImport: (SavedState) throws -> Void
    @State private var kind: ConversationImportKind = .chatGPTConversations
    @State private var preview: ConversationImportPreview?
    @State private var selected = Set<UUID>()
    @State private var acknowledged = false
    @State private var showingPicker = false
    @State private var showingConfirmation = false
    @State private var reading = false
    @State private var status: String?
    @State private var generation = UUID()
    @State private var loadTask: Task<Void, Never>?
    @State private var readerTask: Task<ConversationImportPreview, Error>?

    var body: some View {
        List {
            Section("Import copies you choose") {
                Text("Only files you select are read. This app cannot access your ChatGPT accounts or inherit another assistant’s memories. Conversation exports do not guarantee saved-memory coverage.")
                Text("Destination: local Memory and chat history in \(project). The local assistant may retrieve imported text. Hosted mode uses it only if you explicitly include and review it there. This is untrusted reference material, not permission to act.")
                    .font(.footnote).foregroundStyle(.secondary)
                Text("Extract ZIP files outside this app, then select conversations.json or one numbered conversation JSON part. Images, audio, video, attached files and links are not imported or downloaded. Only the selected active text branch is supported.")
                    .font(.footnote).foregroundStyle(.secondary)
                Link("OpenAI: export your ChatGPT data", destination: URL(string: "https://help.openai.com/en/articles/7260999-exporting-your-chatgpt-history-and-data")!)
                Picker("File format", selection: $kind) {
                    ForEach(ConversationImportKind.allCases) { item in Text(item.label).tag(item) }
                }.disabled(reading)
                if kind != .chatGPTConversations {
                    Text(kind == .memoryText
                         ? "A UTF-8 .txt or .md file becomes one memory note, up to 20,000 characters. Copy only memories you personally want to retain."
                         : "This accepts only the documented Asterion memory-import JSON schema, not an assumed OpenAI saved-memory format. See the project’s conversation import guide.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Button { showingPicker = true } label: { Label("Choose a file to preview", systemImage: "doc.badge.plus") }
                    .disabled(reading).accessibilityIdentifier("conversationImport.choose")
                if reading { ProgressView("Reading selected file locally…") }
                if let status { Text(status).font(.footnote).accessibilityIdentifier("conversationImport.status") }
            }
            if let preview {
                previewSummary(preview)
                Section("Choose what to import") {
                    HStack {
                        Button("Select all") { selected = Set(preview.groups.map(\.id)); acknowledged = false }
                        Spacer()
                        Button("Select none") { selected = []; acknowledged = false }
                    }
                    ForEach(preview.groups) { group in
                        VStack(alignment: .leading, spacing: 6) {
                            Toggle(isOn: Binding(get: { selected.contains(group.id) }, set: { value in
                                if value { selected.insert(group.id) } else { selected.remove(group.id) }
                                acknowledged = false
                            })) {
                                VStack(alignment: .leading) {
                                    Text(group.title)
                                    Text("\(group.recordCount) supported records · \(group.omittedBranchNodes) alternate-branch nodes omitted · \(group.skippedMessages) messages skipped")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            NavigationLink("Review text and provenance") { ConversationImportDetail(group: group) }
                                .font(.footnote)
                        }
                    }
                }
                Section {
                    Toggle("I reviewed the selected content and want to import it, including any selected items I previously deleted.", isOn: $acknowledged)
                        .accessibilityIdentifier("conversationImport.acknowledge")
                    Text("Existing record IDs are kept unchanged. Reimporting cannot overwrite them. Because canonical history has no deletion markers, an explicitly confirmed import can restore selected records you deleted. Duplicate-only selections add nothing.")
                        .font(.footnote).foregroundStyle(.secondary)
                    Button("Review import of \(selected.count) items") { reviewImport(preview) }
                        .disabled(selected.isEmpty || !acknowledged || reading)
                        .accessibilityIdentifier("conversationImport.review")
                    Button("Clear preview", role: .cancel) { reset() }
                } header: { Text("Nothing is saved until you confirm") }
                footer: {
                    Text("Secret detection is a heuristic, not a guarantee. Review private content before importing. The canonical store must stay within 5 MB, 10,000 notes and 10,000 messages; choose a smaller subset if it does not fit. There is no silent truncation or automatic eviction.")
                }
            }
        }
        .navigationTitle("Import conversations")
        .fileImporter(isPresented: $showingPicker, allowedContentTypes: kind == .memoryText ? [.plainText] : [.json], allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls): if let url = urls.first { load(url) }
            case .failure(let error):
                if (error as NSError).code != NSUserCancelledError { status = ConversationImportFailure.unavailable.localizedDescription }
            }
        }
        .confirmationDialog("Import selected local copies?", isPresented: $showingConfirmation, titleVisibility: .visible) {
            Button("Import selected items") { saveSelection() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The selected text will be added to local Memory and chat history in \(project). Existing records will not be overwritten. Selected records that were deleted can be restored. No ChatGPT account is connected.")
        }
        .onChange(of: project) { _, _ in reset() }
        .onChange(of: kind) { _, _ in reset() }
        .onDisappear { cancelReading() }
    }

    private func previewSummary(_ preview: ConversationImportPreview) -> some View {
        Section("Preview · \(preview.filename)") {
            Text("\(preview.sourceItems) source items · \(preview.groups.count) importable items")
            Text("\(preview.groups.reduce(0) { $0 + $1.messages.count }) supported user/assistant text messages · \(preview.groups.filter { $0.memory != nil }.count) memory notes")
            Text("\(preview.omittedBranchNodes) alternate-branch nodes omitted. \(preview.missingTimestamps) records have no source timestamp and use the local import time.")
                .font(.footnote).foregroundStyle(.secondary)
            ForEach(ConversationImportSkip.allCases, id: \.rawValue) { reason in
                if let count = preview.skipped[reason], count > 0 {
                    Text("\(reason.label): \(count)").font(.footnote).foregroundStyle(.orange)
                }
            }
            Text("Coverage is for supported plain text on current_node’s ancestor branch only. Export metadata, tools/system messages, other branches and assets are not copied. Unknown structures may be skipped or rejected. This is not a full account migration.")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    private func load(_ url: URL) {
        reset(); reading = true
        let request = generation, expectedProject = project, expectedKind = kind
        let worker = Task.detached(priority: .userInitiated) {
            try ConversationImportSelectedFileReader.previewSelected(url, kind: expectedKind, project: expectedProject)
        }
        readerTask = worker
        loadTask = Task {
            do {
                let result = try await ConversationImportTask.value(of: worker)
                guard !Task.isCancelled, generation == request, project == expectedProject else { return }
                preview = result; status = result.groups.isEmpty ? "No supported items were found. Review the coverage and skipped counts." : nil
            } catch {
                guard !Task.isCancelled, generation == request else { return }
                status = safeMessage(error)
            }
            if generation == request { reading = false; readerTask = nil; loadTask = nil }
        }
    }
    private func reviewImport(_ preview: ConversationImportPreview) {
        do {
            _ = try preview.selection(ids: selected, into: savedState, acknowledgeRestoringDeleted: acknowledged)
            showingConfirmation = true
        } catch { status = safeMessage(error) }
    }
    private func saveSelection() {
        guard let preview, preview.project == project else { reset(); return }
        do {
            let incoming = try preview.selection(ids: selected, into: savedState, acknowledgeRestoringDeleted: acknowledged)
            if incoming.notes.isEmpty && incoming.chats.isEmpty { status = "All selected record IDs already exist. Nothing was changed."; return }
            try onImport(incoming)
            let summary = "Imported \(incoming.chats.count) text messages and \(incoming.notes.count) memory notes into \(project)."
            reset(); status = summary
        } catch { status = safeMessage(error) }
    }
    private func cancelReading() {
        generation = UUID(); readerTask?.cancel(); readerTask = nil
        loadTask?.cancel(); loadTask = nil; reading = false
    }
    private func reset() {
        cancelReading()
        preview = nil; selected = []; acknowledged = false; showingConfirmation = false; status = nil
    }
    private func safeMessage(_ error: Error) -> String {
        (error as? ConversationImportFailure ?? .unavailable).localizedDescription
    }
}

private struct ConversationImportDetail: View {
    let group: ConversationImportGroup
    var body: some View {
        List {
            Section("Source preview · untrusted plain text") {
                Text(group.title).font(.headline)
                Text("\(group.omittedBranchNodes) alternative-branch nodes and \(group.skippedMessages) unsupported messages are not included.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if let memory = group.memory {
                Section("Memory note") {
                    Text(memory.source).font(.caption)
                    Text(memory.text).textSelection(.enabled)
                }
            }
            ForEach(group.messages, id: \.id) { message in
                Section(message.role == "user" ? "User" : "Assistant") {
                    Text(message.text).textSelection(.enabled)
                }
            }
        }.navigationTitle("Review import")
    }
}
