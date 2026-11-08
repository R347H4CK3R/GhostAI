import XCTest
@testable import AsterionVeyra

final class RepositoryProposalTests: XCTestCase {
    private let repo = Repository(id: 42, full_name: "example/project", default_branch: "main")
    private let pinned = String(repeating: "a", count: 40)
    private let tree = String(repeating: "b", count: 40)
    private let newTree = String(repeating: "c", count: 40)
    private let newCommit = String(repeating: "d", count: 40)
    private let old = "Hello, public example.\n"
    private let new = "Hello, reviewed public example.\n"

    func testPathPolicyRejectsTraversalCredentialsAutomationAndSensitiveFiles() {
        for path in ["../README.md", "/README.md", "a//b.swift", "a/%2e%2e/x.swift", "a\\b.swift", "https://example.test/a", "a?x.swift", ".github/workflows/build.yml", ".git/config", ".env", "src/Auth.swift", "src/TokenStore.swift", "SECURITY.md", "Dockerfile", "Package.swift", "project.pbxproj", "scripts/build.py", "a\u{202e}b.swift", "docs/a\nb.md", "docs/a..b.md", "docs/.hidden.md"] {
            XCTAssertThrowsError(try RepositoryProposalPolicy.validatePath(path), path)
        }
        for path in ["README.md", "docs/guide.md", "App/WelcomeView.swift"] {
            XCTAssertNoThrow(try RepositoryProposalPolicy.validatePath(path), path)
        }
    }

    func testInvalidScopeAndPathAreRejectedBeforeCallingReader() async throws {
        let reader = RepositoryToolReader(tree: { _, _ in
            XCTFail("unvalidated input reached reader")
            return ([], 0)
        }, text: { _, _ in
            XCTFail("unvalidated input reached blob reader")
            return ("", 0)
        })
        for path in ["../README.md", ".github/workflows/test.yml", "src/Auth.swift"] {
            do {
                _ = try await RepositoryProposalSource.load(repository: repo, immutableCommit: pinned, path: path, reader: reader)
                XCTFail("accepted invalid path")
            } catch { XCTAssertEqual(error as? RepositoryProposalFailure, .invalidPath) }
        }
        do {
            _ = try await RepositoryProposalSource.load(repository: repo, immutableCommit: "main", path: "README.md", reader: reader)
            XCTFail("accepted moving source ref")
        } catch { XCTAssertEqual(error as? RepositoryProposalFailure, .invalidScope) }
    }

    func testWriteCredentialCannotBeUsedForDifferentRepository() async throws {
        let review = try await makeReview()
        let auth = try RepositoryProposalAuthorization(token: token, repositoryID: 999, directInstallationConfirmed: true)
        let script = RepositoryProposalScript([])
        let publisher = RepositoryProposalPublisher(review: review, authorization: auth, transport: script.transport, receipts: RepositoryProposalTestReceipts().store)
        let result = await publisher.publish(approval: try approved(review), currentReview: review)
        XCTAssertEqual(result.outcome, .stopped)
        let requests = await script.requests
        XCTAssertTrue(requests.isEmpty)
        XCTAssertThrowsError(try auth.authorizationValue())
    }

    func testTextAndTitleRejectBinaryOversizeAndSecrets() {
        for value in ["ab\0cd", "password=synthetic", "github_pat_SYNTHETIC_NOT_A_REAL_TOKEN", "sk-proj-abcdefghijklmnopqrstuvwxyz", "-----BEGIN PRIVATE KEY-----", "a\u{202e}b", String(repeating: "a", count: 30_001)] {
            XCTAssertThrowsError(try RepositoryProposalPolicy.validateText(value))
        }
        XCTAssertThrowsError(try RepositoryProposalPolicy.validateTitle("hello\nworld"))
        XCTAssertThrowsError(try RepositoryProposalPolicy.validateTitle(""))
        XCTAssertThrowsError(try RepositoryProposalPolicy.validateTitle("@team please review"))
        XCTAssertNoThrow(try RepositoryProposalPolicy.validateText("public\ntext\t"))
    }

    func testWriteCredentialRequiresDirectInstallAndIsSeparatelyRevocable() throws {
        XCTAssertThrowsError(try RepositoryProposalAuthorization(token: token, repositoryID: 42, directInstallationConfirmed: false))
        let auth = try authorization()
        XCTAssertTrue(try auth.authorizationValue().hasPrefix("Bearer "))
        XCTAssertFalse(String(describing: auth).contains(token))
        auth.revoke()
        XCTAssertThrowsError(try auth.authorizationValue())
        XCTAssertThrowsError(try RepositoryProposalAuthorization(token: "ghp_synthetic", repositoryID: 42, directInstallationConfirmed: true))
    }

