import XCTest
@testable import AsterionVeyra

final class RepositoryTextSearchTests: XCTestCase {
    private let commit = String(repeating: "a", count: 40)
    private let tree = String(repeating: "b", count: 40)
    private let blob = String(repeating: "c", count: 40)

    func testSearchFindsLateImplementationWithPinnedLineAndBlobEvidence() async throws {
        let text = String(repeating: "unrelated source line\n", count: 400) + "before\nfunc usefulTarget() {}\nafter\n"
        let spy = SearchReader(text: text)
        let tools = try makeTools(spy)
        let preflight = try await tools.list(path: "", maximumCharacters: 600)
        let result = try await tools.search(path: "Source.swift", query: "usefulTarget")
        XCTAssertTrue(result.contains("Source: owner/repo/Source.swift @ " + commit))
        XCTAssertTrue(result.contains("Blob: " + blob))
        XCTAssertTrue(result.contains("untrusted"))
        XCTAssertTrue(result.contains("L401: before\nL402: func usefulTarget() {}\nL403: after"))
        XCTAssertFalse(result.contains("L1:"))
        XCTAssertLessThanOrEqual(preflight.count + result.count, 4_000)
        let requests = await spy.requests
        XCTAssertEqual(requests, ["tree:" + commit, "blob:" + blob])
    }

    func testSearchTraversesOnlyObservedPinnedAncestors() async throws {
        let spy = SearchReader(text: "needle", nested: true)
        let result = try await makeTools(spy).search(path: "Sources/Source.swift", query: "needle")
        XCTAssertTrue(result.contains("Sources/Source.swift"))
        let requests = await spy.requests
        XCTAssertEqual(requests, ["tree:" + commit, "tree:" + tree, "blob:" + blob])
    }

    func testOverlappingContextWindowsRenderEachLineOnlyOnce() async throws {
        let spy = SearchReader(text: "first\nneedle one\nneedle two\nneedle three\nlast")
        let result = try await makeTools(spy).search(path: "Source.swift", query: "needle")
        XCTAssertTrue(result.contains("Matching lines: 3"))
        XCTAssertTrue(result.contains("L1: first\nL2: needle one\nL3: needle two\nL4: needle three\nL5: last"))
        XCTAssertEqual(result.components(separatedBy: "L3:").count, 2)
    }

    func testSearchDisclosesUnselectedMatchingLinesWithoutClaimingRepositoryCoverage() async throws {
        let text = "needle one\nx\nx\nneedle two\nx\nx\nneedle three\nx\nx\nneedle four\nx\n"
        let result = try await makeTools(SearchReader(text: text)).search(path: "Source.swift", query: "needle")
        XCTAssertTrue(result.contains("Matching lines: 4"))
        XCTAssertTrue(result.contains("1 additional matching line not selected as an anchor"))
        XCTAssertTrue(result.contains("No other files were searched"))
        XCTAssertFalse(result.contains("needle four"))
    }

    func testMatchingContextLineStillShowsItsLateMatchWithoutFalseOmissionClaim() async throws {
        let text = "needle one\nneedle two\nneedle three\n" + String(repeating: "x", count: 1_000) + "needle four"
        let result = try await makeTools(SearchReader(text: text)).search(path: "Source.swift", query: "needle")
        XCTAssertTrue(result.contains("Matching lines: 4"))
        XCTAssertTrue(result.contains("1 additional matching line not selected as an anchor"))
        XCTAssertTrue(result.contains("needle four"), "The fourth match is a context line, not a selected anchor")
        XCTAssertFalse(result.contains("1 matching line omitted"))
    }

    func testNoMatchInspectsOnlyThisCompleteFileAndEmptyFileIsValid() async throws {
        for (text, count) in [("first\r\nsecond\r\n", 3), ("", 1)] {
            let result = try await makeTools(SearchReader(text: text)).search(path: "Source.swift", query: "missing")
            XCTAssertTrue(result.contains("\(count) lines"))
            XCTAssertTrue(result.contains("no matching lines"))
            XCTAssertTrue(result.contains("No other files were searched"))
        }
    }

    func testLiteralSearchDoesNotInterpretRegexFoldCaseOrNormalizeUnicode() async throws {
        let text = "a.b\naxb\nNEEDLE\nneedle\n\u{e9}\ne\u{301}\n"
        let literal = try await makeTools(SearchReader(text: text)).search(path: "Source.swift", query: "a.b")
        XCTAssertTrue(literal.contains("Matching lines: 1"))
        let lower = try await makeTools(SearchReader(text: text)).search(path: "Source.swift", query: "needle")
        XCTAssertTrue(lower.contains("Matching lines: 1"))
        XCTAssertTrue(lower.contains("L4: needle"))
        let composed = try await makeTools(SearchReader(text: text)).search(path: "Source.swift", query: "\u{e9}")
        XCTAssertTrue(composed.contains("Matching lines: 1"))
        XCTAssertTrue(composed.contains("L5: \u{e9}"))
    }

