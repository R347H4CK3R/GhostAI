import XCTest
@testable import AsterionVeyra

/// Synthetic inputs only. The helper has no production caller or persistence codec.
final class ImmutableNoteStateV2Tests: XCTestCase {
    private typealias V = ImmutableNoteStateV2
    private let engine = V.Engine()
    private func id(_ n: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-4000-8000-%012x", n))!
    }
    private func body(_ text: String = "Synthetic", project: String = "General", source: String = "Synthetic source",
                      bits: UInt64 = Double(100).bitPattern) -> V.Payload {
        V.Payload(project: project, text: text, source: source, savedAtBits: bits)
    }
    private func record(_ n: Int = 1, _ payload: V.Payload? = nil) -> V.Record {
        V.Record(id: id(n), payload: payload ?? body())
    }
    private func binding(_ n: Int = 1, _ payload: V.Payload? = nil) throws -> V.Binding {
        V.Binding(id: id(n), contentKey: try engine.contentKey(payload ?? body()))
    }
    private func assertError<T>(_ expected: V.Failure, _ action: @autoclosure () throws -> T,
                                file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try action(), file: file, line: line) {
            XCTAssertEqual($0 as? V.Failure, expected, file: file, line: line)
        }
    }
    private func permutations<T>(_ items: [T]) -> [[T]] {
        if items.isEmpty { return [[]] }
        return items.indices.flatMap { index -> [[T]] in
            var rest = items
            let first = rest.remove(at: index)
            return permutations(rest).map { [first] + $0 }
        }
    }

    // Catches wrong union, inferred lineage, a UUID/content-key reorder or lost binding.
    func testCompatibleJoinAllPermutationsGroupingsIdentityAndIdempotence() throws {
        let a = V.State(records: [record(3), record(1)])
        let b = V.State(records: [record(1), record(2, body("Other"))])
        let c = V.State(tombstones: [id(3), id(4)])
        let expected = V.State(records: [record(1), record(2, body("Other"))],
                               bindings: [try binding(1), try binding(2, body("Other")), try binding(3)],
                               tombstones: [id(3), id(4)])
        for p in permutations([a, b, c]) {
            XCTAssertEqual(try engine.join(p).state, expected)
            XCTAssertEqual(try engine.join([engine.join([p[0], p[1]]).state, p[2]]).state, expected)
            XCTAssertEqual(try engine.join([p[0], engine.join([p[1], p[2]]).state]).state, expected)
        }
        XCTAssertEqual(try engine.join([expected, expected]).state, expected)
        XCTAssertEqual(try engine.join([expected, V.State()]).state, expected)
        XCTAssertEqual(try engine.normalize(expected).state, expected)
        XCTAssertEqual(try engine.join([]).state, V.State())
    }

    func testIndependentLegacyAndConflictCopyUUIDsWithIdenticalPayloadRemainIndependent() throws {
        let left = record(9), right = record(10)
        let result = try engine.join([V.State(records: [right, left]), V.State(tombstones: [left.id])]).state
        XCTAssertEqual(result.records, [right])
        XCTAssertEqual(result.bindings, [try binding(9), try binding(10)])
        XCTAssertEqual(result.tombstones, [left.id])
    }

    func testTLVBytesAndSHA256MatchIndependentSyntheticVector() throws {
        let payload = body("Cafe\u{301}\0x", source: "Synthetic", bits: 0x8000000000000000)
        let hex = try engine.contentBytes(payload).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(hex, "566579726120696d6d757461626c65206e6f7465207061796c6f61642076320001000000000000000747656e6572616c02000000000000000843616665cc81007803000000000000000953796e7468657469630400000000000000088000000000000000")
        XCTAssertEqual(try engine.contentKey(payload).hex, "639fd58b2260f5bf100bf2c6503065b736f7cd85529101eaf807bcd34ddaf39c")
        XCTAssertNotEqual(try engine.contentKey(body("ab", source: "c")), try engine.contentKey(body("a", source: "bc")))
    }

    func testCanonicalEquivalentUnicodeInEveryFieldIsAnImmutableConflict() throws {
        let composed = "Caf\u{e9}", decomposed = "Cafe\u{301}"
        let pairs = [(body("x", project: composed), body("x", project: decomposed)),
                     (body(composed), body(decomposed)),
                     (body("x", source: composed), body("x", source: decomposed))]
        for (a, b) in pairs {
            XCTAssertNotEqual(a, b)
            XCTAssertNotEqual(try engine.contentKey(a), try engine.contentKey(b))
            for p in permutations([V.State(records: [record(1, a)]), V.State(records: [record(1, b)])]) {
                assertError(.immutableConflict(id(1)), try engine.join(p))
            }
        }
    }

    func testOriginalDateBitsArePreservedIncludingSignedZeroSubnormalAndAdjacentValues() throws {
        let bits: [UInt64] = [0, 0x8000000000000000, 1, Double(100).bitPattern,
                              Double(100).nextUp.bitPattern, Double(-978_307_200).bitPattern,
                              Double(252_423_993_599).bitPattern]
        for raw in bits {
            let payload = body(bits: raw)
            let input = V.State(records: [record(1, payload)])
            XCTAssertEqual(try engine.normalize(input).state.records.first?.payload.savedAtBits, raw)
        }
        assertError(.immutableConflict(id(1)), try engine.join([
            V.State(records: [record(1, body(bits: 0))]),
            V.State(records: [record(1, body(bits: 0x8000000000000000))])]))
        assertError(.immutableConflict(id(1)), try engine.join([
            V.State(records: [record(1)]),
            V.State(records: [record(1, body(bits: Double(100).nextUp.bitPattern))])]))
    }

    func testSameUUIDChangedTextSourceOrProjectFailsWithoutMutatingInputs() throws {
        let original = V.State(records: [record()])
        for changed in [body("Changed"), body(source: "Changed"), body(project: "Other")] {
            let incoming = V.State(records: [record(1, changed)])
            let originals = [original, incoming]
            assertError(.immutableConflict(id(1)), try engine.join(originals))
            XCTAssertEqual(originals, [V.State(records: [record()]), V.State(records: [record(1, changed)])])
        }
    }

    func testDeletionRetainsBindingAndRejectsLaterUnequalPayloadInEveryGrouping() throws {
        let a = V.State(records: [record()]), b = V.State(tombstones: [id(1)])
        let c = V.State(records: [record(1, body("Changed"))])
        let deleted = try engine.join([a, b]).state
        XCTAssertEqual(deleted, V.State(bindings: [try binding()], tombstones: [id(1)]))
        XCTAssertEqual(try engine.join([deleted, a, b]).state, deleted)
        for p in permutations([a, b, c]) {
            assertError(.immutableConflict(id(1)), try engine.join(p))
            // A conflicting pair may fail at either level; neither may succeed overall.
            assertError(.immutableConflict(id(1)), try engine.join([engine.join([p[0], p[1]]).state, p[2]]))
            assertError(.immutableConflict(id(1)), try engine.join([p[0], engine.join([p[1], p[2]]).state]))
        }
    }

    func testKnownDeletedBindingsConflictEvenWhenNoPayloadRemains() throws {
        let a = V.State(bindings: [try binding()], tombstones: [id(1)])
        let b = V.State(bindings: [try binding(1, body("Changed"))], tombstones: [id(1)])
        assertError(.immutableConflict(id(1)), try engine.join([a, b]))
        assertError(.immutableConflict(id(1)), try engine.join([b, a]))
    }

    func testOpaqueLegacyTombstoneSuppressesWithoutInventingHistoricalBinding() throws {
        let opaque = V.State(tombstones: [id(1)])
        XCTAssertEqual(try engine.normalize(opaque).state, opaque)
        for candidate in [body(), body("No historical body is known")] {
            let result = try engine.join([opaque, V.State(records: [record(1, candidate)])]).state
            XCTAssertTrue(result.records.isEmpty)
            XCTAssertEqual(result.tombstones, [id(1)])
            // This is a binding to the first observed candidate, not recovered history.
            XCTAssertEqual(result.bindings, [try binding(1, candidate)])
            XCTAssertEqual(try engine.join([opaque, result]).state, result)
        }
    }

    func testTombstoneCannotHideConflictWithinOriginalOrAcrossOriginals() throws {
        assertError(.duplicateRecord(id(1)), try engine.normalize(
            V.State(records: [record(), record(1, body("Changed"))], tombstones: [id(1)])))
        assertError(.immutableConflict(id(1)), try engine.join([
            V.State(records: [record()], tombstones: [id(1)]),
            V.State(records: [record(1, body("Changed"))])]))
    }

    func testTombstoneCannotHideInvalidOriginalDatesOrFields() throws {
        for raw in [Double.nan.bitPattern, Double.infinity.bitPattern, (-Double.infinity).bitPattern,
                    Double(-978_307_200).nextDown.bitPattern, Double(252_423_993_599).nextUp.bitPattern] {
            assertError(.invalidDate, try engine.normalize(V.State(records: [record(1, body(bits: raw))], tombstones: [id(1)])))
        }
        for bad in [body(project: ""), body(project: String(repeating: "x", count: 301)),
                    body(String(repeating: "x", count: 20_001)), body(source: String(repeating: "x", count: 2_001))] {
            assertError(.invalidPayload, try engine.normalize(V.State(records: [record(1, bad)], tombstones: [id(1)])))
        }
    }

    func testOriginalBindingMismatchCannotBeHiddenByDeletion() throws {
        assertError(.immutableConflict(id(1)), try engine.normalize(
            V.State(records: [record()], bindings: [try binding(1, body("Changed"))], tombstones: [id(1)])))
    }

    func testRejectsUnsupportedMetadataDuplicateFactsAndOrphanBindings() throws {
        assertError(.invalidMetadata, try engine.normalize(V.State(format: "future")))
        assertError(.invalidMetadata, try engine.normalize(V.State(identityScheme: "future")))
        assertError(.duplicateRecord(id(1)), try engine.normalize(V.State(records: [record(), record()])))
        assertError(.duplicateBinding(id(1)), try engine.normalize(
            V.State(bindings: [try binding(), try binding()], tombstones: [id(1)])))
        assertError(.duplicateTombstone(id(1)), try engine.normalize(V.State(tombstones: [id(1), id(1)])))
        assertError(.orphanBinding(id(1)), try engine.normalize(V.State(bindings: [try binding()])))
        assertError(.invalidKey, try V.ContentKey(bytes: Data(repeating: 0, count: 31)))
        assertError(.invalidHashLength, try V.Engine(digest: { _ in Data() }).normalize(V.State(records: [record()])))
    }

    func testHashCollisionsFailClosedForDistinctIDsEvenIfOneBodyIsHidden() throws {
        let colliding = V.Engine(digest: { _ in Data(repeating: 42, count: 32) })
        let a = V.State(records: [record(1)]), b = V.State(records: [record(2, body("Other"))], tombstones: [id(2)])
        let key = try V.ContentKey(bytes: Data(repeating: 42, count: 32))
        for p in permutations([a, b]) {
            assertError(.contentCollision(key), try colliding.join(p))
        }
        assertError(.contentCollision(key), try colliding.normalize(
            V.State(records: [record(1), record(2, body("Other"))], tombstones: [id(1), id(2)])))
        assertError(.immutableConflict(id(1)), try colliding.join([
            V.State(records: [record(1)]), V.State(records: [record(1, body("Other"))])]))
    }

    func testLexicographicUUIDByteOrderIsDeterministicForAllRetainedFacts() throws {
        let high = UUID(uuidString: "ffffffff-ffff-ffff-ffff-ffffffffffff")!
        let low = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
        let middle = id(1)
        let result = try engine.normalize(V.State(records: [V.Record(id: high, payload: body()),
                                                              V.Record(id: middle, payload: body()),
                                                              V.Record(id: low, payload: body())],
                                                 tombstones: [middle, low])).state
        XCTAssertEqual(result.records.map(\.id), [high])
        XCTAssertEqual(result.bindings.map(\.id), [low, middle, high])
        XCTAssertEqual(result.tombstones, [low, middle])
    }

    func testLiveAndSharedRecordCapacityNeverSilentlyEvictsOrChangesInputs() throws {
        var limits = V.Limits(); limits.maximumNotes = 1
        let limited = V.Engine(limits: limits)
        let a = V.State(records: [record(1)]), b = V.State(records: [record(2)])
        assertError(.capacity(.notes), try limited.join([a, b]))
        XCTAssertEqual(a, V.State(records: [record(1)])); XCTAssertEqual(b, V.State(records: [record(2)]))
        limits.maximumNotes = 10_000; limits.otherRecords = 29_999
        let shared = V.Engine(limits: limits)
        XCTAssertEqual(try shared.normalize(a).usage.totalRecords, 30_000)
        assertError(.capacity(.records), try shared.join([a, b]))
    }

    func testAllOriginalRecordsCountBeforeSuppressionOrDeduplication() throws {
        var limits = V.Limits(); limits.maximumNotes = 1
        let limited = V.Engine(limits: limits)
        assertError(.capacity(.notes), try limited.normalize(
            V.State(records: [record(1), record(2)], tombstones: [id(1), id(2)])))
        // Separately valid candidates can be joined and then suppressed within capacity.
        XCTAssertTrue(try limited.join([V.State(records: [record(1)]), V.State(records: [record(2)]),
                                       V.State(tombstones: [id(1), id(2)])]).state.records.isEmpty)
    }

    func testSharedTombstoneBudgetIncludesOpaqueAndKnownDeletedIDsOnce() throws {
        var limits = V.Limits(); limits.otherTombstones = 19_999
        let limited = V.Engine(limits: limits)
        let known = V.State(bindings: [try binding()], tombstones: [id(1)])
        XCTAssertEqual(try limited.join([known, V.State(tombstones: [id(1)])]).usage.totalTombstones, 20_000)
        assertError(.capacity(.tombstones), try limited.join([known, V.State(tombstones: [id(2)])]))
        XCTAssertEqual(known.tombstones, [id(1)])
    }

    func testConservativeByteReservationsIncludeMetadataUnicodeAndOtherComponents() throws {
        let input = V.State(records: [record(1, body("\0\n\"\\😀"))], tombstones: [id(2)])
        let measured = try engine.normalize(input)
        XCTAssertGreaterThan(measured.usage.noteDocumentReservationBytes, 512)
        XCTAssertEqual(measured.usage.noteJournalReservationBytes, 2 * measured.usage.noteDocumentReservationBytes)
        var limits = V.Limits()
        limits.otherDocumentBytes = limits.maximumDocumentBytes - measured.usage.noteDocumentReservationBytes
        XCTAssertEqual(try V.Engine(limits: limits).normalize(measured.state).usage.totalDocumentReservationBytes, 8 * 1_024 * 1_024)
        limits.otherDocumentBytes += 1
        assertError(.capacity(.documentBytes), try V.Engine(limits: limits).normalize(measured.state))
        limits.otherDocumentBytes = 0
        limits.otherJournalBytes = limits.maximumJournalBytes - measured.usage.noteJournalReservationBytes
        XCTAssertEqual(try V.Engine(limits: limits).normalize(measured.state).usage.totalJournalReservationBytes, 17 * 1_024 * 1_024)
        limits.otherJournalBytes += 1
        assertError(.capacity(.journalBytes), try V.Engine(limits: limits).normalize(measured.state))
    }

    func testHiddenBodyCannotBypassOriginalByteReservation() throws {
        var limits = V.Limits(); limits.maximumDocumentBytes = 512
        let input = V.State(records: [record()], tombstones: [id(1)])
        assertError(.capacity(.documentBytes), try V.Engine(limits: limits).normalize(input))
        XCTAssertEqual(input.records, [record()])
    }

    func testDefaultTenThousandNoteCeilingAndTwentyThousandMarkerCeiling() throws {
        let notes = (0..<10_000).map { record($0) }
        let full = V.State(records: notes)
        XCTAssertEqual(try engine.normalize(full).usage.notes, 10_000)
        assertError(.capacity(.notes), try engine.join([full, V.State(records: [record(10_000)])]))
        let markers = V.State(tombstones: (0..<20_000).map(id))
        XCTAssertEqual(try engine.normalize(markers).usage.totalTombstones, 20_000)
        assertError(.capacity(.tombstones), try engine.join([markers, V.State(tombstones: [id(20_000)])]))
        XCTAssertEqual(full.records.count, 10_000)
        XCTAssertEqual(markers.tombstones.count, 20_000)
    }

    func testInvalidLimitsAndReservationArithmeticFailClosed() throws {
        var limits = V.Limits(); limits.otherRecords = -1
        assertError(.invalidLimits, try V.Engine(limits: limits).normalize(V.State()))
        limits = V.Limits(); limits.maximumNotes = 10_001
        assertError(.invalidLimits, try V.Engine(limits: limits).normalize(V.State()))
        limits = V.Limits(); limits.otherDocumentBytes = Int.max
        assertError(.capacity(.arithmetic), try V.Engine(limits: limits).normalize(V.State()))
        limits = V.Limits(); limits.otherJournalBytes = Int.max
        assertError(.capacity(.arithmetic), try V.Engine(limits: limits).normalize(V.State()))
    }
}