    func testOriginalMustMatchPinnedBlobAndCannotFollowSymlink() async throws {
        let reader = readerFor(text: "wrong size", type: "file", sha: RepositoryProposalPolicy.blobSHA(old), size: old.utf8.count)
        do { _ = try await RepositoryProposalSource.load(repository: repo, immutableCommit: pinned, path: "README.md", reader: reader); XCTFail("accepted mismatched source") }
        catch { XCTAssertEqual(error as? RepositoryProposalFailure, .sourceMismatch) }
        for type in ["symlink", "submodule", "dir"] {
            do { _ = try await RepositoryProposalSource.load(repository: repo, immutableCommit: pinned, path: "README.md", reader: readerFor(text: old, type: type)); XCTFail("accepted \(type)") }
            catch { XCTAssertEqual(error as? RepositoryProposalFailure, .unsafeFile) }
        }
    }

    func testSameSizeWrongContentFailsGitBlobHashValidation() async throws {
        let different = String(repeating: "x", count: old.utf8.count)
        do {
            _ = try await RepositoryProposalSource.load(repository: repo, immutableCommit: pinned, path: "README.md", reader: readerFor(text: different, sha: RepositoryProposalPolicy.blobSHA(old)))
            XCTFail("accepted wrong original")
        } catch { XCTAssertEqual(error as? RepositoryProposalFailure, .sourceMismatch) }
    }

    func testReviewBindsFullDataAndRequiresBothAcknowledgments() async throws {
        let review = try await makeReview()
        XCTAssertEqual(review.original, old)
        XCTAssertEqual(review.replacement, new)
        XCTAssertTrue(review.branch.hasPrefix("veyra-proposal/"))
        XCTAssertTrue(review.disclosure.contains("example/project"))
        XCTAssertTrue(review.disclosure.contains("public"))
        XCTAssertThrowsError(try review.approve(fullReviewConfirmed: false, destinationConfirmed: true))
        XCTAssertThrowsError(try review.approve(fullReviewConfirmed: true, destinationConfirmed: false))
        XCTAssertNoThrow(try review.approve(fullReviewConfirmed: true, destinationConfirmed: true))
    }

    func testChangedReviewCannotPublishWithOldConsent() async throws {
        let review = try await makeReview()
        let other = try RepositoryProposalReview(source: review.source, replacement: "Another public edit.\n", title: review.title)
        let script = RepositoryProposalScript([])
        let publisher = RepositoryProposalPublisher(review: review, authorization: try authorization(), transport: script.transport, receipts: RepositoryProposalTestReceipts().store)
        let result = await publisher.publish(approval: try approved(review), currentReview: other)
        XCTAssertEqual(result.outcome, .stopped)
        let requests = await script.requests
        XCTAssertTrue(requests.isEmpty)
    }

    func testCancellationBeforePublishSendsNothingAndCannotReplay() async throws {
        let review = try await makeReview()
        let script = RepositoryProposalScript([])
        let publisher = RepositoryProposalPublisher(review: review, authorization: try authorization(), transport: script.transport, receipts: RepositoryProposalTestReceipts().store)
        await publisher.cancel()
        let result = await publisher.publish(approval: try approved(review), currentReview: review)
        XCTAssertEqual(result.outcome, .cancelled)
        let again = await publisher.publish(approval: try approved(review), currentReview: review)
        XCTAssertEqual(again.outcome, .cancelled)
        let requests = await script.requests
        XCTAssertTrue(requests.isEmpty)
    }

