import SwiftUI
import UniformTypeIdentifiers

struct EncryptedMemoryDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.data] }
    let data: Data

    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents,
              data.count <= EncryptedMemoryTransfer.maximumFileBytes else {
            throw EncryptedMemoryTransfer.Failure.fileSize
        }
        self.data = data
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        guard data.count <= EncryptedMemoryTransfer.maximumFileBytes else {
            throw EncryptedMemoryTransfer.Failure.fileSize
        }
        return FileWrapper(regularFileWithContents: data)
    }
}

/// Present as a sheet. Both closures run on the main actor, and import is called
/// only after authentication, complete validation, and the user's final review.
@MainActor struct EncryptedTransferView: View {
    let backupData: () throws -> Data
    let importBackup: (Data) throws -> Void
    var isRestoring = false

    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var format: EncryptedMemoryTransfer.Format = .mobileBackup
    @State private var exportPassphrase = ""
    @State private var repeatedPassphrase = ""
    @State private var importPassphrase = ""
    @State private var selectedData: Data?
    @State private var selectedName = ""
    @State private var pendingImport: ImportPreview?
    @State private var document: EncryptedMemoryDocument?
    @State private var exporting = false
    @State private var importing = false
    @State private var confirmingExport = false
    @State private var working = false
    @State private var message: String?
    @State private var operation: Task<Void, Never>?
    @State private var generation = UUID()

