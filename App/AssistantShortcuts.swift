import AppIntents

/// Standalone installs can expose an OS-managed Siri/Shortcuts entry point.
/// Opening never starts the microphone; the user chooses voice in the app.
struct OpenAsterionIntent: AppIntent {
    static var title: LocalizedStringResource = "Open Asterion Veyra"
    static var description = IntentDescription("Open the assistant for text or a user-started voice conversation.")
    static var openAppWhenRun = true

    @MainActor func perform() async throws -> some IntentResult { .result() }
}
struct AsterionShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: OpenAsterionIntent(),
                    phrases: ["Open \(.applicationName)", "Talk to \(.applicationName)"],
                    shortTitle: "Open assistant", systemImageName: "sparkles")
    }
}
