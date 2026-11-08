import XCTest
@testable import AsterionVeyra

final class RepositoryToolTests: XCTestCase {
    private let commit = String(repeating: "a", count: 40)
    private let tree = String(repeating: "b", count: 40)
    private let blob = String(repeating: "c", count: 40)

    private func file(_ path: String, type: String = "file", size: Int? = 5) -> RepoFile {
        RepoFile(name: path, path: path, type: type, sha: blob, size: size)
    }

    func testScopeRequiresAnImmutableCommitAndSingleRepository() {
        XCTAssertThrowsError(try RepositoryToolScope(repository: "owner/repo", commit: "main"))
        XCTAssertThrowsError(try RepositoryToolScope(repository: "owner/repo/other", commit: commit))
        XCTAssertThrowsError(try RepositoryToolScope(repository: "https://evil.test/repo", commit: commit))
        XCTAssertNoThrow(try RepositoryToolScope(repository: "owner/repo", commit: commit))
    }

    func testRejectsTraversalURLsAndEncodedPathsBeforeAnyRequest() async throws {
        let spy = RepositoryReaderSpy(entries: [:])
        let tools = try makeTools(spy)
        for path in ["../secret", "src/../secret", "/README.md", "https://evil.test/a", "a//b", "a\\b", "a/%2e%2e/b", "a?ref=main"] {
            await assertFailure(.invalidPath) { try await tools.read(path: path) }
        }
        let requests = await spy.requests
        XCTAssertTrue(requests.isEmpty)
    }

    func testRejectsOversizedAndControlCharacterPathsWithoutRequests() async throws {
        let spy = RepositoryReaderSpy(entries: [:])
        let tools = try makeTools(spy)
        for path in [String(repeating: "a", count: 513), "a\u{202E}b", "a\nb", Array(repeating: "a", count: 17).joined(separator: "/")] {
            await assertFailure(.invalidPath) { try await tools.read(path: path) }
        }
        let requests = await spy.requests
        XCTAssertTrue(requests.isEmpty)
    }

    func testRootListingIncludesBoundSourceProvenance() async throws {
        let spy = RepositoryReaderSpy(entries: [commit: [file("README.md")]])
        let output = try await makeTools(spy).list(path: "")
        XCTAssertTrue(output.contains("owner/repo"))
        XCTAssertTrue(output.contains(commit))
        XCTAssertTrue(output.contains("README.md"))
        XCTAssertTrue(output.contains("untrusted"))
        let requests = await spy.requests
        XCTAssertEqual(requests, ["tree:" + commit])
    }

    func testReadResolvesEveryAncestorUsingObservedTreeIDs() async throws {
        let directory = RepoFile(name: "Sources", path: "Sources", type: "dir", sha: tree, size: nil)
        let spy = RepositoryReaderSpy(entries: [commit: [directory], tree: [file("Main.swift")]], text: "hello")
        let output = try await makeTools(spy).read(path: "Sources/Main.swift")
        XCTAssertTrue(output.contains("Sources/Main.swift"))
        XCTAssertTrue(output.contains("hello"))
        let requests = await spy.requests
        XCTAssertEqual(requests, ["tree:" + commit, "tree:" + tree, "blob:" + blob])
    }

    func testDirectoryCacheAvoidsAdditionalNetworkRequests() async throws {
        let spy = RepositoryReaderSpy(entries: [commit: [file("README.md")]])
        let tools = try makeTools(spy)
        _ = try await tools.list(path: "")
        _ = try await tools.read(path: "README.md")
        let requests = await spy.requests
        XCTAssertEqual(requests, ["tree:" + commit, "blob:" + blob])
    }

    func testReadRefusesMissingFilesSymlinksSubmodulesAndDirectories() async throws {
        let spy = RepositoryReaderSpy(entries: [commit: [file("link", type: "symlink"), file("vendor", type: "submodule"), file("src", type: "dir", size: nil)]])
        let tools = try makeTools(spy)
        await assertFailure(.entryUnavailable) { try await tools.read(path: "missing") }
        await assertFailure(.unsafeEntry) { try await tools.read(path: "link") }
        await assertFailure(.unsafeEntry) { try await tools.read(path: "vendor") }
        await assertFailure(.unsafeEntry) { try await tools.read(path: "src") }
        let requests = await spy.requests
        XCTAssertEqual(requests, ["tree:" + commit])
    }

