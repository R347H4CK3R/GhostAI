import Foundation
import CryptoKit

struct PrivateMemorySyncRepository: Decodable, Sendable {
    struct Owner: Decodable, Sendable { let id: Int }
    struct Permissions: Decodable, Sendable { let push: Bool }
    let id: Int
    let full_name: String
    let `private`: Bool
    let default_branch: String
    let archived: Bool
    let disabled: Bool
    let owner: Owner
    let permissions: Permissions
    func validate(_ configuration: PrivateMemorySyncConfiguration) throws {
        guard `private`, !archived, !disabled, permissions.push else { throw PrivateMemorySyncFailure.privateRepository }
        guard id == configuration.repositoryID, full_name == configuration.repository,
              owner.id == configuration.accountID, default_branch == configuration.branch else { throw PrivateMemorySyncFailure.repositoryChanged }
    }
}
struct PrivateMemorySyncCooldown: Error, Sendable {
    let until: Date
    static func deadline(retryAfter: String?, reset: String?, now: Date = Date()) -> Date {
        var intervals: [TimeInterval] = [300]
        if let retryAfter {
            if let seconds = Double(retryAfter), seconds.isFinite, seconds >= 0 { intervals.append(seconds) }
            else {
                let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
                if let date = formatter.date(from: retryAfter) { intervals.append(max(0, date.timeIntervalSince(now))) }
            }
        }
        if let reset, let epoch = Double(reset), epoch.isFinite { intervals.append(max(0, epoch - now.timeIntervalSince1970)) }
        return now.addingTimeInterval(min(86_400, intervals.max() ?? 300))
    }
}
struct PrivateMemorySyncResponse: Sendable { let status: Int; let data: Data }
struct PrivateMemorySyncTransport: Sendable {
    var send: @Sendable (URLRequest, Int, GitHubAuthSession) async throws -> PrivateMemorySyncResponse
    static var live: Self { Self { request, cap, auth in try await PrivateMemorySyncURLTransport().send(request, cap: cap, auth: auth) } }
}

private final class PrivateMemorySyncURLTransport: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust { completionHandler(.performDefaultHandling, nil) }
        else { completionHandler(.cancelAuthenticationChallenge, nil) }
    }
    func send(_ request: URLRequest, cap: Int, auth: GitHubAuthSession) async throws -> PrivateMemorySyncResponse {
        guard let url = request.url, (1...(PrivateMemorySyncPolicy.maximumDocumentBytes + 58)).contains(cap) else { throw PrivateMemorySyncFailure.invalid }
        try GitHubRequestPolicy.validate(url)
        let session = URLSession(configuration: GitHubRequestPolicy.configuration(), delegate: self, delegateQueue: nil)
        var registration: UUID?
        defer { session.invalidateAndCancel(); if let registration { auth.unregister(registration) } }
        do {
            registration = try auth.register(session)
            let (bytes, response) = try await session.bytes(for: request)
            try Task.checkCancellation(); _ = try auth.authorizationValue()
            guard let response = response as? HTTPURLResponse, response.url == url else { throw PrivateMemorySyncFailure.invalid }
            if response.statusCode == 401 { auth.revoke(); throw PrivateMemorySyncFailure.authentication }
            if response.statusCode == 429 || (response.statusCode == 403 && (response.value(forHTTPHeaderField: "X-RateLimit-Remaining") == "0" || response.value(forHTTPHeaderField: "Retry-After") != nil)) {
                throw PrivateMemorySyncCooldown(until: PrivateMemorySyncCooldown.deadline(
                    retryAfter: response.value(forHTTPHeaderField: "Retry-After"), reset: response.value(forHTTPHeaderField: "X-RateLimit-Reset")))
            }
            // Never read an error body, which may echo user data or a request credential.
            guard [200, 201].contains(response.statusCode) else { return .init(status: response.statusCode, data: Data()) }
            guard response.expectedContentLength <= Int64(cap) else { throw PrivateMemorySyncFailure.capacity }
            var data = Data()
            for try await byte in bytes { try Task.checkCancellation(); guard data.count < cap else { throw PrivateMemorySyncFailure.capacity }; data.append(byte) }
            return .init(status: response.statusCode, data: data)
        } catch is CancellationError { throw CancellationError() }
        catch let error as PrivateMemorySyncFailure { throw error }
        catch let error as PrivateMemorySyncCooldown { throw error }
        catch { throw PrivateMemorySyncFailure.unavailable }
    }
}

