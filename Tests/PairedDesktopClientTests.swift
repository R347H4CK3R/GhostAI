import XCTest
import CryptoKit
import Security
@testable import AsterionVeyra

@MainActor final class PairedDesktopClientTests: XCTestCase {
    let host = "11111111-1111-4111-8111-111111111111"
    let device = "33333333-3333-4333-8333-333333333333"
    let project = "55555555-5555-4555-8555-555555555555"
    let job = "66666666-6666-4666-8666-666666666666"
    let screen = UUID()
    func fixture(expiry: Int64 = 253402300799999) -> PairedDesktopRecord {
        // Public scalar one. Never enroll this fixture or use real Keychain/network.
        PairedDesktopRecord(hostID: host, origin: "https://192.168.1.20:8443", pin: String(repeating: "a", count: 64),
            privateKey: Data(repeating: 0, count: 31) + Data([1]), beginBody: nil, safetyCode: "0123456789abcdef",
            expiresAt: expiry, deviceID: device, phase: .active,
            grants: [PairedDesktopGrant(projectID: project, label: "Synthetic", capabilities: ["jobs.read_only"], permissionRevision: 1)])
    }
    private func client(_ vault: MemoryPairingVault, _ transport: RecordingPairingTransport) -> PairedDesktopClient {
        let model = PairedDesktopClient(vault: vault, transport: transport)
        model.setScreen(id: screen, visible: true, foreground: true); return model
    }
    func testPreviewCreatesNoIdentityAndSendsNothing() throws {
        let vault = MemoryPairingVault(); let network = RecordingPairingTransport(); let model = client(vault, network)
        let descriptor = "{\"v\":1,\"host_id\":\"\(host)\",\"origin\":\"https://192.168.1.20:8443\",\"tls_leaf_sha256\":\"\(String(repeating: "a", count: 64))\",\"invite_id\":\"22222222-2222-4222-8222-222222222222\",\"invite_secret\":\"AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8\",\"expires_at_ms\":253402300799999}"
        try model.preview(Data(descriptor.utf8))
        XCTAssertNotNil(model.invitation); XCTAssertNil(vault.record); XCTAssertTrue(network.requests.isEmpty)
    }
    private func descriptor(invite: String = "22222222-2222-4222-8222-222222222222") throws -> Data {
        try JSONSerialization.data(withJSONObject: ["v": 1, "host_id": host, "origin": "https://192.168.1.20:8443",
            "tls_leaf_sha256": String(repeating: "a", count: 64), "invite_id": invite,
            "invite_secret": "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8", "expires_at_ms": 253402300799999 as Int64])
    }
    private func assertStalePreviewHasNoEffects(replacement: Data?) async throws {
        let vault = MemoryPairingVault(); let network = RecordingPairingTransport(); var keyCreations = 0
        let model = PairedDesktopClient(vault: vault, transport: network, makeSigningKey: {
            keyCreations += 1
            return try P256.Signing.PrivateKey(rawRepresentation: Data(repeating: 0, count: 31) + Data([1]))
        })
        model.setScreen(id: screen, visible: true, foreground: true)
        try model.preview(descriptor()); let reviewed = try XCTUnwrap(model.previewToken)
        if let replacement { try model.preview(replacement); XCTAssertNotEqual(model.previewToken, reviewed) }
        else { model.dismissPreview(); XCTAssertNil(model.previewToken) }
        await model.confirmPairing(expectedPreviewToken: reviewed, deviceName: "Synthetic phone")
        XCTAssertEqual(keyCreations, 0); XCTAssertEqual(vault.creations, 0)
        XCTAssertNil(vault.record); XCTAssertTrue(network.requests.isEmpty)
        XCTAssertEqual(model.message, PairedDesktopFailure.stalePreview.localizedDescription)
    }
    func testChangedSharedPreviewRejectsStaleConsentBeforeKeyStorageOrNetwork() async throws {
        try await assertStalePreviewHasNoEffects(replacement: descriptor(invite: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"))
    }
    func testCancelledSharedPreviewRejectsStaleConsentBeforeAnyEffects() async throws {
        try await assertStalePreviewHasNoEffects(replacement: nil)
    }
    func testRepeatedIdenticalPreviewStillRequiresFreshConsent() async throws {
        try await assertStalePreviewHasNoEffects(replacement: descriptor())
    }
    func testOutboxAndCounterAreDurableBeforeSend() async {
        let vault = MemoryPairingVault(fixture()); let network = RecordingPairingTransport(); let model = client(vault, network)
        network.respond = { request in
            XCTAssertEqual(vault.record?.nextSequence, 2); XCTAssertEqual(vault.record?.outbox?.body, request.body)
            throw PairedDesktopFailure.unavailable
        }
        await model.submit(projectID: project, goal: "Synthetic", limits: .defaults)
        XCTAssertEqual(network.requests.count, 1); XCTAssertNotNil(vault.record?.outbox)
    }
    func testLostResponseRelaunchRetriesSameBytesWithNewSignedSequence() async throws {
        let vault = MemoryPairingVault(fixture()); let network = RecordingPairingTransport()
        await client(vault, network).submit(projectID: project, goal: "Synthetic", limits: .defaults)
        await client(vault, network).retrySubmission()
        XCTAssertEqual(network.requests.count, 2)
        XCTAssertEqual(network.requests[0].body, network.requests[1].body)
        XCTAssertEqual(network.requests[0].headers["X-Veyra-Sequence"], "1")
        XCTAssertEqual(network.requests[1].headers["X-Veyra-Sequence"], "2")
        XCTAssertNotEqual(network.requests[0].headers["X-Veyra-Request"], network.requests[1].headers["X-Veyra-Request"])
        let request = network.requests[1]; let key = try P256.Signing.PrivateKey(rawRepresentation: fixture().privateKey)
        let frame = try PairedExecutionCrypto.requestFrame(hostID: host, deviceID: device, sequence: "2",
            requestID: XCTUnwrap(request.headers["X-Veyra-Request"]), route: request.route, body: request.body)
        try PairedExecutionCrypto.verify(signature: XCTUnwrap(request.headers["X-Veyra-Signature"]),
            publicKey: PairedExecutionWire.base64URL(key.publicKey.x963Representation), message: frame)
    }
    func testUncertainSubmissionCannotBeSilentlyReplaced() async {
        let vault = MemoryPairingVault(fixture()); let network = RecordingPairingTransport(); let model = client(vault, network)
        await model.submit(projectID: project, goal: "First", limits: .defaults); let old = vault.record?.outbox
        await model.submit(projectID: project, goal: "Second", limits: .defaults)
        XCTAssertEqual(vault.record?.outbox, old); XCTAssertEqual(network.requests.count, 1)
    }
    func testStorageFailureStopsBeforeNetworking() async {
        let vault = MemoryPairingVault(fixture()); vault.failWrites = true
        let network = RecordingPairingTransport(); let model = client(vault, network)
        await model.refresh(); await model.refresh()
        XCTAssertTrue(model.storageUnavailable); XCTAssertTrue(network.requests.isEmpty)
    }
    func testUnreadableStorageIsNeverReplaced() {
        let vault = MemoryPairingVault(); vault.failReads = true
        let network = RecordingPairingTransport(); let model = client(vault, network)
        XCTAssertTrue(model.storageUnavailable); XCTAssertThrowsError(try model.preview(Data("{}".utf8)))
        XCTAssertNil(vault.record); XCTAssertTrue(network.requests.isEmpty)
    }
    func testReplayStopsDurablyWithoutGuessingCounter() async {
        let vault = MemoryPairingVault(fixture()); let network = RecordingPairingTransport()
        network.respond = { _ in PairedDesktopResponse(status: 409, body: Data("{}".utf8)) }
        let model = client(vault, network); await model.refresh(); await model.refresh()
        XCTAssertEqual(vault.record?.phase, .rePairRequired); XCTAssertEqual(network.requests.count, 1)
        XCTAssertEqual(client(vault, network).record?.phase, .rePairRequired)
    }
    func testInactiveAndHiddenScreensDoNotSend() async {
        let vault = MemoryPairingVault(fixture()); let network = RecordingPairingTransport(); let model = client(vault, network)
        model.setScreen(id: screen, visible: true, foreground: false); await model.refresh()
        model.setScreen(id: screen, visible: false, foreground: true); await model.refresh()
        XCTAssertTrue(network.requests.isEmpty); XCTAssertGreaterThan(network.cancellations, 0)
    }
    func testAcceptanceClearsOnlyMatchingOutboxAndKeepsJob() async throws {
        let vault = MemoryPairingVault(fixture()); let network = RecordingPairingTransport()
        network.respond = { [self] request in
            let object = try JSONSerialization.jsonObject(with: request.body) as! [String: Any]
            return PairedDesktopResponse(status: 202, body: try JSONSerialization.data(withJSONObject:
                ["v": 1, "job_id": job, "submission_id": object["submission_id"]!, "status": "queued", "permission_revision": 1]))
        }
        await client(vault, network).submit(projectID: project, goal: "Synthetic", limits: .defaults)
        XCTAssertNil(vault.record?.outbox); XCTAssertEqual(vault.record?.jobs.first?.jobID, job)
    }
    func testAcceptedJobRetainsExactReviewedRequestAcrossRelaunch() async throws {
        let vault = MemoryPairingVault(fixture()); let network = RecordingPairingTransport()
        network.respond = { [self] request in
            let object = try JSONSerialization.jsonObject(with: request.body) as! [String: Any]
            return PairedDesktopResponse(status: 202, body: try JSONSerialization.data(withJSONObject:
                ["v": 1, "job_id": job, "submission_id": object["submission_id"]!, "status": "queued", "permission_revision": 1]))
        }
        var limits = PairedDesktopLimits.defaults; limits.maxToolCalls = 3; limits.maxSeconds = 15
        await client(vault, network).submit(projectID: project, goal: "Inspect my selected repository.\nDo not change files.", limits: limits)
        let original = try XCTUnwrap(network.requests.first).body
        // A real Codable round trip, not just a shared in-memory controller.
        let persisted = try JSONEncoder().encode(XCTUnwrap(vault.record))
        let restartedVault = MemoryPairingVault(try JSONDecoder().decode(PairedDesktopRecord.self, from: persisted))
        let restartedNetwork = RecordingPairingTransport()
        let restarted = client(restartedVault, restartedNetwork)
        let accepted = try XCTUnwrap(restarted.record?.jobs.first)
        let manifest = try XCTUnwrap(accepted.reviewedSubmission)
        XCTAssertEqual(manifest.body, original); XCTAssertEqual(manifest.permissionRevision, 1)
        XCTAssertEqual(try manifest.reviewedGoal(), "Inspect my selected repository.\nDo not change files.")
        XCTAssertEqual(try manifest.reviewedLimits(), limits)
        XCTAssertNil(restarted.record?.outbox); XCTAssertTrue(restartedNetwork.requests.isEmpty)
        XCTAssertEqual(accepted.status, "queued")
    }
    func testLegacyJobsDecodeWithoutInventingReviewedIntent() throws {
        let old: [String: Any] = ["projectID": project, "submissionID": "77777777-7777-4777-8777-777777777777", "jobID": job, "status": "completed"]
        let decoded = try JSONDecoder().decode(PairedDesktopJob.self, from: JSONSerialization.data(withJSONObject: old))
        XCTAssertNil(decoded.reviewedSubmission)
        var value = fixture(); value.jobs = [decoded]
        XCTAssertNoThrow(try value.validate())
    }
    private func reviewedSubmission(id: String = "77777777-7777-4777-8777-777777777777", goal: String = "Synthetic",
                                    limits: PairedDesktopLimits = .defaults) throws -> PairedDesktopSubmission {
        let limitObject = try JSONSerialization.jsonObject(with: JSONEncoder().encode(limits))
        let body = try JSONSerialization.data(withJSONObject: ["v": 1, "project_id": project, "submission_id": id,
            "goal": goal, "requested_write_paths": [String](), "limits": limitObject], options: [.sortedKeys])
        return PairedDesktopSubmission(projectID: project, submissionID: id, permissionRevision: 1, body: body)
    }
    func testManifestCannotBeAttachedToAnotherJobIdentity() throws {
        let manifest = try reviewedSubmission()
        for wrongProject in [false, true] {
            var value = fixture()
            value.jobs = [PairedDesktopJob(projectID: wrongProject ? host : project,
                submissionID: wrongProject ? manifest.submissionID : device, jobID: job, status: "queued", reviewedSubmission: manifest)]
            XCTAssertThrowsError(try value.validate())
        }
    }
    func testHistoricalManifestSurvivesCurrentGrantChanges() throws {
        let manifest = try reviewedSubmission()
        var value = fixture()
        value.jobs = [PairedDesktopJob(projectID: project, submissionID: manifest.submissionID, jobID: job,
            status: "completed", reviewedSubmission: manifest)]
        value.grants = [] // Revocation never rewrites the historical grant revision.
        XCTAssertNoThrow(try value.validate())
        let decoded = try JSONDecoder().decode(PairedDesktopRecord.self, from: JSONEncoder().encode(value))
        XCTAssertEqual(decoded.jobs.first?.reviewedSubmission, manifest)
    }
    func testAcceptedManifestStorageFailureRetainsOriginalOutboxForReconciliation() async throws {
        let vault = MemoryPairingVault(fixture()); let network = RecordingPairingTransport(); let model = client(vault, network)
        network.respond = { [self] request in
            vault.failWrites = true // Desktop accepts; local persistence then fails.
            let object = try JSONSerialization.jsonObject(with: request.body) as! [String: Any]
            return PairedDesktopResponse(status: 202, body: try JSONSerialization.data(withJSONObject:
                ["v": 1, "job_id": job, "submission_id": object["submission_id"]!, "status": "queued", "permission_revision": 1]))
        }
        await model.submit(projectID: project, goal: "Keep original intent", limits: .defaults)
        let original = try XCTUnwrap(vault.record?.outbox)
        XCTAssertTrue(model.storageUnavailable); XCTAssertTrue(vault.record?.jobs.isEmpty == true)
        vault.failWrites = false
        network.respond = { [self] _ in
            PairedDesktopResponse(status: 202, body: try JSONSerialization.data(withJSONObject:
                ["v": 1, "job_id": job, "submission_id": original.submissionID, "status": "running", "permission_revision": 1]))
        }
        await client(vault, network).retrySubmission()
        XCTAssertEqual(network.requests.map(\.body), [original.body, original.body])
        XCTAssertEqual(vault.record?.jobs.first?.reviewedSubmission, original); XCTAssertNil(vault.record?.outbox)
    }
    func testNewManifestCapacityRejectionDoesNotCreateUnresolvedOutbox() async throws {
        var value = fixture()
        for index in 1...8 {
            let suffix = String(format: "%012d", index)
            let manifest = try reviewedSubmission(id: "99999999-9999-4999-8999-" + suffix, goal: String(repeating: "x", count: 8192))
            value.jobs.append(PairedDesktopJob(projectID: project, submissionID: manifest.submissionID,
                jobID: "88888888-8888-4888-8888-" + suffix, status: "completed", reviewedSubmission: manifest))
        }
        try value.validate()
        XCTAssertLessThan(try JSONEncoder().encode(value).count, PairedDesktopRecord.maximumBytes)
        let vault = MemoryPairingVault(value); let network = RecordingPairingTransport(); let model = client(vault, network)
        await model.submit(projectID: project, goal: String(repeating: "y", count: 8192), limits: .defaults)
        XCTAssertTrue(network.requests.isEmpty); XCTAssertNil(vault.record?.outbox)
        XCTAssertEqual(vault.record?.nextSequence, value.nextSequence); XCTAssertEqual(vault.record?.jobs, value.jobs)
        XCTAssertEqual(model.message, PairedDesktopFailure.limit.localizedDescription)
        XCTAssertFalse(model.storageUnavailable); XCTAssertTrue(model.canSubmit)
    }
    func testManifestCapacityIsReservedBeforeSequenceAllocationOrNetwork() async throws {
        var value = fixture()
        // Fill with legitimate bounded history, leaving the loaded outbox intact.
        for index in 1...7 {
            let suffix = String(format: "%012d", index)
            let manifest = try reviewedSubmission(id: "99999999-9999-4999-8999-" + suffix,
                goal: String(repeating: "x", count: 8192))
            value.jobs.append(PairedDesktopJob(projectID: project, submissionID: manifest.submissionID,
                jobID: "88888888-8888-4888-8888-" + suffix, status: "completed", reviewedSubmission: manifest))
        }
        value.outbox = try reviewedSubmission(goal: String(repeating: "y", count: 8192))
        // Approach the real encoded Keychain limit without constructing a record
        // that the production loader itself would already reject.
        let base = value
        for count in stride(from: 1, through: 8192, by: 64) {
            var candidate = base
            let manifest = try reviewedSubmission(id: "99999999-9999-4999-8999-000000000008", goal: String(repeating: "z", count: count))
            candidate.jobs.append(PairedDesktopJob(projectID: project, submissionID: manifest.submissionID,
                jobID: "88888888-8888-4888-8888-000000000008", status: "completed", reviewedSubmission: manifest))
            if try JSONEncoder().encode(candidate).count > PairedDesktopRecord.maximumBytes { break }
            value = candidate
        }
        try value.validate()
        XCTAssertLessThanOrEqual(try JSONEncoder().encode(value).count, PairedDesktopRecord.maximumBytes)
        XCTAssertGreaterThan(try JSONEncoder().encode(value).count, PairedDesktopRecord.maximumBytes - 128)
        let vault = MemoryPairingVault(value); let network = RecordingPairingTransport(); let model = client(vault, network)
        await model.retrySubmission()
        XCTAssertTrue(network.requests.isEmpty); XCTAssertEqual(vault.record?.nextSequence, value.nextSequence)
        XCTAssertEqual(vault.record?.outbox, value.outbox); XCTAssertEqual(vault.record?.jobs, value.jobs)
        XCTAssertEqual(model.message, PairedDesktopFailure.limit.localizedDescription)
        XCTAssertFalse(model.storageUnavailable)
    }
    func testWrongSubmissionResponseRetainsOutbox() async {
        let vault = MemoryPairingVault(fixture()); let network = RecordingPairingTransport()
        network.respond = { [self] _ in PairedDesktopResponse(status: 202, body: Data("{\"v\":1,\"job_id\":\"\(job)\",\"submission_id\":\"77777777-7777-4777-8777-777777777777\",\"status\":\"queued\",\"permission_revision\":1}".utf8)) }
        await client(vault, network).submit(projectID: project, goal: "Synthetic", limits: .defaults)
        XCTAssertNotNil(vault.record?.outbox); XCTAssertTrue(vault.record?.jobs.isEmpty == true)
    }
    func testStrictJSONRejectsDuplicatesAndNonintegerNumbers() {
        for body in ["{\"v\":1,\"v\":1}", "{\"v\":1,\"\\u0076\":1}", "{\"v\":1.0}", "{\"v\":1e0}"] {
            XCTAssertThrowsError(try PairedDesktopJSON.parse(Data(body.utf8)))
        }
    }
    func testLimitsAndRecordValidationFailClosed() throws {
        var limits = PairedDesktopLimits.defaults; limits.maxSeconds = 121
        XCTAssertThrowsError(try limits.validate()); limits.maxSeconds = 1; XCTAssertNoThrow(try limits.validate())
        var record = fixture(); XCTAssertNoThrow(try record.validate()); record.nextSequence = 0
        XCTAssertThrowsError(try record.validate())
    }
    func testConcurrentActionsHaveOneInFlightRequest() async {
        let vault = MemoryPairingVault(fixture()); let transport = SuspendedPairingTransport()
        let model = PairedDesktopClient(vault: vault, transport: transport); model.setScreen(id: screen, visible: true, foreground: true)
        let task = Task { await model.refresh() }; await transport.waitUntilStarted()
        await model.submit(projectID: project, goal: "No concurrent submit", limits: .defaults)
        XCTAssertTrue(model.busy); XCTAssertNil(vault.record?.outbox)
        transport.release(); await task.value; XCTAssertEqual(transport.count, 1)
    }
    func testBackgroundCancellationPreservesUncertainSubmission() async {
        let vault = MemoryPairingVault(fixture()); let transport = SuspendedPairingTransport()
        let model = PairedDesktopClient(vault: vault, transport: transport); model.setScreen(id: screen, visible: true, foreground: true)
        let task = Task { await model.submit(projectID: project, goal: "Synthetic", limits: .defaults) }
        await transport.waitUntilStarted(); model.setScreen(id: screen, visible: false, foreground: false); await task.value
        XCTAssertNotNil(vault.record?.outbox); XCTAssertEqual(vault.record?.nextSequence, 2); XCTAssertFalse(model.busy)
    }
    func testCancellationRetriesSameIdentityAndBytes() async {
        var value = fixture(); value.jobs = [PairedDesktopJob(projectID: project, submissionID: "77777777-7777-4777-8777-777777777777", jobID: job, status: "running")]
        let vault = MemoryPairingVault(value); let network = RecordingPairingTransport(); let model = client(vault, network)
        await model.cancelJob(job); await model.cancelJob(job)
        XCTAssertEqual(network.requests.count, 2); XCTAssertEqual(network.requests[0].body, network.requests[1].body)
        XCTAssertNotEqual(network.requests[0].headers["X-Veyra-Sequence"], network.requests[1].headers["X-Veyra-Sequence"])
    }
    func testTerminalResultReceiptSurvivesCodableRelaunchWithoutNetwork() async throws {
        let manifest = try reviewedSubmission()
        var value = fixture()
        value.jobs = [PairedDesktopJob(projectID: project, submissionID: manifest.submissionID,
            jobID: job, status: "running", reviewedSubmission: manifest)]
        let vault = MemoryPairingVault(value); let network = RecordingPairingTransport()
        let body = try JSONSerialization.data(withJSONObject: ["v": 1, "job_id": job, "status": "completed",
            "cancel_requested": false, "counters": ["iterations": 2, "tool_calls": 1, "io_bytes": 12, "output_bytes": 20],
            "summary": "Synthetic read-only observation", "error_code": NSNull(), "artifacts": []] as [String: Any])
        network.respond = { _ in PairedDesktopResponse(status: 200, body: body) }
        await client(vault, network).refreshJob(job)
        let encoded = try JSONEncoder().encode(XCTUnwrap(vault.record))
        let restartedVault = MemoryPairingVault(try JSONDecoder().decode(PairedDesktopRecord.self, from: encoded))
        let restartedNetwork = RecordingPairingTransport()
        let restarted = client(restartedVault, restartedNetwork)
        let saved = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(XCTUnwrap(restarted.record))) as? [String: Any])
        let jobs = try XCTUnwrap(saved["jobs"] as? [[String: Any]])
        let receipt = try XCTUnwrap(jobs.first?["resultReceipt"] as? [String: Any], "A terminal response must be retained with its job, not only in transient view state")
        XCTAssertEqual(receipt["jobID"] as? String, job)
        XCTAssertEqual(receipt["summaryPreview"] as? String, "Synthetic read-only observation")
        XCTAssertEqual(receipt["responseSHA256"] as? String, try PairedExecutionCrypto.sha256Hex(body))
        XCTAssertTrue(restartedNetwork.requests.isEmpty)
    }
    private func receiptFixture() throws -> PairedDesktopRecord {
        let manifest = try reviewedSubmission()
        var value = fixture()
        value.jobs = [PairedDesktopJob(projectID: project, submissionID: manifest.submissionID,
            jobID: job, status: "running", reviewedSubmission: manifest)]
        return value
    }
    private func resultBody(status: String = "completed", summary: Any = "Synthetic observation",
                            cancelled: Bool = false, iterations: Int = 2, error: Any = NSNull()) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["v": 1, "job_id": job, "status": status,
            "cancel_requested": cancelled, "counters": ["iterations": iterations, "tool_calls": 1, "io_bytes": 12, "output_bytes": 20],
            "summary": summary, "error_code": error, "artifacts": [Any]()] as [String: Any], options: [.sortedKeys])
    }
    private func savedJob(_ record: PairedDesktopRecord?) throws -> [String: Any] {
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(XCTUnwrap(record))) as? [String: Any])
        return try XCTUnwrap((object["jobs"] as? [[String: Any]])?.first)
    }
    private func savedReceipt(_ record: PairedDesktopRecord?) throws -> [String: Any] {
        try XCTUnwrap(savedJob(record)["resultReceipt"] as? [String: Any])
    }
    func testReceiptPreservesUnicodeBoundaryAndFullSummaryIdentity() async throws {
        let text = String(repeating: "🙂", count: 80)
        let vault = try MemoryPairingVault(receiptFixture()); let network = RecordingPairingTransport()
        let body = try resultBody(summary: text)
        network.respond = { _ in PairedDesktopResponse(status: 200, body: body) }
        await client(vault, network).refreshJob(job)
        let receipt = try savedReceipt(vault.record)
        XCTAssertEqual(receipt["summaryPreview"] as? String, String(repeating: "🙂", count: 64))
        XCTAssertEqual(receipt["summaryByteCount"] as? Int, text.utf8.count)
        XCTAssertEqual(receipt["summarySHA256"] as? String, try PairedExecutionCrypto.sha256Hex(Data(text.utf8)))
        XCTAssertEqual(receipt["responseByteCount"] as? Int, body.count)
    }
    func testReceiptDistinguishesNullAndEmptySummary() async throws {
        let summaries: [Any] = [NSNull(), ""]
        for summary in summaries {
            let vault = try MemoryPairingVault(receiptFixture()); let network = RecordingPairingTransport()
            let body = try resultBody(summary: summary)
            network.respond = { _ in PairedDesktopResponse(status: 200, body: body) }
            await client(vault, network).refreshJob(job)
            let receipt = try savedReceipt(vault.record)
            if summary is NSNull {
                XCTAssertNil(receipt["summaryPreview"]); XCTAssertNil(receipt["summaryByteCount"]); XCTAssertNil(receipt["summarySHA256"])
            } else {
                XCTAssertEqual(receipt["summaryPreview"] as? String, ""); XCTAssertEqual(receipt["summaryByteCount"] as? Int, 0)
                XCTAssertEqual(receipt["summarySHA256"] as? String, try PairedExecutionCrypto.sha256Hex(Data()))
            }
        }
    }
    func testReceiptRejectsTerminalRegressionOrChangedResultWithoutReplacingHistory() async throws {
        for next in [try resultBody(status: "running"), try resultBody(status: "failed"),
                     try resultBody(summary: "Changed result"), try resultBody(iterations: 3), try resultBody(error: "changed_error")] {
            let vault = try MemoryPairingVault(receiptFixture()); let network = RecordingPairingTransport()
            let first = try resultBody()
            network.respond = { _ in PairedDesktopResponse(status: 200, body: first) }
            await client(vault, network).refreshJob(job)
            let previous = try savedJob(vault.record)
            network.respond = { _ in PairedDesktopResponse(status: 200, body: next) }
            let restarted = client(vault, network); await restarted.refreshJob(job)
            XCTAssertEqual(try savedJob(vault.record) as NSDictionary, previous as NSDictionary)
            XCTAssertEqual(restarted.message, PairedDesktopFailure.malformed.localizedDescription)
            XCTAssertFalse(restarted.storageUnavailable)
        }
    }
    func testReceiptAcceptsEquivalentTerminalJSONAndLaterCancellationFlag() async throws {
        let vault = try MemoryPairingVault(receiptFixture()); let network = RecordingPairingTransport()
        let first = try resultBody()
        network.respond = { _ in PairedDesktopResponse(status: 200, body: first) }
        await client(vault, network).refreshJob(job)
        let reformatted = Data(" \n".utf8) + first
        network.respond = { _ in PairedDesktopResponse(status: 200, body: reformatted) }
        await client(vault, network).refreshJob(job)
        XCTAssertEqual(try savedReceipt(vault.record)["responseSHA256"] as? String, try PairedExecutionCrypto.sha256Hex(reformatted))
        let cancellation = try resultBody(cancelled: true)
        network.respond = { _ in PairedDesktopResponse(status: 200, body: cancellation) }
        await client(vault, network).cancelJob(job)
        let receipt = try savedReceipt(vault.record)
        XCTAssertEqual(receipt["cancelRequested"] as? Bool, true)
        XCTAssertEqual(receipt["status"] as? String, "completed", "A cancellation request must not relabel earlier completion")
    }
    func testReceiptAllowsRunningToStartingDuringHostRecovery() async throws {
        let vault = try MemoryPairingVault(receiptFixture()); let network = RecordingPairingTransport()
        for status in ["running", "starting"] {
            let body = try resultBody(status: status, summary: NSNull())
            network.respond = { _ in PairedDesktopResponse(status: 200, body: body) }
            await client(vault, network).refreshJob(job)
            XCTAssertEqual(try savedReceipt(vault.record)["status"] as? String, status)
        }
    }
    func testReceiptSaveFailureKeepsPriorObservationAndStatus() async throws {
        let vault = try MemoryPairingVault(receiptFixture()); let network = RecordingPairingTransport()
        let initial = try resultBody(status: "running", summary: NSNull())
        network.respond = { _ in PairedDesktopResponse(status: 200, body: initial) }
        await client(vault, network).refreshJob(job)
        let previous = try savedJob(vault.record)
        let completion = try resultBody()
        network.respond = { _ in vault.failWrites = true; return PairedDesktopResponse(status: 200, body: completion) }
        let restarted = client(vault, network); await restarted.refreshJob(job)
        XCTAssertTrue(restarted.storageUnavailable)
        XCTAssertEqual(try savedJob(vault.record) as NSDictionary, previous as NSDictionary)
        XCTAssertEqual(vault.record?.nextSequence, 3, "The sent request's sequence stays consumed after a save failure")
        XCTAssertNil(restarted.jobDetails[job])
    }
    func testReceiptRejectsCountersBeyondReviewedLimitsBeforeReplacingStatus() async throws {
        var limits = PairedDesktopLimits.defaults; limits.maxIterations = 1
        let manifest = try reviewedSubmission(limits: limits)
        var value = fixture()
        value.jobs = [PairedDesktopJob(projectID: project, submissionID: manifest.submissionID,
            jobID: job, status: "running", reviewedSubmission: manifest)]
        let vault = MemoryPairingVault(value); let network = RecordingPairingTransport()
        let body = try resultBody(iterations: 2)
        network.respond = { _ in PairedDesktopResponse(status: 200, body: body) }
        let model = client(vault, network); await model.refreshJob(job)
        XCTAssertEqual(vault.record?.jobs.first?.status, "running")
        XCTAssertNil(try savedJob(vault.record)["resultReceipt"])
        XCTAssertEqual(model.message, PairedDesktopFailure.malformed.localizedDescription)
    }
    func testReceiptReservationRejectsNewSubmissionBeforeOutboxOrSequence() async throws {
        var value = fixture()
        for index in 1...7 {
            let suffix = String(format: "%012d", index)
            let manifest = try reviewedSubmission(id: "99999999-9999-4999-8999-" + suffix, goal: String(repeating: "x", count: 8192))
            value.jobs.append(PairedDesktopJob(projectID: project, submissionID: manifest.submissionID,
                jobID: "88888888-8888-4888-8888-" + suffix, status: "completed", reviewedSubmission: manifest))
        }
        let vault = MemoryPairingVault(value); let network = RecordingPairingTransport(); let model = client(vault, network)
        await model.submit(projectID: project, goal: String(repeating: "y", count: 8192), limits: .defaults)
        XCTAssertTrue(network.requests.isEmpty); XCTAssertNil(vault.record?.outbox)
        XCTAssertEqual(vault.record?.nextSequence, 1); XCTAssertEqual(vault.record?.jobs, value.jobs)
        XCTAssertFalse(model.storageUnavailable)
        XCTAssertEqual(model.message, PairedDesktopFailure.limit.localizedDescription)
    }
    func testNearFullLegacyHistoryRejectsReceiptReadAndCancelBeforeNetwork() async throws {
        var value = fixture()
        for index in 1...8 {
            let suffix = String(format: "%012d", index)
            let manifest = try reviewedSubmission(id: "99999999-9999-4999-8999-" + suffix, goal: String(repeating: "x", count: 8192))
            value.jobs.append(PairedDesktopJob(projectID: project, submissionID: manifest.submissionID,
                jobID: index == 1 ? job : "88888888-8888-4888-8888-" + suffix, status: "running", reviewedSubmission: manifest))
        }
        let base = value
        for count in stride(from: 1, through: 8192, by: 32) {
            var candidate = base
            candidate.archivedSubmissions = [try reviewedSubmission(goal: String(repeating: "z", count: count))]
            if try JSONEncoder().encode(candidate).count > PairedDesktopRecord.maximumBytes { break }
            value = candidate
        }
        try value.validate()
        XCTAssertLessThanOrEqual(try JSONEncoder().encode(value).count, PairedDesktopRecord.maximumBytes)
        XCTAssertGreaterThan(try JSONEncoder().encode(value).count, PairedDesktopRecord.maximumBytes - 128)
        for cancel in [false, true] {
            let vault = MemoryPairingVault(value); let network = RecordingPairingTransport(); let model = client(vault, network)
            if cancel { await model.cancelJob(job) } else { await model.refreshJob(job) }
            XCTAssertTrue(network.requests.isEmpty); XCTAssertEqual(vault.record?.nextSequence, value.nextSequence)
            XCTAssertEqual(vault.record?.jobs, value.jobs); XCTAssertEqual(vault.record?.archivedSubmissions, value.archivedSubmissions)
            XCTAssertFalse(model.storageUnavailable); XCTAssertNotNil(model.message)
        }
    }
    func testReceiptWithForeignIdentityMalformedHashTimeOrPreviewCannotLoad() async throws {
        let vault = try MemoryPairingVault(receiptFixture()); let network = RecordingPairingTransport()
        let body = try resultBody()
        network.respond = { _ in PairedDesktopResponse(status: 200, body: body) }
        await client(vault, network).refreshJob(job)
        let receipt = try savedReceipt(vault.record)
        for (field, invalid) in [("projectID", host as Any), ("submissionID", device as Any), ("jobID", host as Any),
                                 ("responseSHA256", "not-a-hash" as Any), ("observedAtMilliseconds", -1 as Any),
                                 ("summaryPreview", String(repeating: "x", count: 257) as Any)] {
            var changed = receipt; changed[field] = invalid
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(XCTUnwrap(vault.record))) as? [String: Any])
            var jobs = try XCTUnwrap(object["jobs"] as? [[String: Any]])
            jobs[0]["resultReceipt"] = changed; object["jobs"] = jobs
            let corrupted = try JSONSerialization.data(withJSONObject: object)
            XCTAssertThrowsError(try JSONDecoder().decode(PairedDesktopRecord.self, from: corrupted).validate(), field)
        }
    }
    func testReceiptEscapingStaysBoundedAndPreservesControlByteHash() async throws {
        let text = String(repeating: "\u{0}", count: 512)
        let vault = try MemoryPairingVault(receiptFixture()); let network = RecordingPairingTransport()
        let body = try resultBody(summary: text, error: String(repeating: "\u{0}", count: 128))
        network.respond = { _ in PairedDesktopResponse(status: 200, body: body) }
        await client(vault, network).refreshJob(job)
        let receipt = try savedReceipt(vault.record)
        XCTAssertEqual(receipt["summaryPreview"] as? String, String(repeating: "\u{0}", count: 256))
        XCTAssertEqual(receipt["summarySHA256"] as? String, try PairedExecutionCrypto.sha256Hex(Data(text.utf8)))
        XCTAssertLessThanOrEqual(try JSONEncoder().encode(XCTUnwrap(vault.record)).count, PairedDesktopRecord.maximumBytes)
        XCTAssertNoThrow(try vault.record?.validate())
    }
    func testBackgroundResponseCannotCreateReceiptOrChangeStatus() async throws {
        let value = try receiptFixture(); let vault = MemoryPairingVault(value); let network = RecordingPairingTransport()
        let model = client(vault, network); let body = try resultBody()
        network.respond = { [self] _ in
            model.setScreen(id: screen, visible: false, foreground: false)
            return PairedDesktopResponse(status: 200, body: body)
        }
        await model.refreshJob(job)
        XCTAssertEqual(vault.record?.jobs, value.jobs); XCTAssertNil(model.jobDetails[job])
    }
    func testReceiptCannotClearObservedCancellationOrRegressLegacyTerminalStatus() async throws {
        for legacy in [false, true] {
            var value = try receiptFixture()
            if legacy { value.jobs[0].status = "completed" }
            let vault = MemoryPairingVault(value); let network = RecordingPairingTransport()
            if !legacy {
                let body = try resultBody(cancelled: true)
                network.respond = { _ in PairedDesktopResponse(status: 200, body: body) }
                await client(vault, network).refreshJob(job)
            }
            let previous = try savedJob(vault.record)
            let body = try resultBody(status: legacy ? "running" : "completed", cancelled: false)
            network.respond = { _ in PairedDesktopResponse(status: 200, body: body) }
            await client(vault, network).refreshJob(job)
            XCTAssertEqual(try savedJob(vault.record) as NSDictionary, previous as NSDictionary)
        }
    }
    func testReservedNearCapacityHistoryFitsEscapedReceiptsAndCancellationForEveryJob() async throws {
        var base = fixture()
        for index in 1...5 {
            let suffix = String(format: "%012d", index)
            let manifest = try reviewedSubmission(id: "99999999-9999-4999-8999-" + suffix, goal: String(repeating: "x", count: 8192))
            base.jobs.append(PairedDesktopJob(projectID: project, submissionID: manifest.submissionID,
                jobID: "88888888-8888-4888-8888-" + suffix, status: "running", reviewedSubmission: manifest))
        }
        let pending = try reviewedSubmission(goal: String(repeating: "y", count: 8192)); base.outbox = pending
        base.archivedSubmissions = [try reviewedSubmission(id: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", goal: String(repeating: "z", count: 4096))]
        var value = base
        try value.validateAcceptanceCapacity(for: pending)
        var reachedBoundary = false
        for count in stride(from: 1, through: 8192, by: 32) {
            var candidate = base
            candidate.archivedSubmissions.append(try reviewedSubmission(id: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb", goal: String(repeating: "z", count: count)))
            do { try candidate.validateAcceptanceCapacity(for: pending); value = candidate }
            catch { reachedBoundary = true; break }
        }
        XCTAssertTrue(reachedBoundary, "Exercise an actual reservation boundary rather than a mostly empty record")
        let vault = MemoryPairingVault(value); let network = RecordingPairingTransport()
        network.respond = { [self] _ in
            PairedDesktopResponse(status: 202, body: try JSONSerialization.data(withJSONObject:
                ["v": 1, "job_id": job, "submission_id": pending.submissionID, "status": "running", "permission_revision": 1]))
        }
        await client(vault, network).retrySubmission()
        XCTAssertNil(vault.record?.outbox); XCTAssertEqual(vault.record?.jobs.count, 6)
        let ids = try XCTUnwrap(vault.record).jobs.map(\.jobID)
        for id in ids {
            for cancel in [false, true] {
                var response = try XCTUnwrap(JSONSerialization.jsonObject(with: resultBody(status: "awaiting_approval",
                    summary: String(repeating: "\u{0}", count: 512), cancelled: cancel,
                    error: String(repeating: "\u{0}", count: 128))) as? [String: Any])
                response["job_id"] = id
                let body = try JSONSerialization.data(withJSONObject: response)
                network.respond = { _ in PairedDesktopResponse(status: 200, body: body) }
                let model = client(vault, network)
                if cancel { await model.cancelJob(id) } else { await model.refreshJob(id) }
                let stored = try XCTUnwrap(vault.record)
                XCTAssertLessThanOrEqual(try JSONEncoder().encode(stored).count, PairedDesktopRecord.maximumBytes)
                try stored.validate()
                let encodedJob = try JSONSerialization.jsonObject(with: JSONEncoder().encode(XCTUnwrap(stored.jobs.first(where: { $0.jobID == id })))) as? [String: Any]
                XCTAssertNotNil(encodedJob?["resultReceipt"])
                XCTAssertFalse(model.storageUnavailable)
            }
        }
        XCTAssertEqual(vault.record?.archivedSubmissions, value.archivedSubmissions)
    }
    func testArchiveRequiresConfirmationAndRetainsOriginal() async throws {
        let vault = MemoryPairingVault(fixture()); let network = RecordingPairingTransport(); let model = client(vault, network)
        await model.submit(projectID: project, goal: "Uncertain", limits: .defaults); let original = try XCTUnwrap(vault.record?.outbox)
        model.archiveSubmission(original.submissionID, confirmedMayAlreadyBeAccepted: false)
        XCTAssertEqual(vault.record?.outbox, original)
        model.archiveSubmission(original.submissionID, confirmedMayAlreadyBeAccepted: true)
        XCTAssertNil(vault.record?.outbox); XCTAssertEqual(vault.record?.archivedSubmissions, [original]); XCTAssertEqual(network.requests.count, 1)
        await model.submit(projectID: project, goal: "Explicit new task", limits: .defaults)
        XCTAssertNotEqual(vault.record?.outbox?.submissionID, original.submissionID)
    }
    func testArchivedRestoreAfterRelaunchDoesNotSendOrChangeBytes() async throws {
        let vault = MemoryPairingVault(fixture()); let network = RecordingPairingTransport(); let model = client(vault, network)
        await model.submit(projectID: project, goal: "Uncertain", limits: .defaults); let original = try XCTUnwrap(vault.record?.outbox)
        model.archiveSubmission(original.submissionID, confirmedMayAlreadyBeAccepted: true)
        let restarted = client(vault, network); restarted.restoreArchivedSubmission(original.submissionID)
        XCTAssertEqual(vault.record?.outbox, original); XCTAssertEqual(network.requests.count, 1)
        await restarted.retrySubmission()
        XCTAssertEqual(network.requests[0].body, network.requests[1].body); XCTAssertEqual(vault.record?.archivedSubmissions, [original])
    }
    func testFullArchiveNeverEvictsOrOverwritesAnOutbox() async throws {
        let vault = MemoryPairingVault(fixture()); let network = RecordingPairingTransport(); let model = client(vault, network)
        for i in 0..<PairedDesktopRecord.maximumArchivedSubmissions {
            await model.submit(projectID: project, goal: "Uncertain \(i)", limits: .defaults)
            model.archiveSubmission(try XCTUnwrap(vault.record?.outbox).submissionID, confirmedMayAlreadyBeAccepted: true)
        }
        let history = try XCTUnwrap(vault.record?.archivedSubmissions)
        await model.submit(projectID: project, goal: "Keep pending", limits: .defaults); let pending = try XCTUnwrap(vault.record?.outbox)
        model.archiveSubmission(pending.submissionID, confirmedMayAlreadyBeAccepted: true); model.restoreArchivedSubmission(history[0].submissionID)
        XCTAssertEqual(vault.record?.outbox, pending); XCTAssertEqual(vault.record?.archivedSubmissions, history)
    }
    private func fullHistoryWithArchivedSubmission(restored: Bool) async throws -> PairedDesktopRecord {
        let vault = MemoryPairingVault(fixture()); let network = RecordingPairingTransport(); let model = client(vault, network)
        await model.submit(projectID: project, goal: "Uncertain archived operation", limits: .defaults)
        let pending = try XCTUnwrap(vault.record?.outbox)
        model.archiveSubmission(pending.submissionID, confirmedMayAlreadyBeAccepted: true)
        var value = try XCTUnwrap(vault.record)
        value.jobs = (1...20).map { index in
            let suffix = String(format: "%012d", index)
            return PairedDesktopJob(projectID: project, submissionID: "99999999-9999-4999-8999-" + suffix,
                jobID: "88888888-8888-4888-8888-" + suffix, status: "completed")
        }
        if restored { value.outbox = pending }
        try value.validate()
        return value
    }
    func testFullJobHistoryRejectsArchiveRestoreWithoutChangingStateOrSending() async throws {
        let original = try await fullHistoryWithArchivedSubmission(restored: false)
        let vault = MemoryPairingVault(original); let network = RecordingPairingTransport(); let model = client(vault, network)
        model.restoreArchivedSubmission(try XCTUnwrap(original.archivedSubmissions.first).submissionID)
        XCTAssertTrue(network.requests.isEmpty)
        XCTAssertEqual(vault.record?.nextSequence, original.nextSequence)
        XCTAssertEqual(vault.record?.outbox, original.outbox)
        XCTAssertEqual(vault.record?.archivedSubmissions, original.archivedSubmissions)
        XCTAssertEqual(vault.record?.jobs, original.jobs)
        XCTAssertEqual(model.message, PairedDesktopFailure.limit.localizedDescription)
        XCTAssertFalse(model.storageUnavailable)
    }
    func testFullJobHistoryPreservesLoadedOutboxWithoutAllocatingSequenceOrSending() async throws {
        let original = try await fullHistoryWithArchivedSubmission(restored: true)
        let vault = MemoryPairingVault(original); let network = RecordingPairingTransport(); let model = client(vault, network)
        await model.retrySubmission()
        XCTAssertTrue(network.requests.isEmpty)
        XCTAssertEqual(vault.record?.nextSequence, original.nextSequence)
        XCTAssertEqual(vault.record?.outbox, original.outbox)
        XCTAssertEqual(vault.record?.archivedSubmissions, original.archivedSubmissions)
        XCTAssertEqual(vault.record?.jobs, original.jobs)
        XCTAssertEqual(model.message, PairedDesktopFailure.limit.localizedDescription)
        XCTAssertFalse(model.storageUnavailable)
    }
    func testRejectedRequestIsNeverAutomaticallyArchived() async {
        let vault = MemoryPairingVault(fixture()); let network = RecordingPairingTransport()
        network.respond = { _ in PairedDesktopResponse(status: 400, body: Data("{}".utf8)) }
        await client(vault, network).submit(projectID: project, goal: "Retain", limits: .defaults)
        XCTAssertNotNil(vault.record?.outbox); XCTAssertTrue(vault.record?.archivedSubmissions.isEmpty == true)
    }
    func testOfflinePendingEnrollmentExpiresLocally() async {
        var value = fixture(expiry: 1000); value.phase = .pending; value.grants = []
        let vault = MemoryPairingVault(value); let network = RecordingPairingTransport()
        let model = PairedDesktopClient(vault: vault, transport: network, now: { Date(timeIntervalSince1970: 2) })
        model.setScreen(id: screen, visible: true, foreground: true); await model.pollIfDue(); await model.refresh()
        XCTAssertEqual(vault.record?.phase, .rePairRequired); XCTAssertEqual(vault.record?.nextSequence, 1); XCTAssertTrue(network.requests.isEmpty)
    }
    func testExpiryDuringDurableAllocationStillStopsBeforeSend() async {
        var value = fixture(expiry: 1000); value.phase = .pending; value.grants = []
        let vault = MemoryPairingVault(value); let network = RecordingPairingTransport(); var clock: TimeInterval = 0.5
        vault.onUpdate = { clock = 2 }
        let model = PairedDesktopClient(vault: vault, transport: network, now: { Date(timeIntervalSince1970: clock) })
        model.setScreen(id: screen, visible: true, foreground: true); await model.refresh()
        XCTAssertTrue(network.requests.isEmpty); XCTAssertEqual(vault.record?.phase, .rePairRequired)
    }
    func testAllStatusEntrypointsRespectFiveSecondsButNotMutations() async {
        let vault = MemoryPairingVault(fixture()); let network = RecordingPairingTransport(); var tick: TimeInterval = 100
        let model = PairedDesktopClient(vault: vault, transport: network, monotonicTime: { tick })
        model.setScreen(id: screen, visible: true, foreground: true); await model.refresh(); await model.refresh()
        model.setScreen(id: screen, visible: true, foreground: false); model.setScreen(id: screen, visible: true, foreground: true); await model.refresh()
        XCTAssertEqual(network.requests.count, 1); tick += 5; await model.refresh(); XCTAssertEqual(network.requests.count, 2)
        await model.submit(projectID: project, goal: "Immediate mutation", limits: .defaults); XCTAssertEqual(network.requests.count, 3)
    }
    func testSharedWindowsKeepOneCounterAndIndependentVisibility() async {
        let vault = MemoryPairingVault(fixture()); let network = RecordingPairingTransport(); let shared = client(vault, network); let second = UUID()
        shared.setScreen(id: second, visible: true, foreground: true); shared.setScreen(id: screen, visible: false, foreground: false)
        XCTAssertTrue(shared.canRequest); XCTAssertEqual(network.cancellations, 0)
        await shared.refresh(); await shared.submit(projectID: project, goal: "Other window", limits: .defaults)
        XCTAssertEqual(network.requests.map { $0.headers["X-Veyra-Sequence"] }, ["1", "2"])
        shared.setScreen(id: second, visible: true, foreground: false); XCTAssertFalse(shared.canRequest); XCTAssertEqual(network.cancellations, 1)
    }
    func testKeychainLoadRequiresPasscodeAttributesWithoutUpgrading() throws {
        let api = RecordingPairingKeychain(); let vault = PairedDesktopKeychain(api: api); let data = try JSONEncoder().encode(fixture())
        api.item = [kSecValueData as String: data, kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        XCTAssertThrowsError(try vault.load()); XCTAssertEqual(api.adds, 0); XCTAssertEqual(api.updates, 0)
        XCTAssertEqual(api.lastQuery?[kSecReturnAttributes as String] as? Bool, true); XCTAssertEqual(api.lastQuery?[kSecReturnData as String] as? Bool, true)
        api.item = [kSecValueData as String: data, kSecAttrAccessible as String: kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly]
        XCTAssertEqual(try vault.load()?.nextSequence, 1)
    }
    func testKeychainRejectsUnknownReceiptFieldsWithoutOverwritingStoredBytes() async throws {
        let memory = try MemoryPairingVault(receiptFixture()); let network = RecordingPairingTransport()
        let body = try resultBody()
        network.respond = { _ in PairedDesktopResponse(status: 200, body: body) }
        await client(memory, network).refreshJob(job)
        let original = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(XCTUnwrap(memory.record))) as? [String: Any])
        for nestedCounter in [false, true] {
            var object = original; var jobs = try XCTUnwrap(object["jobs"] as? [[String: Any]])
            var receipt = try XCTUnwrap(jobs[0]["resultReceipt"] as? [String: Any])
            if nestedCounter {
                var counters = try XCTUnwrap(receipt["counters"] as? [String: Any])
                counters["futureCounter"] = 1; receipt["counters"] = counters
            } else { receipt["futureEvidence"] = "Preserve unsupported evidence" }
            jobs[0]["resultReceipt"] = receipt; object["jobs"] = jobs
            let bytes = try JSONSerialization.data(withJSONObject: object)
            let api = RecordingPairingKeychain(); let vault = PairedDesktopKeychain(api: api)
            api.item = [kSecValueData as String: bytes, kSecAttrAccessible as String: kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly]
            XCTAssertThrowsError(try vault.load())
            let transport = RecordingPairingTransport(); let model = PairedDesktopClient(vault: vault, transport: transport)
            model.setScreen(id: screen, visible: true, foreground: true); await model.refreshJob(job)
            XCTAssertTrue(model.storageUnavailable); XCTAssertTrue(transport.requests.isEmpty)
            XCTAssertEqual(api.adds, 0); XCTAssertEqual(api.updates, 0); XCTAssertEqual(api.deletes, 0)
            XCTAssertEqual(api.item?[kSecValueData as String] as? Data, bytes)
        }
        // Exact supported receipts, absent optional fields and legacy jobs still load.
        for includeReceipt in [true, false] {
            var object = original; var jobs = try XCTUnwrap(object["jobs"] as? [[String: Any]])
            if !includeReceipt { jobs[0].removeValue(forKey: "resultReceipt") }
            object["jobs"] = jobs
            let api = RecordingPairingKeychain(); let vault = PairedDesktopKeychain(api: api)
            api.item = [kSecValueData as String: try JSONSerialization.data(withJSONObject: object),
                        kSecAttrAccessible as String: kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly]
            XCTAssertEqual(try vault.load()?.jobs[0].resultReceipt != nil, includeReceipt)
        }
    }
    func testKeychainCreateAndUpdateRequireNonBackupPasscodePolicy() throws {
        let api = RecordingPairingKeychain(); let vault = PairedDesktopKeychain(api: api)
        try vault.create(fixture()); XCTAssertEqual(api.lastQuery?[kSecAttrAccessible as String] as? String, kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly as String)
        XCTAssertEqual(api.lastQuery?[kSecAttrSynchronizable as String] as? Bool, false)
        api.addStatus = errSecAuthFailed; XCTAssertThrowsError(try vault.create(fixture()))
        try vault.update(fixture()); XCTAssertEqual(api.lastQuery?[kSecAttrAccessible as String] as? String, kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly as String)
        XCTAssertNil(api.lastUpdates?[kSecAttrAccessible as String])
    }
    func testPendingStatusUsesExactRetainedSchema() async {
        var value = fixture(); value.phase = .pending; value.grants = []
        let vault = MemoryPairingVault(value); let network = RecordingPairingTransport()
        network.respond = { _ in PairedDesktopResponse(status: 200, body: Data("{\"v\":1,\"state\":\"pending\",\"expires_at_ms\":253402300799999,\"grants\":[]}".utf8)) }
        await client(vault, network).refresh()
        XCTAssertEqual(vault.record?.phase, .pending); XCTAssertEqual(vault.record?.nextSequence, 2)
        XCTAssertTrue(vault.record?.grants.isEmpty == true)
    }
    func testActiveStatusAcceptsOnlyReadOnlyGrantsAndNullExpiry() async throws {
        var value = fixture(); value.phase = .pending; value.grants = []
        let vault = MemoryPairingVault(value); let network = RecordingPairingTransport()
        network.respond = { [self] _ in
            let object: [String: Any] = ["v": 1, "state": "active", "expires_at_ms": NSNull(), "grants": [
                ["project_id": project, "label": "Synthetic", "capabilities": ["jobs.read_only"], "permission_revision": 1]]]
            return PairedDesktopResponse(status: 200, body: try JSONSerialization.data(withJSONObject: object))
        }
        await client(vault, network).refresh()
        XCTAssertEqual(vault.record?.phase, .active); XCTAssertEqual(vault.record?.grants.first?.projectID, project)
    }
    func testSavedPublicPairingRequestRecoversOriginalIdentity() async throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "paired-execution-v1", withExtension: "json"))
        let fixture = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        func text(_ key: String) throws -> String { try XCTUnwrap(fixture[key] as? String) }
        let body: [String: Any] = ["v": 1, "host_id": host, "invite_id": try text("invite_id"),
            "client_nonce": try text("client_nonce"), "device_name": try text("device_name"), "client_public_key": try text("client_public_key"),
            "proof": try text("proof"), "signature": try text("pair_signature")]
        let raw = try JSONSerialization.data(withJSONObject: body)
        let value = try PairedDesktopRecord(hostID: host, origin: "https://192.168.1.20:8443", pin: String(repeating: "a", count: 64),
            privateKey: Data(repeating: 0, count: 31) + Data([1]), beginBody: raw, safetyCode: text("safety_code"), expiresAt: 253402300799999)
        try value.validate()
        let vault = MemoryPairingVault(value); let network = RecordingPairingTransport()
        network.respond = { [self] request in
            XCTAssertEqual(request.body, raw); XCTAssertTrue(request.headers.isEmpty)
            return PairedDesktopResponse(status: 200, body: try JSONSerialization.data(withJSONObject:
                ["v": 1, "device_id": device, "state": "pending_local_approval", "expires_at_ms": value.expiresAt, "safety_code": value.safetyCode]))
        }
        await client(vault, network).retryEnrollment()
        XCTAssertEqual(vault.record?.deviceID, device); XCTAssertEqual(vault.record?.phase, .pending)
        XCTAssertEqual(vault.record?.privateKey, value.privateKey); XCTAssertEqual(vault.record?.nextSequence, 1)
    }
    func testForgetOnlyDeletesLocalState() {
        let vault = MemoryPairingVault(fixture()); let network = RecordingPairingTransport(); let model = client(vault, network)
        model.forget(); XCTAssertNil(vault.record); XCTAssertNil(model.record); XCTAssertTrue(network.requests.isEmpty)
    }
}

