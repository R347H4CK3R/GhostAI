import SwiftUI
import UniformTypeIdentifiers

/// Owns no AssistantStore, repository client, memory file or persistent credential store.
@MainActor final class HostedAssistantController: ObservableObject {
    @Published private(set) var connected = false
    @Published private(set) var working = false
    @Published private(set) var preview: HostedConsent?
    @Published private(set) var answer = ""
    @Published private(set) var answeredModel = ""
    @Published var message: String?
    private var session: HostedAuthSession?
    private let client: HostedResponsesClient
    private var operation: Task<Void, Never>?
    private var expiry: Task<Void, Never>?
    private var generation = UUID()

    init(client: HostedResponsesClient = HostedResponsesClient()) { self.client = client }
    deinit { operation?.cancel(); expiry?.cancel(); session?.revoke() }

    func begin(token: String, directlyInstalled: Bool) throws {
        endSession()
        let auth = try HostedAuthSession(token: token, directlyInstalled: directlyInstalled)
        session = auth; connected = true; message = nil
        expiry = Task { [weak self] in
            let remaining = max(0, auth.expiresAt.timeIntervalSinceNow)
            try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
            guard !Task.isCancelled, self?.session?.id == auth.id else { return }
            self?.endSession()
            self?.message = "The 30-minute memory-only session ended."
        }
    }
    func review(question: String, context: String, model: String) throws {
        guard !working, let session else { throw HostedFailure.expired }
        invalidateReview()
        preview = try session.prepare(question: question, context: context, model: model)
        message = nil
    }
    func invalidateReview() { preview = nil; session?.cancelPreview() }

    func send(_ consent: HostedConsent) {
        guard !working, let auth = session, preview?.id == consent.id, consent.sessionID == auth.id else {
            message = HostedFailure.invalidConsent.localizedDescription; return
        }
        preview = nil; working = true; answer = ""; answeredModel = ""; message = nil
        let attempt = UUID(); generation = attempt
        operation = Task { [weak self, client] in
            do {
                let text = try await client.answer(consent: consent, session: auth)
                try Task.checkCancellation()
                try auth.validate()
                guard let self, self.generation == attempt, self.session?.id == auth.id else { return }
                self.answer = text; self.answeredModel = consent.model
            } catch {
                guard let self, self.generation == attempt else { return }
                if !(error is CancellationError) { self.message = HostedRequestPolicy.safeError(error).localizedDescription }
                if (error as? HostedFailure) == .expired { self.endSession() }
            }
            guard let self, self.generation == attempt else { return }
            self.working = false; self.operation = nil
        }
    }
    func cancelRequest() {
        generation = UUID(); operation?.cancel(); operation = nil
        working = false; answer = ""; answeredModel = ""; invalidateReview()
    }
    func endSession() {
        cancelRequest(); expiry?.cancel(); expiry = nil
        session?.revoke(); session = nil; connected = false
    }
}

struct HostedTextDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.plainText] }
    let text: String
    init(text: String) { self.text = text }
    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents,
              data.count <= HostedRequestPolicy.maximumOutputBytes,
              let value = String(data: data, encoding: .utf8) else { throw HostedFailure.oversized }
        text = value
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        guard text.utf8.count <= HostedRequestPolicy.maximumOutputBytes else { throw HostedFailure.oversized }
        return FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}