    func testSuccessfulPublicationOnlyCreatesObjectsNewRefAndDraftPullRequest() async throws {
        let review = try await makeReview()
        let script = RepositoryProposalScript(successScript(review))
        let auth = try authorization()
        let publisher = RepositoryProposalPublisher(review: review, authorization: auth, transport: script.transport, receipts: RepositoryProposalTestReceipts().store)
        let result = await publisher.publish(approval: try approved(review), currentReview: review)
        XCTAssertEqual(result.outcome, .completed)
        XCTAssertEqual(result.pullRequestURL?.absoluteString, "https://github.com/example/project/pull/7")
        let requests = await script.requests
        XCTAssertEqual(requests.count, 11)
        XCTAssertEqual(requests.map { $0.httpMethod ?? "" }, Array(repeating: "GET", count: 6) + Array(repeating: "POST", count: 5))
        let ref = try object(requests[9])
        XCTAssertEqual(ref["ref"] as? String, "refs/heads/" + review.branch)
        XCTAssertEqual(ref["sha"] as? String, newCommit)
        let pull = try object(requests[10])
        XCTAssertEqual(pull["draft"] as? Bool, true)
        XCTAssertEqual(pull["maintainer_can_modify"] as? Bool, false)
        XCTAssertEqual(pull["base"] as? String, "main")
        XCTAssertEqual(pull["head"] as? String, review.branch)
        XCTAssertEqual(pull["body"] as? String, review.pullRequestBody)
        XCTAssertThrowsError(try auth.authorizationValue())
        _ = await publisher.publish(approval: try approved(review), currentReview: review)
        let afterReplay = await script.requests
        XCTAssertEqual(afterReplay.count, 11)
    }

    func testMovedBaseStopsBeforeAnyMutation() async throws {
        let review = try await makeReview()
        var steps = successScript(review)
        steps[1] = .json(["ref": "refs/heads/main", "object": ["sha": newCommit, "type": "commit"]])
        let script = RepositoryProposalScript(steps)
        let publisher = RepositoryProposalPublisher(review: review, authorization: try authorization(), transport: script.transport, receipts: RepositoryProposalTestReceipts().store)
        let result = await publisher.publish(approval: try approved(review), currentReview: review)
        XCTAssertEqual(result.outcome, .stopped)
        let requests = await script.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertTrue(requests.allSatisfy { $0.httpMethod == "GET" })
    }

    func testExecutableOrChangedPinnedFileIsRejectedInPreflight() async throws {
        for mode in ["120000", "160000", "100755"] {
            let review = try await makeReview()
            var steps = successScript(review)
            steps[3] = .json(["sha": tree, "truncated": false, "tree": [["path": "README.md", "mode": mode, "type": "blob", "sha": RepositoryProposalPolicy.blobSHA(old), "size": old.utf8.count]]])
            let script = RepositoryProposalScript(steps)
            let publisher = RepositoryProposalPublisher(review: review, authorization: try authorization(), transport: script.transport, receipts: RepositoryProposalTestReceipts().store)
            let result = await publisher.publish(approval: try approved(review), currentReview: review)
            XCTAssertEqual(result.outcome, .stopped)
            let requests = await script.requests
            XCTAssertEqual(requests.count, 4)
        }
    }

    func testAmbiguousBranchResponseStopsWithoutRetryOrPullRequest() async throws {
        let review = try await makeReview()
        var steps = successScript(review)
        steps[9] = .failure
        let script = RepositoryProposalScript(steps)
        let publisher = RepositoryProposalPublisher(review: review, authorization: try authorization(), transport: script.transport, receipts: RepositoryProposalTestReceipts().store)
        let result = await publisher.publish(approval: try approved(review), currentReview: review)
        XCTAssertEqual(result.outcome, .uncertain)
        XCTAssertEqual(result.progress.branch, .uncertain)
        XCTAssertEqual(result.progress.commit, .confirmed(newCommit))
        XCTAssertEqual(result.progress.pullRequest, .notStarted)
        XCTAssertFalse(result.message.contains("sensitive upstream"))
        _ = await publisher.publish(approval: try approved(review), currentReview: review)
        let requests = await script.requests
        XCTAssertEqual(requests.count, 10)
    }

    func testRejectedPullRequestRetainsConfirmedBranchAndNeverDeletesIt() async throws {
        let review = try await makeReview()
        var steps = successScript(review)
        steps[10] = .status(422)
        let script = RepositoryProposalScript(steps)
        let publisher = RepositoryProposalPublisher(review: review, authorization: try authorization(), transport: script.transport, receipts: RepositoryProposalTestReceipts().store)
        let result = await publisher.publish(approval: try approved(review), currentReview: review)
        XCTAssertEqual(result.outcome, .stopped)
        XCTAssertEqual(result.progress.branch, .confirmed(review.branch))
        XCTAssertEqual(result.progress.pullRequest, .rejected)
        let requests = await script.requests
        XCTAssertEqual(requests.count, 11)
        XCTAssertFalse(requests.contains { ["DELETE", "PATCH", "PUT"].contains($0.httpMethod ?? "") })
    }

