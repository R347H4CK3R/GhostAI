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

    init(root: URL, scope: KnowledgeScope, onMutation: (() -> Void)? = nil) {
        self.scope = scope
        do {
            cache = try KnowledgeCache(root: root, scope: scope)
            cache?.onMutation = onMutation
            refresh()
        }
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
    @EnvironmentObject private var store: AssistantStore
    @ObservedObject var model: KnowledgeLibraryModel
    /// The full current canonical state. The view never modifies it.
    var savedState: SavedState
    @State private var importing = false
    @State private var pendingDeletion: Deletion?
    @State private var showingConfirmation = false
    @State private var selectedKind: KnowledgeKind?

    private enum Deletion { case entry(String), all, expired }
    private var isSearching: Bool { !model.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var visibleEntries: [KnowledgeEntry] { model.entries.filter { selectedKind == nil || $0.kind == selectedKind } }
    private var visibleHits: [KnowledgeSearchHit] { model.hits.filter { selectedKind == nil || $0.entry.kind == selectedKind } }

    var body: some View {
        List {
            if !isSearching {
                overview
                if let controller = store.memorySync {
                    Section { MemorySyncStatusCard(controller: controller) }
                }
            }
            if let message = model.message {
                Section {
                    Label(message, systemImage: "exclamationmark.circle").font(.footnote).foregroundStyle(.orange)
                        .accessibilityIdentifier("knowledge.status")
                    Button("Dismiss message") { model.dismissMessage() }
                }
            }
            Section {
                Picker("Filter shown items", selection: $selectedKind) {
                    Text("All saved items").tag(Optional<KnowledgeKind>.none)
                    ForEach(KnowledgeKind.allCases, id: \.self) { Text($0.label).tag(Optional($0)) }
                }
                .accessibilityIdentifier("knowledge.filter")
                if isSearching {
                    ForEach(visibleHits) { hit in row(hit.entry, excerpt: hit.excerpt) }
                    if visibleHits.isEmpty {
                        LibraryEmptyState(title: selectedKind == nil ? "No matching saved text" : "No matches in these results",
                            detail: "The filter applies to up to 20 search matches. Try another phrase or choose All saved items. Search only includes this account and project.", symbol: "magnifyingglass")
                    }
                } else {
                    ForEach(visibleEntries) { entry in row(entry, excerpt: String(entry.text.prefix(220))) }
                    if visibleEntries.isEmpty {
                        LibraryEmptyState(title: selectedKind == nil ? "Your knowledge starts here" : "No items of this type in this view",
                            detail: selectedKind == nil
                                ? "Conversations, app actions and research can be captured below. You can also import a text file."
                                : "This view shows up to 500 recent saved items. Search to find older text, or choose All saved items.", symbol: "books.vertical")
                    }
                }
            } header: { Text(isSearching ? "Search results · up to 20 matches" : "Saved knowledge · up to 500 items") }
            captureSection
            Section("Add a source") {
                Button { importing = true } label: { Label("Import selected text file", systemImage: "doc.badge.plus") }
                    .accessibilityIdentifier("knowledge.import")
                Text("Choose one UTF-8 text file up to 256 KiB. Only that copy is saved; there is no ongoing file or folder access.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Do not import credentials or highly sensitive documents. Secret checks are not a guarantee.")
                    .font(.caption).foregroundStyle(.secondary)
                DisclosureGroup("What is saved and how it is protected") {
                    Text("The filename, content fingerprint, import date and text are retained, not the file’s full location. Local device protection is separate from encrypted private sync.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }.disabled(model.unavailable)
            storageSection
            retentionSection
        }
        .listStyle(.insetGrouped)
        .contentMargins(.bottom, 32, for: .scrollContent)
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle("Knowledge")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $model.query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search saved text offline")
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
            Text("This removes saved copies from this account and project. Original notes, chat history and selected files are unchanged. Deletion markers prevent reindexing. If included in private sync, deletions are sent when sync next succeeds; encrypted older versions can remain in remote history. This cannot be undone in the library.")
        }
    }
    private var overview: some View {
        Section {
            LibraryOverview(eyebrow: "SAVED KNOWLEDGE", title: WorkspaceDisplay(model.scope.project).title,
                subtitle: WorkspaceDisplay(model.scope.project).subtitle, symbol: "books.vertical")
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 20) { coverageMetrics }
                VStack(alignment: .leading, spacing: 16) { coverageMetrics }
            }.padding(.vertical, 4)
            Label(model.unavailable ? "Library unavailable · existing data preserved" : "Ready to search offline",
                  systemImage: model.unavailable ? "exclamationmark.lock" : "checkmark.circle")
                .font(.subheadline).foregroundStyle(model.unavailable ? .orange : .cyan)
            Text("Saved copies for this account and project. They may be older than the original source.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
    @ViewBuilder private var coverageMetrics: some View {
        LibraryMetric(value: String(model.coverage?.entries ?? 0), title: "Saved items", symbol: "square.stack")
        LibraryMetric(value: bytes(model.coverage?.sourceBytes ?? 0), title: "Source text", symbol: "internaldrive")
    }
    private var captureSection: some View {
        Section {
            DisclosureGroup {
                captureToggle("Saved and future conversations", \.captureConversations)
                captureToggle("App action summaries", \.captureActions)
                captureToggle("Sources read for research", \.captureResearch)
                Text("Conversations include this app’s saved user and assistant messages. Actions keep only a fixed type, status and time. Research keeps successful source text read by this app, not provider errors or headers. Capture does not read other apps, listen in the background, scan folders or crawl the web. Turning a switch off keeps existing copies until you delete them.")
                    .font(.caption).foregroundStyle(.secondary)
            } label: {
                VStack(alignment: .leading, spacing: 5) {
                    Label("Automatic capture", systemImage: "sparkles").font(.headline)
                    Text(captureState).font(.caption).foregroundStyle(.secondary)
                }.padding(.vertical, 4)
            }
            .accessibilityIdentifier("knowledge.capture")
            if model.coverage?.captureIsFull == true {
                Label("Storage full. New captures are paused until you delete items. Nothing was evicted.", systemImage: "exclamationmark.circle")
                    .font(.footnote).foregroundStyle(.orange)
            }
        }.disabled(model.unavailable)
    }
    private var storageSection: some View {
        Section {
            DisclosureGroup("Storage and coverage") {
                if let coverage = model.coverage {
                    ForEach(KnowledgeKind.allCases, id: \.self) { kind in
                        LabeledContent(kind.label, value: String(coverage.counts[kind, default: 0]))
                    }
                    Text("Source text: \(bytes(coverage.sourceBytes)) / \(bytes(coverage.maximumSourceBytes)). Search indexes and deletion markers also need space, so capture may pause earlier.")
                        .font(.footnote).foregroundStyle(.secondary)
                    Text("This library: \(bytes(coverage.databaseBytes)). All accounts/projects: \(bytes(coverage.totalDatabaseBytes)) / \(bytes(coverage.maximumBytes)).")
                        .font(.footnote).foregroundStyle(.secondary)
                    if coverage.lastCapture.rejected > 0 { Text("Last conversation index: \(coverage.lastCapture.rejected) unsafe or unsupported messages skipped.").font(.footnote) }
                    if coverage.lastCapture.suppressed > 0 { Text("\(coverage.lastCapture.suppressed) previously deleted messages were not restored.").font(.footnote) }
                    Text("\(coverage.suppressedSources) deletion markers retained to prevent reindexing deleted sources.").font(.footnote).foregroundStyle(.secondary)
                }
                Text("Intentional notes remain in Memory. Only saved text is searchable offline. Refresh a source through its normal read flow or select the updated file again. Source refresh creates a new saved version; online backup does not keep original sources up to date.")
                    .font(.footnote).foregroundStyle(.secondary)
                Text("Manual chat/note exports exclude this library. Check private sync status for online coverage before removing the app or changing devices.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
    }
    private var retentionSection: some View {
        Section {
            DisclosureGroup("Retention and deletion") {
                Picker("Review automatic captures", selection: Binding(get: { model.settings.retention }, set: { value in
                    var next = model.settings; next.retention = value; model.updateSettings(next, savedState: savedState)
                })) {
                    ForEach(KnowledgeRetention.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                Text("Retention marks old automatic captures for review. Nothing is deleted automatically. Imported files remain until you delete them.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Delete \(model.expiredCount) old automatic items…", role: .destructive) { requestDeletion(.expired) }
                    .disabled(model.expiredCount == 0)
                Button("Clear this library…", role: .destructive) { requestDeletion(.all) }
                    .disabled(model.coverage?.entries == 0)
                    .accessibilityIdentifier("knowledge.clear")
            }
        }.disabled(model.unavailable)
    }
    private var captureState: String {
        let count = [model.settings.captureConversations, model.settings.captureActions, model.settings.captureResearch].filter { $0 }.count
        return count == 0 ? "Off · existing copies stay available" : "\(count) of 3 types enabled · saves while you use the app"
    }
    private func captureToggle(_ title: String, _ keyPath: WritableKeyPath<KnowledgeSettings, Bool>) -> some View {
        Toggle(title, isOn: Binding(get: { model.settings[keyPath: keyPath] }, set: { value in
            var next = model.settings; next[keyPath: keyPath] = value; model.updateSettings(next, savedState: savedState)
        }))
    }
    private func bytes(_ value: Int) -> String { ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .binary) }
    private func requestDeletion(_ deletion: Deletion) { pendingDeletion = deletion; showingConfirmation = true }
    private func row(_ entry: KnowledgeEntry, excerpt: String) -> some View {
        NavigationLink { KnowledgeEntryDetailView(model: model, entry: entry) } label: {
            VStack(alignment: .leading, spacing: 8) {
                Text(entry.source.label).font(.headline).lineLimit(3)
                Text(excerpt).font(.subheadline).foregroundStyle(.secondary).lineLimit(3)
                Text("\(entry.kind.label) · \(entry.sourceDate.formatted(date: .abbreviated, time: .omitted)) · \(bytes(entry.byteCount))")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }.padding(.vertical, 6)
        }
        .privacySensitive()
        .swipeActions { Button("Delete", role: .destructive) { requestDeletion(.entry(entry.id)) } }
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
        } message: { Text("The original source is unchanged. This copy cannot be restored by reindexing. If included in private sync, deletion is sent when sync next succeeds; encrypted older versions can remain in remote history.") }
        .onChange(of: model.unavailable) { _, unavailable in if unavailable { dismiss() } }
    }
}