    private struct ImportPreview: Identifiable {
        let id = UUID()
        let result: EncryptedMemoryTransfer.Decoded
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Move memory yourself using encrypted files. The app does not run automatic sync or use a transfer server.")
                    Text("Files may upload through a storage provider you choose. For offline transfer, choose On My iPhone or another local destination. Keep the passphrase separately; forgotten passphrases cannot be recovered.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Export all projects") {
                    Picker("Contents", selection: $format) {
                        ForEach(EncryptedMemoryTransfer.Format.allCases) { option in
                            Text(option.title).tag(option)
                        }
                    }
                    Text(format == .mobileBackup
                         ? "Includes every saved note and chat. Open this format on another compatible iPhone or iPad."
                         : "Includes every saved note, with its project and source. Chats are excluded. Open this format with the desktop companion.")
                        .font(.caption)
                    SecureField("New passphrase (12+ characters)", text: $exportPassphrase)
                        .textContentType(.newPassword).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .accessibilityIdentifier("encryptedExportPassphrase")
                    SecureField("Repeat passphrase", text: $repeatedPassphrase)
                        .textContentType(.newPassword).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .accessibilityIdentifier("encryptedExportRepeat")
                    Button("Review encrypted export") { confirmingExport = true }
                        .disabled(working || exportPassphrase.count < 12 || exportPassphrase != repeatedPassphrase)
                        .accessibilityIdentifier("encryptedExportReview")
                }.disabled(working)
                Section("Import encrypted memory") {
                    Button(selectedData == nil ? "Choose encrypted file" : "Choose a different file") { importing = true }
                        .accessibilityIdentifier("encryptedImportChoose")
                    if selectedData != nil {
                        Text(selectedName).font(.caption).lineLimit(2)
                        SecureField("File passphrase", text: $importPassphrase)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .accessibilityIdentifier("encryptedImportPassphrase")
                        Button("Unlock and review") { unlockImport() }
                            .disabled(importPassphrase.isEmpty)
                            .accessibilityIdentifier("encryptedImportUnlock")
                    }
                    Text("Unlocking only prepares a preview. You confirm before local memory changes. A desktop notes file never adds chats. Unsupported records cause the whole import to be rejected.")
                        .font(.caption)
                }.disabled(working)
                if working {
                    Section {
                        ProgressView("Preparing transfer…")
                        Button("Cancel preparation", role: .cancel) { clearTransientState() }
                    }
                }
            }
            .navigationTitle("Encrypted transfer")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { clearTransientState(); dismiss() } } }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.data]) { result in chooseFile(result) }
            .fileExporter(isPresented: $exporting, document: document, contentType: .data,
                          defaultFilename: format == .mobileBackup ? "AsterionVeyra-mobile.veyra" : "AsterionVeyra-notes.veyra") { result in
                document = nil
                if case .failure = result { message = "The encrypted file was not exported. Choose a destination and try again." }
            }
            .alert("Export encrypted memory?", isPresented: $confirmingExport) {
                Button("Create encrypted file") { prepareExport() }
                Button("Cancel", role: .cancel) { clearPassphrases() }
            } message: {
                Text(format == .mobileBackup
                     ? "This file will contain notes and chats from ALL projects. Anyone with the file and passphrase can read them. You choose where to save it next."
                     : "This file will contain notes from ALL projects, but NO chats. Anyone with the file and passphrase can read them. You choose where to save it next.")
            }
            .alert(isRestoring ? "Restore verified memory?" : "Merge verified memory?",
                   isPresented: Binding(get: { pendingImport != nil }, set: { if !$0 { pendingImport = nil } }),
                   presenting: pendingImport) { preview in
                Button(isRestoring ? "Restore memory" : "Merge memory") { commitImport(preview.result) }
                Button("Cancel", role: .cancel) { pendingImport = nil }
            } message: { preview in
                Text(importReview(preview.result))
            }
            .alert("Encrypted transfer", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
                Button("OK", role: .cancel) { message = nil }
            } message: { Text(message ?? "") }
            .onDisappear { clearTransientState() }
            .onChange(of: scenePhase) { _, phase in
                if phase == .background { clearTransientState() }
            }
        }
    }

    private func prepareExport() {
        guard exportPassphrase == repeatedPassphrase else {
            clearPassphrases(); message = "The passphrases did not match."; return
        }
        let passphrase = exportPassphrase
        clearPassphrases()
        do {
            let raw = try backupData()
            let selectedFormat = format
            let id = beginOperation()
            operation = Task {
                do {
                    // The expensive KDF does not block SwiftUI's main actor.
                    let encrypted = try await Task.detached(priority: .userInitiated) {
                        try EncryptedMemoryTransfer.encrypt(backupData: raw, passphrase: passphrase, format: selectedFormat)
                    }.value
                    try Task.checkCancellation()
                    guard generation == id else { return }
                    document = EncryptedMemoryDocument(data: encrypted)
                    exporting = true
                } catch is CancellationError {
                    // A dismissed or backgrounded view must not present a late export.
                } catch {
                    if generation == id { message = error.localizedDescription }
                }
                finishOperation(id)
            }
        } catch { message = error.localizedDescription }
    }

    private func chooseFile(_ result: Result<URL, Error>) {
        selectedData = nil; selectedName = ""; importPassphrase = ""; pendingImport = nil
        do {
            let url = try result.get()
            let id = beginOperation()
            operation = Task {
                do {
                    // File providers can hydrate remotely. Never block SwiftUI while waiting.
                    let reader = Task.detached(priority: .userInitiated) { try Self.readSelectedFile(url) }
                    let data = try await withTaskCancellationHandler(operation: {
                        try await reader.value
                    }, onCancel: { reader.cancel() })
                    try Task.checkCancellation()
                    guard generation == id else { return }
                    selectedData = data
                    selectedName = url.lastPathComponent
                } catch is CancellationError {
                } catch {
                    if generation == id { message = error.localizedDescription }
                }
                finishOperation(id)
            }
        } catch {
            let nsError = error as NSError
            if nsError.domain != NSCocoaErrorDomain || nsError.code != CocoaError.userCancelled.rawValue {
                message = error.localizedDescription
            }
        }
    }

    nonisolated private static func readSelectedFile(_ url: URL) throws -> Data {
        try Task.checkCancellation()
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        var coordinationError: NSError?
        var readResult: Result<Data, Error>?
        NSFileCoordinator().coordinate(readingItemAt: url, options: .withoutChanges, error: &coordinationError) { coordinated in
            readResult = Result {
                try Task.checkCancellation()
                return try EncryptedMemoryTransfer.readFile(at: coordinated)
            }
        }
        try Task.checkCancellation()
        if let coordinationError { throw coordinationError }
        guard let readResult else { throw EncryptedMemoryTransfer.Failure.file }
        return try readResult.get()
    }

    private func unlockImport() {
        guard let encrypted = selectedData else { return }
        let passphrase = importPassphrase
        clearPassphrases()
        let id = beginOperation()
        operation = Task {
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try EncryptedMemoryTransfer.decrypt(encrypted, passphrase: passphrase)
                }.value
                try Task.checkCancellation()
                guard generation == id else { return }
                selectedData = nil; selectedName = ""
                pendingImport = ImportPreview(result: result)
            } catch is CancellationError {
            } catch {
                if generation == id { message = error.localizedDescription }
            }
            finishOperation(id)
        }
    }

    private func commitImport(_ result: EncryptedMemoryTransfer.Decoded) {
        pendingImport = nil
        do {
            try importBackup(result.backupData)
            message = "Verified memory imported. No automatic sync was enabled."
        } catch { message = error.localizedDescription }
    }

    private func importReview(_ result: EncryptedMemoryTransfer.Decoded) -> String {
        let counts = "\(result.noteCount) notes and \(result.chatCount) chats. "
        let source = result.format == .desktopNotes ? "Desktop notes file; no chats are included. " : "Full mobile backup. "
        let effect = isRestoring
            ? "The unreadable local file will be preserved separately before restoration."
            : "Existing records stay unchanged. Records with an existing ID are skipped; this is not a two-way sync."
        return counts + source + effect
    }

    private func beginOperation() -> UUID {
        operation?.cancel()
        let id = UUID(); generation = id; working = true
        return id
    }
    private func finishOperation(_ id: UUID) {
        if generation == id { working = false; operation = nil }
    }
    private func clearPassphrases() {
        exportPassphrase = ""; repeatedPassphrase = ""; importPassphrase = ""
    }
    private func clearTransientState() {
        operation?.cancel(); operation = nil; generation = UUID(); working = false
        clearPassphrases()
        selectedData = nil; selectedName = ""; pendingImport = nil
        document = nil; exporting = false; importing = false; confirmingExport = false
    }
}
