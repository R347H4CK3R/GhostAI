import SwiftUI
import UniformTypeIdentifiers

struct MemoryView: View {
    @EnvironmentObject var store: AssistantStore
    @State private var note = ""
    @FocusState private var noteFocused: Bool
    @State private var search = ""
    @State private var pendingDelete: UUID?
    @State private var exporting = false
    @State private var importing = false
    @State private var backup = MemoryDocument(data: Data())
    @State private var pendingImport: Data?
    @State private var encryptedTransfer = false
    @State private var conversationImport: ConversationImportRoute?
    @State private var checklistEditor: ChecklistEditorRoute?
    var body: some View {
        NavigationStack {
            List {
                if search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Section {
                        LibraryOverview(eyebrow: "YOUR PERSONAL LIBRARY", title: WorkspaceDisplay(store.project).title,
                            subtitle: "Notes, conversations and saved sources, organized around what you’re working on.", symbol: "brain")
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 20) { memoryMetrics }
                            VStack(alignment: .leading, spacing: 16) { memoryMetrics }
                        }.padding(.vertical, 4)
                    }
                    if let controller = store.memorySync {
                        Section { MemorySyncStatusCard(controller: controller) }
                    }
                    Section("Quick note") {
                        TextField("A fact, decision or source excerpt", text: $note, axis: .vertical)
                            .lineLimit(2...8).focused($noteFocused).accessibilityIdentifier("memoryNoteInput")
                        Button(action: rememberNote) { Label("Remember note", systemImage: "plus.circle.fill") }
                            .disabled(!canRememberNote)
                        Text("Save useful context, not credentials. Notes are retrieved when needed, not permanently learned by the model.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section {
                    if visibleNotes.isEmpty {
                        LibraryEmptyState(title: search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Make room for what matters" : "No matching notes",
                            detail: search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                ? "Save a decision, preference or useful detail above. Your notes will appear here."
                                : "Try different words or search saved source text in the knowledge library.", symbol: "note.text")
                    }
                    ForEach(visibleNotes) { memory in noteRow(memory) }
                } header: { Text("Saved notes · \(visibleNotes.count)") }
                Section("Knowledge library") {
                    if let knowledge = store.knowledge {
                        KnowledgeStatusRow(model: knowledge, savedState: store.saved)
                    } else {
                        Text(store.loadFailed ? "Restore saved memory before opening the library." : "The knowledge library is unavailable in this session.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    if let issue = store.knowledgeIssue { Text(issue).font(.footnote).foregroundStyle(.orange) }
                }
                Section("Bring your context") {
                    Button {
                        guard !store.loadFailed, conversationImport == nil else { return }
                        conversationImport = ConversationImportRoute(project: store.project,
                            workspaceEpoch: store.workspaceEpoch, savedState: store.saved)
                    } label: { Label("Import conversations or memories", systemImage: "square.and.arrow.down") }
                    .disabled(store.loadFailed)
                    .accessibilityIdentifier("conversationImport.open")
                    Text("Choose a file, preview it, then confirm what to add. No ChatGPT account is connected.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Transfer and recovery") {
                    Button { encryptedTransfer = true } label: { Label("Encrypted transfer", systemImage: "lock.doc") }
                        .accessibilityIdentifier("encryptedTransferOpen")
                    DisclosureGroup("Manual backup options") {
                        Button("Export chats and notes backup") {
                            do { backup = MemoryDocument(data: try store.backupData()); exporting = true }
                            catch { store.error = error.localizedDescription }
                        }
                        Button(store.loadFailed ? "Restore backup and preserve unreadable data" : "Import and merge backup") { importing = true }
                        Text("Manual exports include all project notes and chats as unencrypted JSON. Store them privately. Imports preserve existing records and do not refresh source code. These manual backups exclude the separate knowledge library, imported files and action cache.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .contentMargins(.bottom, 32, for: .scrollContent)
            .scrollDismissesKeyboard(.interactively)
            .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search notes and sources")
            .navigationTitle("Memory")
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    if noteFocused {
                        Button("Remember note", action: rememberNote)
                            .disabled(!canRememberNote)
                            .accessibilityIdentifier("memoryNoteSaveKeyboard")
                    }
                    Spacer()
                    Button("Done") { noteFocused = false }
                }
            }
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
                if let route = checklistEditor, route.workspaceEpoch != epoch { checklistEditor = nil }
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
            } message: { _ in
                Text(store.loadFailed
                    ? "Any configured private sync will be paused before recovery. The unreadable local file and encrypted queue are preserved. Recovered data stays local until you explicitly review the effect of existing sync deletions before resuming."
                    : "If private sync is configured, included imported records will sync encrypted. Known deleted IDs are restored as new copy IDs while old deletion markers remain. Import waits for available sync history; existing live copies are not overwritten.")
            }
            .alert("Delete this saved note?", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }), presenting: pendingDelete) { id in
                // Capture the presented ID: dismissal can clear the binding before this action runs.
                Button("Delete note", role: .destructive) { store.forget(id); pendingDelete = nil }
                Button("Cancel", role: .cancel) { pendingDelete = nil }
            } message: { id in
                if let note = store.saved.notes.first(where: { $0.id == id }), let checklist = EditableChecklist.decode(note) {
                    Text("Checklist: \(checklist.goal)\nThis removes only this editable copy, not its original Luma snapshot. If included in private sync, deletion is sent when sync next succeeds. Encrypted older versions can remain in remote history.")
                } else {
                    Text("This removes the note from your saved memory. If included in private sync, the deletion is sent when sync next succeeds. Encrypted older versions can remain in remote history.")
                }
            }
        }
        .sheet(item: $checklistEditor) { route in
            if let checklist = EditableChecklist.decode(route.note) {
                EditableChecklistView(note: route.note, checklist: checklist, onSave: { goal, step, done in
                    guard checklistEditor?.id == route.id else {
                        throw AppFailure.message("This editor is no longer active. Reopen the checklist.")
                    }
                    try store.saveChecklist(route.note, goal: goal, step: step, done: done,
                                            expectedWorkspaceEpoch: route.workspaceEpoch)
                    checklistEditor = nil
                }, onCancel: {
                    if checklistEditor?.id == route.id { checklistEditor = nil }
                }).id(route.id)
            }
        }
    }
    private var visibleNotes: [MemoryNote] {
        LibraryPresentation.notes(store.saved.notes, project: store.project, query: search)
    }
    private var canRememberNote: Bool {
        !store.loadFailed && !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    private func rememberNote() {
        guard canRememberNote else { return }
        store.remember(note)
        if store.error == nil { note = ""; search = ""; noteFocused = false }
    }
    @ViewBuilder private var memoryMetrics: some View {
        LibraryMetric(value: String(store.saved.notes.filter { $0.project == store.project }.count), title: "Notes", symbol: "note.text")
        LibraryMetric(value: String(store.saved.chats.filter { $0.project == store.project }.count), title: "Messages", symbol: "bubble.left.and.bubble.right")
    }
    private func noteRow(_ memory: MemoryNote) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if let checklist = EditableChecklist.decode(memory) {
                Label(checklist.done ? "Completed checklist" : "Checklist · to do",
                      systemImage: checklist.done ? "checkmark.circle.fill" : "circle")
                    .font(.caption.weight(.semibold)).foregroundStyle(checklist.done ? Color.green : Color.secondary)
                Text(checklist.goal).font(.headline).textSelection(.enabled)
                Text(checklist.step).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                Button {
                    guard !store.loadFailed, checklistEditor == nil else { return }
                    checklistEditor = ChecklistEditorRoute(note: memory, workspaceEpoch: store.workspaceEpoch)
                } label: { Label("Edit checklist", systemImage: "square.and.pencil") }
                .disabled(store.loadFailed).buttonStyle(.borderless)
                .accessibilityIdentifier("checklist.edit." + memory.id.uuidString.lowercased())
                Text("Independent editable copy. Original provenance is available in the editor. Completion does not prove an action ran.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                // Unknown/future envelopes remain ordinary visible notes; never drop them.
                Text(memory.text).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
            ViewThatFits(in: .horizontal) {
                HStack { Text(memory.source); Spacer(); Text(memory.savedAt, style: .date) }
                VStack(alignment: .leading, spacing: 4) { Text(memory.source); Text(memory.savedAt, style: .date) }
            }.font(.caption).foregroundStyle(.secondary)
            HStack {
                ShareLink(item: memory.text) { Label("Export", systemImage: "square.and.arrow.up") }
                Spacer()
                Button("Delete", role: .destructive) { pendingDelete = memory.id }
                    .accessibilityLabel(EditableChecklist.decode(memory).map { "Delete checklist: " + String($0.goal.prefix(80)) }
                        ?? "Delete note: " + String(memory.text.prefix(60)))
            }
            .font(.subheadline).buttonStyle(.borderless).frame(minHeight: 44)
        }
        .padding(.vertical, 6)
        .privacySensitive()
    }
    private struct ChecklistEditorRoute: Identifiable {
        let id = UUID()
        let note: MemoryNote
        let workspaceEpoch: UUID
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
                    Label("Browse saved knowledge", systemImage: "books.vertical")
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
