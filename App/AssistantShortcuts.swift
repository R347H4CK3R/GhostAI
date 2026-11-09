import AppIntents

/// Standalone installs can expose an OS-managed Siri/Shortcuts entry point.
/// Opening never starts the microphone; the user chooses voice in the app.
struct OpenAsterionIntent: AppIntent {
    static var title: LocalizedStringResource = "Open Jarvis"
    static var description = IntentDescription("Open the assistant for text or a user-started voice conversation.")
    static var openAppWhenRun = true

    @MainActor func perform() async throws -> some IntentResult { .result() }
}
struct OpenVoiceControlsIntent: AppIntent {
    static var title: LocalizedStringResource = "Open voice controls"
    static var description = IntentDescription("Open voice conversation controls. Recording begins only after you choose Start voice call and grant permission.")
    static var openAppWhenRun = true

    @MainActor func perform() async throws -> some IntentResult {
        VoiceEntryRequest.shared.request()
        return .result()
    }
}
struct AsterionShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: OpenVoiceControlsIntent(),
                    phrases: ["Open voice controls in \(.applicationName)"],
                    shortTitle: "Voice controls", systemImageName: "mic.fill")
        AppShortcut(intent: OpenAsterionIntent(),
                    phrases: ["Open \(.applicationName)", "Talk to \(.applicationName)"],
                    shortTitle: "Open assistant", systemImageName: "sparkles")
    }
}

