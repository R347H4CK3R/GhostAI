import XCTest
@testable import AsterionVeyra

final class ConversationImportTests: XCTestCase {
    private func node(_ id: String, parent: String?, children: [String] = [], role: String = "user", text: String = "A synthetic orchid plan", type: String = "text") -> [String: Any] {
        ["id": id, "parent": parent as Any? ?? NSNull(), "children": children,
         "message": ["id": id, "author": ["role": role], "create_time": 1_700_000_000,
                     "content": ["content_type": type, "parts": [text]]]]
    }
    private func conversation(_ mapping: [String: Any], current: String = "b", id: String = "conversation-1") -> [String: Any] {
        ["id": id, "title": "Synthetic orchid chat", "current_node": current, "mapping": mapping]
    }
    private func parse(_ values: [[String: Any]]) throws -> ConversationImportPreview {
        try ConversationImporter.preview(JSONSerialization.data(withJSONObject: values), kind: .chatGPTConversations, filename: "conversations.json", project: "General")
    }
    private var empty: SavedState { SavedState(notes: [], chats: []) }

    func testActiveBranchPreservesRolesDatesAndProvenanceAndReportsAlternativeBranch() throws {
        let preview = try parse([conversation([
            "a": node("a", parent: nil, children: ["b", "c"]),
            "b": node("b", parent: "a", role: "assistant", text: "Use a shaded window."),
            "c": node("c", parent: "a", role: "assistant", text: "Unselected alternate.")])])
        XCTAssertEqual(preview.groups.count, 1)
        XCTAssertEqual(preview.omittedBranchNodes, 1)
        let state = try preview.selection(ids: Set(preview.groups.map(\.id)), into: empty, acknowledgeRestoringDeleted: true)
        XCTAssertEqual(state.chats.map(\.role), ["user", "assistant"])
        XCTAssertEqual(state.chats.first?.date, Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertTrue(state.chats[0].text.contains("ChatGPT export"))
        XCTAssertTrue(state.chats[0].text.contains("Synthetic orchid chat"))
        XCTAssertFalse(state.chats.contains { $0.text.contains("Unselected alternate") })
    }
    func testFinalMergePreservesBranchOrderWithEqualKnownOrMissingTimestamps() throws {
        for missing in [false, true] {
            var mapping: [String: Any] = [
                "a": node("a", parent: nil, children: ["b"]),
                "b": node("b", parent: "a", role: "assistant")
            ]
            if missing {
                for key in ["a", "b"] {
                    var item = mapping[key] as! [String: Any]
                    var message = item["message"] as! [String: Any]
                    message.removeValue(forKey: "create_time"); item["message"] = message; mapping[key] = item
                }
            }
            let importedAt = Date(timeIntervalSince1970: 1_800_000_000)
            let preview = try ConversationImporter.preview(JSONSerialization.data(withJSONObject: [conversation(mapping)]), kind: .chatGPTConversations, filename: "conversations.json", project: "General", importedAt: importedAt)
            let additions = try preview.selection(ids: Set(preview.groups.map(\.id)), into: empty, acknowledgeRestoringDeleted: true)
            let merged = MemoryBackup.merge(additions, into: empty)
            XCTAssertEqual(merged.chats.map(\.role), ["user", "assistant"])
            XCTAssertEqual(merged.chats.map(\.id), additions.chats.map(\.id))
            XCTAssertEqual(merged.chats.map(\.date), Array(repeating: missing ? importedAt : Date(timeIntervalSince1970: 1_700_000_000), count: 2))
            let repeated = MemoryBackup.merge(additions, into: merged)
            XCTAssertEqual(repeated.chats.map(\.id), merged.chats.map(\.id))
        }
    }
    func testIdentifierRequiresEveryScalarToBeAllowedASCII() throws {
        for suffix in ["\n", "\r", "\r\n", "\u{2028}", "\u{2029}", " ", "é", "\0"] {
            XCTAssertThrowsError(try ConversationImportPolicy.identifier("node" + suffix))
        }
        XCTAssertThrowsError(try ConversationImportPolicy.identifier(""))
        XCTAssertThrowsError(try ConversationImportPolicy.identifier(String(repeating: "a", count: 201)))
        XCTAssertEqual(try ConversationImportPolicy.identifier("node_ABC-012"), "node_ABC-012")
    }
    func testReimportKeepsExistingRecordsAndRequiresExplicitRestoreAcknowledgment() throws {
        let preview = try parse([conversation(["b": node("b", parent: nil)])])
        let ids = Set(preview.groups.map(\.id))
        XCTAssertThrowsError(try preview.selection(ids: ids, into: empty, acknowledgeRestoringDeleted: false))
        let first = try preview.selection(ids: ids, into: empty, acknowledgeRestoringDeleted: true)
        let again = try parse([conversation(["b": node("b", parent: nil, text: "Changed source")])])
        XCTAssertTrue(try again.selection(ids: ids, into: first, acknowledgeRestoringDeleted: true).chats.isEmpty)
        XCTAssertEqual(first.chats[0].text.components(separatedBy: "\n\n").last, "A synthetic orchid plan")
    }
    func testMalformedCyclesMissingParentsAndCurrentNodeFailClosed() throws {
        let cycle = conversation(["a": node("a", parent: "b", children: ["b"]), "b": node("b", parent: "a", children: ["a"])])
        let dangling = conversation(["b": node("b", parent: "missing")], id: "second")
        let missingCurrent = conversation(["a": node("a", parent: nil)], id: "third")
        let preview = try parse([cycle, dangling, missingCurrent])
        XCTAssertTrue(preview.groups.isEmpty)
        XCTAssertEqual(preview.skipped[.malformedConversation], 3)
    }
    func testDuplicateConversationMessageAndJSONKeysAreRejected() throws {
        let value = conversation(["b": node("b", parent: nil)])
        XCTAssertThrowsError(try parse([value, value]))
        var second = node("b", parent: "a")
        second["message"] = (node("a", parent: nil)["message"] as! [String: Any])
        XCTAssertTrue(try parse([conversation(["a": node("a", parent: nil, children: ["b"]), "b": second])]).groups.isEmpty)
        let duplicate = Data("[{\"id\":\"one\",\"id\":\"two\"}]".utf8)
        XCTAssertThrowsError(try ConversationImporter.preview(duplicate, kind: .chatGPTConversations, filename: "conversations.json", project: "General"))
        let escapedDuplicate = Data("[{\"id\":\"one\",\"\\u0069d\":\"two\"}]".utf8)
        XCTAssertThrowsError(try ConversationImporter.preview(escapedDuplicate, kind: .chatGPTConversations, filename: "conversations.json", project: "General"))
    }
    func testUnsupportedRolesAndModalitiesAreReportedNotFetchedOrFlattened() throws {
        let preview = try parse([conversation([
            "a": node("a", parent: nil, children: ["b"], role: "system"),
            "b": node("b", parent: "a", children: ["c"], text: "https://example.invalid/image", type: "multimodal_text"),
            "c": node("c", parent: "b", role: "assistant")], current: "c")])
        XCTAssertEqual(preview.skipped[.unsupportedRole], 1)
        XCTAssertEqual(preview.skipped[.unsupportedContent], 1)
        XCTAssertEqual(preview.groups[0].messages.count, 1)
    }
    func testPossibleCredentialsRejectWholeConversationWithoutEchoingContent() throws {
        let preview = try parse([conversation(["b": node("b", parent: nil, text: "Authorization: Bearer synthetic-private-value")])])
        XCTAssertTrue(preview.groups.isEmpty)
        XCTAssertEqual(preview.skipped[.unsafeContent], 1)
        XCTAssertFalse(String(describing: preview.skipped).contains("synthetic-private-value"))
    }
    func testBoundsNeverSilentlyTruncateAndRequireSubsetForCanonicalLimit() throws {
        XCTAssertThrowsError(try ConversationImporter.preview(Data(repeating: 32, count: ConversationImportPolicy.maximumFileBytes + 1), kind: .chatGPTConversations, filename: "conversations.json", project: "General"))
        let long = try parse([conversation(["b": node("b", parent: nil, text: String(repeating: "x", count: 100_001))])])
        XCTAssertTrue(long.groups.isEmpty)
        let preview = try parse([conversation(["b": node("b", parent: nil)])])
        let current = SavedState(notes: [], chats: (0..<10_000).map { _ in ChatEntry(project: "General", role: "user", text: "synthetic") })
        XCTAssertThrowsError(try preview.selection(ids: Set(preview.groups.map(\.id)), into: current, acknowledgeRestoringDeleted: true))
        XCTAssertThrowsError(try preview.selection(ids: [UUID()], into: empty, acknowledgeRestoringDeleted: true))
    }
    func testMemoryTextIsOneExplicitUserNoteAndKnownJSONOnly() throws {
        let preview = try ConversationImporter.preview(Data("I prefer concise project updates.".utf8), kind: .memoryText, filename: "memory.txt", project: "General")
        let state = try preview.selection(ids: Set(preview.groups.map(\.id)), into: empty, acknowledgeRestoringDeleted: true)
        XCTAssertEqual(state.notes.count, 1)
        XCTAssertTrue(state.notes[0].source.contains("User-provided"))
        XCTAssertTrue(state.chats.isEmpty)
        let json = Data(#"{"format":"asterion-memory-import","version":1,"memories":[{"id":"synthetic-1","text":"I enjoy orchids.","saved_at":"2025-01-01T00:00:00Z"}]}"#.utf8)
        let known = try ConversationImporter.preview(json, kind: .memoryJSON, filename: "memories.json", project: "General")
        XCTAssertEqual(known.groups.count, 1)
        XCTAssertThrowsError(try ConversationImporter.preview(Data(#"{"memories":["unknown schema"]}"#.utf8), kind: .memoryJSON, filename: "memories.json", project: "General"))
    }
    func testWrongExtensionDeepJSONAndInvalidDatesAreNotAccepted() throws {
        XCTAssertThrowsError(try ConversationImporter.preview(Data("[]".utf8), kind: .chatGPTConversations, filename: "export.zip", project: "General"))
        XCTAssertThrowsError(try ConversationImporter.preview(Data((String(repeating: "[", count: 70) + "0" + String(repeating: "]", count: 70)).utf8), kind: .chatGPTConversations, filename: "conversations.json", project: "General"))
        var malformed = node("b", parent: nil)
        var message = malformed["message"] as! [String: Any]; message["create_time"] = true; malformed["message"] = message
        XCTAssertTrue(try parse([conversation(["b": malformed])]).groups.isEmpty)
    }
    func testMissingTimestampIsVisibleAndUsesExplicitImportTime() throws {
        var messageNode = node("b", parent: nil)
        var message = messageNode["message"] as! [String: Any]
        message.removeValue(forKey: "create_time"); messageNode["message"] = message
        let importedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let preview = try ConversationImporter.preview(JSONSerialization.data(withJSONObject: [conversation(["b": messageNode])]), kind: .chatGPTConversations, filename: "conversations.json", project: "General", importedAt: importedAt)
        XCTAssertEqual(preview.missingTimestamps, 1)
        XCTAssertEqual(preview.groups[0].messages[0].date, importedAt)
        XCTAssertTrue(preview.groups[0].messages[0].text.contains("Source timestamp: unavailable; local import date used"))
    }
    func testFileNameDoesNotAffectIDsAndProjectIsolationDoes() throws {
        let bytes = try JSONSerialization.data(withJSONObject: [conversation(["b": node("b", parent: nil)])])
        let first = try ConversationImporter.preview(bytes, kind: .chatGPTConversations, filename: "conversations.json", project: "General")
        let numbered = try ConversationImporter.preview(bytes, kind: .chatGPTConversations, filename: "conversations-2.json", project: "General")
        let other = try ConversationImporter.preview(bytes, kind: .chatGPTConversations, filename: "conversations.json", project: "Other")
        XCTAssertEqual(first.groups[0].messages[0].id, numbered.groups[0].messages[0].id)
        XCTAssertNotEqual(first.groups[0].messages[0].id, other.groups[0].messages[0].id)
    }
    func testDisconnectedCycleIsRejectedEvenOutsideTheSelectedBranch() throws {
        let value = conversation([
            "b": node("b", parent: nil),
            "c": node("c", parent: "d", children: ["d"]),
            "d": node("d", parent: "c", children: ["c"])
        ])
        let preview = try parse([value])
        XCTAssertTrue(preview.groups.isEmpty)
        XCTAssertEqual(preview.skipped[.malformedConversation], 1)
    }
    func testHTMLIsPreservedOnlyAsInertPlainTextAndMixedPartsAreNotFlattened() throws {
        let html = "<script>synthetic()</script><a href='https://example.invalid'>test</a>"
        let plain = try parse([conversation(["b": node("b", parent: nil, text: html)])])
        XCTAssertTrue(plain.groups[0].messages[0].text.hasSuffix(html))
        var mixed = node("b", parent: nil)
        var message = mixed["message"] as! [String: Any]
        message["content"] = ["content_type": "text", "parts": ["synthetic text", ["asset_pointer": "https://example.invalid"]] as [Any]]
        mixed["message"] = message
        let rejected = try parse([conversation(["b": mixed])])
        XCTAssertTrue(rejected.groups.isEmpty)
        XCTAssertEqual(rejected.skipped[.unsupportedContent], 1)
    }
    func testCredentialLikeIdentifiersCannotEnterProvenance() throws {
        let preview = try parse([conversation(["b": node("b", parent: nil)], id: "ghp_synthetic-not-a-real-token")])
        XCTAssertTrue(preview.groups.isEmpty)
        XCTAssertEqual(preview.skipped[.unsafeContent], 1)
        XCTAssertThrowsError(try ConversationImportPolicy.identifier("github_pat_synthetic-not-a-real-token"))
    }
    func testPerFileConversationCountAndMemorySchemaTypesAreBounded() throws {
        let records = (0...ConversationImportPolicy.maximumConversations).map {
            conversation(["b": node("b", parent: nil)], id: "conversation-\($0)")
        }
        XCTAssertThrowsError(try parse(records))
        for json in [
            #"{"format":"asterion-memory-import","version":true,"memories":[]}"#,
            #"{"format":"asterion-memory-import","version":1,"memories":[],"unknown":true}"#,
            #"{"format":"asterion-memory-import","version":1,"memories":[{"id":"same","text":"One"},{"id":"same","text":"Two"}]}"#
        ] {
            XCTAssertThrowsError(try ConversationImporter.preview(Data(json.utf8), kind: .memoryJSON, filename: "memories.json", project: "General"))
        }
    }

}
