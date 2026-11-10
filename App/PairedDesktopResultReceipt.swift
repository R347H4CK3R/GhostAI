import Foundation

struct PairedDesktopResultCounters: Codable, Equatable {
    let iterations: Int64; let toolCalls: Int64; let ioBytes: Int64; let outputBytes: Int64

    func validate(limits: PairedDesktopLimits) throws {
        guard (0...Int64(limits.maxIterations)).contains(iterations),
              (0...Int64(limits.maxToolCalls)).contains(toolCalls),
              (0...Int64(limits.maxIOBytes)).contains(ioBytes),
              (0...Int64(limits.maxOutputBytes)).contains(outputBytes) else { throw PairedDesktopFailure.malformed }
    }
    func isAtLeast(_ previous: Self) -> Bool {
        iterations >= previous.iterations && toolCalls >= previous.toolCalls &&
            ioBytes >= previous.ioBytes && outputBytes >= previous.outputBytes
    }
}

/// A bounded local observation of an authenticated desktop response. Hashes
/// identify received bytes; they are not a server signature or proof of work.
struct PairedDesktopResultReceipt: Codable, Equatable {
    static let maximumPreviewBytes = 256
    let version: Int
    let jobID: String; let projectID: String; let submissionID: String
    let observedAtMilliseconds: Int64
    let status: String; let cancelRequested: Bool
    let counters: PairedDesktopResultCounters
    let summaryPreview: String?; let summaryByteCount: Int?; let summarySHA256: String?
    let responseByteCount: Int; let responseSHA256: String; let errorCode: String?

    var summaryIsTruncated: Bool {
        guard let summaryPreview, let summaryByteCount else { return false }
        return summaryPreview.utf8.count < summaryByteCount
    }
    var observedAt: Date { Date(timeIntervalSince1970: Double(observedAtMilliseconds) / 1000) }

    static func parse(_ response: Data, for job: PairedDesktopJob, observedAtMilliseconds: Int64) throws -> (receipt: Self, summary: String?) {
        let object = try PairedDesktopJSON.parse(response)
        try object.exact(["v", "job_id", "status", "cancel_requested", "counters", "summary", "error_code", "artifacts"])
        guard try object.integer("v") == 1, try object.string("job_id") == job.jobID,
              case let .bool(cancelled) = try object.value("cancel_requested"),
              try object.array("artifacts").isEmpty else { throw PairedDesktopFailure.malformed }
        let values = try object.value("counters")
        try values.exact(["iterations", "tool_calls", "io_bytes", "output_bytes"])
        let counters = try PairedDesktopResultCounters(iterations: values.integer("iterations"),
            toolCalls: values.integer("tool_calls"), ioBytes: values.integer("io_bytes"), outputBytes: values.integer("output_bytes"))
        let summary = try object.optionalString("summary", maximum: 262144)
        let receipt = try Self(version: 1, jobID: job.jobID, projectID: job.projectID, submissionID: job.submissionID,
            observedAtMilliseconds: observedAtMilliseconds, status: object.string("status"), cancelRequested: cancelled,
            counters: counters, summaryPreview: summary.map(preview), summaryByteCount: summary?.utf8.count,
            summarySHA256: summary.map { try PairedExecutionCrypto.sha256Hex(Data($0.utf8)) },
            responseByteCount: response.count, responseSHA256: PairedExecutionCrypto.sha256Hex(response),
            errorCode: object.optionalString("error_code", maximum: 128))
        var observedJob = job; observedJob.status = receipt.status
        try receipt.validate(for: observedJob)
        try receipt.validateTransition(from: job)
        return (receipt, summary)
    }

    /// Codable ignores unknown keys. Reject unsupported persisted evidence
    /// before decoding so a later sequence save cannot silently erase it.
    static func validatePersistedShape(_ value: PairedDesktopJSON) throws {
        guard case let .object(fields) = value else { throw PairedDesktopFailure.storage }
        let required: Set<String> = ["version", "jobID", "projectID", "submissionID", "observedAtMilliseconds",
            "status", "cancelRequested", "counters", "responseByteCount", "responseSHA256"]
        let optional: Set<String> = ["summaryPreview", "summaryByteCount", "summarySHA256", "errorCode"]
        guard required.isSubset(of: Set(fields.keys)), Set(fields.keys).isSubset(of: required.union(optional)) else {
            throw PairedDesktopFailure.storage
        }
        try value.value("counters").exact(["iterations", "toolCalls", "ioBytes", "outputBytes"])
    }

