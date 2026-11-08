import SwiftUI
import UniformTypeIdentifiers

/// Keep one model for the active account/project and invalidate it before changing either.
@MainActor final class KnowledgeLibraryModel: ObservableObject {
    let scope: KnowledgeScope
    @Published private(set) var settings = KnowledgeSettings()
    @Published private(set) var coverage: KnowledgeCoverage?
    @Published private(set) var entries: [KnowledgeEntry] = []
    @Published private(set) var hits: [KnowledgeSearchHit] = []
    @Published private(set) var expiredCount = 0
    @Published private(set) var unavailable = false
    @Published private(set) var message: String?
    @Published var query = ""
    private var cache: KnowledgeCache?
    private var active = true

    init(root: URL, scope: KnowledgeScope) {
        self.scope = scope
        do { cache = try KnowledgeCache(root: root, scope: scope); refresh() }
        catch { unavailable = true; message = safeMessage(error) }
    }
    func invalidate() {
        active = false; cache = nil; entries = []; hits = []; coverage = nil; unavailable = true
        message = "Account or project changed. Open the library for the current selection."
    }
    func refresh() {
        perform { cache in
            settings = cache.settings; coverage = try cache.coverage(); entries = try cache.entries()
            hits = try cache.search(query); expiredCount = try cache.expiredAutomaticCount()
        }
    }
    func updateSettings(_ value: KnowledgeSettings, savedState: SavedState) {
        perform { cache in
            try cache.updateSettings(value)
            // Enabling conversation capture immediately indexes eligible saved messages.
            _ = try cache.captureSavedState(savedState)
        }
        refresh()
    }
    /// Invoke after every successful canonical save, including deletions and backup imports.
    /// Do not pass a partially loaded, filtered or failed-to-load canonical snapshot.
    func captureSavedState(_ state: SavedState) {
        perform { _ = try $0.captureSavedState(state) }; refresh()
    }
    func captureAction(id: UUID = UUID(), kind: KnowledgeActionKind, status: KnowledgeActionStatus,
                       expectedScope: KnowledgeScope, date: Date = Date()) {
        guard active, scope == expectedScope else { return }
        perform { try $0.captureAction(id: id, kind: kind, status: status, date: date) }; refresh()
    }
    func captureResearch(text: String, source: KnowledgeSource,
                         expectedScope: KnowledgeScope, date: Date = Date()) {
        guard active, scope == expectedScope else { return }
        perform { try $0.captureResearch(text: text, source: source, date: date) }; refresh()
    }
    /// A bounded snapshot for the model prompt. Always label this untrusted, stale reference
    /// data. Local search works even when language generation or the network is unavailable.
    func context(query: String, maximumCharacters: Int = 3_000) -> String {
        guard active, let cache else { return "" }
        do { return try cache.context(query: query, maximumCharacters: maximumCharacters) }
        catch { handle(error); return "" }
    }
    @discardableResult func delete(_ id: String) -> Bool { let success = perform { try $0.delete(id: id) }; refresh(); return success }
    func search() { perform { hits = try $0.search(query) } }
    func clear() { perform { try $0.clear() }; refresh() }
    func deleteExpired() { perform { try $0.deleteExpiredAutomaticEntries() }; refresh() }

    /// Called only with a URL returned by this view's system document picker.
    func importSelectedDocument(_ url: URL) {
        guard active, !unavailable else { return }
        guard url.startAccessingSecurityScopedResource() else { message = KnowledgeFailure.unavailable.localizedDescription; return }
        defer { url.stopAccessingSecurityScopedResource() }
        do {
            try KnowledgePolicy.validateFilename(url.lastPathComponent)
            var coordinationError: NSError?
            var outcome: Result<Data, Error> = .failure(KnowledgeFailure.unavailable)
            NSFileCoordinator().coordinate(readingItemAt: url, options: .withoutChanges, error: &coordinationError) { selected in
                outcome = Result {
                    try KnowledgeSelectedFileReader.read(selected)
                }
            }
            guard coordinationError == nil else { throw KnowledgeFailure.unavailable }
            let bytes = try outcome.get()
            perform { try $0.importText(bytes, filename: url.lastPathComponent) }
            refresh()
        } catch { message = safeMessage(error) }
    }
    func dismissMessage() { message = nil }
    func reportImportFailure(_ error: Error) {
        if (error as NSError).code != NSUserCancelledError { message = KnowledgeFailure.unavailable.localizedDescription }
    }
    private func handle(_ error: Error) {
        message = safeMessage(error)
        if error as? KnowledgeFailure == .corrupt {
            unavailable = true; cache = nil; entries = []; hits = []; coverage = nil
        }
    }
    @discardableResult private func perform(_ body: (KnowledgeCache) throws -> Void) -> Bool {
        guard active, let cache else { return false }
        do { try body(cache); return true }
        catch {
            handle(error)
            return false
        }
    }
    private func safeMessage(_ error: Error) -> String {
        (error as? KnowledgeFailure ?? .unavailable).localizedDescription
    }
}

