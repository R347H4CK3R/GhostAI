import Foundation
import Security
import CryptoKit

enum PairedDesktopFailure: Error, LocalizedError {
    case storage, malformed, unavailable, rejected, untrusted, cancelled, busy, rePair, limit, outbox, archiveFull, enrollmentExpired, stalePreview
    var errorDescription: String? {
        switch self {
        case .storage: return "Pairing storage is unavailable or has a weaker policy. A device passcode is required. Unlock the device and retry. No record is replaced automatically. Passcode removal may destroy the identity; revoke it on the desktop before explicitly pairing again."
        case .malformed: return "The request or desktop response is invalid or unsupported. Any unresolved submission is retained."
        case .unavailable: return "The desktop is unavailable or could not be reached securely. Check its foreground host, power and local-network access. Pending submissions are retained."
        case .rejected: return "The desktop rejected the request. Check its grants and finite budgets. The original submission is retained."
        case .untrusted: return "The desktop certificate, name, validity or pinned identity did not match. Verify the desktop locally before re-pairing."
        case .cancelled: return "Connection paused. A request may already have reached the desktop. Its saved submission remains available for reconciliation."
        case .busy: return "A desktop request is already in progress."
        case .rePair: return "The desktop rejected this identity or sequence. Requests stopped. Revoke locally on the desktop and explicitly re-pair; counters are never guessed or reset."
        case .limit: return "The request or local record exceeds a finite limit. No new work was sent."
        case .outbox: return "An earlier submission is unresolved. Retry it or explicitly archive it after checking the desktop before starting another task."
        case .archiveFull: return "The retained submission archive is full. No history was evicted and the outbox is preserved."
        case .enrollmentExpired: return "This invitation expired locally. Approval polling stopped even if the desktop is offline. The identity is preserved until explicit forget/re-pair."
        case .stalePreview: return "The invitation you reviewed changed or was cancelled. Review the current desktop identity and confirm it again. No key or connection was created from that stale confirmation."
        }
    }
}
struct PairedDesktopLimits: Codable, Equatable {
    var maxIterations = 8; var maxToolCalls = 32; var maxSeconds = 120
    var maxIOBytes = 1_048_576; var maxOutputBytes = 262_144
    static let defaults = Self()
    enum CodingKeys: String, CodingKey {
        case maxIterations = "max_iterations", maxToolCalls = "max_tool_calls", maxSeconds = "max_seconds"
        case maxIOBytes = "max_io_bytes", maxOutputBytes = "max_output_bytes"
    }
    func validate() throws {
        guard (1...8).contains(maxIterations), (1...32).contains(maxToolCalls), (1...120).contains(maxSeconds),
              (1...1_048_576).contains(maxIOBytes), (1...262_144).contains(maxOutputBytes) else { throw PairedDesktopFailure.limit }
    }
}
struct PairedDesktopGrant: Codable, Equatable, Identifiable {
    let projectID: String; let label: String; let capabilities: [String]; let permissionRevision: Int64
    var id: String { projectID }
    func validate() throws {
        _ = try PairedExecutionWire.canonicalUUID(projectID)
        guard !label.isEmpty, label.utf8.count <= 1024, permissionRevision > 0, capabilities == ["jobs.read_only"] else { throw PairedDesktopFailure.malformed }
    }
}
struct PairedDesktopSubmission: Codable, Equatable, Identifiable {
    let projectID: String; let submissionID: String; let permissionRevision: Int64
    let body: Data // Immutable exact wire bytes across all retries.
    var id: String { submissionID }
    func validate() throws {
        _ = try PairedExecutionWire.canonicalUUID(projectID); _ = try PairedExecutionWire.canonicalUUID(submissionID)
        guard body.count <= 16384, permissionRevision > 0 else { throw PairedDesktopFailure.storage }
        let value = try PairedDesktopJSON.parse(body)
        try value.exact(["v", "project_id", "submission_id", "goal", "requested_write_paths", "limits"])
        guard try value.integer("v") == 1, try value.string("project_id") == projectID,
              try value.string("submission_id") == submissionID, try value.array("requested_write_paths").isEmpty else { throw PairedDesktopFailure.storage }
        let goal = try value.string("goal")
        guard !goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, goal.utf8.count <= 8192 else { throw PairedDesktopFailure.storage }
        let limits = try value.value("limits")
        let maxima: [String: Int64] = ["max_iterations": 8, "max_tool_calls": 32, "max_seconds": 120, "max_io_bytes": 1_048_576, "max_output_bytes": 262_144]
        try limits.exact(Set(maxima.keys))
        for (key, maximum) in maxima { guard try (1...maximum).contains(limits.integer(key)) else { throw PairedDesktopFailure.storage } }
    }
}
struct PairedDesktopJob: Codable, Equatable, Identifiable {
    let projectID: String; let submissionID: String; let jobID: String
    var status: String; var cancellationBody: Data?
    var id: String { jobID }
    var isTerminal: Bool { Self.terminal.contains(status) }
    static let terminal: Set<String> = ["completed", "refused", "exhausted", "cancelled", "failed", "awaiting_approval", "expired"]
    static let statuses = terminal.union(["queued", "starting", "running"])
}
struct PairedDesktopRecord: Codable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    enum Phase: String, Codable { case beginning, pending, active, rePairRequired }
    static let maximumArchivedSubmissions = 2
    var version = 1
    let hostID: String; let origin: String; let pin: String; let privateKey: Data
    var beginBody: Data?
    let safetyCode: String; let expiresAt: Int64
    var deviceID: String?; var phase: Phase = .beginning; var grants: [PairedDesktopGrant] = []
    var nextSequence: Int64 = 1; var outbox: PairedDesktopSubmission?
    var archivedSubmissions: [PairedDesktopSubmission] = []; var jobs: [PairedDesktopJob] = []
    var description: String { "PairedDesktopRecord(redacted)" }
    var debugDescription: String { description }
    var customMirror: Mirror { Mirror(self, children: ["identity": "redacted"]) }
    func validate() throws {
        guard version == 1, nextSequence > 0, privateKey.count == 32, jobs.count <= 20,
              archivedSubmissions.count <= Self.maximumArchivedSubmissions, grants.count <= 16,
              safetyCode.utf8.count == 16, safetyCode.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              (0...253402300799999).contains(expiresAt) else { throw PairedDesktopFailure.storage }
        let key = try P256.Signing.PrivateKey(rawRepresentation: privateKey)
        _ = try PairedExecutionWire.canonicalUUID(hostID); _ = try PairedExecutionWire.localIPv4Origin(origin); _ = try PairedExecutionWire.sha256Hex(pin)
        if let deviceID { _ = try PairedExecutionWire.canonicalUUID(deviceID) }
        if phase == .beginning { guard beginBody != nil, deviceID == nil else { throw PairedDesktopFailure.storage } }
        if phase == .active || phase == .pending { guard deviceID != nil else { throw PairedDesktopFailure.storage } }
        if let beginBody {
            guard beginBody.count <= 4096 else { throw PairedDesktopFailure.storage }
            let value = try PairedDesktopJSON.parse(beginBody)
            try value.exact(["v", "host_id", "invite_id", "client_nonce", "device_name", "client_public_key", "proof", "signature"])
            let publicKey = PairedExecutionWire.base64URL(key.publicKey.x963Representation)
            guard try value.integer("v") == 1, try value.string("host_id") == hostID, try value.string("client_public_key") == publicKey else { throw PairedDesktopFailure.storage }
            let name = try PairedExecutionWire.deviceName(value.string("device_name")); let proof = try value.string("proof")
            _ = try PairedExecutionWire.decodeBase64URL(proof, byteCount: 32)
            let frame = try PairedExecutionWire.pairFrame(hostID: hostID, inviteID: value.string("invite_id"), clientNonce: value.string("client_nonce"),
                clientPublicKey: publicKey, deviceNameSHA256: PairedExecutionCrypto.sha256Hex(Data(name.utf8))) + Data((proof + "\n").utf8)
            try PairedExecutionCrypto.verify(signature: value.string("signature"), publicKey: publicKey, message: frame)
            guard try String(PairedExecutionCrypto.sha256Hex(frame).prefix(16)) == safetyCode else { throw PairedDesktopFailure.storage }
        }
        guard Set(grants.map(\.projectID)).count == grants.count, Set(jobs.map(\.jobID)).count == jobs.count,
              Set(archivedSubmissions.map(\.submissionID)).count == archivedSubmissions.count else { throw PairedDesktopFailure.storage }
        for grant in grants { try grant.validate() }
        for job in jobs {
            _ = try PairedExecutionWire.canonicalUUID(job.projectID); _ = try PairedExecutionWire.canonicalUUID(job.submissionID); _ = try PairedExecutionWire.canonicalUUID(job.jobID)
            guard PairedDesktopJob.statuses.contains(job.status) else { throw PairedDesktopFailure.storage }
            if let body = job.cancellationBody {
                guard body.count <= 1024 else { throw PairedDesktopFailure.storage }
                let value = try PairedDesktopJSON.parse(body); try value.exact(["v", "project_id", "job_id", "cancellation_id"])
                guard try value.integer("v") == 1, try value.string("project_id") == job.projectID, try value.string("job_id") == job.jobID else { throw PairedDesktopFailure.storage }
                _ = try PairedExecutionWire.canonicalUUID(value.string("cancellation_id"))
            }
        }
        if let outbox, let prior = archivedSubmissions.first(where: { $0.submissionID == outbox.submissionID }) {
            guard prior == outbox else { throw PairedDesktopFailure.storage }
        }
        for submission in archivedSubmissions + [outbox].compactMap({ $0 }) { try submission.validate() }
    }
}
protocol PairedDesktopVault {
    func load() throws -> PairedDesktopRecord?
    func create(_ record: PairedDesktopRecord) throws
    func update(_ record: PairedDesktopRecord) throws
    func delete() throws
}
protocol PairedDesktopKeychainAPI {
    func copyMatching(_ query: [String: Any]) -> (OSStatus, CFTypeRef?)
    func add(_ query: [String: Any]) -> OSStatus
    func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus
    func delete(_ query: [String: Any]) -> OSStatus
}
struct PairedDesktopSystemKeychain: PairedDesktopKeychainAPI {
    func copyMatching(_ query: [String: Any]) -> (OSStatus, CFTypeRef?) { var result: CFTypeRef?; let status = SecItemCopyMatching(query as CFDictionary, &result); return (status, result) }
    func add(_ query: [String: Any]) -> OSStatus { SecItemAdd(query as CFDictionary, nil) }
    func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus { SecItemUpdate(query as CFDictionary, attributes as CFDictionary) }
    func delete(_ query: [String: Any]) -> OSStatus { SecItemDelete(query as CFDictionary) }
}
/// Atomic identity/counter/outbox. Passcode-bound class cannot be backed up or
/// migrated, unlike WhenUnlockedThisDeviceOnly's same-device restore behavior.
struct PairedDesktopKeychain: PairedDesktopVault {
    private let maximumBytes = 96 * 1024
    let api: PairedDesktopKeychainAPI
    init(api: PairedDesktopKeychainAPI = PairedDesktopSystemKeychain()) { self.api = api }
    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "dev.asterionveyra.paired-desktop.v1",
         kSecAttrAccount as String: "single-device-identity-and-outbox", kSecAttrSynchronizable as String: false]
    }
    func load() throws -> PairedDesktopRecord? {
        var request = query; request[kSecReturnData as String] = true; request[kSecReturnAttributes as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        let (status, result) = api.copyMatching(request)
        if status == errSecItemNotFound { return nil }
        // Unfiltered accessibility read distinguishes an unsafe item from absence.
        guard status == errSecSuccess, let attributes = result as? [String: Any],
              attributes[kSecAttrAccessible as String] as? String == kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly as String,
              let data = attributes[kSecValueData as String] as? Data, data.count <= maximumBytes else { throw PairedDesktopFailure.storage }
        do {
            guard case let .object(fields) = try PairedDesktopJSON.parse(data) else { throw PairedDesktopFailure.storage }
            let required: Set<String> = ["version", "hostID", "origin", "pin", "privateKey", "safetyCode", "expiresAt", "phase", "grants", "nextSequence", "jobs", "archivedSubmissions"]
            guard required.isSubset(of: Set(fields.keys)), Set(fields.keys).isSubset(of: required.union(["beginBody", "deviceID", "outbox"])) else { throw PairedDesktopFailure.storage }
            let value = try JSONDecoder().decode(PairedDesktopRecord.self, from: data); try value.validate(); return value
        } catch { throw PairedDesktopFailure.storage }
    }
    private func bytes(_ record: PairedDesktopRecord) throws -> Data {
        do { try record.validate(); let data = try JSONEncoder().encode(record); guard data.count <= maximumBytes else { throw PairedDesktopFailure.storage }; return data }
        catch { throw PairedDesktopFailure.storage }
    }
    func create(_ record: PairedDesktopRecord) throws {
        var request = query; request[kSecAttrAccessible as String] = kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly; request[kSecValueData as String] = try bytes(record)
        guard api.add(request) == errSecSuccess else { throw PairedDesktopFailure.storage } // Never delete/re-add.
    }
    func update(_ record: PairedDesktopRecord) throws {
        var matching = query; matching[kSecAttrAccessible as String] = kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly
        guard api.update(matching, attributes: [kSecValueData as String: try bytes(record)]) == errSecSuccess else { throw PairedDesktopFailure.storage }
    }
    func delete() throws { let status = api.delete(query); guard status == errSecSuccess || status == errSecItemNotFound else { throw PairedDesktopFailure.storage } }
}

