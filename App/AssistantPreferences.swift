import Foundation
import Combine

enum AssistantAvatar: String, CaseIterable, Codable, Identifiable {
    case sparkles, bolt, moon, sun, brain, leaf
    var id: String { rawValue }
    var title: String {
        switch self {
        case .sparkles: return "Sparkles"
        case .bolt: return "Bolt"
        case .moon: return "Moon"
        case .sun: return "Sun"
        case .brain: return "Brain"
        case .leaf: return "Leaf"
        }
    }
    var symbol: String {
        switch self {
        case .sparkles: return "sparkles"
        case .bolt: return "bolt.fill"
        case .moon: return "moon.stars.fill"
        case .sun: return "sun.max.fill"
        case .brain: return "brain.head.profile"
        case .leaf: return "leaf.fill"
        }
    }
}

enum AssistantStartScreen: String, CaseIterable, Codable, Identifiable {
    case assistant, projects, memory, hosted, about
    var id: String { rawValue }
    var title: String {
        switch self {
        case .assistant: return "Assistant"
        case .projects: return "Projects"
        case .memory: return "Memory"
        case .hosted: return "Hosted"
        case .about: return "About"
        }
    }
}

/// Presentation only. Never used as model instructions, workspace identity or permission.
struct AssistantPreferenceValue: Codable, Equatable {
    let version: Int
    let name: String
    let avatar: AssistantAvatar
    let startScreen: AssistantStartScreen
    static let defaults = AssistantPreferenceValue(name: "Jarvis", avatar: .sparkles, startScreen: .assistant)

    init(name: String, avatar: AssistantAvatar, startScreen: AssistantStartScreen) {
        version = 1; self.name = name; self.avatar = avatar; self.startScreen = startScreen
    }

    static func validated(name: String, avatar: AssistantAvatar, startScreen: AssistantStartScreen) throws -> Self {
        // Reject unsafe controls before trimming: a pasted newline must not silently disappear.
        // Explicit scalar ranges allow legitimate joiners in multiscalar emoji and names.
        guard !name.unicodeScalars.contains(where: { scalar in
            let value = scalar.value
            return value <= 0x1f || (0x7f...0x9f).contains(value) || value == 0x2028 || value == 0x2029
                || value == 0x061c || value == 0x200e || value == 0x200f
                || (0x202a...0x202e).contains(value) || (0x2066...0x2069).contains(value)
        }) else { throw AssistantPreferenceFailure.invalidName }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed.count <= 40, trimmed.utf8.count <= 160 else {
            throw AssistantPreferenceFailure.invalidName
        }
        return Self(name: trimmed, avatar: avatar, startScreen: startScreen)
    }
}

enum AssistantPreferenceFailure: LocalizedError {
    case invalidName
    var errorDescription: String? {
        "Use a name of 1–40 characters, up to 160 UTF-8 bytes, without line breaks or direction-control characters."
    }
}

/// One shared owner for all windows, stored separately from user content and credentials.
@MainActor final class AssistantPreferences: ObservableObject {
    static let storageKey = "jarvis.assistantPreferences.v1"
    @Published private(set) var value: AssistantPreferenceValue
    @Published private(set) var loadWarning: String?
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        value = .defaults
        guard let stored = defaults.object(forKey: Self.storageKey) else { return }
        do {
            guard let data = stored as? Data, data.count <= 4096,
                  let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  Set(object.keys) == Set(["version", "name", "avatar", "startScreen"]) else {
                throw AssistantPreferenceFailure.invalidName
            }
            let decoded = try JSONDecoder().decode(AssistantPreferenceValue.self, from: data)
            let validated = try AssistantPreferenceValue.validated(name: decoded.name, avatar: decoded.avatar, startScreen: decoded.startScreen)
            guard decoded.version == 1, Array(validated.name.utf8) == Array(decoded.name.utf8) else {
                throw AssistantPreferenceFailure.invalidName
            }
            value = validated
        } catch {
            // Keep unfamiliar/corrupt bytes untouched until a deliberate valid Save.
            loadWarning = "Saved assistant settings could not be read. Defaults are shown. Saving replaces only these local settings, not chats, memories or connections."
        }
    }

    func save(name: String, avatar: AssistantAvatar, startScreen: AssistantStartScreen) throws {
        let next = try AssistantPreferenceValue.validated(name: name, avatar: avatar, startScreen: startScreen)
        let bytes = try JSONEncoder().encode(next)
        defaults.set(bytes, forKey: Self.storageKey)
        value = next
        loadWarning = nil
    }

    static func forApplication(launchArguments: [String] = ProcessInfo.processInfo.arguments) -> AssistantPreferences {
        #if DEBUG
        if ChatUITestFixture.fromLaunchArguments(launchArguments) != nil {
            // All synthetic chat tests avoid real preferences. A bounded explicit UUID-like
            // suffix lets the persistence UI test relaunch its own isolated suite.
            var suffix = UUID().uuidString
            if let index = launchArguments.firstIndex(of: "--uitest-preferences-suite"),
               launchArguments.indices.contains(index + 1) {
                let requested = launchArguments[index + 1]
                if !requested.isEmpty, requested.utf8.count <= 80,
                   requested.unicodeScalars.allSatisfy({ (48...57).contains($0.value) || (65...90).contains($0.value) || (97...122).contains($0.value) || $0.value == 45 }) {
                    suffix = requested
                }
            }
            return AssistantPreferences(defaults: UserDefaults(suiteName: "JarvisSyntheticPreferences." + suffix)!)
        }
        #endif
        return AssistantPreferences()
    }
}