struct KnowledgeLibraryView: View {
    @ObservedObject var model: KnowledgeLibraryModel
    /// The full current canonical state. The view never modifies it.
    var savedState: SavedState
    @State private var importing = false
    @State private var pendingDeletion: Deletion?
    @State private var showingConfirmation = false

    private enum Deletion { case entry(String), all, expired }
    var body: some View {
        List {
            Section("This account and project only") {
                Text(model.scope.project).font(.headline)
                Text("Offline knowledge is stored only on this device, separately from your notes and chat history. It is not a complete sync or a backup. Chat/note backups do not include this library. Uninstalling the app or moving devices loses these copies unless you recreate them; cache export is not available yet.")
                    .font(.footnote).foregroundStyle(.secondary)
                Label(model.unavailable ? "Library unavailable" : "Search works without cell service", systemImage: model.unavailable ? "exclamationmark.lock" : "wifi.slash")
                if let message = model.message {
                    Text(message).font(.footnote).foregroundStyle(.orange).accessibilityIdentifier("knowledge.status")
                    Button("Dismiss message") { model.dismissMessage() }
                }
            }
            Section {
                captureToggle("Saved and future conversations", \.captureConversations)
                captureToggle("App action summaries", \.captureActions)
                captureToggle("Sources read for research", \.captureResearch)
            } header: { Text("Automatic capture · \(captureState)") }
            footer: {
                Text("Off by default. Enable only what you want remembered. Conversations include user and assistant messages saved by this app. Actions store only a fixed type, status and time. Research stores successful source text supplied by this app, not provider errors or headers. No other apps, microphone background listening, browser history, folder scanning or automatic web crawling. Turning a switch off keeps existing copies until you delete them.")
            }
            .disabled(model.unavailable)
            Section("Coverage") {
                if let coverage = model.coverage {
                    Text("\(coverage.entries) saved items · \(bytes(coverage.sourceBytes)) of source text")
                    Text("Source-text limit: \(bytes(coverage.maximumSourceBytes)). Search indexes and deletion markers also need space, so capture may pause earlier.").font(.footnote).foregroundStyle(.secondary)
                    Text("This library: \(bytes(coverage.databaseBytes)). All accounts/projects: \(bytes(coverage.totalDatabaseBytes)) / \(bytes(coverage.maximumBytes)).")
                        .font(.footnote).foregroundStyle(.secondary)
                    ForEach(KnowledgeKind.allCases, id: \.self) { kind in
                        LabeledContent(kind.label, value: String(coverage.counts[kind, default: 0]))
                    }
                    if coverage.captureIsFull { Text("Full. New captures are paused until you delete items. Nothing was evicted.").foregroundStyle(.orange) }
                    if coverage.lastCapture.rejected > 0 { Text("Last conversation index: \(coverage.lastCapture.rejected) unsafe or unsupported messages skipped.").font(.footnote) }
                    if coverage.lastCapture.suppressed > 0 { Text("\(coverage.lastCapture.suppressed) previously deleted messages were not restored.").font(.footnote) }
                    Text("\(coverage.suppressedSources) deletion markers retained to prevent reindexing deleted sources.").font(.footnote).foregroundStyle(.secondary)
                }
                Text("Intentional notes remain in Memory and are not duplicated here. Only captured text is available offline. These copies may be stale; refresh a source through its normal read flow or select the updated file again. Refreshing creates a new version, never a claim of live synchronization.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section {
                Button { importing = true } label: { Label("Import selected text file", systemImage: "doc.badge.plus") }
                    .accessibilityIdentifier("knowledge.import")
                Text("One UTF-8 document up to 256 KiB. The filename, content fingerprint, import date and text are retained, not the file's full location. No folder or future file access is saved.")
                    .font(.footnote).foregroundStyle(.secondary)
                Text("Secret detection is a warning layer, not a guarantee. Do not import credentials or highly sensitive documents. Device file protection applies while locked; this is not a separate encrypted vault or cross-device backup.")
                    .font(.footnote).foregroundStyle(.secondary)
            }.disabled(model.unavailable)
            Section("Retention and deletion") {
                Picker("Automatic capture retention", selection: Binding(get: { model.settings.retention }, set: { value in
                    var next = model.settings; next.retention = value; model.updateSettings(next, savedState: savedState)
                })) {
                    ForEach(KnowledgeRetention.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                Text("Retention marks old automatic captures for your review. Nothing is deleted automatically. Imported files always remain until you delete them.")
                    .font(.footnote).foregroundStyle(.secondary)
                Button("Delete \(model.expiredCount) old automatic items…", role: .destructive) { requestDeletion(.expired) }
                    .disabled(model.expiredCount == 0)
                Button("Clear this library…", role: .destructive) { requestDeletion(.all) }
                    .disabled(model.coverage?.entries == 0)
                    .accessibilityIdentifier("knowledge.clear")
            }.disabled(model.unavailable)
            Section(model.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Saved copies (up to 500)" : "Search results (up to 20)") {
                if model.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    ForEach(model.entries) { entry in row(entry, excerpt: String(entry.text.prefix(220))) }
                    if model.entries.isEmpty { Text("No cached items. Enable capture or import a selected document.").foregroundStyle(.secondary) }
                } else {
                    ForEach(model.hits) { hit in row(hit.entry, excerpt: hit.excerpt) }
                    if model.hits.isEmpty { Text("No matching saved text in this account and project.").foregroundStyle(.secondary) }
                }
            }
        }
        .navigationTitle("Offline knowledge")
        .searchable(text: $model.query, prompt: "Search saved text offline")
        .onChange(of: model.query) { _, _ in model.search() }
        .onAppear { model.refresh() }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.text, .sourceCode, .json, .commaSeparatedText], allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls): if let url = urls.first { model.importSelectedDocument(url) }
            case .failure(let error): model.reportImportFailure(error)
            }
        }
        .confirmationDialog("Delete cached knowledge?", isPresented: $showingConfirmation, titleVisibility: .visible) {
            Button("Delete cached copies", role: .destructive) {
                switch pendingDeletion { case .entry(let id): model.delete(id); case .all: model.clear(); case .expired: model.deleteExpired(); case nil: break }
                pendingDeletion = nil
            }
            Button("Cancel", role: .cancel) { pendingDeletion = nil }
        } message: {
            Text("This removes cached copies from this account and project only. Original notes, chat history and selected files are unchanged. Deletion markers prevent the same sources from returning during reindexing. This cannot be undone in the library.")
        }
    }
    private var captureState: String {
        let count = [model.settings.captureConversations, model.settings.captureActions, model.settings.captureResearch].filter { $0 }.count
        return count == 0 ? "off" : "\(count) of 3 enabled"
    }
    private func captureToggle(_ title: String, _ keyPath: WritableKeyPath<KnowledgeSettings, Bool>) -> some View {
        Toggle(title, isOn: Binding(get: { model.settings[keyPath: keyPath] }, set: { value in
            var next = model.settings; next[keyPath: keyPath] = value; model.updateSettings(next, savedState: savedState)
        }))
    }
    private func bytes(_ value: Int) -> String { ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .binary) }
    private func requestDeletion(_ deletion: Deletion) { pendingDeletion = deletion; showingConfirmation = true }
    private func row(_ entry: KnowledgeEntry, excerpt: String) -> some View {
        NavigationLink {
            KnowledgeEntryDetailView(model: model, entry: entry)
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                Text(entry.source.label).font(.subheadline).lineLimit(2)
                Text(excerpt).font(.footnote).lineLimit(4)
                Text("\(entry.kind.label) · \(entry.sourceDate.formatted(date: .abbreviated, time: .omitted)) · \(bytes(entry.byteCount)) · offline")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.swipeActions { Button("Delete", role: .destructive) { requestDeletion(.entry(entry.id)) } }
    }
}


