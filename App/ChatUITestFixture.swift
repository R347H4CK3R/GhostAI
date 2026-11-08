#if DEBUG
import Foundation

/// Explicit, synthetic UI-test input. Release builds contain none of this code.
/// All persistence is bypassed while enabled; no saved user data is read or changed.
struct ChatUITestFixture {
    enum Scenario: String { case success, pending, empty }
    let scenario: Scenario

    static func fromLaunchArguments(_ arguments: [String] = ProcessInfo.processInfo.arguments) -> ChatUITestFixture? {
        guard let index = arguments.firstIndex(of: "--uitest-chat"),
              arguments.indices.contains(index + 1),
              let scenario = Scenario(rawValue: arguments[index + 1]) else { return nil }
        return ChatUITestFixture(scenario: scenario)
    }

    var state: SavedState {
        let chats = (1...12).flatMap { index in
            [ChatEntry(project: "General", role: "user", text: "Synthetic project question \(index)"),
             ChatEntry(project: "General", role: "assistant", text: "Synthetic project answer \(index). This longer conversation checks that earlier messages stay scrollable while the keyboard is open.")]
        }
        return SavedState(notes: [MemoryNote(project: "Synthetic second project", text: "Synthetic workspace for draft isolation", source: "UI test fixture")], chats: chats)
    }

    func respond(to question: String) async throws -> String {
        try await Task.sleep(nanoseconds: scenario == .pending ? 60_000_000_000 : 1_000_000_000)
        try Task.checkCancellation()
        return scenario == .empty ? " \n\t " : "Synthetic reply: \(question)"
    }
}
#endif
