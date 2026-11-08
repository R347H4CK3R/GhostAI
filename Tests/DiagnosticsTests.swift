import XCTest
@testable import AsterionVeyra

final class DiagnosticsTests: XCTestCase {
    func testThreeDayForegroundCadence() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertTrue(DiagnosticChecks.isDue(lastRun: nil, now: now))
        XCTAssertFalse(DiagnosticChecks.isDue(lastRun: now.addingTimeInterval(-259_199), now: now))
        XCTAssertTrue(DiagnosticChecks.isDue(lastRun: now.addingTimeInterval(-259_200), now: now))
        XCTAssertTrue(DiagnosticChecks.isDue(lastRun: now.addingTimeInterval(1), now: now))
    }
    func testSyntheticHelpersPass() {
        XCTAssertEqual(DiagnosticChecks.serialization(), .pass)
        XCTAssertEqual(DiagnosticChecks.backup(), .pass)
        XCTAssertEqual(DiagnosticChecks.credentialFilter(), .pass)
    }
    func testStorageUsesAndRemovesThrowawayDirectory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        XCTAssertEqual(DiagnosticChecks.storage(in: root), .pass)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }
    func testStorageFailureIsOnlyAStatus() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("private sentinel".utf8).write(to: file)
        XCTAssertEqual(DiagnosticChecks.storage(in: file), .fail)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "private sentinel")
    }
    @MainActor func testFailedReportSaveDoesNotAdvertiseAFile() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("private sentinel".utf8).write(to: file)
        let controller = DiagnosticsController(reportDirectory: file)
        controller.runChecks()
        XCTAssertNil(controller.reportURL)
        XCTAssertFalse(controller.status.contains(file.path))
        XCTAssertFalse(controller.isRunning)
    }
    @MainActor func testReportHasOnlyAllowlistedMetadataAndStatuses() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "diagnostics-tests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = DiagnosticsController(reportDirectory: root, defaults: defaults)
        controller.runChecks()
        let url = try XCTUnwrap(controller.reportURL)
        let data = try Data(contentsOf: url)
        let report = try JSONDecoder().decode(DiagnosticReport.self, from: data)
        XCTAssertEqual(report.checks.modelGeneration, .notRun)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(object.keys), Set(["schemaVersion", "appVersion", "iosVersion", "checks"]))
        let checks = try XCTUnwrap(object["checks"] as? [String: String])
        XCTAssertEqual(Set(checks.keys), Set(["storage", "serialization", "backup", "credentialFilter", "modelAvailability", "modelGeneration", "speechAvailability", "onDeviceSpeech", "speechPermission", "microphonePermission", "recording", "repositoryUpload"]))
        XCTAssertTrue(checks.values.allSatisfy { ["pass", "fail", "not_run", "unavailable"].contains($0) })
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains(root.path))
        let before = data
        controller.runIfDue()
        XCTAssertEqual(try Data(contentsOf: url), before)
    }
}
