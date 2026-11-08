import Foundation
import XCTest
@testable import AsterionVeyra

final class UpgradePersistenceTests: XCTestCase {
    /// Shared byte-for-byte with the host-side simulator seeder. This is the actual
    /// SavedState v1 encoding used by the pinned 0.3.0 release, not a new encoder round trip.
    private func fixtureData() throws -> Data {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "upgrade-state-v1", withExtension: "json"))
        return try Data(contentsOf: url)
    }

    func testPinnedPriorFormatRemainsReadableWithoutRewritingIt() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let original = try fixtureData()
        let disk = DiskStore(root: root)
        try original.write(to: disk.url)
        assertPriorState(try disk.load())
        XCTAssertEqual(try Data(contentsOf: disk.url), original)
    }

    func testInstalledUpgradeReadsPriorStateWithoutChangingBytes() throws {
        // Only the isolated install-over-existing job may read its installed data.
        // Normal tests must neither require nor alter a developer's app container.
        guard ProcessInfo.processInfo.environment["ASTERION_UPGRADE_SMOKE"] == "1" else {
            throw XCTSkip("Runs only after the isolated simulator upgrade has been seeded")
        }
        XCTAssertEqual(Bundle.main.bundleIdentifier, "dev.asterionveyra.assistant")
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AsterionVeyra", isDirectory: true)
        let disk = DiskStore(root: root)
        let original = try fixtureData()
        XCTAssertEqual(try Data(contentsOf: disk.url), original, "The prior installation's exact file must survive")
        assertPriorState(try disk.load())
        XCTAssertEqual(try Data(contentsOf: disk.url), original, "Reading must not rewrite or reset the old store")
        let timestamp = try XCTUnwrap(ProcessInfo.processInfo.environment["ASTERION_UPGRADE_PREFERENCE_EPOCH"].flatMap(Double.init))
        XCTAssertTrue(timestamp.isFinite)
        let expectedPreference = Date(timeIntervalSince1970: timestamp)
        XCTAssertFalse(DiagnosticChecks.isDue(lastRun: expectedPreference, now: Date()),
                       "The seeded preference must suppress diagnostics using the production date policy")
        XCTAssertEqual(UserDefaults.standard.object(forKey: "diagnostics.lastSuccessfulReport.v1") as? Date,
                       expectedPreference, "The exact prior-release persisted preference must survive")
    }

    private func assertPriorState(_ state: SavedState, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(state.version, 1, file: file, line: line)
        XCTAssertEqual(state.notes.map(\.id.uuidString), [
            "11111111-1111-4111-8111-111111111111", "22222222-2222-4222-8222-222222222222"
        ], file: file, line: line)
        XCTAssertEqual(state.notes.map(\.project), ["General", "upgrade/second-project"], file: file, line: line)
        XCTAssertEqual(state.notes.map(\.text), [
            "Upgrade fixture: keep this offline note.", "Upgrade fixture: keep the other project separate."
        ], file: file, line: line)
        XCTAssertEqual(state.notes.map(\.source), Array(repeating: "Synthetic prior-install fixture", count: 2), file: file, line: line)
        XCTAssertEqual(state.notes.map(\.savedAt), [Date(timeIntervalSinceReferenceDate: 800_000_000),
                                                  Date(timeIntervalSinceReferenceDate: 800_000_001)], file: file, line: line)
        XCTAssertEqual(state.chats.map(\.id.uuidString), [
            "33333333-3333-4333-8333-333333333333", "44444444-4444-4444-8444-444444444444"
        ], file: file, line: line)
        XCTAssertEqual(state.chats.map(\.project), ["General", "General"], file: file, line: line)
        XCTAssertEqual(state.chats.map(\.role), ["user", "assistant"], file: file, line: line)
        XCTAssertEqual(state.chats.map(\.text), [
            "Upgrade fixture: a saved question, not a model request.",
            "Upgrade fixture: a saved response, not generated inference."
        ], file: file, line: line)
        XCTAssertEqual(state.chats.map(\.date), [Date(timeIntervalSinceReferenceDate: 800_000_002),
                                               Date(timeIntervalSinceReferenceDate: 800_000_003)], file: file, line: line)
    }
}