    func testCRLFAndEmojiKeepOriginalLineNumbersAndNoCarriageReturns() async throws {
        let result = try await makeTools(SearchReader(text: "one\r\n🦋 target\r\nthree\r\n"))
            .search(path: "Source.swift", query: "🦋")
        XCTAssertTrue(result.contains("L1: one\nL2: 🦋 target\nL3: three"))
        XCTAssertFalse(result.contains("\r"))
    }

    func testStandaloneCRAndUnicodeSeparatorsAreVisibleWithoutInventingLineNumbers() async throws {
        let text = "before\rneedle\u{2028}part\u{2029}end\r"
        let result = try await makeTools(SearchReader(text: text)).search(path: "Source.swift", query: "needle")
        XCTAssertTrue(result.contains("L1: before\\rneedle\\u{2028}part\\u{2029}end\\r"))
        XCTAssertFalse(result.contains("L2:"))
        XCTAssertFalse(result.contains("\r"))
        XCTAssertFalse(result.contains("\u{2028}"))
        XCTAssertFalse(result.contains("\u{2029}"))
    }

    func testQueryWhitespaceIsValidatedButNeverTrimmedFromLiteralMatch() async throws {
        let text = "needle\n needle \nneedle\n"
        let result = try await makeTools(SearchReader(text: text)).search(path: "Source.swift", query: " needle ")
        XCTAssertTrue(result.contains("Matching lines: 1"))
        XCTAssertTrue(result.contains("L2:  needle "))
    }

    func testLongLineShowsActualLateMatchAndMarksBothOmissions() async throws {
        let text = String(repeating: "x", count: 10_000) + "specificNeedle" + String(repeating: "y", count: 10_000)
        let result = try await makeTools(SearchReader(text: text)).search(path: "Source.swift", query: "specificNeedle")
        XCTAssertTrue(result.contains("specificNeedle"))
        XCTAssertTrue(result.contains("[line prefix omitted]"))
        XCTAssertTrue(result.contains("[line suffix omitted]"))
        XCTAssertLessThan(result.count, 1_000)
    }

    func testMaximumQueryAndUnicodeMatchAreNotCutFromLongLine() async throws {
        let query = String(repeating: "🦋", count: 32) // Exactly 128 UTF-8 bytes.
        let text = String(repeating: "e\u{301}", count: 300) + query + String(repeating: "z", count: 300)
        let result = try await makeTools(SearchReader(text: text)).search(path: "Source.swift", query: query)
        XCTAssertTrue(result.contains(query))
        XCTAssertFalse(result.contains("\u{fffd}"))
        XCTAssertLessThan(result.count, 1_000)
    }

    func testInvalidQueriesFailBeforeAnyNetworkAndNeverEchoTheirContents() async throws {
        for query in ["", " \t", "a\nb", "a\rb", "a\u{0}b", "a\u{200d}b", "a\u{2028}b", "a\u{2029}b", "a\u{202e}b", "a\u{2066}b", String(repeating: "a", count: 129), String(repeating: "🦋", count: 33), "password=privateValue"] {
            let spy = SearchReader(text: "safe")
            let tools = try makeTools(spy)
            await assertFailure(.invalidQuery) { try await tools.search(path: "Source.swift", query: query) }
            let requests = await spy.requests
            XCTAssertTrue(requests.isEmpty)
            let message = try await SearchRepositoryTextTool(repository: tools).call(arguments: .init(path: "Source.swift", query: query))
            XCTAssertFalse(message.contains("privateValue"))
        }
    }

    func testUnsafePathsAndEntriesNeverReachBlobTransport() async throws {
        for (path, type, failure) in [("../Source.swift", "file", RepositoryToolFailure.invalidPath),
                                     (".env", "file", .unsafeEntry), ("Source.swift", "symlink", .unsafeEntry),
                                     ("Source.swift", "submodule", .unsafeEntry), ("Source.swift", "dir", .unsafeEntry)] {
            let spy = SearchReader(text: "needle", type: type)
            await assertFailure(failure) { try await self.makeTools(spy).search(path: path, query: "needle") }
            let requests = await spy.requests
            XCTAssertFalse(requests.contains("blob:" + blob))
        }
    }

    func testOversizedNegativeAndMismatchedFilesStayRejected() async throws {
        for (size, failure) in [(60_001, RepositoryToolFailure.fileTooLarge), (-1, .fileTooLarge), (8, .invalidResponse)] {
            let spy = SearchReader(text: "needle", declaredSize: size)
            await assertFailure(failure) { try await self.makeTools(spy).search(path: "Source.swift", query: "needle") }
        }
    }