    func testAncestorSymlinkCannotBeTraversed() async throws {
        let spy = RepositoryReaderSpy(entries: [commit: [file("link", type: "symlink")]])
        await assertFailure(.unsafeEntry) { try await self.makeTools(spy).read(path: "link/secret") }
        let requests = await spy.requests
        XCTAssertEqual(requests, ["tree:" + commit])
    }

    func testMalformedTreeMetadataIsRejectedBeforeBlobRead() async throws {
        let escaped = RepoFile(name: "safe", path: "../private", type: "file", sha: blob, size: 5)
        let spy = RepositoryReaderSpy(entries: [commit: [escaped]])
        await assertFailure(.invalidResponse) { try await self.makeTools(spy).read(path: "safe") }
        let requests = await spy.requests
        XCTAssertEqual(requests.count, 1)
    }

    func testDuplicateTreePathsAreNotTrusted() async throws {
        let spy = RepositoryReaderSpy(entries: [commit: [file("same"), file("same")]])
        await assertFailure(.invalidResponse) { try await self.makeTools(spy).list(path: "") }
    }

    func testLargeOrUnknownSizeFilesAreRefusedBeforeBlobRead() async throws {
        let spy = RepositoryReaderSpy(entries: [commit: [file("big", size: 60_001), file("unknown", size: nil), file("negative", size: -1)]])
        let tools = try makeTools(spy)
        for path in ["big", "unknown", "negative"] {
            await assertFailure(.fileTooLarge) { try await tools.read(path: path) }
        }
        let requests = await spy.requests
        XCTAssertEqual(requests, ["tree:" + commit])
    }

    func testBinaryAndCredentialLikeTextNeverReachModelOutput() async throws {
        for content in ["ab\u{0}cd", "password=example", "ghp_123456789012345678901234567890123456"] {
            let spy = RepositoryReaderSpy(entries: [commit: [file("config", size: content.utf8.count)]], text: content)
            await assertFailure(.unsafeText) { try await self.makeTools(spy).read(path: "config") }
        }
    }

    func testBlobSizeMustMatchVerifiedTreeMetadata() async throws {
        let spy = RepositoryReaderSpy(entries: [commit: [file("small", size: 1)]], text: "hello")
        await assertFailure(.invalidResponse) { try await self.makeTools(spy).read(path: "small") }
    }

    func testCallLimitIsSharedByBothTools() async throws {
        let spy = RepositoryReaderSpy(entries: [commit: [file("README.md")]])
        let tools = try makeTools(spy, limits: .init(maximumCalls: 2))
        _ = try await tools.list(path: "")
        _ = try await tools.read(path: "README.md")
        await assertFailure(.callLimit) { try await tools.read(path: "README.md") }
        let requests = await spy.requests
        XCTAssertEqual(requests.count, 2)
    }

    func testRequestLimitIncludesAncestorTraversal() async throws {
        let directory = RepoFile(name: "src", path: "src", type: "dir", sha: tree, size: nil)
        let spy = RepositoryReaderSpy(entries: [commit: [directory], tree: [file("main")]])
        let tools = try makeTools(spy, limits: .init(maximumRequests: 1))
        await assertFailure(.requestLimit) { try await tools.read(path: "src/main") }
        let requests = await spy.requests
        XCTAssertEqual(requests, ["tree:" + commit])
    }

    func testByteBudgetUsesActualResponsesAndCapsRemainingRequest() async throws {
        let spy = RepositoryReaderSpy(entries: [commit: [file("README.md")]], responseBytes: 100)
        let tools = try makeTools(spy, limits: .init(maximumResponseBytes: 200))
        _ = try await tools.read(path: "README.md")
        await assertFailure(.byteLimit) { try await tools.read(path: "README.md") }
        let caps = await spy.caps
        XCTAssertEqual(caps, [200, 100])
    }

