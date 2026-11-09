import XCTest
@testable import AsterionVeyra

final class LumaBackupImportTests: XCTestCase {
    private func preview(_ json: String) throws -> ConversationImportPreview {
        try ConversationImporter.preview(Data(json.utf8), kind: .lumaBackup, filename: "Luma.json", project: "General")
    }
    private let valid = #"{"version":1,"memories":[{"id":"m1","text":"A useful note","created":"2026-11-09T09:00:00.123Z"}],"tasks":[{"id":"t1","goal":"Ship","text":"Test","done":false}]}"#
    func testPreviewPreservesNotesAndChecklistWithoutExecuting() throws {
        let result = try preview(valid)
        XCTAssertEqual(result.groups.count, 2)
        XCTAssertEqual(result.missingTimestamps, 1)
        XCTAssertEqual(result.groups[0].memory?.text, "A useful note")
        XCTAssertTrue(result.groups[1].memory!.text.contains("Not completed"))
        XCTAssertTrue(result.groups.allSatisfy { $0.messages.isEmpty })
        XCTAssertEqual(result.groups.map(\.id), try preview(valid).groups.map(\.id))
    }
    func testChangedStatusCreatesExplicitNewSnapshot() throws {
        let changed = valid.replacingOccurrences(of: "false", with: "true")
        XCTAssertNotEqual(try preview(valid).groups[1].id, try preview(changed).groups[1].id)
    }
    func testRejectsDuplicateKeysAndIdentifiers() {
        XCTAssertThrowsError(try preview(valid.replacingOccurrences(of: "\"version\":1", with: "\"version\":1,\"version\":1")))
        XCTAssertThrowsError(try preview(valid.replacingOccurrences(of: "t1", with: "m1")))
    }
    func testRejectsCredentialsAndMalformedRecords() {
        XCTAssertThrowsError(try preview(valid.replacingOccurrences(of: "A useful note", with: "api_key=example")))
        XCTAssertThrowsError(try preview(valid.replacingOccurrences(of: "false", with: "0")))
        XCTAssertThrowsError(try preview(valid.replacingOccurrences(of: "\"version\":1", with: "\"version\":true")))
    }
    func testRejectsOversizeAndUnsupportedEncryptedData() {
        XCTAssertThrowsError(try preview(String(repeating: " ", count: 2_000_001)))
        XCTAssertThrowsError(try preview(#"{"format":"encrypted","ciphertext":"sample"}"#))
        XCTAssertThrowsError(try preview(valid.replacingOccurrences(of: "A useful note", with: String(repeating: "a", count: 4001))))
    }
    func testWorkspaceIdentitySeparatesImports() throws {
        let other = try ConversationImporter.preview(Data(valid.utf8), kind: .lumaBackup, filename: "Luma.json", project: "Other")
        XCTAssertNotEqual(try preview(valid).groups[0].id, other.groups[0].id)
    }
    func testPreviewRequiresExplicitAcknowledgmentAndDeduplicates() throws {
        let result = try preview(valid)
        let ids = Set(result.groups.map(\.id))
        let empty = SavedState(notes: [], chats: [])
        XCTAssertThrowsError(try result.selection(ids: ids, into: empty, acknowledgeRestoringDeleted: false))
        let first = try result.selection(ids: ids, into: empty, acknowledgeRestoringDeleted: true)
        XCTAssertTrue(try result.selection(ids: ids, into: first, acknowledgeRestoringDeleted: true).notes.isEmpty)
    }
}
