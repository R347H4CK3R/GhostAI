import Foundation

/// A write-only capability wrapper. It cannot be initialized from a read connection or Keychain.
/// The underlying token stays in memory for at most 15 minutes and one publication attempt.
/// Swift String storage cannot promise complete memory zeroization.
final class RepositoryProposalAuthorization: @unchecked Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    let repositoryID: Int
    private let session: GitHubAuthSession
    var description: String { "RepositoryProposalAuthorization(redacted)" }
    var debugDescription: String { description }
    var customMirror: Mirror { Mirror(self, children: ["credential": "redacted"]) }

    init(token: String, repositoryID: Int, directInstallationConfirmed: Bool) throws {
        guard directInstallationConfirmed else { throw RepositoryProposalFailure.directInstallRequired }
        guard repositoryID > 0 else { throw RepositoryProposalFailure.invalidScope }
        self.repositoryID = repositoryID
        do { session = try GitHubAuthSession(token: token, expiresAt: Date().addingTimeInterval(15 * 60)) }
        catch { throw RepositoryProposalFailure.invalidToken }
    }
    func authorizationValue() throws -> String {
        do { return try session.authorizationValue() }
        catch { throw RepositoryProposalFailure.credentialEnded }
    }
    func register(_ transport: URLSession) throws -> UUID {
        do { return try session.register(transport) }
        catch { throw RepositoryProposalFailure.credentialEnded }
    }
    func unregister(_ id: UUID) { session.unregister(id) }
    func revoke() { session.revoke() }
    deinit { session.revoke() }
}

enum RepositoryProposalNetworkPolicy {
    static let allowsRedirects = false
    static func validate(_ url: URL) throws {
        do { try GitHubRequestPolicy.validate(url) }
        catch { throw RepositoryProposalFailure.invalidResponse }
    }
    static func configuration() -> URLSessionConfiguration {
        let config = GitHubRequestPolicy.configuration()
        config.waitsForConnectivity = false
        return config
    }
}

struct RepositoryProposalResponse: Sendable {
    let status: Int
    let data: Data
    let url: URL
}

/// Injected transports must honor the byte cap and cancellation. Production streams the body.
struct RepositoryProposalTransport: Sendable {
    var send: @Sendable (URLRequest, Int, RepositoryProposalAuthorization) async throws -> RepositoryProposalResponse
    static var live: Self {
        Self { request, cap, auth in
            try await RepositoryProposalURLTransport().send(request, maximumBytes: cap, authorization: auth)
        }
    }
}

private final class RepositoryProposalURLTransport: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust {
            completionHandler(.performDefaultHandling, nil)
        } else { completionHandler(.cancelAuthenticationChallenge, nil) }
    }

    func send(_ request: URLRequest, maximumBytes: Int, authorization: RepositoryProposalAuthorization) async throws -> RepositoryProposalResponse {
        guard let url = request.url, (1...RepositoryProposalPolicy.maximumResponseBytes).contains(maximumBytes) else { throw RepositoryProposalFailure.invalidResponse }
        try RepositoryProposalNetworkPolicy.validate(url)
        let session = URLSession(configuration: RepositoryProposalNetworkPolicy.configuration(), delegate: self, delegateQueue: nil)
        var registration: UUID?
        defer {
            session.invalidateAndCancel()
            if let registration { authorization.unregister(registration) }
        }
        registration = try authorization.register(session)
        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse, response.url == url else { throw RepositoryProposalFailure.invalidResponse }
        if response.statusCode == 401 { authorization.revoke() }
        // Error bodies can echo credentials or source. Never consume or surface them.
        guard [200, 201].contains(response.statusCode) else {
            return RepositoryProposalResponse(status: response.statusCode, data: Data(), url: url)
        }
        guard response.expectedContentLength <= Int64(maximumBytes) else { throw RepositoryProposalFailure.invalidResponse }
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < maximumBytes else { throw RepositoryProposalFailure.invalidResponse }
            data.append(byte)
        }
        return RepositoryProposalResponse(status: response.statusCode, data: data, url: url)
    }
}