    func testOversizedResponseFailsClosedAndConsumesReservation() async throws {
        let spy = RepositoryReaderSpy(entries: [commit: [file("README.md")]], responseBytes: 201)
        let tools = try makeTools(spy, limits: .init(maximumResponseBytes: 200))
        await assertFailure(.invalidResponse) { try await tools.list(path: "") }
        await assertFailure(.byteLimit) { try await tools.list(path: "") }
        let requests = await spy.requests
        XCTAssertEqual(requests.count, 1)
    }

    func testOutputBudgetIsSharedAndTruncationIsExplicit() async throws {
        let content = String(repeating: "source line\n", count: 1_000)
        let spy = RepositoryReaderSpy(entries: [commit: [file("README.md", size: content.utf8.count)]], text: content)
        let tools = try makeTools(spy)
        let listing = try await tools.list(path: "")
        let reading = try await tools.read(path: "README.md")
        XCTAssertLessThanOrEqual(listing.count + reading.count, 4_000)
        XCTAssertTrue(reading.contains("Truncated"))
        await assertFailure(.outputLimit) { try await tools.read(path: "README.md") }
        let requests = await spy.requests
        XCTAssertEqual(requests.count, 2)
    }

    func testDirectorySummaryDoesNotPretendItIsComplete() async throws {
        let entries = (0..<70).map { file("file\($0)") }
        let spy = RepositoryReaderSpy(entries: [commit: entries])
        let output = try await makeTools(spy).list(path: "")
        XCTAssertTrue(output.contains("10 entries omitted"))
    }

    func testUpstreamErrorDoesNotLeakItsContents() async throws {
        let reader = RepositoryToolReader(tree: { _, _ in throw AppFailure.message("password=DO_NOT_LEAK") }, text: { _, _ in throw AppFailure.message("private URL") })
        let tools = try RepositoryQuestionTools(scope: .init(repository: "owner/repo", commit: commit), reader: reader)
        let output = try await ListRepositoryDirectoryTool(repository: tools).call(arguments: .init(path: ""))
        XCTAssertFalse(output.contains("DO_NOT_LEAK"))
        XCTAssertFalse(output.contains("password"))
        XCTAssertTrue(output.contains("failed"))
    }

    func testCredentialFileNamesAreRefusedBeforeNetwork() async throws {
        let spy = RepositoryReaderSpy(entries: [:])
        let tools = try makeTools(spy)
        for path in [".env", "config/.env.local", "id_ed25519", "private.pem"] {
            await assertFailure(.unsafeEntry) { try await tools.read(path: path) }
        }
        let requests = await spy.requests
        XCTAssertTrue(requests.isEmpty)
    }

    func testRevokedConnectionCannotReadCachedMetadata() async throws {
        let access = RepositoryAccessGate()
        let spy = RepositoryReaderSpy(entries: [commit: [file("README.md")]])
        var reader = spy.reader
        reader.checkAccess = { try access.check() }
        let tools = try RepositoryQuestionTools(scope: .init(repository: "owner/repo", commit: commit), reader: reader)
        _ = try await tools.list(path: "")
        access.revoke()
        await assertFailure(.readFailed) { try await tools.list(path: "") }
        let requests = await spy.requests
        XCTAssertEqual(requests.count, 1)
    }

    func testConcurrentCallsCannotOverspendReservedBytes() async throws {
        let waiting = WaitingRepositoryReader()
        let reader = RepositoryToolReader(tree: { _, _ in try await waiting.tree() }, text: { _, _ in ("hello", 100) })
        let tools = try RepositoryQuestionTools(scope: .init(repository: "owner/repo", commit: commit), reader: reader,
                                              limits: .init(maximumResponseBytes: 100))
        let first = Task { try await tools.list(path: "") }
        await waiting.waitUntilStarted()
        await assertFailure(.byteLimit) { try await tools.list(path: "") }
        await tools.cancel()
        do { _ = try await first.value; XCTFail("Expected cancellation") } catch is CancellationError {} catch { XCTFail("Wrong error: \(error)") }
    }

