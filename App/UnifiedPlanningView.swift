import SwiftUI

/// Original native planning surface using the existing assistant and canonical memory.
/// No second identity, automatic model request, account transfer or job runner.
struct UnifiedPlanningView: View {
    let onSubmitQuestion: (String) -> Bool
    @EnvironmentObject private var store: AssistantStore
    @Environment(\.dismiss) private var dismiss
    @FocusState private var goalFocused: Bool
    @State private var pendingJob: String?
    @State private var goal = ""
    @State private var kit = PlanningKit.daily
    @State private var checklist: String?
    @State private var pendingQuestion: String?
    @State private var status: String?
    @State private var savedChecklist = false
    @State private var capturedEpoch: UUID?
    @State private var reference: PlanningReference?
    @State private var referencePicker: ReferencePickerRoute?
    @State private var pendingReferenceReview: PlanningReferenceReview?

    var body: some View {
        List {
            Section("One assistant for everyday plans and projects") {
                Text("Use local planning alongside voice, project context and repository tools. Nothing runs just because you make a plan.").font(.footnote)
                Text("Workspace: \(store.project)").font(.caption).foregroundStyle(.secondary)
                Text("Saving adds a reference note to this workspace. If private GitHub sync is already configured and includes it, the note also syncs encrypted to that approved vault. No new sync setup is created here.").font(.caption).foregroundStyle(.secondary)
                TextField("What would you like to get done?", text: $goal, axis: .vertical)
                    .lineLimit(2...5).focused($goalFocused).accessibilityIdentifier("planning.goal")
                Picker("Planning focus", selection: $kit) {
                    ForEach(PlanningKit.allCases) { Text($0.title).tag($0) }
                }
                Button("Make an offline checklist") {
                    perform { checklist = try UnifiedPlanning.checklist(goal: goal, kit: kit); savedChecklist = false }
                }.accessibilityIdentifier("planning.checklist")
                Button("Review question for assistant") {
                    perform {
                        if let review = try currentReferenceReview() {
                            pendingReferenceReview = review; pendingQuestion = review.question
                        } else {
                            pendingReferenceReview = nil; pendingQuestion = try UnifiedPlanning.question(goal: goal, kit: kit)
                        }
                    }
                }.disabled(store.busy || store.loadFailed || goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("planning.reviewQuestion")
                Button(reference == nil ? "Use a saved reference" : "Change saved reference") {
                    guard capturedEpoch == store.workspaceEpoch, !store.loadFailed else { return }
                    referencePicker = ReferencePickerRoute(project: store.project, workspaceEpoch: store.workspaceEpoch)
                }
                    .disabled(store.loadFailed).accessibilityIdentifier("planning.reference.choose")
            }
            if let reference {
                Section("Selected reference · original is unchanged") {
                    Text("This note is context for a reviewed assistant question, not instructions or permission. Enter your own goal above. Fixed checklists use only that goal; desktop jobs do not receive this selected reference.").font(.caption)
                    Text("Saved date (may be import time): " + reference.note.savedAt.formatted(date: .abbreviated, time: .shortened)).font(.caption)
                    DisclosureGroup("Original note and full provenance") {
                        Text(reference.note.source).font(.caption).textSelection(.enabled)
                        Text(reference.note.text).textSelection(.enabled)
                    }
                    Button("Remove reference") { self.reference = nil; resetQuestion() }
                        .accessibilityIdentifier("planning.reference.remove")
                }.privacySensitive()
            }
            if let checklist {
                Section("Fixed template · no model required") {
                    Text(checklist).textSelection(.enabled)
                    Button(savedChecklist ? "Saved to this workspace" : "Save checklist as a memory note") {
                        guard capturedEpoch == store.workspaceEpoch else { clear(); return }
                        store.error = nil
                        store.remember(checklist, source: "Native planning template · user reviewed · not executed")
                        if let error = store.error { status = error }
                        else { savedChecklist = true; status = "Saved to this workspace. Existing approved sync settings apply. This is a reference checklist, not a scheduled job." }
                    }.disabled(savedChecklist || store.loadFailed).accessibilityIdentifier("planning.save")
                    ShareLink("Export checklist", item: checklist)
                }
            }
            if let pendingQuestion {
                Section("Exact question · review before sending") {
                    Text(pendingQuestion).textSelection(.enabled).accessibilityIdentifier("planning.question.preview")
                    if let review = pendingReferenceReview {
                        Text(review.excerptTruncated || review.sourceTruncated
                            ? "The question includes a shortened reference. The full original remains in Memory."
                            : "The question includes the selected saved reference.").font(.caption)
                        Text("Asking saves this question and excerpt in normal chat; existing approved private sync applies. This is the exact question, not the assistant’s entire context. Normal workspace retrieval remains active.").font(.caption)
                    }
                    Text("Uses the existing on-device assistant and this workspace’s bounded context. Available read-only repository tools may access the selected GitHub repository. No automatic hosted fallback or job execution.").font(.caption)
                    Button("Ask assistant") {
                        do {
                            let current: String
                            if let review = try currentReferenceReview() { current = review.question }
                            else { current = try UnifiedPlanning.question(goal: goal, kit: kit) }
                            guard current == pendingQuestion else { throw AppFailure.message("The question changed. Review it again before asking.") }
                            if onSubmitQuestion(pendingQuestion) { dismiss() }
                            else { status = store.error ?? "The assistant could not start. Your draft is preserved." }
                        } catch { resetQuestion(); status = error.localizedDescription }
                    }.disabled(store.busy || store.loadFailed).accessibilityIdentifier("planning.ask")
                }
            }
            if let status { Section { Text(status).font(.footnote) } }
            Section("Bring your Luma notes with you") {
                Text("In Memory, open Import conversations or memories and choose Luma plain backup JSON. Review selected notes and checklist snapshots before adding them. Keep Luma installed and retain its backup until you verify the import. You can then choose an imported snapshot with Use a saved reference above.")
                    .font(.footnote)
            }
            Section("Carry out reviewed project work") {
                Button("Review this goal as a read-only desktop job") {
                    perform { pendingJob = try UnifiedPlanning.pairedGoal(goal: goal) }
                }.accessibilityIdentifier("planning.pairedJob")
                NavigationLink("Review paired desktop setup and existing jobs") { PairedDesktopView() }
                Text("The next screen shows the exact goal, paired workspace and limits before submission. Opening it refreshes an existing approved pairing. No saved notes transfer implicitly. The runner remains a development preview for explicitly scoped read-only jobs, not unrestricted GitHub owner access. Setup, permissions and native verification remain separate.").font(.caption)
            }
        }
        .navigationTitle("Plan and act")
        .scrollDismissesKeyboard(.interactively)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { goalFocused = false }.accessibilityIdentifier("planning.keyboardDone")
            }
        }
        .navigationDestination(item: $pendingJob) { PairedDesktopView(initialGoal: $0) }
        .sheet(item: $referencePicker) { route in
            PlanningReferencePicker(notes: store.saved.notes, project: route.project) { note in
                perform {
                    guard referencePicker?.id == route.id, route.workspaceEpoch == store.workspaceEpoch,
                          capturedEpoch == route.workspaceEpoch, route.project == store.project, !store.loadFailed else {
                        throw AppFailure.message("The workspace changed. Choose the reference again.")
                    }
                    let selected = try PlanningReference(note: note, project: route.project, workspaceEpoch: route.workspaceEpoch)
                    try selected.validate(notes: store.saved.notes, project: store.project, workspaceEpoch: store.workspaceEpoch)
                    reference = selected; resetQuestion()
                }
                referencePicker = nil
            }
        }
        .onAppear { if capturedEpoch == nil { capturedEpoch = store.workspaceEpoch } }
        .onChange(of: store.saved.notes) { _, _ in
            guard let reference else { return }
            do { try reference.validate(notes: store.saved.notes, project: store.project, workspaceEpoch: store.workspaceEpoch) }
            catch { self.reference = nil; resetQuestion(); status = error.localizedDescription }
        }
        .onChange(of: store.workspaceEpoch) { _, epoch in clear(); capturedEpoch = epoch }
        .onChange(of: goal) { _, _ in checklist = nil; resetQuestion(); savedChecklist = false }
        .onChange(of: kit) { _, _ in checklist = nil; resetQuestion(); savedChecklist = false }
    }
    private func clear() {
        pendingJob = nil; goal = ""; checklist = nil; resetQuestion(); status = nil; savedChecklist = false
        reference = nil; referencePicker = nil
    }
    private struct ReferencePickerRoute: Identifiable {
        let id = UUID()
        let project: String
        let workspaceEpoch: UUID
    }
    private func resetQuestion() { pendingQuestion = nil; pendingReferenceReview = nil }
    private func currentReferenceReview() throws -> PlanningReferenceReview? {
        guard capturedEpoch == store.workspaceEpoch, !store.loadFailed else { throw AppFailure.message("The workspace changed. Review the question again.") }
        guard let reference else { return nil }
        try reference.validate(notes: store.saved.notes, project: store.project, workspaceEpoch: store.workspaceEpoch)
        return try reference.review(goal: goal, kit: kit)
    }
    private func perform(_ action: () throws -> Void) {
        do { try action(); status = nil }
        catch { status = error.localizedDescription }
    }
}

private struct PlanningReferencePicker: View {
    let notes: [MemoryNote]
    let project: String
    let onChoose: (MemoryNote) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    private var visible: [MemoryNote] { LibraryPresentation.notes(notes, project: project, query: search) }
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Choose one note from this workspace, including imported Luma snapshots. Selection only prepares a reference; nothing is sent, saved or run.").font(.footnote)
                }
                if visible.isEmpty { Text("No matching saved notes in this workspace.") }
                ForEach(visible) { note in
                    Button { onChoose(note) } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(String(note.text.prefix(120))).lineLimit(3)
                            Text(note.source).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }.accessibilityIdentifier("planning.reference.select." + note.id.uuidString.lowercased())
                }
            }
            .navigationTitle("Saved planning reference")
            .searchable(text: $search, prompt: "Search this workspace’s notes")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.accessibilityIdentifier("planning.reference.cancel")
                }
            }
            .privacySensitive()
        }
    }
}