    func testHTTP401RevokesCredentialAndServerFailureIsUncertain() async throws {
        for status in [401, 500] {
            let review = try await makeReview()
            var steps = successScript(review)
            steps[6] = .status(status)
            let auth = try authorization()
            let script = RepositoryProposalScript(steps)
            let publisher = RepositoryProposalPublisher(review: review, authorization: auth, transport: script.transport, receipts: RepositoryProposalTestReceipts().store)
            let result = await publisher.publish(approval: try approved(review), currentReview: review)
            XCTAssertEqual(result.outcome, status == 401 ? .stopped : .uncertain)
            XCTAssertThrowsError(try auth.authorizationValue())
            let requests = await script.requests
            XCTAssertEqual(requests.count, 7)
        }
    }

    func testMalformedSuccessIsUncertainAndNotRetried() async throws {
        let review = try await makeReview()
        var steps = successScript(review)
        steps[6] = .json(["sha": "invalid"], status: 201)
        let script = RepositoryProposalScript(steps)
        let publisher = RepositoryProposalPublisher(review: review, authorization: try authorization(), transport: script.transport, receipts: RepositoryProposalTestReceipts().store)
        let result = await publisher.publish(approval: try approved(review), currentReview: review)
        XCTAssertEqual(result.outcome, .uncertain)
        let requests = await script.requests
        XCTAssertEqual(requests.count, 7)
    }

    func testTransportPolicyDoesNotAllowRedirectsCookiesOrProxyConfiguration() throws {
        for value in ["http://api.github.com/repos/a/b", "https://api.github.com.evil.test/x", "https://user@api.github.com/x", "https://api.github.com:8443/x", "https://api.github.com/x#fragment"] {
            XCTAssertThrowsError(try RepositoryProposalNetworkPolicy.validate(URL(string: value)!))
        }
        let config = RepositoryProposalNetworkPolicy.configuration()
        XCTAssertNil(config.httpCookieStorage)
        XCTAssertNil(config.urlCredentialStorage)
        XCTAssertNil(config.urlCache)
        XCTAssertEqual(config.connectionProxyDictionary?["HTTPEnable"] as? Int, 0)
        XCTAssertFalse(RepositoryProposalNetworkPolicy.allowsRedirects)
    }


    func testBaseIsRecheckedImmediatelyBeforeFirstMutation() async throws {
        let review = try await makeReview()
        var steps = successScript(review)
        steps[5] = .json(["ref": "refs/heads/main", "object": ["sha": newCommit, "type": "commit"]])
        let script = RepositoryProposalScript(steps)
        let publisher = RepositoryProposalPublisher(review: review, authorization: try authorization(), transport: script.transport, receipts: RepositoryProposalTestReceipts().store)
        let result = await publisher.publish(approval: try approved(review), currentReview: review)
        XCTAssertEqual(result.outcome, .stopped)
        let requests = await script.requests
        XCTAssertEqual(requests.count, 6)
        XCTAssertTrue(requests.allSatisfy { $0.httpMethod == "GET" })
    }

