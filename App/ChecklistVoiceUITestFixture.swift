#if DEBUG
import SwiftUI

/// Synthetic navigation only. Requires the isolated checklist UI-test state and
/// an explicit launch flag; Release builds contain neither the hook nor its flag.
struct ChecklistVoiceUITestFixture: ViewModifier {
    @Environment(\.scenePhase) private var scenePhase
    @State private var backgrounded = false
    private var enabled: Bool {
        ChatUITestFixture.fromLaunchArguments()?.scenario == .checklists
            && ProcessInfo.processInfo.arguments.contains("--uitest-checklist-voice-on-return")
    }
    func body(content: Content) -> some View {
        content.onChange(of: scenePhase) { _, phase in
            guard enabled else { return }
            if phase == .background {
                backgrounded = true
            } else if phase == .active, backgrounded {
                backgrounded = false
                VoiceEntryRequest.shared.request()
            }
        }
    }
}
#endif