    func testUnknownSizeFileStaysRejectedWithoutBlobRead() async throws {
        let source = RepoFile(name: "Source.swift", path: "Source.swift", type: "file", sha: blob, size: nil)
        let reader = RepositoryToolReader(tree: { _, _ in ([source], 100) }, text: { _, _ in
            XCTFail("Unknown-size source must not be fetched"); return ("needle", 100)
        })
        let tools = try RepositoryQuestionTools(scope: .init(repository: "owner/repo", commit: commit), reader: reader)
        await assertFailure(.fileTooLarge) { try await tools.search(path: "Source.swift", query: "needle") }
    }

    func testFullFileSafetyScreeningPrecedesEvenInnocuousMatchingExcerpt() async throws {
        for unsafe in ["password=DO_NOT_RETURN", "\u{0}", "\u{01}"] {
            let text = "innocuous needle\n" + String(repeating: "normal\n", count: 1_000) + unsafe
            let tools = try makeTools(SearchReader(text: text))
            await assertFailure(.unsafeText) { try await tools.search(path: "Source.swift", query: "needle") }
        }
    }

    func testInvalidSearchConsumesSharedCallLimitButNoRequest() async throws {
        let spy = SearchReader(text: "needle")
        let tools = try makeTools(spy, limits: .init(maximumCalls: 2))
        await assertFailure(.invalidQuery) { try await tools.search(path: "Source.swift", query: "") }
        _ = try await tools.read(path: "Source.swift")
        await assertFailure(.callLimit) { try await tools.list(path: "") }
        let requests = await spy.requests
        XCTAssertEqual(requests.count, 2)
    }

    func testSearchChargesOneCallAndOnlyItsReturnedExcerpt() async throws {
        let text = String(repeating: "prefix\n", count: 2_000) + "needle"
        let tools = try makeTools(SearchReader(text: text), limits: .init(maximumCalls: 1))
        let result = try await tools.search(path: "Source.swift", query: "needle")
        XCTAssertTrue(result.contains("L2001: needle"))
        XCTAssertFalse(result.contains("Truncated"))
        await assertFailure(.callLimit) { try await tools.list(path: "") }
    }

    func testSearchCannotRestoreBudgetAlreadySpentOnTruncatedPrefixRead() async throws {
        let spy = SearchReader(text: String(repeating: "prefix\n", count: 2_000) + "needle")
        let tools = try makeTools(spy)
        let prefix = try await tools.read(path: "Source.swift")
        XCTAssertTrue(prefix.contains("Truncated"))
        await assertFailure(.outputLimit) { try await tools.search(path: "Source.swift", query: "needle") }
        let requests = await spy.requests
        XCTAssertEqual(requests.count, 2, "Search must fail before another blob request when output is exhausted")
    }

    func testSearchAndReadShareRequestAndResponseByteBudgets() async throws {
        for limits in [RepositoryToolLimits(maximumRequests: 2), .init(maximumResponseBytes: 200)] {
            let spy = SearchReader(text: "needle")
            let tools = try makeTools(spy, limits: limits)
            _ = try await tools.search(path: "Source.swift", query: "needle")
            let expected: RepositoryToolFailure = limits.maximumRequests == 2 ? .requestLimit : .byteLimit
            await assertFailure(expected) { try await tools.read(path: "Source.swift") }
            let requests = await spy.requests
            XCTAssertEqual(requests.count, 2)
        }
    }

    func testOutputBudgetStillBoundsSearchAndPreventsFollowUpRequests() async throws {
        let spy = SearchReader(text: String(repeating: "x", count: 400) + "needle" + String(repeating: "y", count: 400))
        let tools = try makeTools(spy, limits: .init(maximumOutputCharacters: 256))
        let result = try await tools.search(path: "Source.swift", query: "needle")
        XCTAssertEqual(result.count, 256)
        XCTAssertTrue(result.contains("Truncated"))
        await assertFailure(.outputLimit) { try await tools.read(path: "Source.swift") }
        let requests = await spy.requests
        XCTAssertEqual(requests.count, 2)
    }

    func testSearchCannotUseCachedMetadataAfterRevocation() async throws {
        let session = try GitHubAuthSession(token: "github_pat_SYNTHETIC_TEST_ONLY_123")
        let client = GitHubClient(authentication: session)
        let spy = SearchReader(text: "needle")
        var reader = spy.reader
        reader.checkAccess = { try client.validateSession() }
        let tools = try RepositoryQuestionTools(scope: .init(repository: "owner/repo", commit: commit), reader: reader)
        _ = try await tools.list(path: "")
        session.revoke()
        await assertFailure(.authenticationRequired) { try await tools.search(path: "Source.swift", query: "needle") }
        let requests = await spy.requests
        XCTAssertEqual(requests, ["tree:" + commit])
    }