private final class MemoryPairingVault: PairedDesktopVault {
    var record: PairedDesktopRecord?; var failReads = false; var failWrites = false; var onUpdate: (() -> Void)?; var creations = 0
    init(_ record: PairedDesktopRecord? = nil) { self.record = record }
    func load() throws -> PairedDesktopRecord? { if failReads { throw PairedDesktopFailure.storage }; return record }
    func create(_ record: PairedDesktopRecord) throws { creations += 1; if failWrites || self.record != nil { throw PairedDesktopFailure.storage }; self.record = record }
    func update(_ record: PairedDesktopRecord) throws { if failWrites || self.record == nil { throw PairedDesktopFailure.storage }; self.record = record; onUpdate?() }
    func delete() throws { if failWrites { throw PairedDesktopFailure.storage }; record = nil }
}
private final class RecordingPairingTransport: PairedDesktopTransport {
    var requests: [PairedDesktopRequest] = []; var cancellations = 0
    var respond: ((PairedDesktopRequest) throws -> PairedDesktopResponse)?
    func send(_ request: PairedDesktopRequest) async throws -> PairedDesktopResponse { requests.append(request); if let respond { return try respond(request) }; throw PairedDesktopFailure.unavailable }
    func cancel() { cancellations += 1 }
}
private final class SuspendedPairingTransport: PairedDesktopTransport {
    private let lock = NSLock(); private var continuation: CheckedContinuation<PairedDesktopResponse, Error>?
    private var waiter: CheckedContinuation<Void, Never>?; private var requestCount = 0
    var count: Int { lock.lock(); defer { lock.unlock() }; return requestCount }
    func waitUntilStarted() async { await withCheckedContinuation { value in lock.lock(); if requestCount > 0 { lock.unlock(); value.resume() } else { waiter = value; lock.unlock() } } }
    func send(_ request: PairedDesktopRequest) async throws -> PairedDesktopResponse {
        try await withCheckedThrowingContinuation { value in lock.lock(); continuation = value; requestCount += 1; let w = waiter; waiter = nil; lock.unlock(); w?.resume() }
    }
    func release() { lock.lock(); let value = continuation; continuation = nil; lock.unlock(); value?.resume(throwing: PairedDesktopFailure.unavailable) }
    func cancel() { release() }
}
private final class RecordingPairingKeychain: PairedDesktopKeychainAPI {
    var item: [String: Any]?; var addStatus: OSStatus = errSecSuccess; var adds = 0; var updates = 0; var deletes = 0
    var lastQuery: [String: Any]?; var lastUpdates: [String: Any]?
    func copyMatching(_ query: [String: Any]) -> (OSStatus, CFTypeRef?) { lastQuery = query; guard let item else { return (errSecItemNotFound, nil) }; return (errSecSuccess, item as CFDictionary) }
    func add(_ query: [String: Any]) -> OSStatus { lastQuery = query; adds += 1; return addStatus }
    func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus { lastQuery = query; lastUpdates = attributes; updates += 1; return errSecSuccess }
    func delete(_ query: [String: Any]) -> OSStatus { lastQuery = query; deletes += 1; return errSecSuccess }
}
