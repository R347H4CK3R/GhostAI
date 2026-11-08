import Foundation
import Combine
import CryptoKit
import Security

struct PairedDesktopRequest { let origin: String; let pin: String; let route: String; let headers: [String: String]; let body: Data }
struct PairedDesktopResponse { let status: Int; let body: Data }
protocol PairedDesktopTransport: AnyObject {
    func send(_ request: PairedDesktopRequest) async throws -> PairedDesktopResponse
    func cancel()
}
/// One App-owned controller for all windows. Busy spans every suspension; every
/// sequence is committed before transmission, and lifecycle cancellation never
/// discards operation bytes or silently creates a new submission identity.
@MainActor final class PairedDesktopClient: ObservableObject {
    @Published private(set) var record: PairedDesktopRecord?
    @Published private(set) var invitation: PairedExecutionInvitation?
    @Published private(set) var previewToken: UUID?
    @Published private(set) var busy = false
    @Published private(set) var storageUnavailable = false
    @Published private(set) var message: String?
    @Published private(set) var jobDetails: [String: String] = [:]
    private let vault: PairedDesktopVault; private let transport: PairedDesktopTransport
    private let now: () -> Date; private let monotonicTime: () -> TimeInterval
    private let makeSigningKey: () throws -> P256.Signing.PrivateKey
    private var descriptor: Data?; private var loaded = false
    private var screens: [UUID: Bool] = [:]; private var epoch: UInt64 = 0
    private var lastPoll: TimeInterval = -.infinity; private var lastStatusPoll: TimeInterval = -.infinity
    private var lastJobPoll: [String: TimeInterval] = [:]
    init(vault: PairedDesktopVault = PairedDesktopKeychain(), transport: PairedDesktopTransport = PairedDesktopPinnedTransport(),
         now: @escaping () -> Date = Date.init, monotonicTime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         makeSigningKey: @escaping () throws -> P256.Signing.PrivateKey = { P256.Signing.PrivateKey() }) {
        self.vault = vault; self.transport = transport; self.now = now; self.monotonicTime = monotonicTime
        self.makeSigningKey = makeSigningKey; reloadStorage()
    }
    private var hasActiveScreen: Bool { screens.values.contains(true) }
    private var nowMilliseconds: Int64 { Int64(now().timeIntervalSince1970 * 1000) }
    var canRequest: Bool { hasActiveScreen && !busy && !storageUnavailable && record?.phase != .rePairRequired }
    var canSubmit: Bool { canRequest && record?.phase == .active && record?.outbox == nil && (record?.jobs.count ?? 20) < 20 }
    private var provisionalExpired: Bool {
        guard let value = record, value.phase == .beginning || value.phase == .pending else { return false }; return value.expiresAt <= nowMilliseconds
    }
    func reloadStorage() {
        guard !busy else { return }
        do { record = try vault.load(); storageUnavailable = false; loaded = true; message = nil }
        catch { storageUnavailable = true; message = PairedDesktopFailure.storage.localizedDescription }
    }
    func setScreen(id: UUID, visible: Bool, foreground: Bool) {
        let wasActive = hasActiveScreen
        if visible { screens[id] = foreground } else { screens.removeValue(forKey: id) }
        if wasActive && !hasActiveScreen { pause() }
    }
    private func pause() { epoch &+= 1; transport.cancel() }
    func preview(_ data: Data) throws {
        guard loaded, !storageUnavailable, record == nil, !busy else { throw PairedDesktopFailure.storage }
        let invitation = try PairedExecutionInvitation.parse(data, nowMilliseconds: nowMilliseconds)
        // Even an identical repeat is a new review. Invalidate consent before
        // publishing different descriptor contents to any observing window.
        previewToken = nil; descriptor = data; self.invitation = invitation; previewToken = UUID(); message = nil
    }
    func dismissPreview() { previewToken = nil; descriptor = nil; invitation = nil }
    /// Called only after explicit review/approval of persistent access in the UI.
    func confirmPairing(expectedPreviewToken: UUID, deviceName: String) async {
        // Main-actor preflight has no suspension before acquiring busy and making
        // the key. A stale window can never authorize a newer shared invitation.
        guard record == nil, previewToken == expectedPreviewToken, let descriptor else {
            report(PairedDesktopFailure.stalePreview); return
        }
        guard canRequest else { return }
        busy = true; defer { busy = false }
        do {
            try Task.checkCancellation()
            let invitation = try PairedExecutionInvitation.parse(descriptor, nowMilliseconds: nowMilliseconds)
            let name = try PairedExecutionWire.deviceName(deviceName)
            let key = try makeSigningKey(); var nonce = [UInt8](repeating: 0, count: 32)
            guard SecRandomCopyBytes(kSecRandomDefault, nonce.count, &nonce) == errSecSuccess else { throw PairedDesktopFailure.storage }
            let publicKey = PairedExecutionWire.base64URL(key.publicKey.x963Representation); let nonceText = PairedExecutionWire.base64URL(Data(nonce))
            let proof = try PairedExecutionCrypto.pairProof(invitation: invitation, clientNonce: nonceText, clientPublicKey: publicKey, deviceName: name)
            let body = try Self.encode(["v": 1, "host_id": invitation.hostID, "invite_id": invitation.inviteID,
                "client_nonce": nonceText, "device_name": name, "client_public_key": publicKey, "proof": proof.proof,
                "signature": try PairedExecutionCrypto.sign(message: proof.signedBytes, using: key)])
            let value = PairedDesktopRecord(hostID: invitation.hostID, origin: invitation.origin, pin: invitation.tlsLeafSHA256,
                privateKey: key.rawRepresentation, beginBody: body, safetyCode: proof.safetyCode, expiresAt: invitation.expiresAtMilliseconds)
            do { try vault.create(value) } catch { throw PairedDesktopFailure.storage }
            record = value; dismissPreview(); try await begin()
        } catch { report(error) }
    }
    func retryEnrollment() async { await perform { try await self.begin() } }
    private func begin() async throws {
        guard var value = record, value.phase == .beginning, let body = value.beginBody else { throw PairedDesktopFailure.malformed }
        let response = try await send(PairedDesktopRequest(origin: value.origin, pin: value.pin, route: "/v1/pair/begin", headers: [:], body: body))
        guard response.status == 200 else { throw PairedDesktopFailure.malformed }
        let object = try PairedDesktopJSON.parse(response.body); try object.exact(["v", "device_id", "state", "expires_at_ms", "safety_code"])
        guard try object.integer("v") == 1, try object.string("state") == "pending_local_approval",
              try object.integer("expires_at_ms") == value.expiresAt, try object.string("safety_code") == value.safetyCode else { throw PairedDesktopFailure.malformed }
        value.deviceID = try PairedExecutionWire.canonicalUUID(object.string("device_id")); value.phase = .pending; try persist(value)
        message = "Compare the safety code and exact grants on the desktop, then approve locally there."
    }
    func refresh() async {
        await perform {
            guard let value = self.record else { throw PairedDesktopFailure.malformed }
            if value.phase == .beginning { try await self.begin() } else { try await self.refreshGrants() }
        }
    }
    func pollIfDue() async {
        guard canRequest else { return }
        if provisionalExpired { await perform {}; return }
        guard let value = record else { return }
        let tick = monotonicTime(); guard tick - lastPoll >= 5 else { return }; lastPoll = tick
        if value.phase == .pending { await refresh() }
        else if value.phase == .active, let job = value.jobs.first(where: { !$0.isTerminal }) { await refreshJob(job.jobID) }
    }
    private func refreshGrants() async throws {
        let tick = monotonicTime(); guard tick - lastStatusPoll >= 5 else { return }; lastStatusPoll = tick
        let response = try await signed(route: "/v1/pair/status", body: Data("{\"v\":1}".utf8))
        guard response.status == 200, var value = record else { throw PairedDesktopFailure.malformed }
        let object = try PairedDesktopJSON.parse(response.body); try object.exact(["v", "state", "expires_at_ms", "grants"])
        guard try object.integer("v") == 1 else { throw PairedDesktopFailure.malformed }
        let phase = try object.string("state"); let items = try object.array("grants")
        guard items.count <= 16 else { throw PairedDesktopFailure.malformed }
        var grants: [PairedDesktopGrant] = []
        for item in items {
            try item.exact(["project_id", "label", "capabilities", "permission_revision"])
            let caps = try item.array("capabilities"); guard caps.count == 1, case .string("jobs.read_only") = caps[0] else { throw PairedDesktopFailure.malformed }
            let grant = try PairedDesktopGrant(projectID: item.string("project_id"), label: item.string("label"), capabilities: ["jobs.read_only"], permissionRevision: item.integer("permission_revision"))
            try grant.validate(); grants.append(grant)
        }
        guard Set(grants.map(\.projectID)).count == grants.count else { throw PairedDesktopFailure.malformed }
        if phase == "active" {
            guard case .null = try object.value("expires_at_ms") else { throw PairedDesktopFailure.malformed }
            value.phase = .active; value.grants = grants; value.beginBody = nil
        } else if phase == "pending" {
            guard grants.isEmpty, try object.integer("expires_at_ms") == value.expiresAt else { throw PairedDesktopFailure.malformed }
            guard value.expiresAt > nowMilliseconds else { try stopPairing(); throw PairedDesktopFailure.enrollmentExpired }
            value.phase = .pending
        } else if ["expired", "rejected"].contains(phase) { try stopPairing(); throw PairedDesktopFailure.rePair }
        else { throw PairedDesktopFailure.malformed }
        try persist(value); message = phase == "active" ? "Desktop authorization confirmed for the listed read-only projects." : "Waiting for local desktop approval."
    }
    func submit(projectID: String, goal: String, limits: PairedDesktopLimits) async {
        await perform {
            guard var value = self.record, value.phase == .active else { throw PairedDesktopFailure.malformed }
            guard value.outbox == nil else { throw PairedDesktopFailure.outbox }; guard value.jobs.count < 20 else { throw PairedDesktopFailure.limit }
            guard let grant = value.grants.first(where: { $0.projectID == projectID }), !goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, goal.utf8.count <= 8192 else { throw PairedDesktopFailure.malformed }
            try limits.validate(); let submission = UUID().uuidString.lowercased()
            let limitObject = try JSONSerialization.jsonObject(with: JSONEncoder().encode(limits))
            let body = try Self.encode(["v": 1, "project_id": projectID, "submission_id": submission, "goal": goal, "requested_write_paths": [String](), "limits": limitObject])
            guard body.count <= 16384 else { throw PairedDesktopFailure.limit }
            value.outbox = PairedDesktopSubmission(projectID: projectID, submissionID: submission, permissionRevision: grant.permissionRevision, body: body)
            try self.persist(value); try await self.submitOutbox()
        }
    }
    func retrySubmission() async { await perform { try await self.submitOutbox() } }
    private func submitOutbox() async throws {
        guard let value = record, value.phase == .active, let outbox = value.outbox else { throw PairedDesktopFailure.malformed }
        // Reserve local reconciliation capacity before consuming a sequence or
        // sending an archived/loaded operation that the desktop could accept.
        guard value.jobs.count < 20 else { throw PairedDesktopFailure.limit }
        let response = try await signed(route: "/v1/jobs/submit", body: outbox.body)
        guard response.status == 202, var current = record else { throw PairedDesktopFailure.malformed }
        let object = try PairedDesktopJSON.parse(response.body); try object.exact(["v", "job_id", "submission_id", "status", "permission_revision"])
        let status = try object.string("status")
        guard try object.integer("v") == 1, try object.string("submission_id") == outbox.submissionID,
              try object.integer("permission_revision") == outbox.permissionRevision, current.outbox == outbox,
              PairedDesktopJob.statuses.contains(status), current.jobs.count < 20 else { throw PairedDesktopFailure.malformed }
        let jobID = try PairedExecutionWire.canonicalUUID(object.string("job_id"))
        guard !current.jobs.contains(where: { $0.jobID == jobID }) else { throw PairedDesktopFailure.malformed }
        current.jobs.append(PairedDesktopJob(projectID: outbox.projectID, submissionID: outbox.submissionID, jobID: jobID, status: status))
        current.outbox = nil; try persist(current); message = "The desktop durably accepted the job. Acceptance does not mean completion."
    }
    func archiveSubmission(_ submissionID: String, confirmedMayAlreadyBeAccepted: Bool) {
        guard confirmedMayAlreadyBeAccepted else { return }
        mutateLocal {
            guard var value = self.record, let pending = value.outbox, pending.submissionID == submissionID else { throw PairedDesktopFailure.outbox }
            if let old = value.archivedSubmissions.first(where: { $0.submissionID == submissionID }) { guard old == pending else { throw PairedDesktopFailure.storage } }
            else { guard value.archivedSubmissions.count < PairedDesktopRecord.maximumArchivedSubmissions else { throw PairedDesktopFailure.archiveFull }; value.archivedSubmissions.append(pending) }
            value.outbox = nil; try self.persist(value)
            self.message = "Original bytes and ID retained in the archive. This did not cancel the job or prove failure. Check the desktop before starting a new task."
        }
    }
    func restoreArchivedSubmission(_ submissionID: String) {
        mutateLocal {
            guard var value = self.record, value.outbox == nil, !value.jobs.contains(where: { $0.submissionID == submissionID }),
                  let archived = value.archivedSubmissions.first(where: { $0.submissionID == submissionID }) else { throw PairedDesktopFailure.outbox }
            guard value.jobs.count < 20 else { throw PairedDesktopFailure.limit }
            value.outbox = archived; try self.persist(value); self.message = "Original submission restored without sending. Explicit retry reconciles the same ID and bytes."
        }
    }
    private func mutateLocal(_ operation: () throws -> Void) {
        guard canRequest, record?.phase == .active else { return }; do { try operation() } catch { report(error) }
    }
    func refreshJob(_ jobID: String) async {
        await perform {
            guard let job = self.record?.jobs.first(where: { $0.jobID == jobID }) else { throw PairedDesktopFailure.malformed }
            let tick = self.monotonicTime(); guard tick - (self.lastJobPoll[jobID] ?? -.infinity) >= 5 else { return }; self.lastJobPoll[jobID] = tick
            try await self.readJob(route: "/v1/jobs/get", body: Self.encode(["v": 1, "project_id": job.projectID, "job_id": job.jobID]), jobID: jobID)
        }
    }
    func cancelJob(_ jobID: String) async {
        await perform {
            guard var value = self.record, let index = value.jobs.firstIndex(where: { $0.jobID == jobID }) else { throw PairedDesktopFailure.malformed }
            if value.jobs[index].cancellationBody == nil {
                value.jobs[index].cancellationBody = try Self.encode(["v": 1, "project_id": value.jobs[index].projectID, "job_id": jobID, "cancellation_id": UUID().uuidString.lowercased()]); try self.persist(value)
            }
            guard let body = value.jobs[index].cancellationBody else { throw PairedDesktopFailure.malformed }
            try await self.readJob(route: "/v1/jobs/cancel", body: body, jobID: jobID)
        }
    }
    private func readJob(route: String, body: Data, jobID: String) async throws {
        let response = try await signed(route: route, body: body)
        guard response.status == 200, var value = record, let index = value.jobs.firstIndex(where: { $0.jobID == jobID }) else { throw PairedDesktopFailure.malformed }
        let object = try PairedDesktopJSON.parse(response.body); try object.exact(["v", "job_id", "status", "cancel_requested", "counters", "summary", "error_code", "artifacts"])
        let status = try object.string("status")
        guard try object.integer("v") == 1, try object.string("job_id") == jobID, PairedDesktopJob.statuses.contains(status),
              case let .bool(cancelled) = try object.value("cancel_requested"), try object.array("artifacts").isEmpty else { throw PairedDesktopFailure.malformed }
        let counters = try object.value("counters"); try counters.exact(["iterations", "tool_calls", "io_bytes", "output_bytes"])
        for name in ["iterations", "tool_calls", "io_bytes", "output_bytes"] { guard try counters.integer(name) >= 0 else { throw PairedDesktopFailure.malformed } }
        let summary = try object.optionalString("summary", maximum: 262144); let error = try object.optionalString("error_code", maximum: 128)
        value.jobs[index].status = status; try persist(value)
        jobDetails[jobID] = [summary, error.map { "Desktop result code: \($0)" }, cancelled ? "Cancellation requested. Earlier reads cannot be undone." : nil].compactMap { $0 }.joined(separator: "\n\n")
        message = "Status refreshed. A model summary is not independent proof of completion."
    }
    private func signed(route: String, body: Data) async throws -> PairedDesktopResponse {
        guard var value = record, let device = value.deviceID, value.phase == .pending || value.phase == .active else { throw PairedDesktopFailure.rePair }
        guard value.nextSequence < Int64.max else { try stopPairing(); throw PairedDesktopFailure.rePair }
        let sequence = value.nextSequence; value.nextSequence += 1; try persist(value)
        let requestID = UUID().uuidString.lowercased()
        let frame = try PairedExecutionCrypto.requestFrame(hostID: value.hostID, deviceID: device, sequence: String(sequence), requestID: requestID, route: route, body: body)
        let key = try P256.Signing.PrivateKey(rawRepresentation: value.privateKey)
        let headers = ["X-Veyra-Host": value.hostID, "X-Veyra-Device": device, "X-Veyra-Sequence": String(sequence),
                       "X-Veyra-Request": requestID, "X-Veyra-Signature": try PairedExecutionCrypto.sign(message: frame, using: key)]
        return try await send(PairedDesktopRequest(origin: value.origin, pin: value.pin, route: route, headers: headers, body: body))
    }
    private func send(_ request: PairedDesktopRequest) async throws -> PairedDesktopResponse {
        guard hasActiveScreen else { throw PairedDesktopFailure.cancelled }
        // Storage/cryptographic work can cross the invitation deadline after the
        // operation's initial check. Recheck immediately before entering I/O.
        if provisionalExpired { try stopPairing(); throw PairedDesktopFailure.enrollmentExpired }
        let current = epoch; let response = try await transport.send(request)
        guard epoch == current, hasActiveScreen else { throw PairedDesktopFailure.cancelled }
        if response.status == 403 || response.status == 409 { try stopPairing(); throw PairedDesktopFailure.rePair }
        if response.status == 429 || response.status >= 500 { throw PairedDesktopFailure.unavailable }
        guard (200...299).contains(response.status) else { throw PairedDesktopFailure.rejected }; return response
    }
    private func persist(_ value: PairedDesktopRecord) throws { do { try vault.update(value) } catch { throw PairedDesktopFailure.storage }; record = value }
    private func stopPairing() throws { guard var value = record else { return }; value.phase = .rePairRequired; try persist(value) }
    private func perform(_ operation: () async throws -> Void) async {
        guard canRequest else { return }; busy = true; defer { busy = false }
        do {
            try Task.checkCancellation()
            if provisionalExpired { try stopPairing(); message = PairedDesktopFailure.enrollmentExpired.localizedDescription; return }
            try await operation()
        } catch { report(error) }
    }
    private func report(_ error: Error) {
        if case PairedDesktopFailure.storage = error { storageUnavailable = true }
        if error is CancellationError { message = PairedDesktopFailure.cancelled.localizedDescription }
        else { message = (error as? PairedDesktopFailure)?.localizedDescription ?? PairedDesktopFailure.malformed.localizedDescription }
    }
    func forget() {
        guard !busy else { return }; pause()
        do {
            try vault.delete(); record = nil; loaded = true; storageUnavailable = false; dismissPreview(); jobDetails = [:]
            lastPoll = -.infinity; lastStatusPoll = -.infinity; lastJobPoll = [:]
            message = "Local pairing removed. Revoke the device on the desktop too. This did not cancel desktop jobs or erase desktop data."
        } catch { report(PairedDesktopFailure.storage) }
    }
    private static func encode(_ value: [String: Any]) throws -> Data {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes]); guard data.count <= 262144 else { throw PairedDesktopFailure.limit }; return data
    }
}
