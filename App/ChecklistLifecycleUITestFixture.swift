#if DEBUG
import SwiftUI
import Foundation

/// Reduced, synthetic lifecycle comparison. No AssistantStore, preferences,
/// credentials, disk persistence, network services or voice objects are created.
struct ChecklistLifecycleUITestFixture {
    enum Scenario: String {
        case editor, form
        case privacyQA = "privacy-qa"
    }
    let scenario: Scenario
    let note: MemoryNote
    let checklist: EditableChecklist

    static func fromLaunchArguments(_ arguments: [String] = ProcessInfo.processInfo.arguments) -> Self? {
        guard let chat = ChatUITestFixture.fromLaunchArguments(arguments), chat.scenario == .checklists,
              let index = arguments.firstIndex(of: "--uitest-checklist-lifecycle"),
              arguments.indices.contains(index + 1),
              let scenario = Scenario(rawValue: arguments[index + 1]) else { return nil }
        for note in chat.state.notes {
            if let checklist = EditableChecklist.decode(note) {
                return Self(scenario: scenario, note: note, checklist: checklist)
            }
        }
        return nil
    }

    func log(_ event: String) {
        // Public app-side API only. Never log draft text or user content.
        print("CHECKLIST_LIFECYCLE_FIXTURE pid=\(ProcessInfo.processInfo.processIdentifier) scenario=\(scenario.rawValue) \(event)")
    }
}

/// Only the DEBUG dispatcher can choose this app, with both explicit fixture flags.
@MainActor struct ChecklistLifecycleUITestApp: App {
    private let fixture: ChecklistLifecycleUITestFixture

    init() {
        guard let fixture = ChecklistLifecycleUITestFixture.fromLaunchArguments() else {
            preconditionFailure("The reduced app requires explicit synthetic checklist lifecycle arguments")
        }
        self.fixture = fixture
        fixture.log("launch")
    }

    var body: some Scene {
        WindowGroup { ChecklistLifecycleUITestHost(fixture: fixture) }
    }
}

private struct ChecklistLifecycleUITestHost: View {
    let fixture: ChecklistLifecycleUITestFixture
    @Environment(\.scenePhase) private var scenePhase
    @State private var presenting = false

    var body: some View {
        VStack(spacing: 16) {
            Text("Synthetic checklist lifecycle: \(fixture.scenario.rawValue)")
            Button("Open editor") { presenting = true }
                .accessibilityIdentifier("checklistLifecycle.open")
        }
        .padding()
        // Deliberately no parent NavigationStack, TabView, search or toolbar.
        .sheet(isPresented: $presenting) {
            switch fixture.scenario {
            case .editor:
                // The exact production view, including its privacySensitive(),
                // automatic title, Form, multiline fields and keyboard toolbar.
                // Callbacks only dismiss; this fixture never persists any edit.
                EditableChecklistView(note: fixture.note, checklist: fixture.checklist,
                    onSave: { _, _, _ in presenting = false }, onCancel: { presenting = false })
            case .form:
                ChecklistLifecycleFormControl(initialGoal: fixture.checklist.goal, initialStep: fixture.checklist.step,
                    onDismiss: { presenting = false })
            case .privacyQA:
                ChecklistPrivacyUITestEditor(fixture: fixture, onDismiss: { presenting = false })
            }
        }
        .onAppear { fixture.log("appear phase=\(scenePhase)") }
        .onChange(of: scenePhase) { _, phase in
            // Diagnostics do not mutate state while iOS takes its snapshot.
            fixture.log("phase=\(phase) presented=\(presenting)")
        }
        .onChange(of: presenting) { _, presented in fixture.log("presented=\(presented)") }
        .tint(.cyan)
        .preferredColorScheme(.dark)
    }
}

/// Keeps the editor's navigation/input/toolbar shape, without checklist
/// validation or reference sections. Differences are diagnostic, not a repair.
private struct ChecklistLifecycleFormControl: View {
    let initialGoal: String
    let initialStep: String
    let onDismiss: () -> Void
    @State private var goal: String
    @State private var step: String
    @FocusState private var editing: Bool

    init(initialGoal: String, initialStep: String, onDismiss: @escaping () -> Void) {
        self.initialGoal = initialGoal; self.initialStep = initialStep; self.onDismiss = onDismiss
        _goal = State(initialValue: initialGoal); _step = State(initialValue: initialStep)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Your checklist copy") {
                    TextField("Goal", text: $goal, axis: .vertical).lineLimit(1...6)
                        .focused($editing).accessibilityIdentifier("checklistLifecycle.goal")
                    TextField("Step", text: $step, axis: .vertical).lineLimit(2...8)
                        .focused($editing).accessibilityIdentifier("checklistLifecycle.step")
                }
            }
            // This content-only boundary passed the reduced background control;
            // keep it aligned with the exact editor's privacy boundary.
            .privacySensitive()
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Edit checklist")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onDismiss).accessibilityIdentifier("checklistLifecycle.cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: onDismiss).disabled(goal == initialGoal && step == initialStep)
                        .accessibilityIdentifier("checklistLifecycle.save")
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer(); Button("Done") { editing = false }.accessibilityIdentifier("checklistLifecycle.keyboardDone")
                }
            }
        }
    }
}

/// Explicit rendering QA only, separate from both lifecycle cases. The supplied
/// privacy reason exercises markings; it does not simulate the app switcher or
/// promise that screenshots, recordings or accessibility content are hidden.
private struct ChecklistPrivacyUITestEditor: View {
    let fixture: ChecklistLifecycleUITestFixture
    let onDismiss: () -> Void
    @State private var redactionEnabled = false

    var body: some View {
        // A sibling above the editor gives NavigationStack a real, smaller
        // viewport. An outer bottom safeAreaInset overlapped the Form's last
        // row even at its maximum scroll offset on iOS 26.
        VStack(spacing: 0) {
            Button(redactionEnabled ? "Show original synthetic content" : "Show explicit privacy redaction") {
                redactionEnabled.toggle()
            }
            .accessibilityIdentifier("checklistPrivacy.toggle")
            .accessibilityValue(redactionEnabled ? "On" : "Off")
            .font(.caption)
            .frame(maxWidth: .infinity)
            .padding(12)
            .background(.bar)

            EditableChecklistView(note: fixture.note, checklist: fixture.checklist,
                onSave: { _, _, _ in
                    throw AppFailure.message("Synthetic private save detail for redaction QA")
                }, onCancel: onDismiss)
            .redacted(reason: redactionEnabled ? .privacy : [])
        }
    }
}
#endif
