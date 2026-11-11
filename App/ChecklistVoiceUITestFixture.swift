#if DEBUG
import SwiftUI

/// Synthetic navigation only. Requires the isolated checklist UI-test state and
/// an explicit launch flag; Release builds contain neither the hook nor its flag.
struct ChecklistVoiceUITestFixture: ViewModifier {
    @Environment(\.scenePhase) private var scenePhase
    // Non-observable bookkeeping must not invalidate the sheet host while iOS
    // is taking its background snapshot. Only request() changes production state.
    private final class Trigger { var backgrounded = false }
    @State private var trigger = Trigger()
    private var enabled: Bool {
        ChatUITestFixture.fromLaunchArguments()?.scenario == .checklists
            && ProcessInfo.processInfo.arguments.contains("--uitest-checklist-voice-on-return")
    }
    func body(content: Content) -> some View {
        content.onChange(of: scenePhase) { _, phase in
            guard enabled else { return }
            print("CHECKLIST_VOICE_FIXTURE pid=\(ProcessInfo.processInfo.processIdentifier) phase=\(phase) armed=\(trigger.backgrounded)")
            if phase == .background {
                trigger.backgrounded = true
            } else if phase == .active, trigger.backgrounded {
                trigger.backgrounded = false
                print("CHECKLIST_VOICE_FIXTURE pid=\(ProcessInfo.processInfo.processIdentifier) request")
                VoiceEntryRequest.shared.request()
            }
        }
    }
}
#endif
