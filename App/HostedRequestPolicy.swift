import Foundation

// Never include provider response bodies, URLs, input, or underlying transport errors here.
enum HostedFailure: LocalizedError, Equatable {
    case invalidToken, directInstallRequired, expired, invalidConsent, invalidInput, possibleCredential
    case untrustedDestination, oversized, invalidResponse, providerRejected, transport
    var errorDescription: String? {
        switch self {
        case .invalidToken: return "Enter an existing OpenAI API key without spaces or line breaks."
        case .directInstallRequired: return "Use a directly installed app. Do not enter API keys in Strata or another app host."
        case .expired: return "This hosted session ended. Enter your key again to start a new memory-only session."
        case .invalidConsent: return "This preview is no longer valid. Review the exact request again before sending."
        case .invalidInput: return "Enter a question and a model ID available to your account. Check the text size limits."
        case .possibleCredential: return "Possible credentials were detected. Remove secrets from your question and context before reviewing. Detection is not a guarantee."
        case .untrustedDestination: return "Blocked a request outside the fixed official HTTPS Responses endpoint."
        case .oversized: return "The request or response exceeds this app’s size limit. Nothing was automatically retried."
        case .invalidResponse: return "The provider returned an incomplete or unsupported text response. No partial answer was accepted."
        case .providerRejected: return "The provider rejected this request. Check your model access, API billing and limits. No automatic retry was made."
        case .transport: return "The request could not finish securely. It may have reached the provider and incurred charges. No automatic retry was made."
        }
    }
}

/// Immutable, single-use preview. No API key, automatic memory, chat history, or repository data.
struct HostedConsent: Identifiable, Sendable {
    let id: UUID
    let sessionID: UUID
    let question: String
    let context: String
    let model: String
    var recipient: String { HostedRequestPolicy.endpoint.absoluteString }
    fileprivate init(id: UUID, sessionID: UUID, question: String, context: String, model: String) {
        self.id = id; self.sessionID = sessionID; self.question = question; self.context = context; self.model = model
    }
}

enum HostedSecretFilter {
    // Heuristics only. User review remains mandatory; arbitrary sensitive information cannot be detected.
    private static let patterns = [
        "sk-[A-Za-z0-9_-]{8,}", "gh[pousr]_[A-Za-z0-9_]+", "github_pat_[A-Za-z0-9_]+",
        "AKIA[A-Z0-9]{16}", "-----BEGIN [A-Z ]*PRIVATE KEY-----",
        "(?i)authorization\\s*:\\s*bearer\\s+\\S+",
        "(?i)(password|api[_ -]?key|access[_ -]?token|client[_ -]?secret|secret)\\s*[:=]\\s*\\S+"
    ]
    static func containsCredential(_ text: String) -> Bool {
        patterns.contains { text.range(of: $0, options: .regularExpression) != nil }
    }
    static func redact(_ text: String) -> String {
        patterns.reduce(text) { $0.replacingOccurrences(of: $1, with: "[redacted credential]", options: .regularExpression) }
    }
}