struct PrivateMemorySyncClient: Sendable {
    let auth: GitHubAuthSession
    let transport: PrivateMemorySyncTransport
    init(auth: GitHubAuthSession, transport: PrivateMemorySyncTransport = .live) { self.auth = auth; self.transport = transport }
    private func request(_ components: [String], query: [URLQueryItem] = [], body: Data? = nil, cap: Int = 64_000, raw: Bool = false, object: Bool = false) async throws -> PrivateMemorySyncResponse {
        var request = try GitHubRequestPolicy.request(url: GitHubRoute.url(components, query: query), authentication: auth)
        if raw { request.setValue("application/vnd.github.raw+json", forHTTPHeaderField: "Accept") }
        if object { request.setValue("application/vnd.github.object+json", forHTTPHeaderField: "Accept") }
        if let body { request.httpMethod = "PUT"; request.httpBody = body; request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let response = try await transport.send(request, cap, auth)
        if response.status >= 500 { throw PrivateMemorySyncFailure.unavailable }
        if response.status == 401 { auth.revoke(); throw PrivateMemorySyncFailure.authentication }
        if response.status == 403 { throw PrivateMemorySyncFailure.privateRepository }
        if response.status == 429 { throw PrivateMemorySyncCooldown(until: Date().addingTimeInterval(300)) }
        return response
    }
    func verifySetup(repository: String, includePrivateWorkspaces: Bool) async throws -> PrivateMemorySyncConfiguration {
        let (owner, name) = try GitHubRoute.repository(repository)
        guard repository.lowercased() != "r347h4ck3r/ghostai" else { throw PrivateMemorySyncFailure.privateRepository }
        let userResponse = try await request(["user"])
        guard userResponse.status == 200 else { throw PrivateMemorySyncFailure.authentication }
        let user = try JSONDecoder().decode(GitHubAccount.self, from: userResponse.data)
        let response = try await request(["repos", owner, name])
        guard response.status == 200 else { throw PrivateMemorySyncFailure.privateRepository }
        let repo = try JSONDecoder().decode(PrivateMemorySyncRepository.self, from: response.data)
        let configuration = PrivateMemorySyncConfiguration(repository: repo.full_name, repositoryID: repo.id,
            accountID: user.id, branch: repo.default_branch, includePrivateWorkspaces: includePrivateWorkspaces)
        guard repo.full_name.caseInsensitiveCompare(repository) == .orderedSame else { throw PrivateMemorySyncFailure.repositoryChanged }
        _ = try configuration.validated(); try repo.validate(configuration); return configuration
    }
    func verify(_ configuration: PrivateMemorySyncConfiguration) async throws {
        let (owner, name) = try GitHubRoute.repository(configuration.repository)
        let response = try await request(["repos", owner, name])
        guard response.status == 200 else { throw PrivateMemorySyncFailure.repositoryChanged }
        try JSONDecoder().decode(PrivateMemorySyncRepository.self, from: response.data).validate(configuration)
    }
    struct Remote: Sendable { let encrypted: Data?; let sha: String? }
    func fetch(_ configuration: PrivateMemorySyncConfiguration) async throws -> Remote {
        try await verify(configuration)
        let (owner, name) = try GitHubRoute.repository(configuration.repository)
        let response = try await request(["repos", owner, name, "contents"] + PrivateMemorySyncPolicy.path,
            query: [.init(name: "ref", value: configuration.branch)], cap: 1_500_000, object: true)
        // Only file absence after positive repository verification means a new vault.
        if response.status == 404 { return Remote(encrypted: nil, sha: nil) }
        guard response.status == 200 else { throw PrivateMemorySyncFailure.invalid }
        struct File: Decodable { let type: String; let path: String; let sha: String; let size: Int; let encoding: String?; let content: String?; let target: String?; let submodule_git_url: String? }
        let file = try JSONDecoder().decode(File.self, from: response.data)
        guard file.type == "file", file.path == PrivateMemorySyncPolicy.path.joined(separator: "/"),
              file.target == nil, file.submodule_git_url == nil, RepositoryToolPolicy.isObjectSHA(file.sha),
              (58...(PrivateMemorySyncPolicy.maximumDocumentBytes + 58)).contains(file.size) else { throw PrivateMemorySyncFailure.invalid }
        let encrypted: Data
        if file.encoding == "base64", let content = file.content,
           let decoded = Data(base64Encoded: content, options: .ignoreUnknownCharacters) {
            encrypted = decoded
        } else if file.encoding == "none" || file.content == nil {
            // Never follow a download_url or mutable branch between metadata and content.
            // The Git blob ID pins the raw read; the authenticated result is checked again.
            let blob = try await request(["repos", owner, name, "git", "blobs", file.sha],
                cap: PrivateMemorySyncPolicy.maximumDocumentBytes + 58, raw: true)
            guard blob.status == 200 else { throw PrivateMemorySyncFailure.invalid }
            encrypted = blob.data
        } else { throw PrivateMemorySyncFailure.invalid }
        guard encrypted.count == file.size else { throw PrivateMemorySyncFailure.invalid }
        let gitBlob = Data("blob \(encrypted.count)\0".utf8) + encrypted
        let sha = Insecure.SHA1.hash(data: gitBlob).map { String(format: "%02x", $0) }.joined()
        guard sha == file.sha.lowercased() else { throw PrivateMemorySyncFailure.invalid }
        return Remote(encrypted: encrypted, sha: file.sha)
    }
    /// true = committed; false = CAS conflict, re-fetch before any retry. An uncertain
    /// transport outcome is never blindly repeated: the next cycle reads the current file.
    func put(_ encrypted: Data, configuration: PrivateMemorySyncConfiguration, expectedSHA: String?) async throws -> Bool {
        guard encrypted.count <= PrivateMemorySyncPolicy.maximumDocumentBytes + 58,
              expectedSHA == nil || RepositoryToolPolicy.isObjectSHA(expectedSHA!) else { throw PrivateMemorySyncFailure.invalid }
        try await verify(configuration) // Refuse visibility/identity changes immediately before write.
        let (owner, name) = try GitHubRoute.repository(configuration.repository)
        struct Body: Encodable { let message: String; let content: String; let branch: String; let sha: String? }
        let body = try JSONEncoder().encode(Body(message: "Update encrypted Veyra memory", content: encrypted.base64EncodedString(), branch: configuration.branch, sha: expectedSHA))
        let response = try await request(["repos", owner, name, "contents"] + PrivateMemorySyncPolicy.path, body: body)
        if response.status == 409 || response.status == 422 { return false }
        guard response.status == 200 || response.status == 201 else { throw PrivateMemorySyncFailure.invalid }
        struct Result: Decodable { struct Content: Decodable { let sha: String; let path: String }; let content: Content }
        let result = try JSONDecoder().decode(Result.self, from: response.data)
        guard RepositoryToolPolicy.isObjectSHA(result.content.sha), result.content.path == PrivateMemorySyncPolicy.path.joined(separator: "/") else { throw PrivateMemorySyncFailure.invalid }
        return true
    }
}
