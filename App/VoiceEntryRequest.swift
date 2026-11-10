import SwiftUI

/// A navigation request only. Never activates microphone, speech or background audio.
@MainActor final class VoiceEntryRequest: ObservableObject {
    static let shared = VoiceEntryRequest()
    @Published private(set) var pending = false
    func request() { pending = true }
    func consume(canPresent: Bool = true) -> Bool {
        guard canPresent, pending else { return false }
        pending = false
        return true
    }
}
