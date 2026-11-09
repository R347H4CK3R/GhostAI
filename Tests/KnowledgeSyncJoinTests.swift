import XCTest
@testable import AsterionVeyra

final class KnowledgeSyncJoinTests: XCTestCase {
    private func date(_ seconds: Double) -> Date { Date(timeIntervalSinceReferenceDate: seconds) }

    private func source(_ origin: KnowledgeSource.Origin, _ label: String,
                        revision: String? = nil, repository: String? = nil) throws -> KnowledgeSource {
        var object = ["origin": origin.rawValue, "label": label]
        object["revision"] = revision; object["repositoryName"] = repository
        return try JSONDecoder().decode(KnowledgeSource.self, from: JSONSerialization.data(withJSONObject: object))
    }

    private func entry(_ kind: KnowledgeKind = .selectedFile, index: Int = 0,
                       observed: Double = 100, cached: Double = 100,
                       filename: String = "sample.txt", text suppliedText: String? = nil) throws -> KnowledgeEntry {
        let text = suppliedText ?? (kind == .action ? "Question: succeeded" : "Synthetic source \(index)")
        let uuid = String(format: "00000000-0000-4000-8000-%012x", index)
        let id: String, provenance: KnowledgeSource
        switch kind {
        case .selectedFile:
            let digest = KnowledgePolicy.digest(text)
            id = "file:" + digest; provenance = try source(.selectedFile, filename, revision: digest)
        case .research:
            provenance = try KnowledgeSource.web(URL(string: "https://example.com/source/\(index)")!)
            id = "research:" + KnowledgePolicy.digest(provenance.label + "\0" + text)
        case .action:
            id = "action:" + uuid; provenance = try source(.appAction, "In-app activity")
        case .conversation:
            id = "chat:" + uuid; provenance = try source(.conversation, "In-app user message")
        }
        return KnowledgeEntry(id: id, kind: kind, text: text, source: provenance,
                              sourceDate: date(observed), cachedAt: date(cached), byteCount: text.utf8.count)
    }

    private func copy(_ entry: KnowledgeEntry, source: KnowledgeSource? = nil,
                      observed: Double? = nil, cached: Double? = nil, byteCount: Int? = nil) -> KnowledgeEntry {
        KnowledgeEntry(id: entry.id, kind: entry.kind, text: entry.text, source: source ?? entry.source,
                       sourceDate: observed.map(date) ?? entry.sourceDate,
                       cachedAt: cached.map(date) ?? entry.cachedAt, byteCount: byteCount ?? entry.byteCount)
    }

    private func snapshot(_ entries: [KnowledgeEntry] = [], suppressed: [String] = [], cutoff: Double? = nil,
                          project: String = "General", account: String = "device-local",
                          repository: String? = nil) -> KnowledgeSyncSnapshot {
        KnowledgeSyncSnapshot(accountID: account, project: project, repository: repository,
                              entries: entries, suppressedIDs: suppressed, clearBefore: cutoff.map(date))
    }

    private func joined(_ values: [KnowledgeSyncSnapshot]) throws -> KnowledgeSyncSnapshot {
        try KnowledgeSyncJoin.join(values).snapshot
    }