    func testCancellationOfInFlightWriteIsUncertainAndDoesNotContinue() async throws {
        let review = try await makeReview()
        var steps = successScript(review)
        steps[6] = .waitForCancellation
        let script = RepositoryProposalScript(steps)
        let publisher = RepositoryProposalPublisher(review: review, authorization: try authorization(), transport: script.transport, receipts: RepositoryProposalTestReceipts().store)
        let approval = try approved(review)
        let task = Task { await publisher.publish(approval: approval, currentReview: review) }
        for _ in 0..<1_000 {
            if await script.requests.count >= 7 { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        let beforeCancel = await script.requests.count
        XCTAssertEqual(beforeCancel, 7)
        await publisher.cancel()
        let result = await task.value
        XCTAssertEqual(result.outcome, .uncertain)
        XCTAssertEqual(result.progress.blob, .uncertain)
        let requests = await script.requests
        XCTAssertEqual(requests.count, 7)
    }

    func testOversizedOrForeignMutationResponsesAreUncertain() async throws {
        for failure in [RepositoryProposalScript.Step.oversized, .foreignDestination] {
            let review = try await makeReview()
            var steps = successScript(review)
            steps[6] = failure
            let script = RepositoryProposalScript(steps)
            let publisher = RepositoryProposalPublisher(review: review, authorization: try authorization(), transport: script.transport, receipts: RepositoryProposalTestReceipts().store)
            let result = await publisher.publish(approval: try approved(review), currentReview: review)
            XCTAssertEqual(result.outcome, .uncertain)
            let requests = await script.requests
            XCTAssertEqual(requests.count, 7)
            XCTAssertTrue(requests.allSatisfy { $0.url?.host == "api.github.com" && $0.httpShouldHandleCookies == false })
        }
    }

    func testWriteAheadReceiptExistsBeforeEveryPOST() async throws {
        let review = try await makeReview()
        let records = RepositoryProposalTestReceipts()
        let store = records.store
        let script = RepositoryProposalScript(successScript(review))
        let underlying = script.transport
        let transport = RepositoryProposalTransport { request, cap, auth in
            if request.httpMethod == "POST" {
                let receipt = try XCTUnwrap(store.load().first)
                XCTAssertEqual(receipt.id, review.id)
                let stages = [receipt.progress.blob, receipt.progress.tree, receipt.progress.commit, receipt.progress.branch, receipt.progress.pullRequest]
                XCTAssertEqual(stages.filter { $0 == .inFlight }.count, 1)
                XCTAssertEqual(receipt.outcome, .running)
            }
            return try await underlying.send(request, cap, auth)
        }
        let publisher = RepositoryProposalPublisher(review: review, authorization: try authorization(), transport: transport, receipts: store)
        let result = await publisher.publish(approval: try approved(review), currentReview: review)
        XCTAssertEqual(result.outcome, .completed)
        let receipt = try XCTUnwrap(store.load().first)
        XCTAssertEqual(receipt.outcome, .completed)
        XCTAssertFalse(receipt.requiresInspection)
        let encoded = String(data: try JSONEncoder().encode(receipt), encoding: .utf8)!
        for privateValue in [token, old, new, review.title, review.source.path] {
            XCTAssertFalse(encoded.contains(privateValue))
        }
    }

    func testCrashReceiptReloadBlocksBothReplayAndNewProposalUntilInspection() async throws {
        let review = try await makeReview()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let initial = RepositoryProposalReceiptStore.disk(directory: directory)
        var receipt = recoveryReceipt(review)
        receipt.progress.branch = .inFlight
        let initialLease = try initial.claim(receipt)
        initial.release(receipt.id, initialLease)
        // A new store and coordinator represent a relaunch after the process was killed mid-POST.
        let reloaded = RepositoryProposalReceiptStore.disk(directory: directory)
        let saved = try XCTUnwrap(reloaded.load().first)
        XCTAssertTrue(saved.requiresInspection)
        XCTAssertEqual(saved.progress.branch, .inFlight)
        for candidate in [review, try await makeReview()] {
            let script = RepositoryProposalScript([])
            let publisher = RepositoryProposalPublisher(review: candidate, authorization: try authorization(), transport: script.transport, receipts: reloaded)
            let result = await publisher.publish(approval: try approved(candidate), currentReview: candidate)
            XCTAssertEqual(result.outcome, .stopped)
            let requests = await script.requests
            XCTAssertTrue(requests.isEmpty)
        }
        try reloaded.acknowledgeInspection(saved)
        XCTAssertFalse(try XCTUnwrap(reloaded.load().first).requiresInspection)
        let script = RepositoryProposalScript([])
        let replay = RepositoryProposalPublisher(review: review, authorization: try authorization(), transport: script.transport, receipts: reloaded)
        let replayResult = await replay.publish(approval: try approved(review), currentReview: review)
        XCTAssertEqual(replayResult.outcome, .stopped) // Inspecting cannot make the same attempt replayable.
        let requests = await script.requests
        XCTAssertTrue(requests.isEmpty)
    }

    func testFailedWriteAheadSavePreventsFirstMutation() async throws {
        let review = try await makeReview()
        let store = RepositoryProposalReceiptStore(load: { [] }, claim: { _ in throw NSError(domain: "sensitive disk error", code: 1) }, update: { _, _ in }, release: { _, _ in }, acknowledgeInspection: { _ in })
        let script = RepositoryProposalScript(successScript(review))
        let publisher = RepositoryProposalPublisher(review: review, authorization: try authorization(), transport: script.transport, receipts: store)
        let result = await publisher.publish(approval: try approved(review), currentReview: review)
        XCTAssertEqual(result.outcome, .stopped)
        XCTAssertEqual(result.progress.blob, .notStarted)
        XCTAssertFalse(result.message.contains("sensitive disk error"))
        let requests = await script.requests
        XCTAssertEqual(requests.count, 6)
        XCTAssertTrue(requests.allSatisfy { $0.httpMethod == "GET" })
    }

    func testCorruptReceiptBlocksPublicationWithoutNetwork() async throws {
        let review = try await makeReview()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("invalid".utf8).write(to: directory.appendingPathComponent(UUID().uuidString + ".json"))
        let store = RepositoryProposalReceiptStore.disk(directory: directory)
        XCTAssertThrowsError(try store.load())
        let script = RepositoryProposalScript([])
        let publisher = RepositoryProposalPublisher(review: review, authorization: try authorization(), transport: script.transport, receipts: store)
        let result = await publisher.publish(approval: try approved(review), currentReview: review)
        XCTAssertEqual(result.outcome, .stopped)
        let requests = await script.requests
        XCTAssertTrue(requests.isEmpty)
    }

    private func recoveryReceipt(_ review: RepositoryProposalReview) -> RepositoryProposalReceipt {
        RepositoryProposalReceipt(version: 1, id: review.id, repositoryID: repo.id, repository: repo.full_name,
            branch: review.branch, baseBranch: repo.default_branch, baseCommit: pinned, createdAt: Date(), updatedAt: Date(),
            outcome: .running, progress: RepositoryProposalProgress(), inspectedAt: nil)
    }

    func testNestedPathPublicationResolvesAndPreservesEveryAncestor() async throws {
        let folderSHA = String(repeating: "e", count: 40)
        let oldText = old
        let sourceReader = RepositoryToolReader(tree: { sha, _ in
            if sha == String(repeating: "a", count: 40) {
                return ([RepoFile(name: "docs", path: "docs", type: "dir", sha: folderSHA, size: nil)], 200)
            }
            return ([RepoFile(name: "guide.md", path: "guide.md", type: "file", sha: RepositoryProposalPolicy.blobSHA(oldText), size: oldText.utf8.count)], 200)
        }, text: { _, _ in (oldText, 200) })
        let source = try await RepositoryProposalSource.load(repository: repo, immutableCommit: pinned, path: "docs/guide.md", reader: sourceReader)
        let review = try RepositoryProposalReview(source: source, replacement: new, title: "Improve the guide")
        var steps = successScript(review)
        steps[3] = .json(["sha": tree, "truncated": false, "tree": [["path": "docs", "mode": "040000", "type": "tree", "sha": folderSHA]]])
        steps.insert(.json(["sha": folderSHA, "truncated": false, "tree": [["path": "guide.md", "mode": "100644", "type": "blob", "sha": RepositoryProposalPolicy.blobSHA(old), "size": old.utf8.count]]]), at: 4)
        let script = RepositoryProposalScript(steps)
        let publisher = RepositoryProposalPublisher(review: review, authorization: try authorization(), transport: script.transport, receipts: RepositoryProposalTestReceipts().store)
        let result = await publisher.publish(approval: try approved(review), currentReview: review)
        XCTAssertEqual(result.outcome, .completed)
        let requests = await script.requests
        XCTAssertEqual(requests.count, 12)
        XCTAssertEqual(requests[4].url?.path, "/repos/example/project/git/trees/" + folderSHA)
        let treeRequest = try object(requests[8])
        let changed = try XCTUnwrap(treeRequest["tree"] as? [[String: String]])
        XCTAssertEqual(changed.count, 1)
        XCTAssertEqual(changed.first?["path"], "docs/guide.md")
        XCTAssertEqual(changed.first?["mode"], "100644")
    }

    func testSeparateCoordinatorsCannotClaimAndReplaySameAttemptConcurrently() async throws {
        let review = try await makeReview()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let firstScript = RepositoryProposalScript(successScript(review))
        let secondScript = RepositoryProposalScript(successScript(review))
        let barrier = RepositoryProposalTestBarrier()
        func gated(_ script: RepositoryProposalScript) -> RepositoryProposalTransport {
            let underlying = script.transport
            return RepositoryProposalTransport { request, cap, auth in
                let response = try await underlying.send(request, cap, auth)
                if request.httpMethod == "GET", await script.requests.count == 6 { await barrier.waitForBoth() }
                return response
            }
        }
        let first = RepositoryProposalPublisher(review: review, authorization: try authorization(), transport: gated(firstScript), receipts: .disk(directory: directory))
        let second = RepositoryProposalPublisher(review: review, authorization: try authorization(), transport: gated(secondScript), receipts: .disk(directory: directory))
        let approval = try approved(review)
        async let firstResult = first.publish(approval: approval, currentReview: review)
        async let secondResult = second.publish(approval: approval, currentReview: review)
        let (firstValue, secondValue) = await (firstResult, secondResult)
        let results = [firstValue, secondValue]
        XCTAssertEqual(results.filter { $0.outcome == .completed }.count, 1)
        XCTAssertEqual(results.filter { $0.outcome == .stopped }.count, 1)
        let firstRequests = await firstScript.requests
        let secondRequests = await secondScript.requests
        XCTAssertEqual((firstRequests + secondRequests).filter { $0.httpMethod == "POST" }.count, 5)
    }

    func testInspectionCannotOverwriteAnActiveOrNewerReceipt() async throws {
        let review = try await makeReview()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = RepositoryProposalReceiptStore.disk(directory: directory)
        let second = RepositoryProposalReceiptStore.disk(directory: directory)
        var receipt = recoveryReceipt(review)
        receipt.progress.blob = .inFlight
        let lease = try first.claim(receipt)
        XCTAssertThrowsError(try second.acknowledgeInspection(receipt))
        var newer = receipt
        newer.progress.blob = .confirmed(RepositoryProposalPolicy.blobSHA(new))
        newer.updatedAt = receipt.updatedAt.addingTimeInterval(1)
        try first.update(newer, lease)
        first.release(receipt.id, lease)
        XCTAssertThrowsError(try second.acknowledgeInspection(receipt))
        try second.acknowledgeInspection(newer)
        let saved = try XCTUnwrap(first.load().first)
        XCTAssertNotNil(saved.inspectedAt)
        XCTAssertEqual(saved.progress.blob, newer.progress.blob)
    }

    func testFailedConfirmedOutcomeSaveStopsBeforeNextPOST() async throws {
        let review = try await makeReview()
        let records = RepositoryProposalTestReceipts(failUpdateAt: 1)
        let script = RepositoryProposalScript(successScript(review))
        let publisher = RepositoryProposalPublisher(review: review, authorization: try authorization(), transport: script.transport, receipts: records.store)
        let result = await publisher.publish(approval: try approved(review), currentReview: review)
        XCTAssertEqual(result.outcome, .stopped)
        XCTAssertEqual(result.progress.blob, .confirmed(RepositoryProposalPolicy.blobSHA(new)))
        XCTAssertEqual(result.progress.tree, .notStarted)
        let requests = await script.requests
        XCTAssertEqual(requests.count, 7)
        XCTAssertTrue(try XCTUnwrap(records.store.load().first).requiresInspection)
    }

    private var token: String { "github_pat_SYNTHETIC_TEST_ONLY_123456789" }
    private func authorization() throws -> RepositoryProposalAuthorization {
        try RepositoryProposalAuthorization(token: token, repositoryID: repo.id, directInstallationConfirmed: true)
    }
    private func approved(_ review: RepositoryProposalReview) throws -> RepositoryProposalApproval {
        try review.approve(fullReviewConfirmed: true, destinationConfirmed: true)
    }
    private func readerFor(text: String, type: String = "file", sha: String? = nil, size: Int? = nil) -> RepositoryToolReader {
        let file = RepoFile(name: "README.md", path: "README.md", type: type, sha: sha ?? RepositoryProposalPolicy.blobSHA(text), size: size ?? text.utf8.count)
        return RepositoryToolReader(tree: { _, _ in ([file], 200) }, text: { _, _ in (text, 200) })
    }
    private func makeReview() async throws -> RepositoryProposalReview {
        let source = try await RepositoryProposalSource.load(repository: repo, immutableCommit: pinned, path: "README.md", reader: readerFor(text: old))
        return try RepositoryProposalReview(source: source, replacement: new, title: "Improve the public example")
    }
    private func object(_ request: URLRequest) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
    }
    private func successScript(_ review: RepositoryProposalReview) -> [RepositoryProposalScript.Step] {
        let oldSHA = RepositoryProposalPolicy.blobSHA(old)
        return [
            .json(["id": 42, "full_name": "example/project", "default_branch": "main"]),
            .json(["ref": "refs/heads/main", "object": ["sha": pinned, "type": "commit"]]),
            .json(["sha": pinned, "tree": ["sha": tree]]),
            .json(["sha": tree, "truncated": false, "tree": [["path": "README.md", "mode": "100644", "type": "blob", "sha": oldSHA, "size": old.utf8.count]]]),
            .json(["sha": oldSHA, "encoding": "base64", "size": old.utf8.count, "content": Data(old.utf8).base64EncodedString()]),
            .json(["ref": "refs/heads/main", "object": ["sha": pinned, "type": "commit"]]),
            .json(["sha": RepositoryProposalPolicy.blobSHA(new)], status: 201),
            .json(["sha": newTree], status: 201),
            .json(["sha": newCommit, "tree": ["sha": newTree], "parents": [["sha": pinned]]], status: 201),
            .json(["ref": "refs/heads/" + review.branch, "object": ["sha": newCommit, "type": "commit"]], status: 201),
            .json(["number": 7, "draft": true, "state": "open", "head": ["ref": review.branch, "sha": newCommit, "repo": ["id": 42]], "base": ["ref": "main", "repo": ["id": 42]]], status: 201)
        ]
    }
}

private actor RepositoryProposalScript {
    enum Step: @unchecked Sendable {
        case json([String: Any], status: Int = 200)
        case status(Int)
        case failure, waitForCancellation, oversized, foreignDestination
    }
    private var steps: [Step]
    private(set) var requests: [URLRequest] = []
    init(_ steps: [Step]) { self.steps = steps }
    nonisolated var transport: RepositoryProposalTransport {
        RepositoryProposalTransport { [self] request, _, _ in try await send(request) }
    }
    private func send(_ request: URLRequest) async throws -> RepositoryProposalResponse {
        requests.append(request)
        guard !steps.isEmpty else { throw NSError(domain: "sensitive upstream", code: 1) }
        let step = steps.removeFirst()
        switch step {
        case .json(let object, let status): return RepositoryProposalResponse(status: status, data: try JSONSerialization.data(withJSONObject: object), url: request.url!)
        case .status(let status): return RepositoryProposalResponse(status: status, data: Data("sensitive upstream".utf8), url: request.url!)
        case .failure: throw NSError(domain: "sensitive upstream", code: 2)
        case .waitForCancellation:
            try await Task.sleep(nanoseconds: 60_000_000_000)
            throw NSError(domain: "sensitive upstream", code: 3)
        case .oversized:
            return RepositoryProposalResponse(status: 201, data: Data(repeating: 65, count: RepositoryProposalPolicy.maximumResponseBytes + 1), url: request.url!)
        case .foreignDestination:
            return RepositoryProposalResponse(status: 201, data: Data(), url: URL(string: "https://untrusted.invalid/result")!)
        }
    }
}


private final class RepositoryProposalTestReceipts: @unchecked Sendable {
    private let lock = NSLock()
    private var records: [UUID: RepositoryProposalReceipt] = [:]
    private var owners: [UUID: UUID] = [:]
    private var updateCount = 0
    private let failUpdateAt: Int?
    init(failUpdateAt: Int? = nil) { self.failUpdateAt = failUpdateAt }
    var store: RepositoryProposalReceiptStore {
        RepositoryProposalReceiptStore(load: { [self] in
            lock.lock(); defer { lock.unlock() }
            return Array(records.values)
        }, claim: { [self] receipt in
            lock.lock(); defer { lock.unlock() }
            guard records[receipt.id] == nil, !records.values.contains(where: { $0.repositoryID == receipt.repositoryID && $0.requiresInspection }) else { throw RepositoryProposalFailure.previousAttempt }
            records[receipt.id] = receipt
            let lease = UUID(); owners[receipt.id] = lease
            return lease
        }, update: { [self] receipt, lease in
            lock.lock(); defer { lock.unlock() }
            guard owners[receipt.id] == lease else { throw RepositoryProposalFailure.receiptUnavailable }
            updateCount += 1
            if let failUpdateAt, updateCount == failUpdateAt { throw RepositoryProposalFailure.receiptUnavailable }
            records[receipt.id] = receipt
        }, release: { [self] id, lease in
            lock.lock(); defer { lock.unlock() }
            if owners[id] == lease { owners.removeValue(forKey: id) }
        }, acknowledgeInspection: { [self] expected in
            lock.lock(); defer { lock.unlock() }
            guard owners[expected.id] == nil, var current = records[expected.id], current == expected else { throw RepositoryProposalFailure.receiptChanged }
            current.inspectedAt = Date(); records[current.id] = current
        })
    }
}

private actor RepositoryProposalTestBarrier {
    private var waiting: [CheckedContinuation<Void, Never>] = []
    func waitForBoth() async {
        await withCheckedContinuation { continuation in
            waiting.append(continuation)
            if waiting.count == 2 {
                let ready = waiting; waiting.removeAll()
                ready.forEach { $0.resume() }
            }
        }
    }
}