private struct KnowledgeEntryDetailView: View {
    @ObservedObject var model: KnowledgeLibraryModel
    let entry: KnowledgeEntry
    @Environment(\.dismiss) private var dismiss
    @State private var confirming = false
    var body: some View {
        List {
            Section("Provenance") {
                Text(entry.kind.label); Text(entry.source.label).textSelection(.enabled)
                LabeledContent("Source date", value: entry.sourceDate.formatted())
                LabeledContent("Cached", value: entry.cachedAt.formatted())
                LabeledContent("Source bytes", value: ByteCountFormatter.string(fromByteCount: Int64(entry.byteCount), countStyle: .binary))
                if let revision = entry.source.revision { Text("Revision / fingerprint: \(revision)").font(.caption).textSelection(.enabled) }
                Text(entry.offlineStatus).font(.footnote).foregroundStyle(.secondary)
            }
            Section("Saved reference text") { Text(entry.text).textSelection(.enabled) }
            Section {
                if let message = model.message { Text(message).foregroundStyle(.orange).font(.footnote) }
                Button("Delete this cached copy…", role: .destructive) { confirming = true }
            }
        }
        .navigationTitle(entry.kind.label)
        .confirmationDialog("Delete this cached copy?", isPresented: $confirming, titleVisibility: .visible) {
            Button("Delete cached copy", role: .destructive) { if model.delete(entry.id) { dismiss() } }
            Button("Cancel", role: .cancel) { }
        } message: { Text("The original source is unchanged. This cached copy cannot be restored by reindexing.") }
        .onChange(of: model.unavailable) { _, unavailable in if unavailable { dismiss() } }
    }
}