/// Memory-only and shared across requests so revocation also blocks late answers.
/// Swift/URLSession cannot guarantee zeroization of prior String/header copies or protect a compromised host.
final class HostedAuthSession: @unchecked Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    let id = UUID()
    let expiresAt: Date
    private let lock = NSLock()
    private var token: String?
    private var pendingConsentID: UUID?
    private var cancellations: [UUID: @Sendable () -> Void] = [:]
    var description: String { "HostedAuthSession(redacted)" }
    var debugDescription: String { description }
    var customMirror: Mirror { Mirror(self, children: ["credential": "redacted"]) }

    init(token: String, directlyInstalled: Bool, expiresAt: Date = Date().addingTimeInterval(30 * 60)) throws {
        guard directlyInstalled else { throw HostedFailure.directInstallRequired }
        guard (20...512).contains(token.utf8.count), token.hasPrefix("sk-"),
              token.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95 }) else {
            throw HostedFailure.invalidToken
        }
        self.token = token; self.expiresAt = expiresAt
    }
    deinit { revoke() }

    func validate() throws {
        lock.lock()
        let valid = token != nil && Date() < expiresAt
        lock.unlock()
        if !valid { revoke(); throw HostedFailure.expired }
    }

    func prepare(question: String, context: String, model: String) throws -> HostedConsent {
        cancelPreview()
        try validate()
        try HostedRequestPolicy.validateInput(question: question, context: context, model: model)
        lock.lock()
        guard let token, Date() < expiresAt else {
            lock.unlock(); revoke(); throw HostedFailure.expired
        }
        guard !question.contains(token), !context.contains(token) else {
            lock.unlock(); throw HostedFailure.possibleCredential
        }
        let nonce = UUID()
        pendingConsentID = nonce
        lock.unlock()
        return HostedConsent(id: nonce, sessionID: id, question: question, context: context, model: model)
    }

    fileprivate func consume(_ consent: HostedConsent) throws -> String {
        lock.lock()
        guard let token, Date() < expiresAt else {
            lock.unlock(); revoke(); throw HostedFailure.expired
        }
        guard consent.sessionID == id, pendingConsentID == consent.id else {
            lock.unlock(); throw HostedFailure.invalidConsent
        }
        pendingConsentID = nil
        lock.unlock()
        return "Bearer " + token
    }

    func cancelPreview() { lock.lock(); pendingConsentID = nil; lock.unlock() }

    func registerCancellation(_ cancel: @escaping @Sendable () -> Void) throws -> UUID {
        lock.lock()
        guard token != nil, Date() < expiresAt else {
            lock.unlock(); cancel(); revoke(); throw HostedFailure.expired
        }
        let registration = UUID()
        cancellations[registration] = cancel
        lock.unlock()
        return registration
    }
    func unregister(_ registration: UUID) { lock.lock(); cancellations.removeValue(forKey: registration); lock.unlock() }
    func revoke() {
        lock.lock()
        token = nil; pendingConsentID = nil
        let active = Array(cancellations.values)
        cancellations.removeAll()
        lock.unlock()
        active.forEach { $0() }
    }

    func redactAnswer(_ text: String) throws -> String {
        lock.lock()
        guard let token, Date() < expiresAt else {
            lock.unlock(); revoke(); throw HostedFailure.expired
        }
        let result = text.replacingOccurrences(of: token, with: "[redacted credential]")
        lock.unlock()
        let redacted = HostedSecretFilter.redact(result)
        guard redacted.utf8.count <= HostedRequestPolicy.maximumOutputBytes else { throw HostedFailure.oversized }
        return redacted
    }
}

enum HostedRequestPolicy {
    static let endpoint = URL(string: "https://api.openai.com/v1/responses")!
    static let maximumQuestionBytes = 8_000
    static let maximumContextBytes = 24_000
    static let maximumResponseBytes = 524_288
    static let maximumOutputBytes = 32_768
    static let maximumOutputTokens = 2_048

    static func validate(_ url: URL) throws {
        // A byte-exact route deliberately excludes alternate ports, queries, escaped paths and user info.
        guard url.absoluteString == endpoint.absoluteString else { throw HostedFailure.untrustedDestination }
    }
    static func validateInput(question: String, context: String, model: String) throws {
        guard question.utf8.count <= maximumQuestionBytes, context.utf8.count <= maximumContextBytes else { throw HostedFailure.oversized }
        guard !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              (1...128).contains(model.utf8.count),
              model.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95 || $0 == 46 }),
              !question.contains("\0"), !context.contains("\0") else { throw HostedFailure.invalidInput }
        guard !HostedSecretFilter.containsCredential(question), !HostedSecretFilter.containsCredential(context),
              !HostedSecretFilter.containsCredential(model) else { throw HostedFailure.possibleCredential }
    }
    static func body(consent: HostedConsent) throws -> Data {
        try validateInput(question: consent.question, context: consent.context, model: consent.model)
        var content = [["type": "input_text", "text": consent.question]]
        if !consent.context.isEmpty { content.append(["type": "input_text", "text": consent.context]) }
        return try JSONSerialization.data(withJSONObject: [
            "model": consent.model, "input": [["role": "user", "content": content]],
            "stream": true, "store": false, "max_output_tokens": maximumOutputTokens,
            "tools": [], "tool_choice": "none"
        ], options: [.sortedKeys, .prettyPrinted])
    }
    static func request(consent: HostedConsent, session: HostedAuthSession) throws -> URLRequest {
        try validate(endpoint)
        let data = try body(consent: consent)
        var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 25)
        request.httpMethod = "POST"
        request.httpShouldHandleCookies = false
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = data
        request.setValue(try session.consume(consent), forHTTPHeaderField: "Authorization")
        return request
    }
    static func configuration() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 25
        config.timeoutIntervalForResource = 60
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCredentialStorage = nil
        config.protocolClasses = []
        config.connectionProxyDictionary = ["HTTPEnable": 0, "HTTPSEnable": 0, "SOCKSEnable": 0,
                                           "ProxyAutoConfigEnable": 0, "ProxyAutoDiscoveryEnable": 0]
        return config
    }
    static func safeError(_ error: Error) -> Error {
        if error is CancellationError || (error as? URLError)?.code == .cancelled { return CancellationError() }
        if let known = error as? HostedFailure { return known }
        return HostedFailure.transport
    }
}
