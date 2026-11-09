import XCTest
import CryptoKit
@testable import AsterionVeyra

/// Synthetic-only tests. No changes to native v1 golden vectors or writers.
final class ChatStateV2Tests: XCTestCase {
    private typealias V = ChatStateV2
    private let engine = V.Engine()
    private let root = UUID(uuidString: "abcdef01-2345-4abc-8def-0123456789ab")!
    private let origin = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
    private let batch = UUID(uuidString: "00000000-0000-4000-8000-000000000002")!
    private func payload(_ text: String, project: String = "General", role: V.Role = .user) -> V.Payload {
        V.Payload(project: project, role: role, text: text)
    }
    private func key(_ text: String) throws -> V.ContentKey { try engine.contentKey(payload(text)) }
    private func order(_ sequence: UInt64 = 0, counter: UInt64 = 0) -> V.OrderKey {
        V.OrderKey(counter: counter, originID: origin, batchID: batch, sequence: sequence)
    }
    private func variant(_ text: String, _ date: Double) throws -> V.Variant {
        let body = payload(text)
        return V.Variant(contentKey: try engine.contentKey(body), payload: body, dateBits: try V.DateBits(date))
    }
    private func family(_ variants: [V.Variant], id: UUID? = nil, anchor: String = "X", orderKey: V.OrderKey? = nil) throws -> V.Family {
        V.Family(familyID: id ?? root, anchorContentKey: try key(anchor), orderKey: orderKey ?? order(), variants: variants)
    }
    private func state(_ variants: [V.Variant]) throws -> V.Validated {
        try engine.validate(V.State(families: [family(variants)]))
    }
    private func permutations<T>(_ values: [T]) -> [[T]] {
        if values.isEmpty { return [[]] }
        return values.indices.flatMap { i in
            var rest = values; let first = rest.remove(at: i)
            return permutations(rest).map { [first] + $0 }
        }
    }
    private func assertACI(_ states: [V.Validated], engine e: V.Engine? = nil, file: StaticString = #filePath, line: UInt = #line) throws {
        let e = e ?? engine
        let expected = try e.join(e.join(states[0], states[1]), states[2])
        for p in permutations(states) {
            XCTAssertEqual(try e.join(e.join(p[0], p[1]), p[2]), expected, file: file, line: line)
            XCTAssertEqual(try e.join(p[0], e.join(p[1], p[2])), expected, file: file, line: line)
        }
        XCTAssertEqual(try e.join(expected, expected), expected, file: file, line: line)
        XCTAssertEqual(try e.join(expected, e.validate(V.State())), expected, file: file, line: line)
        XCTAssertEqual(try e.project(e.validate(expected.state)), e.project(expected), file: file, line: line)
    }
    private func assertError<T>(_ expected: V.Failure, _ body: @autoclosure () throws -> T, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try body(), file: file, line: line) {
            XCTAssertEqual($0 as? V.Failure, expected, file: file, line: line)
        }
    }

    // Test-evidence schema only, deliberately separate from any vault/wire codec.
    // UTF-8 and binary64 travel as hex; JSON number/string behavior cannot fold
    // Unicode, round a counter, or erase negative zero in this attachment.
    private func evidencePayload(_ body: V.Payload) -> [String: String] {
        func hex(_ value: String) -> String { value.utf8.map { String(format: "%02x", $0) }.joined() }
        return ["projectUTF8": hex(body.project), "roleUTF8": hex(body.role.rawValue), "textUTF8": hex(body.text)]
    }
    private func evidenceReference(_ ref: V.Reference) -> [String: String] {
        ["familyID": ref.familyID.uuidString.lowercased(), "contentKey": ref.contentKey.hex,
         "projectedID": ref.projectedID.uuidString.lowercased()]
    }
    private func evidenceState(_ state: V.State) -> [String: Any] {
        let families: [[String: Any]] = state.families.map { family in
            let variants: [[String: Any]] = family.variants.map { variant in
                ["contentKey": variant.contentKey.hex, "payload": evidencePayload(variant.payload), "dateBits": variant.dateBits.hex]
            }
            let order = family.orderKey
            return ["familyID": family.familyID.uuidString.lowercased(), "anchorContentKey": family.anchorContentKey.hex,
                    "orderKey": ["counter": String(order.counter), "originID": order.originID.uuidString.lowercased(),
                                 "batchID": order.batchID.uuidString.lowercased(), "sequence": String(order.sequence)],
                    "variants": variants]
        }
        return ["format": state.format, "identityScheme": state.identityScheme, "orderClock": String(state.orderClock),
                "families": families, "familyDeletes": state.familyDeletes.map { $0.uuidString.lowercased() },
                "variantDeletes": state.variantDeletes.map(evidenceReference),
                "chatTombstones": state.chatTombstones.map { $0.uuidString.lowercased() }]
    }
    private func evidenceResult(_ name: String, _ state: V.Validated) -> [String: Any] {
        let rows: [[String: Any]] = engine.project(state).map { row in
            ["reference": evidenceReference(row.reference), "payload": evidencePayload(row.payload), "dateBits": row.dateBits.hex]
        }
        return ["name": name, "state": evidenceState(state.state), "projection": rows]
    }
    private func evidenceInputs() throws -> [(String, [V.State])] {
        func bodyVariant(_ body: V.Payload, _ date: Double) throws -> V.Variant {
            V.Variant(contentKey: try engine.contentKey(body), payload: body, dateBits: try V.DateBits(date))
        }
        let nfc = try bodyVariant(payload("café", role: .assistant), -0.0)
        let plus = try bodyVariant(payload("café", role: .assistant), 0.0)
        let nfd = try bodyVariant(payload("cafe\u{301}", role: .assistant), Double.leastNonzeroMagnitude)
        let escaped = try bodyVariant(payload("\0😀\n", project: "😀"), 1.0.nextUp)
        let small = V.OrderKey(counter: 1, originID: batch, batchID: origin, sequence: 9)
        let large = V.OrderKey(counter: 2, originID: origin, batchID: batch, sequence: 0)
        func unicode(_ variants: [V.Variant], _ order: V.OrderKey, _ clock: UInt64) -> V.State {
            V.State(orderClock: clock, families: [V.Family(familyID: root, anchorContentKey: nfc.contentKey,
                                                         orderKey: order, variants: variants)])
        }
        let f0 = try family([variant("X", 100)], id: UUID(uuidString: "00000000-0000-4000-8000-000000000000")!)
        let f1 = try family([variant("X", 100)], id: origin, orderKey: order(1))
        let x100 = try family([variant("X", 100)]), x200 = try family([variant("X", 200)])
        let xy = try family([variant("X", 100), variant("Y", 150)])
        let laterXY = try family([variant("X", 200), variant("Y", 150)])
        let stale = try V.State(families: [family([variant("X", 200), variant("Y", 150), variant("Z", 99)])])
        return [
            ("unicode", [unicode([nfc], small, 3), unicode([plus, nfd], large, 7), unicode([plus, escaped], small, 0)]),
            ("source-order", [V.State(families: [f0]), V.State(families: [f1]), V.State(families: [f1, f0])]),
            ("date-grouping", [V.State(families: [x100]), V.State(families: [x200]), V.State(families: [laterXY])]),
            ("variant-delete-replay", [V.State(families: [xy]), stale]),
            ("family-delete-replay", [V.State(families: [x100]), stale])
        ]
    }
    private func exportProjectionEvidence() throws {
        var scenarios: [[String: Any]] = []
        for (name, sources) in try evidenceInputs() {
            // Every source is a complete, valid state before any join/deletion.
            let checked = try sources.map { try engine.validate($0) }
            var results: [[String: Any]] = []
            if checked.count == 3 {
                var baseline: V.Validated?
                for indices in permutations([0, 1, 2]) {
                    let a = checked[indices[0]], b = checked[indices[1]], c = checked[indices[2]]
                    let label = indices.map { String($0) }.joined()
                    let left = try engine.join(engine.join(a, b), c)
                    let right = try engine.join(a, engine.join(b, c))
                    let expected = baseline ?? left
                    baseline = expected
                    // Native invariance is required independently of Python parity:
                    // two implementations sharing a grouping bug must not pass.
                    XCTAssertEqual(left.state, expected.state, "\(name)/\(label)-left")
                    XCTAssertEqual(right.state, expected.state, "\(name)/\(label)-right")
                    XCTAssertEqual(engine.project(left), engine.project(expected), "\(name)/\(label)-left projection")
                    XCTAssertEqual(engine.project(right), engine.project(expected), "\(name)/\(label)-right projection")
                    results.append(evidenceResult(label + "-left", left))
                    results.append(evidenceResult(label + "-right", right))
                }
            } else {
                let initial = checked[0], stale = checked[1]
                let deleted: V.Validated
                let observedText: String
                if name == "variant-delete-replay" {
                    deleted = try engine.deleteVariants(initial, references: [engine.project(initial)[0].reference]).state
                    observedText = "X"
                } else {
                    deleted = try engine.deleteFamilies(initial, familyIDs: [root]).state
                    observedText = "late"
                }
                let replayed = try engine.join(deleted, stale)
                let observed = try engine.observe(replayed, familyID: root, payload: payload(observedText), dateBits: V.DateBits(1)).state
                results = [("initial", initial), ("deleted", deleted), ("replayed", replayed), ("observed", observed)].map {
                    evidenceResult($0.0, $0.1)
                }
            }
            scenarios.append(["name": name, "inputs": sources.map(evidenceState), "results": results])
        }
        let evidence: [String: Any] = ["format": "veyra-chat-state-v2-projection-evidence-v1", "status": "native-export",
                                       "producer": "ChatStateV2Tests", "scenarios": scenarios]
        let data = try JSONSerialization.data(withJSONObject: evidence, options: [.sortedKeys, .prettyPrinted])
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = "chat-state-v2-projection-evidence.json"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testExactTLVHashAndUUIDNetworkVectors() throws {
        let x = payload("X")
        XCTAssertEqual(try engine.contentBytes(x).map { String(format: "%02x", $0) }.joined(),
                       "5665797261206368617420636f6e74656e7420763200000000000000000747656e6572616c000000000000000475736572000000000000000158")
        let xKey = try engine.contentKey(x)
        XCTAssertEqual(xKey.hex, "58b32ca7a34840dc3a7ef370534b1b810e1a6f4efd831a053c88218534a6c25f")
        XCTAssertEqual(try engine.projectedID(familyID: root, anchor: xKey, key: xKey), root)
        let anchor = try key("anchor")
        let id = try engine.projectedID(familyID: root, anchor: anchor, key: xKey)
        XCTAssertEqual(id.uuidString.lowercased(), "cca7cac2-8201-8b3b-8033-078c6bea66a1")
        XCTAssertEqual(V.uuidBytes(id)[6] >> 4, 8)
        XCTAssertEqual(V.uuidBytes(id)[8] >> 6, 2)
        let vectors: [(V.Payload, String, String)] = [
            (payload("café", role: .assistant), "c0bd1ba711785726140ddee8c7b4af34c8d0b4379ac08c2952ae2c600996bed4", "f05d9b78-64a6-83ab-a1e8-5c0e0ef25bc1"),
            (payload("cafe\u{301}", role: .assistant), "0a9f819d4fad98d8134e23f16f7ff61ebd0f79e9f9f401bc59491da268125e72", "92401135-eeab-8a56-8a2e-8f2ca559b2b0"),
            (payload("\0😀\n", project: "😀"), "8cba91f3e0fec54203843d059b1612c433b07ddaa385b3417ccd95ebdbb87beb", "dce58054-07f4-8e60-9983-72dfe56518e1")
        ]
        for (body, hash, expectedID) in vectors {
            let k = try engine.contentKey(body)
            XCTAssertEqual(k.hex, hash)
            XCTAssertEqual(try engine.projectedID(familyID: root, anchor: anchor, key: k).uuidString.lowercased(), expectedID)
        }
        XCTAssertNotEqual(payload("café"), payload("cafe\u{301}"))
        XCTAssertNotEqual(try engine.contentKey(payload("X", project: "Other")), xKey)
        XCTAssertNotEqual(try engine.contentKey(payload("X", role: .assistant)), xKey)
        try exportProjectionEvidence()
    }

    func testStrictPrimitiveBoundaries() throws {
        XCTAssertNil(V.Role(rawValue: "system"))
        XCTAssertThrowsError(try V.ContentKey(bytes: Data(repeating: 0, count: 31)))
        XCTAssertThrowsError(try V.ContentKey(hex: String(repeating: "A", count: 64)))
        XCTAssertThrowsError(try V.ContentKey(hex: "00"))
        XCTAssertEqual(try V.ContentKey(hex: String(repeating: "00", count: 32)).bytes.count, 32)
        for invalid in ["", "00", "+1", "-1", "1.0", "1e0", " 1", "18446744073709551616", "١"] {
            XCTAssertThrowsError(try V.parseCounter(invalid))
        }
        XCTAssertEqual(try V.parseCounter("18446744073709551615"), UInt64.max)
        XCTAssertEqual(try V.parseCounter("0"), 0)
        XCTAssertThrowsError(try V.DateBits(hex: "800000000000000"))
        XCTAssertThrowsError(try V.DateBits(hex: "7FF8000000000000"))
        XCTAssertThrowsError(try V.DateBits(.nan))
        XCTAssertThrowsError(try V.DateBits(.infinity))
        XCTAssertThrowsError(try V.DateBits((-978_307_200.0).nextDown))
        XCTAssertThrowsError(try V.DateBits(252_423_993_599.0.nextUp))
        XCTAssertNoThrow(try V.DateBits(-978_307_200))
        XCTAssertNoThrow(try V.DateBits(252_423_993_599))
        let badHash = V.Engine(digest: { _ in Data(repeating: 0, count: 31) })
        assertError(.invalidHashLength, try badHash.contentKey(payload("X")))
    }

    func testLosslessDateMinimumAndRepeatedObservations() throws {
        let minus = try V.DateBits(-0.0), plus = try V.DateBits(0.0)
        XCTAssertEqual(V.DateBits.minimum(minus, minus).rawValue, 1 << 63)
        XCTAssertEqual(V.DateBits.minimum(minus, plus).rawValue, 0)
        XCTAssertEqual(V.DateBits.minimum(plus, minus).rawValue, 0)
        XCTAssertEqual(try V.DateBits(hex: minus.hex), minus)
        for date in [Double.leastNonzeroMagnitude, -Double.leastNonzeroMagnitude, 1.0.nextUp, 100.0] {
            let bits = try V.DateBits(date)
            XCTAssertEqual(bits.rawValue, date.bitPattern)
            XCTAssertEqual(V.DateBits.minimum(bits, try V.DateBits(date.nextUp)), bits)
        }
        let start = try state([variant("X", 200)])
        let lower = try engine.observe(start, familyID: root, payload: payload("X"), dateBits: V.DateBits(100))
        XCTAssertTrue(lower.addedIDs.isEmpty)
        XCTAssertEqual(engine.project(lower.state).count, 1)
        XCTAssertEqual(engine.project(lower.state)[0].dateBits.rawValue, 100.0.bitPattern)
        XCTAssertEqual(try engine.observe(lower.state, familyID: root, payload: payload("X"), dateBits: V.DateBits(200)).state, lower.state)
    }

    func testNativeX100X200Y150CounterexampleAllGroupings() throws {
        let a = try state([variant("X", 100)]), b = try state([variant("X", 200)])
        let c = try state([variant("X", 200), variant("Y", 150)])
        try assertACI([a, b, c])
        let rows = engine.project(try engine.join(a, c))
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].reference.projectedID, root)
        XCTAssertEqual(rows[0].dateBits, try V.DateBits(100))
        XCTAssertEqual(rows[1].dateBits, try V.DateBits(150))
        XCTAssertEqual(rows[1].reference.projectedID, engine.project(c)[1].reference.projectedID)
        // The anchor is fixed even when migration chose Y instead of X.
        let yAnchor = try engine.validate(V.State(families: [family([variant("X", 200), variant("Y", 150)], anchor: "Y")]))
        let yEarlier = try engine.observe(yAnchor, familyID: root, payload: payload("X"), dateBits: V.DateBits(100)).state
        XCTAssertEqual(engine.project(yEarlier)[0].payload.text, "Y")
        XCTAssertEqual(engine.project(yEarlier)[1].reference.projectedID, engine.project(yAnchor)[1].reference.projectedID)
    }

    func testNativeSourceOrderCounterexampleUsesEstablishedKeys() throws {
        let id0 = UUID(uuidString: "00000000-0000-4000-8000-000000000000")!
        let id1 = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
        let f0 = try family([variant("X", 100)], id: id0, orderKey: order(0))
        let f1 = try family([variant("X", 100)], id: id1, orderKey: order(1))
        let a = try engine.validate(V.State(families: [f0]))
        let b = try engine.validate(V.State(families: [f1]))
        let c = try engine.validate(V.State(families: [f1, f0]))
        try assertACI([a, b, c])
        XCTAssertEqual(engine.project(try engine.join(a, c)).map { $0.reference.projectedID }, [id0, id1])
        let reorderedObservation = try engine.observe(c, familyID: id1, payload: payload("X"), dateBits: V.DateBits(90)).state
        XCTAssertEqual(engine.project(reorderedObservation).map { $0.reference.projectedID }, [id0, id1])
    }

    func testWholeOrderKeyMinimumRetainsMaximumClock() throws {
        let small = V.OrderKey(counter: 1, originID: batch, batchID: origin, sequence: 9)
        let large = V.OrderKey(counter: 2, originID: origin, batchID: batch, sequence: 0)
        let a = try engine.validate(V.State(families: [family([variant("X", 100)], orderKey: small)]))
        let b = try engine.validate(V.State(orderClock: 7, families: [family([variant("X", 100)], orderKey: large)]))
        let joined = try engine.join(a, b)
        XCTAssertEqual(joined.state.families[0].orderKey, small)
        XCTAssertEqual(joined.state.orderClock, 7)
        let keys = try engine.newOrderBatch(clock: joined.state.orderClock, originID: origin, batchID: batch, count: 2)
        XCTAssertEqual(keys.map(\.counter), [8, 8]); XCTAssertEqual(keys.map(\.sequence), [0, 1])
        assertError(.capacity(.orderClock), try engine.newOrderBatch(clock: UInt64.max, originID: origin, batchID: batch, count: 1))
        XCTAssertThrowsError(try engine.newOrderBatch(clock: 0, originID: origin, batchID: batch, count: -1))
        XCTAssertThrowsError(try engine.newOrderBatch(clock: 0, originID: origin, batchID: batch, count: 10_001))
    }

    func testLegacyOriginalConflictRestoreIDsStayIndependent() throws {
        let ids = [root, UUID(uuidString: "b1fbeefd-3dd1-5f9a-b0a9-103d1e093175")!, UUID(uuidString: "deafbeef-0000-5000-8000-000000000000")!]
        let families = try ids.enumerated().map { try family([variant("X", 100)], id: $0.element, orderKey: order(UInt64($0.offset))) }
        let complete = try engine.validate(V.State(families: Array(families.reversed())))
        XCTAssertEqual(engine.project(complete).map { $0.reference.projectedID }, ids)
        let deleted = try engine.deleteFamilies(complete, familyIDs: [root]).state
        XCTAssertEqual(engine.project(deleted).map { $0.reference.projectedID }, Array(ids.dropFirst()))
        let legacyMarker = try engine.validate(V.State(familyDeletes: [root], chatTombstones: [root]))
        let replay = try engine.join(legacyMarker, complete)
        XCTAssertEqual(engine.project(replay).map { $0.reference.projectedID }, Array(ids.dropFirst()))
    }

    func testSelectiveAnchorDeletionNeverPromotesOrResurrects() throws {
        let initial = try state([variant("X", 100), variant("Y", 150)])
        let rows = engine.project(initial), anchor = rows[0].reference, sibling = rows[1].reference
        let result = try engine.deleteVariants(initial, references: [anchor])
        XCTAssertEqual(engine.project(result.state).map(\.reference), [sibling])
        XCTAssertEqual(result.addedVariantDeletes, [anchor])
        XCTAssertEqual(result.addedTombstones, [root])
        XCTAssertTrue(result.addedFamilyDeletes.isEmpty)
        let replay = try engine.observe(result.state, familyID: root, payload: payload("X"), dateBits: V.DateBits(1)).state
        XCTAssertEqual(replay, result.state)
        XCTAssertEqual(try engine.join(initial, result.state), result.state)
        XCTAssertEqual(try engine.deleteVariants(result.state, references: [anchor]).state, result.state)
        let both = try engine.deleteVariants(result.state, references: [sibling]).state
        XCTAssertTrue(engine.project(both).isEmpty)
        XCTAssertEqual(try engine.observe(both, familyID: root, payload: payload("Y"), dateBits: V.DateBits(999)).state, both)
    }

    func testFamilyDeletionFansOutToUnknownVariantsAndKeepsRoot() throws {
        let initial = try state([variant("X", 100)])
        let deleted = try engine.deleteFamilies(initial, familyIDs: [root]).state
        let incoming = try state([variant("X", 100), variant("Y", 150)])
        let joined = try engine.join(deleted, incoming)
        XCTAssertTrue(engine.project(joined).isEmpty)
        XCTAssertEqual(joined.state.variantDeletes.count, 2)
        XCTAssertEqual(joined.state.chatTombstones.count, 2)
        XCTAssertEqual(joined.state.familyDeletes, [root])
        XCTAssertEqual(joined.state.families.count, 1)
        try assertACI([initial, deleted, incoming])
        let late = try engine.observe(joined, familyID: root, payload: payload("Z"), dateBits: V.DateBits(99))
        XCTAssertTrue(engine.project(late.state).isEmpty)
        XCTAssertEqual(late.addedVariantDeletes.count, 1)
        XCTAssertEqual(late.addedTombstones.count, 1)
        XCTAssertTrue(late.addedIDs.isEmpty)
    }

    func testProjectSelectionRequiresExactReferencesNotOmittedRows() throws {
        let initial = try state([variant("X", 100)])
        let other = payload("Y", project: "Elsewhere")
        let both = try engine.observe(initial, familyID: root, payload: other, dateBits: V.DateBits(100)).state
        XCTAssertEqual(try engine.deleteVariants(both, references: []).state, both)
        let selected = Set(engine.project(both).filter { $0.payload.project == "General" }.map(\.reference))
        let remaining = engine.project(try engine.deleteVariants(both, references: selected).state)
        XCTAssertEqual(remaining.map(\.payload), [other])
        let bad = V.Reference(familyID: root, contentKey: try key("unknown"), projectedID: UUID())
        XCTAssertThrowsError(try engine.deleteVariants(both, references: [bad]))
        XCTAssertThrowsError(try engine.deleteFamilies(both, familyIDs: [UUID()]))
    }

    func testMalformedCompleteStateAndAnchorMismatchFailClosed() throws {
        let x = try variant("X", 100), f = try family([x])
        XCTAssertThrowsError(try engine.validate(V.State(format: "future", families: [f])))
        XCTAssertThrowsError(try engine.validate(V.State(identityScheme: "future", families: [f])))
        XCTAssertThrowsError(try engine.validate(V.State(families: [f, f])))
        XCTAssertThrowsError(try engine.validate(V.State(families: [family([x, x])])))
        XCTAssertThrowsError(try engine.validate(V.State(families: [family([variant("Y", 150)])])))
        XCTAssertThrowsError(try engine.validate(V.State(chatTombstones: [root])))
        let a = try state([x])
        let b = try engine.validate(V.State(families: [family([variant("Y", 150)], anchor: "Y")]))
        assertError(.anchorConflict(root), try engine.join(a, b))
        XCTAssertEqual(a, try state([x]))
        XCTAssertEqual(engine.project(b)[0].payload.text, "Y")
        let wrong = V.Variant(contentKey: try key("Y"), payload: payload("X"), dateBits: try V.DateBits(100))
        XCTAssertThrowsError(try engine.validate(V.State(families: [family([wrong])])))
    }

    func testInjectedDigestAndUUIDCollisionsFailClosed() throws {
        let constant = Data(repeating: 17, count: 32)
        let e = V.Engine(digest: { _ in constant })
        let collisionKey = try e.contentKey(payload("X"))
        func s(_ text: String) throws -> V.Validated {
            let v = V.Variant(contentKey: collisionKey, payload: payload(text), dateBits: try V.DateBits(100))
            return try e.validate(V.State(families: [V.Family(familyID: root, anchorContentKey: collisionKey, orderKey: order(), variants: [v])]))
        }
        let a = try s("café"), b = try s("cafe\u{301}")
        assertError(.contentCollision(collisionKey), try e.join(a, b))
        XCTAssertEqual(e.project(a)[0].payload.text.utf8.count, 5)
        let variantDomain = Data("Veyra chat variant identity v2\0".utf8)
        let idsCollide = V.Engine(digest: { bytes in
            bytes.starts(with: variantDomain) ? constant : Data(SHA256.hash(data: bytes))
        })
        let ordinary = try idsCollide.validate(V.State(families: [family([variant("X", 1), variant("Y", 2)])]))
        let collidedID = idsCollide.project(ordinary)[1].reference.projectedID
        assertError(.identifierCollision(collidedID), try idsCollide.observe(ordinary, familyID: root, payload: payload("Z"), dateBits: V.DateBits(3)))
        let reserved = try idsCollide.validate(V.State(familyDeletes: [collidedID], chatTombstones: [collidedID]))
        assertError(.identifierCollision(collidedID), try idsCollide.join(ordinary, reserved))
        let otherRoot = try family([variant("X", 1)], id: collidedID)
        assertError(.identifierCollision(collidedID), try idsCollide.validate(V.State(families: ordinary.state.families + [otherRoot])))
        let tombstoned = try idsCollide.deleteVariants(ordinary, references: [idsCollide.project(ordinary)[1].reference]).state
        assertError(.identifierCollision(collidedID), try idsCollide.observe(tombstoned, familyID: root, payload: payload("Z"), dateBits: V.DateBits(3)))
    }

    func testDerivedCollisionAcrossFamiliesAndCachedProjection() throws {
        let constant = Data(repeating: 17, count: 32)
        let domain = Data("Veyra chat variant identity v2\0".utf8)
        let injected = V.Engine(digest: { bytes in bytes.starts(with: domain) ? constant : Data(SHA256.hash(data: bytes)) })
        let f0 = try family([variant("X", 1), variant("Y", 2)])
        let f1 = try family([variant("X", 1), variant("Z", 2)], id: origin)
        let first = try injected.validate(V.State(families: [f0]))
        let second = try injected.validate(V.State(families: [f1]))
        let collision = injected.project(first)[1].reference
        assertError(.identifierCollision(collision.projectedID), try injected.join(first, second))
        let deleted = try injected.deleteVariants(first, references: [collision]).state
        assertError(.identifierCollision(collision.projectedID), try injected.join(deleted, second))
        XCTAssertEqual(engine.project(first), injected.project(first))
        // Projection reads cached validated references. Mutation/join still revalidate
        // under the receiving engine, so they cannot accept a foreign identity scheme.
        XCTAssertThrowsError(try engine.join(deleted, engine.validate(V.State())))
    }

    func testCountByteAndFanoutBoundsNeverReturnPartialState() throws {
        let initial = try state([variant("X", 100)])
        var limits = V.Limits(); limits.maximumLiveVariants = 1
        let small = V.Engine(limits: limits)
        assertError(.capacity(.liveVariants), try small.observe(initial, familyID: root, payload: payload("Y"), dateBits: V.DateBits(100)))
        limits = V.Limits(); limits.maximumFamilies = 0
        assertError(.capacity(.families), try V.Engine(limits: limits).validate(initial.state))
        limits = V.Limits(); limits.maximumRecords = 1; limits.otherRecords = 1
        assertError(.capacity(.records), try V.Engine(limits: limits).validate(initial.state))
        let deleted = try engine.deleteFamilies(initial, familyIDs: [root]).state
        limits = V.Limits(); limits.maximumTombstones = 2; limits.otherTombstones = 1
        let capped = V.Engine(limits: limits)
        XCTAssertNoThrow(try capped.validate(deleted.state))
        assertError(.capacity(.tombstones), try capped.observe(deleted, familyID: root, payload: payload("Y"), dateBits: V.DateBits(1)))
        XCTAssertEqual(deleted.state.variantDeletes.count, 1)
        limits = V.Limits(); limits.maximumDocumentBytes = initial.usage.documentBytes
        XCTAssertNoThrow(try V.Engine(limits: limits).validate(initial.state))
        limits.maximumDocumentBytes -= 1
        assertError(.capacity(.documentBytes), try V.Engine(limits: limits).validate(initial.state))
        limits = V.Limits(); limits.maximumJournalBytes = initial.usage.journalBytes
        XCTAssertNoThrow(try V.Engine(limits: limits).validate(initial.state))
        limits.maximumJournalBytes -= 1
        assertError(.capacity(.journalBytes), try V.Engine(limits: limits).validate(initial.state))
        limits = V.Limits(); limits.otherDocumentBytes = Int.max
        XCTAssertThrowsError(try V.Engine(limits: limits).validate(initial.state))
        limits = V.Limits(); limits.otherRecords = -1
        assertError(.invalidLimits, try V.Engine(limits: limits).validate(initial.state))
        XCTAssertEqual(initial.state.families[0].variants.count, 1)
    }

    func testOrderTupleUsesNumericValuesAndNetworkUUIDBytes() throws {
        let low = UUID(uuidString: "00000000-0000-4000-8000-000000000009")!
        let high = UUID(uuidString: "00000000-0000-4000-8000-00000000000a")!
        func k(_ counter: UInt64, _ origin: UUID, _ batch: UUID, _ sequence: UInt64) -> V.OrderKey {
            V.OrderKey(counter: counter, originID: origin, batchID: batch, sequence: sequence)
        }
        XCTAssertLessThan(k(2, high, high, 10), k(10, low, low, 2))
        XCTAssertLessThan(k(2, low, high, 10), k(2, high, low, 2))
        XCTAssertLessThan(k(2, low, low, 10), k(2, low, high, 2))
        XCTAssertLessThan(k(2, low, low, 2), k(2, low, low, 10))
        let a = try family([variant("X", 1)], id: low, orderKey: order())
        let b = try family([variant("X", 1)], id: high, orderKey: order())
        let joined = try engine.validate(V.State(families: [b, a]))
        XCTAssertEqual(engine.project(joined).map { $0.reference.familyID }, [low, high])
    }

    func testDeleteMetadataIsCompleteDuplicateFreeAndScoped() throws {
        let initial = try state([variant("X", 1), variant("Y", 2)])
        let ref = engine.project(initial)[1].reference
        XCTAssertThrowsError(try engine.validate(V.State(families: initial.state.families, variantDeletes: [ref])))
        assertError(.duplicateSelector(ref), try engine.validate(V.State(families: initial.state.families,
                    variantDeletes: [ref, ref], chatTombstones: [ref.projectedID])))
        let wrong = V.Reference(familyID: ref.familyID, contentKey: ref.contentKey, projectedID: root)
        XCTAssertThrowsError(try engine.validate(V.State(families: initial.state.families,
                    variantDeletes: [wrong], chatTombstones: [root])))
        let deleted = try engine.deleteVariants(initial, references: [ref]).state
        let different = try engine.observe(deleted, familyID: root, payload: payload("Z"), dateBits: V.DateBits(0))
        XCTAssertEqual(different.addedIDs.count, 1)
        XCTAssertEqual(engine.project(different.state).count, 2)
        XCTAssertEqual(different.state.state.chatTombstones, [ref.projectedID])
        XCTAssertTrue(different.addedVariantDeletes.isEmpty)
        // The same key with differing bytes is also a collision across independent roots.
        let constant = Data(repeating: 7, count: 32)
        let e = V.Engine(digest: { _ in constant })
        let key = try V.ContentKey(bytes: constant)
        let f0 = V.Family(familyID: root, anchorContentKey: key, orderKey: order(),
                          variants: [V.Variant(contentKey: key, payload: payload("A"), dateBits: try V.DateBits(1))])
        let f1 = V.Family(familyID: origin, anchorContentKey: key, orderKey: order(1),
                          variants: [V.Variant(contentKey: key, payload: payload("B"), dateBits: try V.DateBits(1))])
        assertError(.contentCollision(key), try e.join(e.validate(V.State(families: [f0])), e.validate(V.State(families: [f1]))))
    }

    func testActualDefaultCountBoundaries() throws {
        let variants = try (0..<10_000).map { try variant("X\($0)", 1) }
        let full = try engine.validate(V.State(families: [family(variants, anchor: "X0")]))
        XCTAssertEqual(full.usage.liveVariants, 10_000)
        assertError(.capacity(.liveVariants), try engine.observe(full, familyID: root, payload: payload("overflow"), dateBits: V.DateBits(1)))

        func id(_ n: Int) -> UUID { UUID(uuidString: String(format: "10000000-0000-4000-8000-%012d", n))! }
        let shared = try variant("X", 1)
        let live = try (0..<10_000).map { try family([shared], id: id($0), orderKey: order(UInt64($0))) }
        let roots = (10_000..<30_000).map(id)
        // Raise only bytes to isolate the actual count ceilings; default bytes are tested above.
        var limits = V.Limits(); limits.maximumDocumentBytes = 64 * 1_024 * 1_024
        limits.maximumJournalBytes = 128 * 1_024 * 1_024; limits.otherRecords = 20_000
        let input = V.State(families: live, familyDeletes: roots, chatTombstones: roots)
        let maximum = try V.Engine(limits: limits).validate(input)
        XCTAssertEqual(maximum.usage.retainedRoots, 30_000)
        XCTAssertEqual(maximum.usage.tombstones, 20_000)
        limits.otherRecords += 1
        assertError(.capacity(.records), try V.Engine(limits: limits).validate(input))
        limits.otherRecords -= 1; limits.otherTombstones = 1
        assertError(.capacity(.tombstones), try V.Engine(limits: limits).validate(input))
        limits.otherTombstones = 0; limits.maximumTombstones = 20_001
        let extra = roots + [id(30_000)]
        assertError(.capacity(.families), try V.Engine(limits: limits).validate(V.State(families: live, familyDeletes: extra, chatTombstones: extra)))
    }

    func testDeterministicSeedPropertiesCompatibleNormalizedStates() throws {
        // Fixed LCG, never system randomness. Each snapshot has the same anchors.
        var seed: UInt64 = 0xc0ffee1234567890
        func next() -> UInt64 { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return seed }
        let ids = (0..<4).map { UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", $0 + 10))! }
        for _ in 0..<48 {
            var states: [V.Validated] = []
            for _ in 0..<3 {
                var families: [V.Family] = []
                for (i, id) in ids.enumerated() {
                    var variants = [try variant("X", Double(next() % 500))]
                    if next() & 1 == 0 { variants.append(try variant("Y", Double(next() % 500))) }
                    if next() % 3 == 0 { variants.append(try variant("Z", Double(next() % 500))) }
                    families.append(try family(variants, id: id, orderKey: order(UInt64(i), counter: next() % 4)))
                }
                var current = try engine.validate(V.State(families: Array(families.reversed())))
                if next() % 3 == 0 {
                    current = try engine.deleteFamilies(current, familyIDs: [ids[Int(next() % 4)]]).state
                } else if next() % 3 == 0, let row = engine.project(current).first {
                    current = try engine.deleteVariants(current, references: [row.reference]).state
                }
                states.append(current)
            }
            try assertACI(states)
            let joined = try engine.join(engine.join(states[0], states[1]), states[2])
            for input in states {
                XCTAssertTrue(Set(input.state.variantDeletes).isSubset(of: Set(joined.state.variantDeletes)))
                XCTAssertTrue(Set(input.state.familyDeletes).isSubset(of: Set(joined.state.familyDeletes)))
                XCTAssertTrue(Set(input.state.chatTombstones).isSubset(of: Set(joined.state.chatTombstones)))
            }
            for row in engine.project(joined) {
                let observations = states.flatMap { engine.project($0) }.filter { $0.reference == row.reference }
                let minimum = observations.map(\.dateBits).reduce(observations[0].dateBits, V.DateBits.minimum)
                XCTAssertEqual(row.dateBits, minimum)
            }
            var repeated = joined
            for _ in 0..<5 { repeated = try engine.join(repeated, joined) }
            XCTAssertEqual(repeated, joined)
            XCTAssertEqual(repeated.usage, joined.usage)
        }
    }
}
