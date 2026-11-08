import Foundation

struct Repository: Decodable, Identifiable, Hashable, Sendable {
    var id: Int
    var full_name: String
    var default_branch: String
}
struct RepoFile: Decodable, Identifiable, Hashable, Sendable {
    var name: String
    var path: String
    var type: String
    var sha: String
    var size: Int?
    var target: String? = nil
    var submodule_git_url: String? = nil
    var id: String { path }
    var isRegularFile: Bool { type == "file" && target == nil && submodule_git_url == nil }
}
private struct FilePayload: Decodable {
    let content: String?; let encoding: String?; let size: Int
    let type: String; let target: String?; let submodule_git_url: String?
}

enum GitHubRequestPolicy {
    static func validate(_ url: URL) throws {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme == "https", parts.host == "api.github.com",
              parts.port == nil || parts.port == 443,
              parts.user == nil, parts.password == nil, parts.fragment == nil else {
            throw GitHubAccessError.untrustedDestination
        }
    }
    static func request(url: URL, authentication: GitHubAuthSession?) throws -> URLRequest {
        try validate(url) // Validate destination before reading or attaching any credential.
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 25)
        request.httpMethod = "GET"
        request.httpShouldHandleCookies = false
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        if let authentication { request.setValue(try authentication.authorizationValue(), forHTTPHeaderField: "Authorization") }
        return request
    }
    static func configuration() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 25
        config.timeoutIntervalForResource = 45
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCredentialStorage = nil
        config.protocolClasses = []
        // Override inherited HTTP/SOCKS/PAC proxies. This cannot secure a compromised device or host.
        config.connectionProxyDictionary = ["HTTPEnable": 0, "HTTPSEnable": 0, "SOCKSEnable": 0,
                                           "ProxyAutoConfigEnable": 0, "ProxyAutoDiscoveryEnable": 0]
        return config
    }
    static func safeError(_ error: Error, authenticated: Bool) -> Error {
        if error is CancellationError { return CancellationError() }
        if let known = error as? GitHubAccessError { return known }
        if let known = error as? AppFailure { return known }
        // Never surface URLSession/decoder errors or HTTP response bodies; they may echo request details.
        return GitHubAccessError.transport
    }
}

