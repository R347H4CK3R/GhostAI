import SwiftUI

struct EditableChecklistView: View {
    let note: MemoryNote
    let checklist: EditableChecklist
    let onSave: (String, String, Bool) throws -> Void
    let onCancel: () -> Void
    @State private var goal: String
    @State private var step: String
    @State private var done: Bool
    @State private var saving = false
    @State private var issue: String?
    @FocusState private var editing: Bool

    init(note: MemoryNote, checklist: EditableChecklist,
         onSave: @escaping (String, String, Bool) throws -> Void, onCancel: @escaping () -> Void) {
        self.note = note; self.checklist = checklist; self.onSave = onSave; self.onCancel = onCancel
        _goal = State(initialValue: checklist.goal); _step = State(initialValue: checklist.step)
        _done = State(initialValue: checklist.done)
    }
    var body: some View {
        NavigationStack {
            Form {
                Section("Your checklist copy") {
                    TextField("Goal", text: $goal, axis: .vertical).lineLimit(1...6)
                        .focused($editing).accessibilityIdentifier("checklist.goal")
                    TextField("Step", text: $step, axis: .vertical).lineLimit(2...8)
                        .focused($editing).accessibilityIdentifier("checklist.step")
                    Toggle("Completed", isOn: $done).accessibilityIdentifier("checklist.done")
                    Text("Goal: \(goal.utf16.count)/300 · Step: \(step.utf16.count)/400 UTF-16 units. Emoji can count as two units. Remove credentials and hidden controls before saving.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Before you save") {
                    Text("Save updates only this copy in \(note.project). The original Luma snapshot stays unchanged. Marking a step completed records your choice; it does not run or verify any action.")
                    Text("This copy is stored with Memory and follows existing approved encrypted-sync settings. Concurrent edits can remain as separate copies. No reminders, jobs or permissions are created.")
                        .font(.footnote).foregroundStyle(.secondary)
                    if let issue { Text(issue).foregroundStyle(.orange).accessibilityIdentifier("checklist.issue") }
                }
                Section("Original reference · untrusted text") {
                    Text(checklist.origin.source).font(.caption)
                    Text(checklist.origin.text).textSelection(.enabled)
                    Text("Source snapshot ID: \(checklist.origin.snapshotID.uuidString.lowercased())")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("Copy creation/import time: \(note.savedAt.formatted()). This is not the original Luma task date or a last-edited date.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Edit checklist")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel).accessibilityIdentifier("checklist.cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save).disabled(!canSave || saving).accessibilityIdentifier("checklist.save")
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer(); Button("Done") { editing = false }.accessibilityIdentifier("checklist.keyboardDone")
                }
            }
        }.privacySensitive()
    }
    private var canSave: Bool {
        (goal.utf8.elementsEqual(checklist.goal.utf8) == false
            || step.utf8.elementsEqual(checklist.step.utf8) == false || done != checklist.done)
            && (try? EditableChecklist.edit(note, goal: goal, step: step, done: done)) != nil
    }
    private func save() {
        guard canSave, !saving else { return }
        saving = true; issue = nil; editing = false
        do { try onSave(goal, step, done) }
        catch {
            issue = (error as? AppFailure)?.localizedDescription ?? "The checklist could not be saved. Your changes remain here; check storage and reopen if the source changed."
            saving = false
        }
    }
}