    func testCancellationStopsInFlightReadAndPreventsFurtherRequests() async throws {
        let waiting = WaitingRepositoryReader()
        let reader = RepositoryToolReader(tree: { _, _ in try await waiting.tree() }, text: { _, _ in ("hello", 100) })
        let tools = try RepositoryQuestionTools(scope: .init(repository: "owner/repo", commit: commit), reader: reader)
        let task = Task { try await tools.list(path: "") }
        await waiting.waitUntilStarted()
        await tools.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") } catch is CancellationError {} catch { XCTFail("Wrong error: \(error)") }
        do { _ = try await tools.list(path: ""); XCTFail("Expected cancelled question") } catch is CancellationError {} catch { XCTFail("Wrong error: \(error)") }
    }

    func testRevokedTransportCancellationStillReportsAuthentication() async throws {
        let session = try GitHubAuthSession(token: "github_pat_SYNTHETIC_TEST_ONLY_123")
        let client = GitHubClient(authentication: session)
        let states = RepositoryConnectionStates()
        let reader = RepositoryToolReader(tree: { _, _ in
            session.revoke()
            throw CancellationError() // Matches URLSession cancellation normalized by safeError.
        }, text: { _, _ in ("", 0) }, checkAccess: { try client.validateSession() })
        let tools = try RepositoryQuestionTools(scope: .init(repository: "owner/repo", commit: commit), reader: reader,
                                                connectionChanged: { await states.append($0) })
        await assertFailure(.authenticationRequired) { try await tools.list(path: "") }
        let observed = await states.values
        XCTAssertEqual(observed, [.checking, .authenticationRequired])
    }

    func testRevokedSessionReportsAuthenticationAndWithholdsCachedDirectory() async throws {
        let session = try GitHubAuthSession(token: "github_pat_SYNTHETIC_TEST_ONLY_123")
        let client = GitHubClient(authentication: session)
        let states = RepositoryConnectionStates()
        let spy = RepositoryReaderSpy(entries: [commit: [file("README.md")]])
        var reader = spy.reader
        reader.checkAccess = { try client.validateSession() }
        let tools = try RepositoryQuestionTools(scope: .init(repository: "owner/repo", commit: commit), reader: reader,
                                                connectionChanged: { await states.append($0) })
        _ = try await tools.list(path: "")
        session.revoke()
        await assertFailure(.authenticationRequired) { try await tools.list(path: "") }
        let observed = await states.values
        XCTAssertEqual(observed.last, .authenticationRequired)
        let requests = await spy.requests
        XCTAssertEqual(requests, ["tree:" + commit], "Revoked cached reads must not reach transport")
    }

    func testAccessGateDenialIsTypedAndReportedBeforeAnyNetwork() async throws {
        let states = RepositoryConnectionStates()
        let spy = RepositoryReaderSpy(entries: [:])
        var reader = spy.reader
        reader.checkAccess = { throw GitHubAccessError.accessDenied }
        let tools = try RepositoryQuestionTools(scope: .init(repository: "owner/repo", commit: commit), reader: reader,
                                                connectionChanged: { await states.append($0) })
        await assertFailure(.accessDenied) { try await tools.list(path: "") }
        let observed = await states.values
        XCTAssertEqual(observed, [.accessDenied])
        let requests = await spy.requests
        XCTAssertTrue(requests.isEmpty)
    }

