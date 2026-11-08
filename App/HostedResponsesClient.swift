import Foundation

/// Injection occurs only at the network boundary. Production never substitutes another provider or route.
protocol HostedTransport: Sendable {
    func stream(_ request: URLRequest, session: HostedAuthSession, receive: @escaping @Sendable (Data) throws -> Void) async throws
}

final class HostedHTTPTransport: NSObject, HostedTransport, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust {
            completionHandler(.performDefaultHandling, nil)
        } else { completionHandler(.cancelAuthenticationChallenge, nil) }
    }
    static func validateResponse(_ response: URLResponse, session: HostedAuthSession) throws {
        try session.validate()
        guard let http = response as? HTTPURLResponse, let url = http.url else { throw HostedFailure.invalidResponse }
        try HostedRequestPolicy.validate(url)
        if http.statusCode == 401 { session.revoke(); throw HostedFailure.expired }
        guard http.statusCode == 200 else { throw HostedFailure.providerRejected }
        guard http.mimeType?.lowercased() == "text/event-stream" else { throw HostedFailure.invalidResponse }
        guard response.expectedContentLength <= Int64(HostedRequestPolicy.maximumResponseBytes) else { throw HostedFailure.oversized }
    }
    func stream(_ request: URLRequest, session authentication: HostedAuthSession,
                receive: @escaping @Sendable (Data) throws -> Void) async throws {
        guard let url = request.url else { throw HostedFailure.untrustedDestination }
        try HostedRequestPolicy.validate(url)
        try Task.checkCancellation()
        try authentication.validate()
        let session = URLSession(configuration: HostedRequestPolicy.configuration(), delegate: self, delegateQueue: nil)
        let registration = try authentication.registerCancellation { session.invalidateAndCancel() }
        defer { session.invalidateAndCancel(); authentication.unregister(registration) }
        try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            let (bytes, response) = try await session.bytes(for: request)
            try Self.validateResponse(response, session: authentication)
            var chunk = Data()
            var total = 0
            for try await byte in bytes {
                try Task.checkCancellation()
                guard total < HostedRequestPolicy.maximumResponseBytes else { throw HostedFailure.oversized }
                total += 1; chunk.append(byte)
                if chunk.count == 4_096 {
                    try authentication.validate()
                    try receive(chunk)
                    chunk.removeAll(keepingCapacity: true)
                }
            }
            try Task.checkCancellation()
            try authentication.validate()
            if !chunk.isEmpty { try receive(chunk) }
        }, onCancel: { session.invalidateAndCancel() })
    }
}

struct HostedResponsesClient: Sendable {
    private let transport: any HostedTransport
    init(transport: any HostedTransport = HostedHTTPTransport()) { self.transport = transport }
    func answer(consent: HostedConsent, session: HostedAuthSession) async throws -> String {
        do {
            try Task.checkCancellation()
            let request = try HostedRequestPolicy.request(consent: consent, session: session)
            let accumulator = HostedEventAccumulator()
            try await transport.stream(request, session: session) { data in
                try Task.checkCancellation()
                try session.validate()
                try accumulator.append(data)
            }
            try Task.checkCancellation()
            try session.validate()
            let answer = try session.redactAnswer(accumulator.finish())
            try Task.checkCancellation()
            try session.validate()
            return answer
        } catch { throw HostedRequestPolicy.safeError(error) }
    }
}

/// Incremental SSE decoder. Bounds apply before UTF-8/JSON decoding, including ignored events.
/// Only text deltas and completed message text are used; tool calls never execute or reach another tool.
final class HostedEventAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var line = Data()
    private var eventData = Data()
    private var totalBytes = 0
    private var answer = ""
    private var completed = false
    private var failed = false

    func append(_ data: Data) throws {
        lock.lock(); defer { lock.unlock() }
        do {
            guard !failed, data.count <= HostedRequestPolicy.maximumResponseBytes - totalBytes else { throw HostedFailure.oversized }
            totalBytes += data.count
            for byte in data {
                if byte == 10 {
                    if line.last == 13 { line.removeLast() }
                    try consumeLine()
                    line.removeAll(keepingCapacity: true)
                } else {
                    guard line.count < 65_536 else { throw HostedFailure.oversized }
                    line.append(byte)
                }
            }
        } catch { failed = true; throw error }
    }
    func finish() throws -> String {
        lock.lock(); defer { lock.unlock() }
        guard !failed, completed, line.isEmpty, eventData.isEmpty,
              !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw HostedFailure.invalidResponse }
        return answer
    }
    private func consumeLine() throws {
        if line.isEmpty { try consumeEvent(); return }
        guard let text = String(data: line, encoding: .utf8) else { throw HostedFailure.invalidResponse }
        guard text.hasPrefix("data:") else { return } // SSE comments, event labels, IDs, retry hints are inert.
        var payload = text.dropFirst(5)
        if payload.first == " " { payload = payload.dropFirst() }
        let bytes = Data(payload.utf8)
        guard bytes.count + eventData.count + 1 <= 131_072 else { throw HostedFailure.oversized }
        if !eventData.isEmpty { eventData.append(10) }
        eventData.append(bytes)
    }
    private func consumeEvent() throws {
        guard !eventData.isEmpty else { return }
        let data = eventData
        eventData.removeAll(keepingCapacity: true)
        if data == Data("[DONE]".utf8) {
            guard completed else { throw HostedFailure.invalidResponse }
            return
        }
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let event = object as? [String: Any], let type = event["type"] as? String else { throw HostedFailure.invalidResponse }
        guard !completed else { throw HostedFailure.invalidResponse }
        switch type {
        case "response.output_text.delta", "response.refusal.delta":
            guard let delta = event["delta"] as? String else { throw HostedFailure.invalidResponse }
            try appendText(delta)
        case "response.completed":
            guard let response = event["response"] as? [String: Any], response["status"] as? String == "completed" else { throw HostedFailure.invalidResponse }
            // Some compatible responses contain final text only. Do not append the full answer twice.
            if answer.isEmpty, let output = response["output"] as? [[String: Any]] {
                for item in output where item["type"] as? String == "message" {
                    for content in item["content"] as? [[String: Any]] ?? [] {
                        if content["type"] as? String == "output_text", let text = content["text"] as? String { try appendText(text) }
                        if content["type"] as? String == "refusal", let text = content["refusal"] as? String { try appendText(text) }
                    }
                }
            }
            completed = true
        case "error", "response.failed", "response.incomplete": throw HostedFailure.invalidResponse
        default: break
        }
    }
    private func appendText(_ text: String) throws {
        guard text.utf8.count <= HostedRequestPolicy.maximumOutputBytes - answer.utf8.count else { throw HostedFailure.oversized }
        answer += text
    }
}