/// Strict bounded JSON; rejects duplicate/escaped duplicate keys, floating-point
/// numbers, invalid UTF-8, excessive nesting and noncanonical integer encodings.
indirect enum PairedDesktopJSON {
    case object([String: Self]), array([Self]), string(String), integer(Int64), bool(Bool), null
    static func parse(_ data: Data) throws -> Self {
        guard data.count <= 524288, String(data: data, encoding: .utf8) != nil else { throw PairedDesktopFailure.malformed }
        var scanner = Scanner(bytes: Array(data)); let value = try scanner.value(depth: 0); scanner.whitespace()
        guard scanner.index == data.count else { throw PairedDesktopFailure.malformed }; return value
    }
    func exact(_ keys: Set<String>) throws { guard case let .object(values) = self, Set(values.keys) == keys else { throw PairedDesktopFailure.malformed } }
    func value(_ key: String) throws -> Self { guard case let .object(values) = self, let value = values[key] else { throw PairedDesktopFailure.malformed }; return value }
    func string(_ key: String) throws -> String { guard case let .string(text) = try value(key) else { throw PairedDesktopFailure.malformed }; return text }
    func integer(_ key: String) throws -> Int64 { guard case let .integer(number) = try value(key) else { throw PairedDesktopFailure.malformed }; return number }
    func array(_ key: String) throws -> [Self] { guard case let .array(values) = try value(key) else { throw PairedDesktopFailure.malformed }; return values }
    func optionalString(_ key: String, maximum: Int) throws -> String? {
        let value = try value(key); if case .null = value { return nil }
        guard case let .string(text) = value, text.utf8.count <= maximum else { throw PairedDesktopFailure.malformed }; return text
    }
    private struct Scanner {
        let bytes: [UInt8]; var index = 0; var tokens = 0
        mutating func whitespace() { while index < bytes.count, [9,10,13,32].contains(bytes[index]) { index += 1 } }
        mutating func take(_ byte: UInt8) -> Bool { guard index < bytes.count, bytes[index] == byte else { return false }; index += 1; return true }
        mutating func string() throws -> String {
            let start = index; guard take(34) else { throw PairedDesktopFailure.malformed }
            while index < bytes.count {
                let byte = bytes[index]; index += 1
                if byte == 34 { guard let text = try? JSONDecoder().decode(String.self, from: Data(bytes[start..<index])) else { throw PairedDesktopFailure.malformed }; return text }
                if byte == 92 { guard index < bytes.count else { throw PairedDesktopFailure.malformed }; index += 1 }
                else if byte < 32 { throw PairedDesktopFailure.malformed }
            }
            throw PairedDesktopFailure.malformed
        }
        mutating func value(depth: Int) throws -> PairedDesktopJSON {
            tokens += 1; guard depth <= 12, tokens <= 10000 else { throw PairedDesktopFailure.malformed }
            whitespace(); guard index < bytes.count else { throw PairedDesktopFailure.malformed }
            if take(123) {
                whitespace(); var fields: [String: PairedDesktopJSON] = [:]; if take(125) { return .object(fields) }
                while true {
                    let key = try string(); guard fields[key] == nil else { throw PairedDesktopFailure.malformed }
                    whitespace(); guard take(58) else { throw PairedDesktopFailure.malformed }
                    fields[key] = try value(depth: depth + 1); whitespace(); if take(125) { return .object(fields) }
                    guard take(44) else { throw PairedDesktopFailure.malformed }; whitespace()
                }
            }
            if take(91) {
                whitespace(); var values: [PairedDesktopJSON] = []; if take(93) { return .array(values) }
                while true { values.append(try value(depth: depth + 1)); whitespace(); if take(93) { return .array(values) }; guard take(44) else { throw PairedDesktopFailure.malformed } }
            }
            if bytes[index] == 34 { return .string(try string()) }
            let start = index; while index < bytes.count, ![9,10,13,32,44,93,125].contains(bytes[index]) { index += 1 }
            let text = String(decoding: bytes[start..<index], as: UTF8.self)
            if text == "null" { return .null }; if text == "true" { return .bool(true) }; if text == "false" { return .bool(false) }
            guard !text.isEmpty, text.utf8.count <= 19, text.utf8.allSatisfy({ (48...57).contains($0) }), text.count == 1 || text.first != "0", let integer = Int64(text) else { throw PairedDesktopFailure.malformed }
            return .integer(integer)
        }
    }
}
