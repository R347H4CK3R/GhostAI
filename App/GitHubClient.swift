import Foundation

struct Repository: Decodable, Identifiable, Hashable {
    var id: Int
    var full_name: String
    var default_branch: String
}
struct RepoFile: Decodable, Identifiable, Hashable {
    var name: String
    var path: String
    var type: String
    var sha: String
    var size: Int?
    var id: String { path }
}
private struct CommitRef: Decodable { let sha: String }
private struct FilePayload: Decodable { let content: String?; let encoding: String?; let size: Int }

// All requests are anonymous and read-only. Authentication is deliberately not implied
// by the GitHub connection in the assistant that generated this source project.
final class GitHubClient: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil) // Do not follow redirects to arbitrary hosts.
    }
    func read<T: Decodable>(_ url: URL, as: T.Type) async throws -> T {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 25
        let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw AppFailure.message("GitHub returned HTTP \(code). Public repositories only; 403/429 may mean the anonymous rate limit was reached.")
        }
        guard response.expectedContentLength <= 2_000_000 else { throw AppFailure.message("GitHub response is too large.") }
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < 2_000_000 else { throw AppFailure.message("GitHub response exceeds the size budget.") }
            data.append(byte)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
    func repositories(owner: String, page: Int) async throws -> [Repository] {
        _ = try GitHubRoute.repository(owner + "/placeholder")
        return try await read(GitHubRoute.url(["users", owner, "repos"], query: [.init(name: "per_page", value: "50"), .init(name: "page", value: String(page)), .init(name: "sort", value: "updated")]), as: [Repository].self)
    }
    func commit(_ repository: Repository) async throws -> String {
        let (owner, name) = try GitHubRoute.repository(repository.full_name)
        // Default branch names can contain slashes. GitHub accepts a ref query on commits.
        struct Commit: Decodable { var sha: String }
        let commits = try await read(GitHubRoute.url(["repos", owner, name, "commits"], query: [.init(name: "sha", value: repository.default_branch), .init(name: "per_page", value: "1")]), as: [Commit].self)
        guard let sha = commits.first?.sha else { throw AppFailure.message("Repository has no commits.") }
        return sha
    }
    private func contentURL(repo: String, path: String, ref: String) throws -> URL {
        let (owner, name) = try GitHubRoute.repository(repo)
        let segments = path.isEmpty ? [] : path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        return try GitHubRoute.url(["repos", owner, name, "contents"] + segments, query: [.init(name: "ref", value: ref)])
    }
    func directory(repo: String, path: String, ref: String) async throws -> [RepoFile] {
        try await read(contentURL(repo: repo, path: path, ref: ref), as: [RepoFile].self)
    }
    func text(repo: String, file: RepoFile, ref: String) async throws -> String {
        guard file.type == "file", (file.size ?? 0) <= 60_000 else { throw AppFailure.message("Only text files up to 60 KB can be opened.") }
        let result = try await read(contentURL(repo: repo, path: file.path, ref: ref), as: FilePayload.self)
        guard result.size <= 60_000, result.encoding == "base64", let encoded = result.content,
              let data = Data(base64Encoded: encoded, options: .ignoreUnknownCharacters), data.count <= 60_000,
              !data.contains(0), let text = String(data: data, encoding: .utf8) else {
            throw AppFailure.message("File is binary, unavailable, or exceeds the text budget.")
        }
        return text
    }
}