    private static func preview(_ text: String) -> String {
        var result = ""; var count = 0
        for scalar in text.unicodeScalars {
            let part = String(scalar)
            guard count + part.utf8.count <= maximumPreviewBytes else { break }
            result += part; count += part.utf8.count
        }
        return result
    }

    func validate(for job: PairedDesktopJob) throws {
        _ = try PairedExecutionWire.canonicalUUID(jobID)
        _ = try PairedExecutionWire.canonicalUUID(projectID)
        _ = try PairedExecutionWire.canonicalUUID(submissionID)
        guard version == 1, jobID == job.jobID, projectID == job.projectID, submissionID == job.submissionID,
              status == job.status, PairedDesktopJob.statuses.contains(status),
              (0...253402300799999).contains(observedAtMilliseconds), (1...524288).contains(responseByteCount),
              (errorCode?.utf8.count ?? 0) <= 128 else { throw PairedDesktopFailure.malformed }
        _ = try PairedExecutionWire.sha256Hex(responseSHA256)
        let limits = try job.reviewedSubmission?.reviewedLimits() ?? .defaults
        try counters.validate(limits: limits)
        if let summaryPreview {
            guard let count = summaryByteCount, let hash = summarySHA256, (0...262144).contains(count),
                  summaryPreview.utf8.count <= min(Self.maximumPreviewBytes, count) else { throw PairedDesktopFailure.malformed }
            _ = try PairedExecutionWire.sha256Hex(hash)
            if summaryPreview.utf8.count == count {
                guard try hash == PairedExecutionCrypto.sha256Hex(Data(summaryPreview.utf8)) else { throw PairedDesktopFailure.malformed }
            } else {
                // A scalar occupies at most four UTF-8 bytes, so a truncated
                // prefix must fill all but at most three bytes of its budget.
                guard count > Self.maximumPreviewBytes, summaryPreview.utf8.count >= Self.maximumPreviewBytes - 3 else { throw PairedDesktopFailure.malformed }
            }
        } else if summaryByteCount != nil || summarySHA256 != nil { throw PairedDesktopFailure.malformed }
    }

    private func validateTransition(from job: PairedDesktopJob) throws {
        if job.isTerminal && status != job.status { throw PairedDesktopFailure.malformed }
        guard let previous = job.resultReceipt else { return }
        try previous.validate(for: job)
        guard counters.isAtLeast(previous.counters), !previous.cancelRequested || cancelRequested else { throw PairedDesktopFailure.malformed }
        if job.isTerminal {
            guard counters == previous.counters, summaryPreview == previous.summaryPreview,
                  summaryByteCount == previous.summaryByteCount, summarySHA256 == previous.summarySHA256,
                  errorCode == previous.errorCode else { throw PairedDesktopFailure.malformed }
        }
        // Whitespace/key order and false-to-true cancellation can change the
        // response hash without changing a previously observed terminal result.
    }

    /// JSON control characters expand to six bytes each. This valid synthetic
    /// receipt bounds every optional string, counter and timestamp encoding.
    /// It is only encoded for admission checks, never persisted or displayed.
    static func capacityReservation(for job: PairedDesktopJob) throws -> Self {
        let limits = try job.reviewedSubmission?.reviewedLimits() ?? .defaults
        return Self(version: 1, jobID: job.jobID, projectID: job.projectID, submissionID: job.submissionID,
            observedAtMilliseconds: 253402300799999, status: job.status, cancelRequested: false,
            counters: PairedDesktopResultCounters(iterations: Int64(limits.maxIterations), toolCalls: Int64(limits.maxToolCalls),
                ioBytes: Int64(limits.maxIOBytes), outputBytes: Int64(limits.maxOutputBytes)),
            summaryPreview: String(repeating: "\u{0}", count: maximumPreviewBytes), summaryByteCount: 262144,
            summarySHA256: String(repeating: "f", count: 64), responseByteCount: 524288,
            responseSHA256: String(repeating: "f", count: 64), errorCode: String(repeating: "\u{0}", count: 128))
    }
}