    // Synthesized Equatable and JSON date serialization cannot prove exact string/date bits.
    private func assertExact(_ lhs: KnowledgeSyncSnapshot, _ rhs: KnowledgeSyncSnapshot,
                             file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(Data(lhs.accountID.utf8), Data(rhs.accountID.utf8), file: file, line: line)
        XCTAssertEqual(Data(lhs.project.utf8), Data(rhs.project.utf8), file: file, line: line)
        XCTAssertEqual(lhs.repository.map { Data($0.utf8) }, rhs.repository.map { Data($0.utf8) }, file: file, line: line)
        XCTAssertEqual(lhs.clearBefore?.timeIntervalSinceReferenceDate.bitPattern,
                       rhs.clearBefore?.timeIntervalSinceReferenceDate.bitPattern, file: file, line: line)
        XCTAssertEqual(lhs.suppressedIDs, rhs.suppressedIDs, file: file, line: line)
        XCTAssertEqual(lhs.entries.count, rhs.entries.count, file: file, line: line)
        for (a, b) in zip(lhs.entries, rhs.entries) {
            XCTAssertEqual(a.id, b.id, file: file, line: line)
            XCTAssertEqual(a.kind, b.kind, file: file, line: line)
            XCTAssertEqual(Data(a.text.utf8), Data(b.text.utf8), file: file, line: line)
            XCTAssertEqual(a.source.origin, b.source.origin, file: file, line: line)
            XCTAssertEqual(Data(a.source.label.utf8), Data(b.source.label.utf8), file: file, line: line)
            XCTAssertEqual(a.source.revision.map { Data($0.utf8) }, b.source.revision.map { Data($0.utf8) }, file: file, line: line)
            XCTAssertEqual(a.source.repositoryName.map { Data($0.utf8) }, b.source.repositoryName.map { Data($0.utf8) }, file: file, line: line)
            XCTAssertEqual(a.sourceDate.timeIntervalSinceReferenceDate.bitPattern,
                           b.sourceDate.timeIntervalSinceReferenceDate.bitPattern, file: file, line: line)
            XCTAssertEqual(a.cachedAt.timeIntervalSinceReferenceDate.bitPattern,
                           b.cachedAt.timeIntervalSinceReferenceDate.bitPattern, file: file, line: line)
            XCTAssertEqual(a.byteCount, b.byteCount, file: file, line: line)
        }
    }