/// Standalone tab or sheet: HostedAssistantView(). No app/store injection and no offline-path changes.
@MainActor struct HostedAssistantView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var controller = HostedAssistantController()
    @State private var token = ""
    @State private var directlyInstalled = false
    @State private var model = ""
    @State private var question = ""
    @State private var context = ""
    @State private var exporting = false
    @State private var exportDocument: HostedTextDocument?

    var body: some View {
        NavigationStack {
            Form {
                Section("Optional online text") {
                    Text("This screen sends only the question and context you review to OpenAI. It does not read saved memory, repository files, local conversations or voice sessions.")
                    Text("Requires your own existing API account, API key and model access. API usage is metered under your API account. Do not assume your ChatGPT subscription covers it. No account, key or paid plan is created here.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if controller.connected { connectedSession } else { sessionEntry }
                Section("Prepare a request") {
                    TextField("Model ID available to your API account", text: $model)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .accessibilityIdentifier("hosted-model")
                    Text("No model is selected automatically. Compatibility and availability depend on your account. This client supports Responses text models only.")
                        .font(.caption).foregroundStyle(.secondary)
                    TextField("Question", text: $question, axis: .vertical).lineLimit(3...8)
                        .privacySensitive().accessibilityIdentifier("hosted-question")
                    Text("Question: \(question.utf8.count) / 8,000 bytes").font(.caption)
                    TextField("Optional context you paste yourself", text: $context, axis: .vertical).lineLimit(4...12)
                        .privacySensitive().accessibilityIdentifier("hosted-context")
                    Text("Context: \(context.utf8.count) / 24,000 bytes. Remove credentials and private information you do not want OpenAI to receive. Secret detection is only a heuristic.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Review exact request") { review() }
                        .disabled(!controller.connected || question.isEmpty || model.isEmpty)
                        .accessibilityIdentifier("hosted-review")
                }.disabled(controller.working || controller.preview != nil)
                if controller.working {
                    Section {
                        ProgressView("Receiving bounded text response…")
                        Button("Cancel request", role: .cancel) {
                            controller.cancelRequest()
                            controller.message = "Cancelled locally. A request already received by OpenAI may still incur charges."
                        }.accessibilityIdentifier("hosted-cancel-request")
                    }
                }
                if !controller.answer.isEmpty {
                    Section("Answer · \(controller.answeredModel)") {
                        Text(verbatim: controller.answer).textSelection(.enabled).privacySensitive()
                            .accessibilityIdentifier("hosted-answer")
                        Text("AI output can be wrong. Suggestions and commands are inert text and are never run. This answer is not saved to your memory or chat history.")
                            .font(.caption).foregroundStyle(.secondary)
                        Button("Export answer as text") {
                            exportDocument = HostedTextDocument(text: controller.answer)
                            exporting = true
                        }.accessibilityIdentifier("hosted-export")
                        Text("Export contains only this answer. The file provider you select may upload it. Choose a local destination to keep it on this device.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let message = controller.message {
                    Section("Status") { Text(message).accessibilityIdentifier("hosted-status") }
                }
            }
            .navigationTitle("Hosted assistant")
            .sheet(item: Binding(get: { controller.preview }, set: { value in
                if value == nil, controller.preview != nil { controller.invalidateReview() }
            })) { consent in
                HostedConsentReview(consent: consent,
                    onSend: { controller.send(consent) }, onCancel: { controller.invalidateReview() })
                    .interactiveDismissDisabled()
            }
            .fileExporter(isPresented: $exporting, document: exportDocument, contentType: .plainText,
                          defaultFilename: "AsterionVeyra-hosted-answer") { result in
                exportDocument = nil
                if case .failure = result { controller.message = "The answer was not exported. Choose a destination and try again." }
            }
        }
        .onChange(of: model) { _, _ in controller.invalidateReview() }
        .onChange(of: question) { _, _ in controller.invalidateReview() }
        .onChange(of: context) { _, _ in controller.invalidateReview() }
        .onChange(of: token) { _, _ in controller.invalidateReview() }
        .onChange(of: directlyInstalled) { _, confirmed in
            if !confirmed { clearSession() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { clearSession() }
        }
        .onDisappear { clearSession() }
    }

    private var sessionEntry: some View {
        Section("Memory-only API key") {
            Label("Do not enter keys in Strata or another app host. A host may read credentials and private text. This app cannot reliably detect that environment.", systemImage: "exclamationmark.shield.fill")
                .font(.callout).foregroundStyle(.orange)
            Toggle("I am using a directly installed app", isOn: $directlyInstalled)
                .accessibilityIdentifier("hosted-direct-install")
            SecureField("Existing OpenAI API key", text: $token)
                .textInputAutocapitalization(.never).autocorrectionDisabled().privacySensitive()
                .disabled(!directlyInstalled).accessibilityIdentifier("hosted-api-key")
            Button("Use key for this session") {
                do { try controller.begin(token: token, directlyInstalled: directlyInstalled) }
                catch { controller.message = HostedRequestPolicy.safeError(error).localizedDescription }
                token = ""
            }.disabled(!directlyInstalled || token.isEmpty)
                .accessibilityIdentifier("hosted-start-session")
            Text("This button does not send a network request or verify the key. The key stays in memory for up to 30 minutes and is cleared when you leave this screen or background the app. It is never saved to Keychain, memory, backups or diagnostics.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
    private var connectedSession: some View {
        Section("Memory-only session ready") {
            Text("Key not yet verified. Every send requires a fresh data and cost review.")
            Button("End session and clear screen", role: .destructive) { clearSession() }
                .accessibilityIdentifier("hosted-end-session")
            Text("Ending the local session cancels pending work. It does not revoke the key at OpenAI or erase information already sent there. Revoke the key through your provider account if needed.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
    private func review() {
        do { try controller.review(question: question, context: context, model: model) }
        catch { controller.message = HostedRequestPolicy.safeError(error).localizedDescription }
    }
    private func clearSession() {
        controller.endSession(); token = ""; directlyInstalled = false
        question = ""; context = ""; model = ""
        exporting = false; exportDocument = nil
    }
}

@MainActor private struct HostedConsentReview: View {
    let consent: HostedConsent
    let onSend: () -> Void
    let onCancel: () -> Void
    @State private var approved = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Recipient and charges") {
                    Text("OpenAI · \(consent.recipient)").font(.caption)
                    Text("The API key in this session is sent to OpenAI as an Authorization header. Exposure of this key could allow use of your API account and billable requests.")
                    Text("Sending is a metered API request. Charges depend on the model, your account and usage. This app cannot quote or enforce a currency spending limit. The maximum output is 2,048 tokens; reasoning can also use that budget. Cancelling may not avoid charges.")
                        .foregroundStyle(.orange)
                    Text("OpenAI receives the exact text below. store=false is requested, but this is not a promise of zero provider retention. Your provider terms and data controls apply.")
                    Text("Model: \(consent.model)")
                }
                Section("Exact question") { Text(verbatim: consent.question).textSelection(.enabled).privacySensitive() }
                Section("Exact context") {
                    if consent.context.isEmpty { Text("No additional context") }
                    else { Text(verbatim: consent.context).textSelection(.enabled).privacySensitive() }
                }
                Section("Exact request JSON · key excluded") {
                    if let data = try? HostedRequestPolicy.body(consent: consent) {
                        Text(verbatim: String(decoding: data, as: UTF8.self))
                            .font(.caption.monospaced()).textSelection(.enabled).privacySensitive()
                    }
                }
                Section {
                    Toggle("I approve sending this text and key to OpenAI and accept metered API charges", isOn: $approved)
                        .accessibilityIdentifier("hosted-approve-send")
                    Button("Send this request to OpenAI", action: onSend)
                        .disabled(!approved).accessibilityIdentifier("hosted-confirm-send")
                    Button("Cancel", role: .cancel, action: onCancel)
                        .accessibilityIdentifier("hosted-cancel-review")
                }
            }
            .navigationTitle("Review hosted request")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
