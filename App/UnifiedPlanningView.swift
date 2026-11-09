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
                    perform { pendingQuestion = try UnifiedPlanning.question(goal: goal, kit: kit) }
                }.disabled(store.busy || store.loadFailed).accessibilityIdentifier("planning.reviewQuestion")
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
                    Text(pendingQuestion).textSelection(.enabled)
                    Text("Uses the existing on-device assistant and this workspace’s bounded context. Available read-only repository tools may access the selected GitHub repository. No automatic hosted fallback or job execution.").font(.caption)
                    Button("Ask assistant") {
                        guard capturedEpoch == store.workspaceEpoch else { clear(); return }
                        if onSubmitQuestion(pendingQuestion) { dismiss() }
                        else { status = store.error ?? "The assistant could not start. Your draft is preserved." }
                    }.disabled(store.busy || store.loadFailed).accessibilityIdentifier("planning.ask")
                }
            }
            if let status { Section { Text(status).font(.footnote) } }
            Section("Bring your Luma notes with you") {
                Text("In Memory, open Import conversations or memories and choose Luma plain backup JSON. Review selected notes and checklist snapshots before adding them. Keep Luma installed and retain its backup until you verify the import.")
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
        .onAppear { capturedEpoch = store.workspaceEpoch }
        .onChange(of: store.workspaceEpoch) { _, epoch in clear(); capturedEpoch = epoch }
        .onChange(of: goal) { _, _ in checklist = nil; pendingQuestion = nil; savedChecklist = false }
        .onChange(of: kit) { _, _ in checklist = nil; pendingQuestion = nil; savedChecklist = false }
    }
    private func clear() { pendingJob = nil; goal = ""; checklist = nil; pendingQuestion = nil; status = nil; savedChecklist = false }
    private func perform(_ action: () throws -> Void) {
        do { try action(); status = nil }
        catch { status = error.localizedDescription }
    }
}