    private func assertFailure(_ failure: KnowledgeFailure, _ values: [KnowledgeSyncSnapshot],
                               file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try joined(values), file: file, line: line) {
            XCTAssertEqual($0 as? KnowledgeFailure, failure, file: file, line: line)
        }
    }

    private let permutations = [[0, 1, 2], [0, 2, 1], [1, 0, 2], [1, 2, 0], [2, 0, 1], [2, 1, 0]]

    func testSingletonSuppressionOverlapNormalizesAndReportsRemovedIdentity() throws {
        for kind in KnowledgeKind.allCases {
            let item = try entry(kind)
            let raw = snapshot([item], suppressed: [item.id])
            _ = try raw.validated() // Accepted legacy overlap is deliberately not a fixed point.
            let result = try KnowledgeSyncJoin.normalize(raw)
            assertExact(result.snapshot, snapshot(suppressed: [item.id]))
            XCTAssertEqual(result.removedEntryIDs, [item.id])
            XCTAssertTrue(result.cutoffSuppressedIDs.isEmpty)
            assertExact(try joined([raw, raw]), result.snapshot)
            assertExact(try joined([raw, snapshot()]), result.snapshot)
            assertExact(try KnowledgeSyncJoin.normalize(result.snapshot).snapshot, result.snapshot)
        }
    }

    func testEveryGroupingPromotesOldFileAndResearchObservationsToPermanentSuppression() throws {
        for kind in [KnowledgeKind.selectedFile, .research] {
            let old = try entry(kind, observed: 100, cached: 100)
            let new = try entry(kind, observed: 200, cached: 200)
            let states = [snapshot([old]), snapshot([new]), snapshot(cutoff: 150)]
            let expected = snapshot(suppressed: [old.id], cutoff: 150)
            for order in permutations {
                let a = states[order[0]], b = states[order[1]], c = states[order[2]]
                assertExact(try joined([a, b, c]), expected)
                assertExact(try joined([joined([a, b]), c]), expected)
                assertExact(try joined([a, joined([b, c])]), expected)
            }
            let surviving = try joined([states[1], states[2]])
            XCTAssertEqual(surviving.entries.map(\.id), [new.id])
            XCTAssertTrue(surviving.suppressedIDs.isEmpty)
            let result = try KnowledgeSyncJoin.join([surviving, states[0]])
            XCTAssertEqual(result.cutoffSuppressedIDs, [old.id])
            assertExact(result.snapshot, expected)
            assertExact(try joined([result.snapshot, snapshot([new])]), expected)
        }
    }

    func testCutoffUsesCachedAtOnlyForSelectedFilesAndIncludesEquality() throws {
        for kind in KnowledgeKind.allCases {
            let stale = try entry(kind, observed: kind == .selectedFile ? 200 : 150,
                                  cached: kind == .selectedFile ? 150 : 200)
            let result = try KnowledgeSyncJoin.normalize(snapshot([stale], cutoff: 150))
            XCTAssertTrue(result.snapshot.entries.isEmpty)
            XCTAssertEqual(result.cutoffSuppressedIDs, [stale.id])
            let fresh = try entry(kind, observed: kind == .selectedFile ? 100 : 151,
                                  cached: kind == .selectedFile ? 151 : 100)
            assertExact(try joined([snapshot([fresh], cutoff: 150)]), snapshot([fresh], cutoff: 150))
            assertExact(try joined([snapshot([fresh]), snapshot(suppressed: [fresh.id])]), snapshot(suppressed: [fresh.id]))
        }
    }

    func testFilenameUsesUTF8LengthThenUnsignedBytesWithoutUnicodeNormalization() throws {
        let pairs = [("a\u{301}\u{327}.txt", "a\u{327}\u{301}.txt", "a\u{301}\u{327}.txt"),
                     ("Caf\u{e9}.txt", "Cafe\u{301}.txt", "Caf\u{e9}.txt"),
                     ("z.txt", "a.txt", "a.txt"), ("😀.txt", "zzzz.txt", "zzzz.txt"),
                     ("z.txt", "aaaa.txt", "z.txt")]
        for (left, right, expected) in pairs {
            let a = snapshot([try entry(filename: left)]), b = snapshot([try entry(filename: right)])
            let ab = try joined([a, b]), ba = try joined([b, a])
            XCTAssertEqual(Data(ab.entries[0].source.label.utf8), Data(expected.utf8))
            assertExact(ab, ba)
        }
    }

    func testReferenceDateBitsSurviveSingletonAndDeterministicMinMaxTies() throws {
        let minusZero = -Double.zero
        for kind in KnowledgeKind.allCases {
            let original = try entry(kind, observed: minusZero, cached: minusZero)
            let alone = try joined([snapshot([original])])
            assertExact(alone, snapshot([original]))
            XCTAssertEqual(alone.entries[0].sourceDate.timeIntervalSinceReferenceDate.bitPattern, 0x8000000000000000)
            // Automatic UUID source dates are immutable, but their cachedAt is reducible.
            let plusCached = copy(original, cached: 0)
            let merged = try joined([snapshot([original]), snapshot([plusCached])])
            XCTAssertEqual(merged.entries[0].cachedAt.timeIntervalSinceReferenceDate.bitPattern, 0)
            assertExact(merged, try joined([snapshot([plusCached]), snapshot([original])]))
            if kind == .selectedFile || kind == .research {
                let plus = copy(original, observed: 0, cached: 0)
                let winner = try joined([snapshot([original]), snapshot([plus])])
                XCTAssertEqual(winner.entries[0].sourceDate.timeIntervalSinceReferenceDate.bitPattern, 0)
                assertExact(winner, try joined([snapshot([plus]), snapshot([original])]))
            } else {
                assertFailure(.changedSource, [snapshot([original]), snapshot([copy(original, observed: 0)])])
            }
        }
        let cutoff = try joined([snapshot(cutoff: 0), snapshot(cutoff: minusZero)])
        XCTAssertEqual(cutoff.clearBefore?.timeIntervalSinceReferenceDate.bitPattern, 0x8000000000000000)
        assertExact(cutoff, try joined([snapshot(cutoff: minusZero), snapshot(cutoff: 0)]))
        XCTAssertNil(try joined([snapshot()]).clearBefore)
        let zeroEntry = try entry(observed: minusZero, cached: minusZero)
        XCTAssertTrue(try joined([snapshot([zeroEntry], cutoff: 0)]).entries.isEmpty)
    }

    func testAdjacentAndSubnormalDatesAreNotRoundedThroughUnixConversion() throws {
        for (earlier, later) in [(721692800.0000001, 721692800.0000002),
                                 (Double.leastNonzeroMagnitude, Double.leastNonzeroMagnitude.nextUp),
                                 (-Double.leastNonzeroMagnitude, -Double.zero)] {
            let a = try entry(observed: later, cached: later), b = try entry(observed: earlier, cached: earlier)
            let result = try joined([snapshot([a]), snapshot([b])])
            XCTAssertEqual(result.entries[0].sourceDate.timeIntervalSinceReferenceDate.bitPattern, earlier.bitPattern)
            XCTAssertEqual(result.entries[0].cachedAt.timeIntervalSinceReferenceDate.bitPattern, earlier.bitPattern)
            assertExact(result, try joined([snapshot([b]), snapshot([a])]))
            XCTAssertEqual(try joined([snapshot([a], cutoff: earlier)]).entries.count, 1)
            let removed = try joined([snapshot([b], cutoff: earlier)])
            XCTAssertEqual(removed.suppressedIDs, [b.id])
            XCTAssertEqual(removed.clearBefore?.timeIntervalSinceReferenceDate.bitPattern, earlier.bitPattern)
        }
    }

    func testSurvivingEntriesKeepEarliestAllowedDatesAndExactRepositoryProvenance() throws {
        for kind in KnowledgeKind.allCases {
            let original = try entry(kind, observed: 200, cached: 300)
            let other = copy(original, observed: kind == .selectedFile || kind == .research ? 100 : 200, cached: 150)
            let expected = copy(other, cached: 150)
            assertExact(try joined([snapshot([original]), snapshot([other])]), snapshot([expected]))
            assertExact(try joined([snapshot([other]), snapshot([original])]), snapshot([expected]))
        }
        let provenance = try KnowledgeSource.repository("owner/repo", path: "Caf\u{e9}.md", commit: String(repeating: "a", count: 40))
        let text = "Pinned synthetic research"
        let item = KnowledgeEntry(id: "research:" + KnowledgePolicy.digest(provenance.label + "\0" + text),
                                  kind: .research, text: text, source: provenance,
                                  sourceDate: date(200), cachedAt: date(300), byteCount: text.utf8.count)
        let a = snapshot([item], project: "owner/repo", repository: "owner/repo")
        let earlier = copy(item, observed: 100, cached: 150)
        let b = snapshot([earlier], project: "owner/repo", repository: "owner/repo")
        assertExact(try KnowledgeSyncJoin.normalize(a).snapshot, a)
        assertExact(try joined([a, b]), b)
        assertExact(try joined([b, a]), b)
        assertFailure(.invalidScope, [snapshot([item], project: "owner/repo")])
    }

    func testImmutablePayloadAndSourceMismatchesFailEvenWhenSuppressedOrCutoffStale() throws {
        let a = try entry(.conversation, text: "a\u{301}\u{327}")
        let b = try entry(.conversation, text: "a\u{327}\u{301}")
        XCTAssertEqual(a.text, b.text) // Swift equality hides this byte conflict.
        XCTAssertEqual(a.byteCount, b.byteCount)
        for history in [snapshot(), snapshot(suppressed: [a.id]), snapshot(cutoff: 200)] {
            assertFailure(.changedSource, [snapshot([a]), snapshot([b]), history])
            assertFailure(.changedSource, [snapshot([b]), history, snapshot([a])])
        }
        let assistant = try source(.conversation, "In-app assistant message")
        assertFailure(.changedSource, [snapshot([a]), snapshot([copy(a, source: assistant)])])
        for kind in [KnowledgeKind.conversation, .action] {
            let original = try entry(kind)
            assertFailure(.changedSource, [snapshot([original]), snapshot([copy(original, observed: 101)])])
        }
    }

    func testScopeAndRepositoryBindingAreExactAndFailClosed() throws {
        let a = snapshot(project: "Caf\u{e9}"), b = snapshot(project: "Cafe\u{301}")
        XCTAssertEqual(a.project, b.project)
        assertFailure(.invalidScope, [a, b])
        assertFailure(.invalidScope, [])
        assertFailure(.invalidScope, [snapshot(account: "github-user-1")])
        assertFailure(.invalidScope, [snapshot(project: "owner/repo", repository: "owner/other")])
        let project = "GitHub account 1: owner/repo"
        let without = snapshot(project: project, account: "github-user-1")
        let with = snapshot(project: project, account: "github-user-1", repository: "owner/repo")
        assertExact(try joined([without, with]), with)
        assertExact(try joined([with, without]), with)
        assertFailure(.invalidScope, [with, snapshot(project: project, account: "github-user-1", repository: "other/repo")])
    }

    func testInvalidOriginalsAreRejectedBeforeNormalizationCanHideThem() throws {
        let item = try entry()
        assertFailure(.invalidContent, [snapshot([item, item], suppressed: [item.id])])
        assertFailure(.invalidContent, [snapshot(suppressed: [item.id, item.id])])
        assertFailure(.invalidContent, [snapshot(suppressed: ["file:invalid"])])
        assertFailure(.invalidContent, [snapshot([copy(item, byteCount: 1)], suppressed: [item.id])])
        for value in [Double.nan, Double.infinity, -Double.infinity, -978307201, Date.distantFuture.timeIntervalSinceReferenceDate.nextUp] {
            assertFailure(.invalidContent, [snapshot([copy(item, observed: value)], suppressed: [item.id])])
            assertFailure(.invalidContent, [snapshot([copy(item, cached: value)], suppressed: [item.id])])
            assertFailure(.invalidContent, [snapshot(cutoff: value)])
        }
        assertFailure(.invalidContent, [snapshot(cutoff: Date().timeIntervalSinceReferenceDate + 600)])
        let research = try entry(.research)
        let emptyRevision = try source(.web, research.source.label, revision: "")
        let emptyRepository = try source(.web, research.source.label, repository: "")
        assertFailure(.invalidContent, [snapshot([copy(research, source: emptyRevision)])])
        assertFailure(.invalidContent, [snapshot([copy(research, source: emptyRepository)])])
        let badFile = try copy(item, source: source(.selectedFile, "../sample.txt", revision: item.source.revision))
        assertFailure(.unsupportedFile, [snapshot([badFile], suppressed: [item.id])])
    }

    func testCompatibleStatesAreCommutativeIdempotentAndAssociativeAcrossAllKinds() throws {
        // Deterministic generated cases: every kind, overlap pattern, cutoff and explicit
        // deletion exercises the real join, then all six three-device permutations.
        for seed in 0..<12 {
            var states: [KnowledgeSyncSnapshot] = []
            for device in 0..<3 {
                var items: [KnowledgeEntry] = [], deleted: [String] = []
                for (kindIndex, kind) in KnowledgeKind.allCases.enumerated() {
                    for index in 0..<3 {
                        let observation = kind == .selectedFile || kind == .research ? Double(100 + 50 * device) : Double(100 + 50 * index)
                        let item = try entry(kind, index: kindIndex * 10 + index, observed: observation,
                                             cached: Double(100 + 50 * device), filename: ["z.txt", "a.txt", "long.txt"][device])
                        if (seed + device + index) % 3 != 0 { items.append(item) }
                        if (seed + device + index + kindIndex) % 7 == 0 { deleted.append(item.id) }
                    }
                }
                let cutoff: Double? = (seed + device) % 3 == 0 ? 150 : nil
                states.append(snapshot(Array(items.reversed()), suppressed: Array(deleted.reversed()), cutoff: cutoff))
            }
            let expected = try joined(states)
            XCTAssertTrue(expected.entries.allSatisfy { !Set(expected.suppressedIDs).contains($0.id) && !$0.predatesSyncClear(expected.clearBefore) })
            XCTAssertEqual(expected.entries.map(\.id), expected.entries.map(\.id).sorted())
            XCTAssertEqual(expected.suppressedIDs, expected.suppressedIDs.sorted())
            assertExact(try joined([expected, expected]), expected)
            assertExact(try joined([snapshot(), expected]), expected)
            assertExact(try joined([expected, snapshot()]), expected)
            for order in permutations {
                let a = states[order[0]], b = states[order[1]], c = states[order[2]]
                assertExact(try joined([a, b, c]), expected)
                assertExact(try joined([joined([a, b]), c]), expected)
                assertExact(try joined([a, joined([b, c])]), expected)
                assertExact(try joined([expected, a]), expected)
            }
        }
    }

    private func marker(_ index: Int) -> String {
        "file:" + String(repeating: "0", count: 64 - String(index, radix: 16).count) + String(index, radix: 16)
    }

    func testSuppressionBudgetRetainsExactlyOneHundredThousandAndRejectsOverflow() throws {
        let markers = (0..<99_999).map(marker)
        let stale = try entry(cached: 100)
        let prior = snapshot(suppressed: markers, cutoff: 150)
        let result = try KnowledgeSyncJoin.join([prior, snapshot([stale])])
        XCTAssertEqual(result.snapshot.suppressedIDs.count, 100_000)
        XCTAssertEqual(result.cutoffSuppressedIDs, [stale.id])
        XCTAssertTrue(result.snapshot.entries.isEmpty)
        assertExact(try joined([result.snapshot, snapshot(suppressed: [stale.id])]), result.snapshot)
        assertFailure(.quota, [result.snapshot, snapshot(suppressed: [marker(100_000)])])
        XCTAssertEqual(prior.suppressedIDs.count, 99_999)
        XCTAssertEqual(prior.clearBefore?.timeIntervalSinceReferenceDate, 150)
        assertFailure(.invalidContent, [snapshot(suppressed: (0...100_000).map(marker))])
    }

    func testAllTenThousandCutoffEntriesBecomeMarkersWithoutTruncation() throws {
        let items = try (0..<10_000).map { try entry(.action, index: $0) }
        let prior = snapshot(items, suppressed: (0..<90_000).map(marker), cutoff: 100)
        let result = try KnowledgeSyncJoin.normalize(prior)
        XCTAssertTrue(result.snapshot.entries.isEmpty)
        XCTAssertEqual(result.snapshot.suppressedIDs.count, 100_000)
        XCTAssertEqual(result.cutoffSuppressedIDs.count, 10_000)
        XCTAssertEqual(Set(result.cutoffSuppressedIDs), Set(items.map(\.id)))
        XCTAssertEqual(result.removedEntryIDs, result.cutoffSuppressedIDs)
        assertFailure(.quota, [prior, snapshot(suppressed: [marker(90_000)])])
        XCTAssertEqual(prior.entries.count, 10_000)
        XCTAssertEqual(prior.suppressedIDs.count, 90_000)
    }

    func testEntryCountLimitFailsWithoutEviction() throws {
        let a = snapshot(try (0..<5_000).map { try entry(.action, index: $0) })
        let b = snapshot(try (5_000..<10_000).map { try entry(.action, index: $0) })
        XCTAssertEqual(try joined([a, b]).entries.count, 10_000)
        let extra = snapshot([try entry(.action, index: 10_000)])
        assertFailure(.quota, [a, b, extra])
        let oversized = snapshot(a.entries + b.entries + extra.entries, suppressed: [extra.entries[0].id])
        assertFailure(.invalidContent, [oversized])
        XCTAssertEqual(a.entries.count, 5_000)
        XCTAssertEqual(b.entries.count, 5_000)
    }

    private func sourceByteBoundaryEntries(_ count: Int) throws -> [KnowledgeEntry] {
        // Preserve the actual 256 KiB record / 50 MiB cache limits and safety scans.
        // The ASCII fixture timed out even after splitting these tests. Four-byte
        // scalars preserve the byte boundary while reducing repeated scalar scans.
        // Production validation and all per-test/invocation bounds stay unchanged.
        let text = String(repeating: "😀", count: 64 * 1_024)
        XCTAssertEqual(text.utf8.count, 256 * 1_024)
        XCTAssertEqual(text.unicodeScalars.count, 64 * 1_024)
        return try (0..<count).map { try entry(.conversation, index: $0, text: text) }
    }

    func testSourceByteUnionAcceptsExactlyFiftyMiB() throws {
        let large = try sourceByteBoundaryEntries(200)
        let atLimit = try joined([snapshot(Array(large.prefix(100))), snapshot(Array(large[100..<200]))])
        XCTAssertEqual(atLimit.entries.count, 200)
        XCTAssertEqual(atLimit.entries.reduce(0) { $0 + $1.byteCount }, 50 * 1_024 * 1_024)
    }

    func testSourceByteUnionRejectsOverflowWithoutEviction() throws {
        let large = try sourceByteBoundaryEntries(201)
        let a = snapshot(Array(large.prefix(100))), b = snapshot(Array(large.dropFirst(100)))
        assertFailure(.quota, [a, b])
        XCTAssertEqual(a.entries.count, 100)
        XCTAssertEqual(b.entries.count, 101)
        XCTAssertEqual(a.entries.reduce(0) { $0 + $1.byteCount } + b.entries.reduce(0) { $0 + $1.byteCount },
                       50 * 1_024 * 1_024 + 256 * 1_024)
    }

    func testSuppressionCannotHideSourceByteOverflow() throws {
        let large = try sourceByteBoundaryEntries(201)
        assertFailure(.quota, [snapshot(large, suppressed: large.map(\.id))])
        XCTAssertEqual(large.count, 201)
    }
}
