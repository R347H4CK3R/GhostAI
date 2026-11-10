import Foundation
import XCTest
@testable import AsterionVeyra

@MainActor final class AssistantPreferencesTests: XCTestCase {
    private func isolatedDefaults() -> (UserDefaults, String) {
        let name = "AssistantPreferencesTests." + UUID().uuidString
        return (UserDefaults(suiteName: name)!, name)
    }

    func testFirstLaunchUsesExistingIdentityWithoutCreatingStoredSettings() {
        let (defaults, suite) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = AssistantPreferences(defaults: defaults)
        XCTAssertEqual(preferences.value.name, "Jarvis")
        XCTAssertEqual(preferences.value.avatar, .sparkles)
        XCTAssertEqual(preferences.value.startScreen, .assistant)
        XCTAssertNil(defaults.object(forKey: AssistantPreferences.storageKey))
        XCTAssertNil(preferences.loadWarning)
    }

    func testExplicitSavePersistsAllChoicesAndLeavesUnrelatedPreferencesUntouched() throws {
        let (defaults, suite) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let priorDate = Date(timeIntervalSince1970: 1_700_000_000)
        defaults.set(priorDate, forKey: "diagnostics.lastSuccessfulReport.v1")
        defaults.set(Data([1, 2, 3]), forKey: "unrelated.private-data")
        let preferences = AssistantPreferences(defaults: defaults)
        try preferences.save(name: "  Nova  ", avatar: .moon, startScreen: .memory)
        let reloaded = AssistantPreferences(defaults: defaults)
        XCTAssertEqual(reloaded.value.name, "Nova")
        XCTAssertEqual(reloaded.value.avatar, .moon)
        XCTAssertEqual(reloaded.value.startScreen, .memory)
        XCTAssertEqual(defaults.object(forKey: "diagnostics.lastSuccessfulReport.v1") as? Date, priorDate)
        XCTAssertEqual(defaults.data(forKey: "unrelated.private-data"), Data([1, 2, 3]))
    }

    func testInvalidNamesNeverReplaceSavedValueOrStoredBytes() throws {
        let (defaults, suite) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = AssistantPreferences(defaults: defaults)
        try preferences.save(name: "Nova", avatar: .moon, startScreen: .memory)
        let before = defaults.data(forKey: AssistantPreferences.storageKey)
        let invalid = ["", "   ", "\nNova", "Nova\n", "No\tva", "No\u{0000}va", "No\u{007f}va",
                       "No\u{0085}va", "No\u{2028}va", "No\u{2029}va", "No\u{202e}va", "No\u{2066}va",
                       String(repeating: "N", count: 41), "A" + String(repeating: "\u{0301}", count: 81)]
        for name in invalid {
            XCTAssertThrowsError(try preferences.save(name: name, avatar: .bolt, startScreen: .hosted), "Must reject unsafe/oversized name")
            XCTAssertEqual(preferences.value.name, "Nova")
            XCTAssertEqual(preferences.value.avatar, .moon)
            XCTAssertEqual(preferences.value.startScreen, .memory)
            XCTAssertEqual(defaults.data(forKey: AssistantPreferences.storageKey), before)
        }
    }

    func testUnicodeNamesRemainByteExactAndValidBoundariesAreAccepted() throws {
        let (defaults, suite) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = AssistantPreferences(defaults: defaults)
        for name in ["Cafe\u{0301}", "家庭 👨‍👩‍👧‍👦", String(repeating: "🚀", count: 40)] {
            try preferences.save(name: name, avatar: .brain, startScreen: .projects)
            let reloaded = AssistantPreferences(defaults: defaults)
            XCTAssertEqual(Array(reloaded.value.name.utf8), Array(name.utf8))
        }
    }

    func testMalformedFutureOrNoncanonicalStoredPreferencesArePreservedUntilExplicitSave() throws {
        let samples = ["not JSON", "{}",
                       #"{"version":2,"name":"Future","avatar":"sparkles","startScreen":"assistant"}"#,
                       #"{"version":1,"name":"Future","avatar":"unknown","startScreen":"assistant"}"#,
                       #"{"version":1,"name":"Future","avatar":"sparkles","startScreen":"unknown"}"#,
                       #"{"version":1,"name":"Future","avatar":"sparkles","startScreen":"assistant","newField":true}"#,
                       #"{"version":1,"name":" spaced ","avatar":"sparkles","startScreen":"assistant"}"#,
                       #"{"version":1,"name":"line\nbreak","avatar":"sparkles","startScreen":"assistant"}"#]
        for sample in samples {
            let (defaults, suite) = isolatedDefaults()
            defer { defaults.removePersistentDomain(forName: suite) }
            let bytes = Data(sample.utf8)
            defaults.set(bytes, forKey: AssistantPreferences.storageKey)
            let preferences = AssistantPreferences(defaults: defaults)
            XCTAssertEqual(preferences.value.name, "Jarvis")
            XCTAssertNotNil(preferences.loadWarning)
            XCTAssertEqual(defaults.data(forKey: AssistantPreferences.storageKey), bytes)
            try preferences.save(name: "Nova", avatar: .leaf, startScreen: .about)
            XCTAssertNil(preferences.loadWarning)
            XCTAssertEqual(AssistantPreferences(defaults: defaults).value.name, "Nova")
        }
    }

    func testOversizedAndUnexpectedStoredTypesDoNotCrashOrSilentlyOverwrite() {
        let (defaults, suite) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(Data(repeating: 32, count: 4097), forKey: AssistantPreferences.storageKey)
        XCTAssertNotNil(AssistantPreferences(defaults: defaults).loadWarning)
        XCTAssertEqual(defaults.data(forKey: AssistantPreferences.storageKey)?.count, 4097)
        defaults.set("unexpected legacy value", forKey: AssistantPreferences.storageKey)
        XCTAssertNotNil(AssistantPreferences(defaults: defaults).loadWarning)
        XCTAssertEqual(defaults.string(forKey: AssistantPreferences.storageKey), "unexpected legacy value")
    }
}

@MainActor final class AssistantControlsVoiceEntryTests: XCTestCase {
    func testPendingVoiceRequestWaitsForAvailablePresentationThenConsumesOnlyOnce() {
        let request = VoiceEntryRequest()
        request.request()
        XCTAssertFalse(request.consume(canPresent: false))
        XCTAssertTrue(request.pending, "A settings/computer sheet must not swallow a Siri request")
        XCTAssertTrue(request.consume(canPresent: true))
        XCTAssertFalse(request.pending)
        XCTAssertFalse(request.consume(canPresent: true))
    }
}