/// Each client is permanently public or bound to one revocable authenticated session.
final class GitHubClient: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let authentication: GitHubAuthSession?
    init(authentication: GitHubAuthSession? = nil) { self.authentication = authentication; super.init() }

    func request(for url: URL) throws -> URLRequest { try GitHubRequestPolicy.request(url: url, authentication: authentication) }
    func validateSession() throws { if let authentication { _ = try authentication.authorizationValue() } }
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust {
            completionHandler(.performDefaultHandling, nil)
        } else { completionHandler(.cancelAuthenticationChallenge, nil) }
    }

    private func read<T: Decodable>(_ url: URL, as: T.Type, maximumResponseBytes: Int = 2_000_000) async throws -> T {
        try await readResponse(url, as: T.self, maximumResponseBytes: maximumResponseBytes).value
    }

    private func readResponse<T: Decodable>(_ url: URL, as: T.Type, maximumResponseBytes: Int) async throws -> (value: T, responseBytes: Int) {
        guard maximumResponseBytes > 0, maximumResponseBytes <= 2_000_000 else { throw GitHubAccessError.oversized }
        let request = try request(for: url)
        let session = URLSession(configuration: GitHubRequestPolicy.configuration(), delegate: self, delegateQueue: nil)
        var transportID: UUID?
        defer {
            session.invalidateAndCancel()
            if let transportID { authentication?.unregister(transportID) }
        }
        do {
            transportID = try authentication?.register(session)
            let (bytes, response) = try await session.bytes(for: request)
            try validateSession()
            guard let http = response as? HTTPURLResponse, let finalURL = http.url else { throw GitHubAccessError.invalidResponse }
            try GitHubRequestPolicy.validate(finalURL)
            guard http.statusCode == 200 else {
                switch http.statusCode {
                case 401: throw AppFailure.message("GitHub rejected this token. Sign out, check its expiration and connect again.")
                case 403, 429: throw AppFailure.message("GitHub denied this read or its rate limit was reached. Check repository permissions and try later.")
                case 404: throw AppFailure.message("GitHub repository or file is unavailable to this connection.")
                default: throw AppFailure.message("GitHub returned HTTP \(http.statusCode). No automatic retry was made.")
                }
            }
            guard response.expectedContentLength <= Int64(maximumResponseBytes) else { throw GitHubAccessError.oversized }
            var data = Data()
            for try await byte in bytes {
                try Task.checkCancellation()
                guard data.count < maximumResponseBytes else { throw GitHubAccessError.oversized }
                data.append(byte)
            }
            try validateSession()
            return (try JSONDecoder().decode(T.self, from: data), data.count)
        } catch { throw GitHubRequestPolicy.safeError(error, authenticated: authentication != nil) }
    }

    func account() async throws -> GitHubAccount {
        guard authentication != nil else { throw GitHubAccessError.expired }
        return try await read(GitHubRoute.url(["user"]), as: GitHubAccount.self, maximumResponseBytes: 64_000)
    }
    static func repositoryListURL(owner: String?, page: Int) throws -> URL {
        guard (1...1000).contains(page) else { throw AppFailure.message("Invalid repository page.") }
        var query: [URLQueryItem] = [.init(name: "per_page", value: "50"), .init(name: "page", value: String(page)), .init(name: "sort", value: "updated")]
        if let owner {
            _ = try GitHubRoute.repository(owner + "/placeholder")
            return try GitHubRoute.url(["users", owner, "repos"], query: query)
        }
        query.append(.init(name: "visibility", value: "all"))
        return try GitHubRoute.url(["user", "repos"], query: query)
    }
    func repositories(owner: String, page: Int) async throws -> [Repository] {
        guard authentication == nil else { throw AppFailure.message("Use this account’s repository list or sign out for public mode.") }
        return try await read(Self.repositoryListURL(owner: owner, page: page), as: [Repository].self)
    }
    func repositories(page: Int) async throws -> [Repository] {
        guard authentication != nil else { throw GitHubAccessError.expired }
        return try await read(Self.repositoryListURL(owner: nil, page: page), as: [Repository].self)
    }
    func commit(_ repository: Repository) async throws -> String {
        let (owner, name) = try GitHubRoute.repository(repository.full_name)
        struct Commit: Decodable { var sha: String }
        let commits = try await read(GitHubRoute.url(["repos", owner, name, "commits"], query: [.init(name: "sha", value: repository.default_branch), .init(name: "per_page", value: "1")]), as: [Commit].self, maximumResponseBytes: 512_000)
        guard let sha = commits.first?.sha else {
            throw AppFailure.message("Repository has no valid commit.")
        }
        try Self.validateObjectSHA(sha)
        return sha
    }
    private func contentURL(repo: String, path: String, ref: String) throws -> URL {
        let (owner, name) = try GitHubRoute.repository(repo)
        let segments = path.isEmpty ? [] : path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        return try GitHubRoute.url(["repos", owner, name, "contents"] + segments, query: [.init(name: "ref", value: ref)])
    }
    func directory(repo: String, path: String, ref: String, maximumResponseBytes: Int = 2_000_000) async throws -> [RepoFile] {
        try await read(contentURL(repo: repo, path: path, ref: ref), as: [RepoFile].self, maximumResponseBytes: maximumResponseBytes)
    }
    func text(repo: String, file: RepoFile, ref: String, maximumResponseBytes: Int = 120_000) async throws -> String {
        guard file.isRegularFile, (file.size ?? 0) <= 60_000 else { throw AppFailure.message("Only regular text files up to 60 KB can be opened.") }
        let result = try await read(contentURL(repo: repo, path: file.path, ref: ref), as: FilePayload.self, maximumResponseBytes: maximumResponseBytes)
        guard result.type == "file", result.target == nil, result.submodule_git_url == nil,
              result.size <= 60_000, result.encoding == "base64", let encoded = result.content,
              let data = Data(base64Encoded: encoded, options: .ignoreUnknownCharacters), data.count <= 60_000,
              !data.contains(0), let text = String(data: data, encoding: .utf8) else {
            throw AppFailure.message("File is binary, unavailable, or exceeds the text budget.")
        }
        return text
    }

    // Model tools use immutable Git tree/blob objects, not the Contents API's symlink dereferencing.
    func toolTree(repo: String, sha: String, maximumResponseBytes: Int) async throws -> (files: [RepoFile], responseBytes: Int) {
        let (owner, name) = try GitHubRoute.repository(repo)
        try Self.validateObjectSHA(sha)
        struct Tree: Decodable {
            struct Entry: Decodable { let path: String; let mode: String; let type: String; let sha: String; let size: Int? }
            let tree: [Entry]
            let truncated: Bool
        }
        let result = try await readResponse(GitHubRoute.url(["repos", owner, name, "git", "trees", sha]), as: Tree.self, maximumResponseBytes: maximumResponseBytes)
        guard !result.value.truncated else { throw AppFailure.message("GitHub tree is truncated. Choose a smaller directory.") }
        let files = try result.value.tree.map { entry -> RepoFile in
            guard !entry.path.isEmpty, !entry.path.contains("/"), ![".", ".."].contains(entry.path) else { throw GitHubAccessError.invalidResponse }
            try Self.validateObjectSHA(entry.sha)
            let kind: String
            switch (entry.mode, entry.type) {
            case ("040000", "tree"): kind = "dir"
            case ("100644", "blob"), ("100755", "blob"): kind = "file"
            case ("120000", "blob"): kind = "symlink"
            case ("160000", "commit"): kind = "submodule"
            default: kind = "unsupported"
            }
            return RepoFile(name: entry.path, path: entry.path, type: kind, sha: entry.sha, size: entry.size)
        }
        return (files, result.responseBytes)
    }

    func toolText(repo: String, file: RepoFile, maximumResponseBytes: Int) async throws -> (text: String, responseBytes: Int) {
        let (owner, name) = try GitHubRoute.repository(repo)
        guard file.isRegularFile, let size = file.size, (0...60_000).contains(size) else {
            throw AppFailure.message("Only regular text blobs up to 60 KB can be read.")
        }
        try Self.validateObjectSHA(file.sha)
        struct Blob: Decodable { let sha: String; let content: String; let encoding: String; let size: Int }
        let result = try await readResponse(GitHubRoute.url(["repos", owner, name, "git", "blobs", file.sha]), as: Blob.self, maximumResponseBytes: maximumResponseBytes)
        guard result.value.sha == file.sha, result.value.size == size, result.value.encoding == "base64",
              let data = Data(base64Encoded: result.value.content, options: .ignoreUnknownCharacters),
              data.count == size, !data.contains(0), let text = String(data: data, encoding: .utf8) else {
            throw AppFailure.message("Blob is binary, unavailable, or inconsistent with its pinned tree.")
        }
        return (text, result.responseBytes)
    }

    private static func validateObjectSHA(_ sha: String) throws {
        guard sha.utf8.count == 40, sha.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }) else { throw GitHubAccessError.invalidResponse }
    }

}