    func testSearchWithholdsLateBlobAfterRevocation() async throws {
        let session = try GitHubAuthSession(token: "github_pat_SYNTHETIC_TEST_ONLY_123")
        let client = GitHubClient(authentication: session)
        let spy = SearchReader(text: "needle")
        var reader = spy.reader
        reader.checkAccess = { try client.validateSession() }
        reader.text = { _, _ in session.revoke(); return ("needle", 100) }
        let tools = try RepositoryQuestionTools(scope: .init(repository: "owner/repo", commit: commit), reader: reader)
        await assertFailure(.authenticationRequired) { try await tools.search(path: "Source.swift", query: "needle") }
    }

    func testConcurrentSearchAndReadCannotSpendTheSameBlobReservation() async throws {
        let gate = SearchBlobGate()
        let spy = SearchReader(text: "needle")
        var reader = spy.reader
        reader.text = { _, _ in try await gate.read() }
        let tools = try RepositoryQuestionTools(scope: .init(repository: "owner/repo", commit: commit), reader: reader,
                                               limits: .init(maximumResponseBytes: 200))
        _ = try await tools.list(path: "")
        let search = Task { try await tools.search(path: "Source.swift", query: "needle") }
        await gate.waitUntilStarted()
        await assertFailure(.byteLimit) { try await tools.read(path: "Source.swift") }
        await tools.cancel()
        do { _ = try await search.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        do { _ = try await tools.search(path: "Source.swift", query: "needle"); XCTFail("Cancelled scope cannot search") }
        catch { XCTAssertTrue(error is CancellationError) }
    }

    func testSearchTransportErrorsAreSanitizedAndNeverRetried() async throws {
        let spy = SearchReader(text: "needle")
        let failedBlobs = SearchFailedBlobCounter()
        var reader = spy.reader
        reader.text = { _, _ in try await failedBlobs.read() }
        let tools = try RepositoryQuestionTools(scope: .init(repository: "owner/repo", commit: commit), reader: reader)
        let message = try await SearchRepositoryTextTool(repository: tools).call(arguments: .init(path: "Source.swift", query: "needle"))
        XCTAssertTrue(message.contains("failed"))
        XCTAssertFalse(message.contains("DO_NOT_RETURN"))
        let requests = await spy.requests
        XCTAssertEqual(requests, ["tree:" + commit])
        let attempts = await failedBlobs.attempts
        XCTAssertEqual(attempts, 1, "A failed blob request must not be retried")
    }

    private func makeTools(_ spy: SearchReader, limits: RepositoryToolLimits = .init()) throws -> RepositoryQuestionTools {
        try RepositoryQuestionTools(scope: .init(repository: "owner/repo", commit: commit), reader: spy.reader, limits: limits)
    }
    private func assertFailure(_ expected: RepositoryToolFailure, operation: () async throws -> String,
                               file: StaticString = #filePath, line: UInt = #line) async {
        do { _ = try await operation(); XCTFail("Expected \(expected)", file: file, line: line) }
        catch { XCTAssertEqual(error as? RepositoryToolFailure, expected, file: file, line: line) }
    }
}

// Only network I/O is substituted. Traversal, policy, formatting and budgets stay real.
private actor SearchReader {
    let text: String
    let type: String
    let size: Int
    let nested: Bool
    var requests: [String] = []
    init(text: String, type: String = "file", declaredSize: Int? = nil, nested: Bool = false) {
        self.text = text; self.type = type; size = declaredSize ?? text.utf8.count; self.nested = nested
    }
    nonisolated var reader: RepositoryToolReader {
        RepositoryToolReader(tree: { sha, _ in await self.tree(sha) }, text: { file, _ in await self.read(file) })
    }
    func tree(_ sha: String) -> (files: [RepoFile], responseBytes: Int) {
        requests.append("tree:" + sha)
        if nested && sha == String(repeating: "a", count: 40) {
            return ([RepoFile(name: "Sources", path: "Sources", type: "dir", sha: String(repeating: "b", count: 40), size: nil)], 100)
        }
        return ([RepoFile(name: "Source.swift", path: "Source.swift", type: type, sha: String(repeating: "c", count: 40), size: size)], 100)
    }
    func read(_ file: RepoFile) -> (text: String, responseBytes: Int) {
        requests.append("blob:" + file.sha); return (text, 100)
    }
}

private actor SearchBlobGate {
    var started = false
    var waiter: CheckedContinuation<Void, Never>?
    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { waiter = $0 }
    }
    func read() async throws -> (text: String, responseBytes: Int) {
        started = true; waiter?.resume(); waiter = nil
        try await Task.sleep(nanoseconds: 30_000_000_000)
        return ("needle", 100)
    }
}

private actor SearchFailedBlobCounter {
    var attempts = 0
    func read() throws -> (text: String, responseBytes: Int) {
        attempts += 1
        throw AppFailure.message("private response DO_NOT_RETURN")
    }
}