    func testRevocationSupersedesEarlierOfflineFallbackAndStillWithholdsData() async throws {
        let session = try GitHubAuthSession(token: "github_pat_SYNTHETIC_TEST_ONLY_123")
        let client = GitHubClient(authentication: session)
        let states = RepositoryConnectionStates()
        let reader = RepositoryToolReader(tree: { _, _ in throw GitHubAccessError.unavailable },
            text: { _, _ in XCTFail("No private blob read"); return ("", 0) }, checkAccess: { try client.validateSession() })
        let tools = try RepositoryQuestionTools(scope: .init(repository: "owner/repo", commit: commit), reader: reader,
                                                connectionChanged: { await states.append($0) })
        await assertFailure(.connectionUnavailable) { try await tools.list(path: "") }
        session.revoke()
        await assertFailure(.authenticationRequired) { try await tools.list(path: "") }
        let observed = await states.values
        XCTAssertEqual(observed, [.checking, .offline, .authenticationRequired])
    }

    func testConcurrentLateProviderFailureCannotRelabelSavedOnlyFallback() async throws {
        for unavailableFirst in [true, false] {
            let states = RepositoryConnectionStates()
            let gate = ConcurrentRepositoryFailures()
            let reader = RepositoryToolReader(tree: { _, _ in try await gate.fail() }, text: { _, _ in ("", 0) })
            let tools = try RepositoryQuestionTools(scope: .init(repository: "owner/repo", commit: commit), reader: reader,
                                                    connectionChanged: { await states.append($0) })
            let first = Task { try await tools.list(path: "") }
            await gate.waitForCount(1)
            let second = Task { try await tools.list(path: "") }
            await gate.waitForCount(2)
            await gate.release(0, error: unavailableFirst ? GitHubAccessError.unavailable : GitHubAccessError.rateLimited)
            _ = try? await first.value
            await gate.release(1, error: unavailableFirst ? GitHubAccessError.rateLimited : GitHubAccessError.unavailable)
            _ = try? await second.value
            let observed = await states.values
            XCTAssertEqual(observed.last, .offline)
            await assertFailure(.connectionUnavailable) { try await tools.list(path: "") }
        }
    }

    func testBoundedPreflightLeavesBudgetForActualSourceRead() async throws {
        let entries = (0..<60).map { file("long-repository-root-entry-\($0).swift") }
        let spy = RepositoryReaderSpy(entries: [commit: entries], text: "hello")
        let tools = try makeTools(spy)
        let root = try await tools.list(path: "", maximumCharacters: 600)
        XCTAssertLessThanOrEqual(root.count, 600)
        let source = try await tools.read(path: "long-repository-root-entry-0.swift")
        XCTAssertTrue(source.contains("hello"))
        XCTAssertLessThanOrEqual(root.count + source.count, 4_000)
        let requests = await spy.requests
        XCTAssertEqual(requests, ["tree:" + commit, "blob:" + blob])
    }

    func testConnectionLossStopsLiveReadsForThisQuestionAndNextQuestionRecovers() async throws {
        let states = RepositoryConnectionStates()
        let failing = RepositoryToolReader(tree: { _, _ in throw GitHubAccessError.unavailable }, text: { _, _ in XCTFail("No blob read after loss"); return ("", 0) })
        let tools = try RepositoryQuestionTools(scope: .init(repository: "owner/repo", commit: commit), reader: failing,
                                                connectionChanged: { await states.append($0) })
        let output = try await ListRepositoryDirectoryTool(repository: tools).call(arguments: .init(path: ""))
        XCTAssertTrue(output.contains("saved"))
        await assertFailure(.connectionUnavailable) { try await tools.read(path: "README.md") }
        let observed = await states.values
        XCTAssertEqual(observed, [.checking, .offline])
        let recovered = try RepositoryQuestionTools(scope: .init(repository: "owner/repo", commit: commit),
            reader: RepositoryReaderSpy(entries: [commit: [file("README.md")]]).reader,
            connectionChanged: { await states.append($0) })
        _ = try await recovered.list(path: "")
        let afterRecovery = await states.values
        XCTAssertEqual(afterRecovery, [.checking, .offline, .checking, .online])
    }

