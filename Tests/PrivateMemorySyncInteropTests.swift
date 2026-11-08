import XCTest
@testable import AsterionVeyra

/// Synthetic inputs only. Foundation/CryptoKit are the oracle; portable tools must
/// never generate a replacement expected record encoding or rewrite this protocol.
final class PrivateMemorySyncInteropTests: XCTestCase {
    private let repositoryID = 12345
    private let identifier = UUID(uuidString: "aBcDeF01-2345-4aBc-8dEf-0123456789aB")!
    private let date = Date(timeIntervalSinceReferenceDate: 721_692_800.0000001)

    private func empty() -> PrivateMemorySyncDocument { .empty(repositoryID: repositoryID) }
    private func note(_ text: String) -> MemoryNote {
        MemoryNote(id: identifier, project: "General", text: text, source: "Synthetic fixture", savedAt: date)
    }
    private func chat(_ text: String) -> ChatEntry {
        ChatEntry(id: identifier, project: "General", role: "user", text: text, date: date)
    }
    private func encoded<T: Encodable>(_ value: T) throws -> String {
        try PrivateMemorySyncPolicy.canonical(value).base64EncodedString()
    }
    private func bits(_ value: Date) -> String {
        String(format: "%016llx", value.timeIntervalSinceReferenceDate.bitPattern)
    }
    private func jsonString(_ value: String) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: [value], options: [.fragmentsAllowed])
        return String(decoding: data, as: UTF8.self).dropFirst().dropLast().description
    }
    private func noteInput(text: String, seconds: String) throws -> Data {
        Data("{\"id\":\"aBcDeF01-2345-4aBc-8dEf-0123456789aB\",\"project\":\"General\",\"text\":\(try jsonString(text)),\"source\":\"Synthetic fixture\",\"savedAt\":\(seconds)}".utf8)
    }

    private func records() throws -> [[String: Any]] {
        // Number spellings are inputs, not predictions of JSONEncoder's output.
        let dates: [(String, String)] = [
            ("integer", "0"), ("negative-zero", "-0"), ("negative-fraction", "-0.5"),
            ("fraction", "0.125"), ("smallest-positive", "5e-324"), ("smallest-negative", "-5e-324"),
            ("small-exponent", "1e-7"), ("decimal-threshold", "0.000001"),
            ("present-next-up", "721692800.0000001"),
            ("unix-lower-bound", "-978307200"), ("unix-upper-bound", "252423993599")
        ]
        let strings: [(String, String)] = [
            ("escapes", "slash/ quote\" backslash\\ tab\t newline\n carriage\r nul\u{0} backspace\u{8}"),
            ("nfc", "Caf\u{e9}"), ("nfd", "Cafe\u{301}"),
            ("supplementary", "🧭 𝄞 中文"), ("separators", "one\u{2028}two\u{2029}three")
        ]
        var result: [[String: Any]] = []
        for (name, seconds) in dates {
            let input = try noteInput(text: "Synthetic date", seconds: seconds)
            let value = try JSONDecoder().decode(MemoryNote.self, from: input)
            XCTAssertTrue(PrivateMemorySyncPolicy.validDate(value.savedAt), name)
            result.append(["name": "date-" + name, "kind": "note", "inputBase64": input.base64EncodedString(),
                           "canonicalBase64": try encoded(value), "dateBits": bits(value.savedAt)])
        }
        for (name, text) in strings {
            let input = try noteInput(text: text, seconds: "721692800.0000001")
            let value = try JSONDecoder().decode(MemoryNote.self, from: input)
            result.append(["name": "string-" + name, "kind": "note", "inputBase64": input.base64EncodedString(),
                           "canonicalBase64": try encoded(value), "dateBits": bits(value.savedAt)])
        }
        for (name, suffix) in [("omitted", ""), ("null", ",\"revision\":null,\"repositoryName\":null"),
                               ("empty", ",\"revision\":\"\",\"repositoryName\":\"\"")] {
            let input = Data("{\"origin\":\"selectedFile\",\"label\":\"a.txt\"\(suffix)}".utf8)
            let value = try JSONDecoder().decode(KnowledgeSource.self, from: input)
            result.append(["name": "optional-" + name, "kind": "knowledgeSource", "inputBase64": input.base64EncodedString(),
                           "canonicalBase64": try encoded(value)])
        }
        return result
    }

    private func conflicts() throws -> [[String: Any]] {
        var vectors: [[String: Any]] = []
        for kind in ["note", "chat"] {
            var left = empty(), right = empty()
            if kind == "note" { left.notes = [note("Alpha")]; right.notes = [note("Zulu")] }
            else { left.chats = [chat("Alpha")]; right.chats = [chat("Zulu")] }
            let merged = try PrivateMemorySyncMerge.merge(base: empty(), local: left, remote: right)
            let reversed = try PrivateMemorySyncMerge.merge(base: empty(), local: right, remote: left)
            XCTAssertEqual(try merged.encoded(), try reversed.encoded())
            let ids = kind == "note" ? merged.notes.map(\.id) : merged.chats.map(\.id)
            XCTAssertEqual(ids.count, 2)
            let conflict = try XCTUnwrap(ids.first { $0 != identifier })
            let a = kind == "note" ? try PrivateMemorySyncPolicy.canonical(left.notes[0]) : try PrivateMemorySyncPolicy.canonical(left.chats[0])
            let b = kind == "note" ? try PrivateMemorySyncPolicy.canonical(right.notes[0]) : try PrivateMemorySyncPolicy.canonical(right.chats[0])
            vectors.append(["kind": kind, "originalID": identifier.uuidString.lowercased(),
                            "loserCanonicalBase64": (a.lexicographicallyPrecedes(b) ? b : a).base64EncodedString(),
                            "expectedID": conflict.uuidString.lowercased(), "mergedBase64": try merged.encoded().base64EncodedString(),
                            "reversedBase64": try reversed.encoded().base64EncodedString()])
        }
        return vectors
    }

    private func restorations() throws -> [[String: Any]] {
        var vectors: [[String: Any]] = []
        for kind in ["note", "chat"] {
            let incoming = SavedState(notes: kind == "note" ? [note("Restoration")] : [],
                                      chats: kind == "chat" ? [chat("Restoration")] : [])
            var history = empty()
            var currentID = identifier
            for generation in 1...3 {
                history.tombstones.append(kind + ":" + currentID.uuidString.lowercased())
                let restored = try PrivateMemorySyncRestore.prepare(incoming, current: SavedState(notes: [], chats: []), history: history)
                currentID = kind == "note" ? restored.notes[0].id : restored.chats[0].id
                XCTAssertEqual(history.tombstones.count, generation)
                XCTAssertFalse(history.tombstones.contains(kind + ":" + currentID.uuidString.lowercased()))
                vectors.append(["kind": kind, "originalID": identifier.uuidString.lowercased(), "generation": generation,
                                "tombstones": history.tombstones, "expectedID": currentID.uuidString.lowercased()])
            }
        }
        return vectors
    }

    private func documents() throws -> [[String: Any]] {
        let identifiers = ["ffffffff-ffff-4fff-8fff-ffffffffffff", "11111111-1111-4111-8111-111111111111", "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"]
        var local = empty()
        local.chats = identifiers.enumerated().map { index, id in
            ChatEntry(id: UUID(uuidString: id)!, project: "General", role: index == 1 ? "assistant" : "user", text: "Synthetic turn \(index)", date: date)
        }
        local.chatOrder = local.chats.map(\.id)
        local.notes = [note("Synthetic document")]
        let merged = try PrivateMemorySyncMerge.merge(base: empty(), local: local, remote: empty())
        XCTAssertEqual(merged.chatOrder, local.chatOrder)
        let decoded = try PrivateMemorySyncDocument.decode(merged.encoded(), repositoryID: repositoryID)
        XCTAssertEqual(decoded.chatOrder, local.chatOrder)
        return [["name": "equal-date-chat-order", "inputBase64": try encoded(local),
                 "normalizedBase64": try merged.encoded().base64EncodedString(),
                 "chatOrder": identifiers.map { $0.uppercased() }]]
    }

    private func unicodeProbes() throws -> [[String: Any]] {
        var left = empty(), right = empty()
        left.chats = [chat("Caf\u{e9}")]; right.chats = [chat("Cafe\u{301}")]
        right.chats[0].date = date.addingTimeInterval(1)
        let forward = try PrivateMemorySyncMerge.merge(base: empty(), local: left, remote: right).encoded()
        let reverse = try PrivateMemorySyncMerge.merge(base: empty(), local: right, remote: left).encoded()
        var probes: [[String: Any]] = [["name": "canonically-equivalent-chat", "leftBase64": try encoded(left),
            "rightBase64": try encoded(right), "forwardBase64": forward.base64EncodedString(),
            "reverseBase64": reverse.base64EncodedString(), "converges": forward == reverse]]
        // Equal UTF-8 length and canonically equivalent, but different scalar order.
        // Also include an ordinary equal-length tie to establish normal behavior.
        for (name, a, b) in [("filename-ascii-tie", "a.txt", "z.txt"),
                              ("filename-unicode-tie", "a\u{301}\u{327}.txt", "a\u{327}\u{301}.txt")] {
            func entry(_ label: String) throws -> KnowledgeEntry {
                let text = "Synthetic shared file", digest = KnowledgePolicy.digest(text)
                let raw = "{\"origin\":\"selectedFile\",\"label\":\(try jsonString(label)),\"revision\":\"\(digest)\"}"
                let source = try JSONDecoder().decode(KnowledgeSource.self, from: Data(raw.utf8))
                return KnowledgeEntry(id: "file:" + digest, kind: .selectedFile, text: text, source: source,
                                      sourceDate: date, cachedAt: date, byteCount: text.utf8.count)
            }
            let first = try entry(a), second = try entry(b)
            let f = try PrivateMemorySyncPolicy.canonical(first.mergedSyncCopy(second))
            let r = try PrivateMemorySyncPolicy.canonical(second.mergedSyncCopy(first))
            probes.append(["name": name, "leftBase64": try encoded(first), "rightBase64": try encoded(second),
                           "forwardBase64": f.base64EncodedString(), "reverseBase64": r.base64EncodedString(), "converges": f == r])
        }
        return probes
    }

    private func malformedDateProbes() throws -> [[String: Any]] {
        var probes: [[String: Any]] = []
        for value in ["true", "null", "\"0\"", "NaN", "Infinity", "1e999", "-978307201", "252423993600"] {
            let input = try noteInput(text: "Synthetic invalid date", seconds: value)
            let decoded = try? JSONDecoder().decode(MemoryNote.self, from: input)
            probes.append(["name": value, "inputBase64": input.base64EncodedString(), "decodes": decoded != nil,
                           "validDate": decoded.map { PrivateMemorySyncPolicy.validDate($0.savedAt) } ?? false])
        }
        return probes
    }

    private func malformedDocumentProbes() throws -> [[String: Any]] {
        let original = String(decoding: try empty().encoded(), as: UTF8.self)
        let inputs: [(String, String)] = [
            ("duplicate-version-same", original.replacingOccurrences(of: "\"version\":1", with: "\"version\":1,\"version\":1")),
            ("duplicate-version-different", original.replacingOccurrences(of: "\"version\":1", with: "\"version\":1,\"version\":2")),
            ("unknown-nested-65", String(original.dropLast()) + ",\"unknown\":" + String(repeating: "[", count: 65) + "0" + String(repeating: "]", count: 65) + "}"),
            ("unknown-nested-513", String(original.dropLast()) + ",\"unknown\":" + String(repeating: "[", count: 513) + "0" + String(repeating: "]", count: 513) + "}")
        ]
        return inputs.map { name, input in
            let data = Data(input.utf8)
            return ["name": name, "inputBase64": data.base64EncodedString(),
                    "accepted": (try? PrivateMemorySyncDocument.decode(data, repositoryID: repositoryID)) != nil]
        }
    }

    private func knowledgeProbes() throws -> [[String: Any]] {
        let text = "synthetic file", digest = KnowledgePolicy.digest("synthetic file")
        let sourceJSON = "{\"origin\":\"selectedFile\",\"label\":\"sample.txt\",\"revision\":\"\(digest)\"}"
        let source = try JSONDecoder().decode(KnowledgeSource.self, from: Data(sourceJSON.utf8))
        func document(cachedAt: Double?, suppressed: Bool = false, clearBefore: Double? = nil) throws -> PrivateMemorySyncDocument {
            let entries = cachedAt.map { seconds in
                [KnowledgeEntry(id: "file:" + digest, kind: .selectedFile, text: text, source: source,
                                sourceDate: Date(timeIntervalSinceReferenceDate: 0),
                                cachedAt: Date(timeIntervalSinceReferenceDate: seconds), byteCount: text.utf8.count)]
            } ?? []
            let snapshot = KnowledgeSyncSnapshot(accountID: "device-local", project: "General", repository: nil,
                entries: entries, suppressedIDs: suppressed ? ["file:" + digest] : [],
                clearBefore: clearBefore.map { Date(timeIntervalSinceReferenceDate: $0) })
            _ = try snapshot.validated()
            var result = empty(); result.knowledge = [snapshot]
            try result.validate()
            return result
        }
        func merge(_ left: PrivateMemorySyncDocument, _ right: PrivateMemorySyncDocument) throws -> PrivateMemorySyncDocument {
            try PrivateMemorySyncMerge.merge(base: empty(), local: left, remote: right)
        }
        let overlap = try document(cachedAt: 100, suppressed: true)
        let once = try merge(overlap, empty()).encoded()
        let twice = try merge(overlap, overlap).encoded()
        let original = try overlap.encoded()
        let identity = try PrivateMemorySyncMerge.merge(base: overlap, local: overlap, remote: overlap).encoded()
        let a = try document(cachedAt: 100), b = try document(cachedAt: 200), c = try document(cachedAt: nil, clearBefore: 150)
        let leftGrouped = try merge(merge(a, b), c).encoded()
        let rightGrouped = try merge(a, merge(b, c)).encoded()
        return [
            ["name": "knowledge-suppressed-idempotence", "acceptedInput": true,
             "inputBase64": original.base64EncodedString(), "forwardBase64": once.base64EncodedString(),
             "reverseBase64": twice.base64EncodedString(), "converges": once == twice],
            ["name": "knowledge-suppressed-identity", "acceptedInput": true,
             "inputBase64": original.base64EncodedString(), "forwardBase64": original.base64EncodedString(),
             "reverseBase64": identity.base64EncodedString(), "converges": original == identity],
            ["name": "knowledge-clear-grouping", "acceptedInputs": true,
             "leftInputBase64": try a.encoded().base64EncodedString(), "middleInputBase64": try b.encoded().base64EncodedString(),
             "rightInputBase64": try c.encoded().base64EncodedString(), "forwardBase64": leftGrouped.base64EncodedString(),
             "reverseBase64": rightGrouped.base64EncodedString(), "converges": leftGrouped == rightGrouped]
        ]
    }

    private func deterministicVectors() throws -> [String: Any] {
        ["records": try records(), "conflicts": try conflicts(), "restorations": try restorations(),
         "documents": try documents(), "unicodeProbes": try unicodeProbes(), "malformedDates": try malformedDateProbes(), "malformedDocuments": try malformedDocumentProbes(), "knowledgeProbes": try knowledgeProbes()]
    }

    func testExportSyntheticNativeGoldenVectors() throws {
        var fixture = try deterministicVectors()
        fixture["format"] = "veyra-private-sync-interop-v1"
        fixture["status"] = "native-export"
        fixture["producer"] = ["runtime": ProcessInfo.processInfo.operatingSystemVersionString,
                               "oracle": "Unchanged Veyra Swift Foundation and CryptoKit implementation"]
        var envelopes: [[String: String]] = []
        let raw = try empty().encoded()
        for passphrase in ["Synthetic recovery words only", "  Synthetic Caf\u{e9} 🧭 recovery  ", "  Synthetic Cafe\u{301} 🧭 recovery  "] {
            let encrypted = try EncryptedMemoryTransfer.encryptSyncPayload(raw, passphrase: passphrase)
            XCTAssertEqual(try EncryptedMemoryTransfer.decryptSyncPayload(encrypted, passphrase: passphrase), raw)
            envelopes.append(["passphrase": passphrase, "plaintextBase64": raw.base64EncodedString(), "encryptedBase64": encrypted.base64EncodedString()])
        }
        fixture["envelopes"] = envelopes
        let data = try JSONSerialization.data(withJSONObject: fixture, options: [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes])
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = "private-memory-sync-interop-v1.json"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testCommittedNativeGoldenVectorsMatchThisRuntime() throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "private-memory-sync-interop-v1", withExtension: "json"))
        let fixture = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        guard fixture["format"] as? String == "veyra-private-sync-interop-v1" else {
            XCTFail("Unrecognized native fixture format"); return
        }
        if fixture["status"] as? String == "pending-native-export" {
            throw XCTSkip("Native vectors have not been exported. This is not an interoperability release pass.")
        }
        guard fixture["status"] as? String == "native-export" else {
            XCTFail("Invalid native fixture status"); return
        }
        for (key, value) in try deterministicVectors() {
            let expected = try XCTUnwrap(fixture[key], key)
            XCTAssertEqual(try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
                           try JSONSerialization.data(withJSONObject: expected, options: [.sortedKeys]), key)
        }
        for vector in try XCTUnwrap(fixture["envelopes"] as? [[String: String]]) {
            let encrypted = try XCTUnwrap(Data(base64Encoded: XCTUnwrap(vector["encryptedBase64"])))
            let plaintext = try XCTUnwrap(Data(base64Encoded: XCTUnwrap(vector["plaintextBase64"])))
            XCTAssertEqual(try EncryptedMemoryTransfer.decryptSyncPayload(encrypted, passphrase: XCTUnwrap(vector["passphrase"])), plaintext)
        }
    }
}