    func testRateLimitDoesNotClaimOfflineAndCancelledQuestionCannotReportSuccess() async throws {
        let states = RepositoryConnectionStates()
        let reader = RepositoryToolReader(tree: { _, _ in throw GitHubAccessError.rateLimited }, text: { _, _ in ("", 0) })
        let tools = try RepositoryQuestionTools(scope: .init(repository: "owner/repo", commit: commit), reader: reader,
                                                connectionChanged: { await states.append($0) })
        await assertFailure(.rateLimited) { try await tools.list(path: "") }
        let observed = await states.values
        XCTAssertEqual(observed, [.checking, .rateLimited])
        await tools.cancel()
        do { _ = try await tools.list(path: ""); XCTFail("Cancelled tool must stop") }
        catch { XCTAssertTrue(error is CancellationError) }
        let afterCancel = await states.values
        XCTAssertEqual(afterCancel, observed)
    }

    private func makeTools(_ spy: RepositoryReaderSpy, limits: RepositoryToolLimits = .init()) throws -> RepositoryQuestionTools {
        try RepositoryQuestionTools(scope: .init(repository: "owner/repo", commit: commit), reader: spy.reader, limits: limits)
    }

    private func assertFailure(_ expected: RepositoryToolFailure, operation: () async throws -> String, file: StaticString = #filePath, line: UInt = #line) async {
        do { _ = try await operation(); XCTFail("Expected \(expected)", file: file, line: line) }
        catch { XCTAssertEqual(error as? RepositoryToolFailure, expected, file: file, line: line) }
    }
}

// Only network I/O is substituted. Scope resolution, budgets and formatting stay real.
private actor RepositoryReaderSpy {
    let entries: [String: [RepoFile]]
    let content: String
    let responseBytes: Int
    var requests: [String] = []
    var caps: [Int] = []

    init(entries: [String: [RepoFile]], text: String = "hello", responseBytes: Int = 100) {
        self.entries = entries; content = text; self.responseBytes = responseBytes
    }
    nonisolated var reader: RepositoryToolReader {
        RepositoryToolReader(tree: { sha, cap in await self.tree(sha, cap: cap) }, text: { file, cap in await self.text(file, cap: cap) })
    }
    func tree(_ sha: String, cap: Int) -> (files: [RepoFile], responseBytes: Int) {
        requests.append("tree:" + sha); caps.append(cap)
        return (entries[sha] ?? [], responseBytes)
    }
    func text(_ file: RepoFile, cap: Int) -> (text: String, responseBytes: Int) {
        requests.append("blob:" + file.sha); caps.append(cap)
        return (content, responseBytes)
    }
}

private actor WaitingRepositoryReader {
    var started = false
    var waiter: CheckedContinuation<Void, Never>?
    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { waiter = $0 }
    }
    func tree() async throws -> (files: [RepoFile], responseBytes: Int) {
        started = true; waiter?.resume(); waiter = nil
        try await Task.sleep(nanoseconds: 30_000_000_000)
        return ([], 0)
    }
}

private final class RepositoryAccessGate: @unchecked Sendable {
    private let lock = NSLock()
    private var revoked = false
    func revoke() { lock.lock(); defer { lock.unlock() }; revoked = true }
    func check() throws {
        lock.lock(); defer { lock.unlock() }
        if revoked { throw AppFailure.message("revoked") }
    }
}

private actor RepositoryConnectionStates {
    var values: [AssistantConnectionState] = []
    func append(_ state: AssistantConnectionState) { values.append(state) }
}

private actor ConcurrentRepositoryFailures {
    private var waits: [CheckedContinuation<(files: [RepoFile], responseBytes: Int), Error>] = []
    func fail() async throws -> (files: [RepoFile], responseBytes: Int) {
        try await withCheckedThrowingContinuation { waits.append($0) }
    }
    func waitForCount(_ count: Int) async {
        let deadline = Date().addingTimeInterval(3)
        while waits.count < count && Date() < deadline { try? await Task.sleep(nanoseconds: 1_000_000) }
        XCTAssertGreaterThanOrEqual(waits.count, count)
    }
    func release(_ index: Int, error: Error) {
        guard waits.indices.contains(index) else { XCTFail("Missing pending read"); return }
        waits[index].resume(throwing: error)
    }
}
