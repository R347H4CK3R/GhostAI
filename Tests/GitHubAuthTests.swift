import XCTest
@testable import AsterionVeyra

final class GitHubAuthTests: XCTestCase {
    private let syntheticToken = "github_pat_SYNTHETIC_NOT_A_REAL_TOKEN_123456"

    func testAuthenticatedRequestUsesOnlyHeaderAndGET() throws {
        let session = try GitHubAuthSession(token: syntheticToken)
        let url = URL(string: "https://api.github.com/user/repos?per_page=50&page=1")!
        let request = try GitHubRequestPolicy.request(url: url, authentication: session)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer " + syntheticToken)
        XCTAssertFalse(request.url!.absoluteString.contains(syntheticToken))
        XCTAssertNil(request.httpBody)
        XCTAssertFalse(request.httpShouldHandleCookies)
    }

    func testPublicRequestCannotAcquireStoredCredentials() throws {
        let request = try GitHubRequestPolicy.request(url: URL(string: "https://api.github.com/users/example/repos")!, authentication: nil)
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
    }

    func testRejectsOtherHostsSchemesPortsAndEmbeddedCredentials() throws {
        let session = try GitHubAuthSession(token: syntheticToken)
        for value in ["http://api.github.com/user", "https://github.com/user", "https://api.github.com.evil.example/user",
                      "https://api.github.com:444/user", "https://user:password@api.github.com/user", "https://api.github.com/user#fragment"] {
            XCTAssertThrowsError(try GitHubRequestPolicy.request(url: URL(string: value)!, authentication: session), value)
        }
    }

    func testRevocationDoesNotFallBackToAnonymous() throws {
        let session = try GitHubAuthSession(token: syntheticToken)
        let client = GitHubClient(authentication: session)
        session.revoke()
        XCTAssertThrowsError(try client.request(for: URL(string: "https://api.github.com/user/repos")!))
    }

    func testExpiredSessionCannotCreateRequest() throws {
        let session = try GitHubAuthSession(token: syntheticToken, expiresAt: Date(timeIntervalSince1970: 1))
        XCTAssertThrowsError(try GitHubRequestPolicy.request(url: URL(string: "https://api.github.com/user")!, authentication: session))
    }

    func testTokenValidationRejectsHeaderInjectionAndClassicTokens() {
        for token in ["", "ghp_SYNTHETIC_NOT_A_REAL_TOKEN", syntheticToken + "\r\nX-Evil: yes", syntheticToken + "\n", "github_pat_ spaces", String(repeating: "a", count: 1000)] {
            XCTAssertThrowsError(try GitHubAuthSession(token: token))
        }
    }

    func testDescriptionsAndErrorsNeverIncludeToken() throws {
        let session = try GitHubAuthSession(token: syntheticToken)
        XCTAssertFalse(String(describing: session).contains(syntheticToken))
        XCTAssertFalse(String(reflecting: session).contains(syntheticToken))
        var dumpText = ""
        dump(session, to: &dumpText)
        XCTAssertFalse(dumpText.contains(syntheticToken))
        let unsafeError = NSError(domain: NSURLErrorDomain, code: -1011, userInfo: [NSLocalizedDescriptionKey: syntheticToken])
        XCTAssertFalse(GitHubRequestPolicy.safeError(unsafeError, authenticated: true).localizedDescription.contains(syntheticToken))
    }

    func testPrivateAndPublicRepositoryRoutesRemainSeparate() throws {
        XCTAssertEqual(try GitHubClient.repositoryListURL(owner: nil, page: 2).path, "/user/repos")
        XCTAssertEqual(try GitHubClient.repositoryListURL(owner: "example", page: 1).path, "/users/example/repos")
        XCTAssertThrowsError(try GitHubClient.repositoryListURL(owner: nil, page: 0))
    }

    func testConfigurationHasNoCredentialCookieOrDiskCacheAndDisablesProxies() {
        let config = GitHubRequestPolicy.configuration()
        XCTAssertNil(config.urlCache)
        XCTAssertNil(config.urlCredentialStorage)
        XCTAssertNil(config.httpCookieStorage)
        XCTAssertFalse(config.httpShouldSetCookies)
        XCTAssertEqual(config.requestCachePolicy, .reloadIgnoringLocalCacheData)
        XCTAssertEqual(config.connectionProxyDictionary?["HTTPSEnable"] as? Int, 0)
        XCTAssertEqual(config.connectionProxyDictionary?["ProxyAutoConfigEnable"] as? Int, 0)
    }

    func testRedirectIsRejectedEvenForSameHost() {
        let client = GitHubClient()
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let url = URL(string: "https://api.github.com/user")!
        let task = session.dataTask(with: url)
        client.urlSession(session, task: task, willPerformHTTPRedirection: HTTPURLResponse(url: url, statusCode: 302, httpVersion: nil, headerFields: nil)!, newRequest: URLRequest(url: url)) { request in
            XCTAssertNil(request)
        }
        task.cancel()
    }

    func testToolRejectsSymlinkAndSubmoduleBeforeFetching() async {
        let client = GitHubClient()
        for kind in ["symlink", "submodule"] {
            let file = RepoFile(name: "entry", path: "entry", type: kind, sha: String(repeating: "a", count: 40), size: 10)
            do {
                _ = try await client.toolText(repo: "owner/repo", file: file, maximumResponseBytes: 1000)
                XCTFail("Non-regular objects must not be fetched")
            } catch {
                XCTAssertTrue(error is AppFailure)
            }
        }
    }

    func testTreeRejectsMutableRefsAndInvalidSHAsBeforeFetching() async {
        let client = GitHubClient()
        for sha in ["main", String(repeating: "a", count: 40) + "\n", "../main"] {
            do {
                _ = try await client.toolTree(repo: "owner/repo", sha: sha, maximumResponseBytes: 1000)
                XCTFail("Only immutable object SHAs are allowed")
            } catch {
                guard case GitHubAccessError.invalidResponse = error else { XCTFail("Wrong validation error"); continue }
            }
        }
    }

    @MainActor func testMemoryOnlyConnectionNeverSavesTokenAndSignOutRevokesClient() throws {
        let vault = TestGitHubVault()
        let store = GitHubCredentialStore(vault: vault)
        let session = try store.begin(token: syntheticToken, directInstallationConfirmed: true)
        try store.complete(session: session, account: GitHubAccount(id: 7, login: "example"), rememberOnDevice: false)
        XCTAssertNil(vault.stored)
        let client = try XCTUnwrap(store.connection?.client)
        try store.signOut()
        XCTAssertNil(store.connection)
        XCTAssertThrowsError(try client.request(for: URL(string: "https://api.github.com/user")!))
    }

    @MainActor func testKeychainRequiresExplicitOptInAndNeverLoadsAutomatically() throws {
        let vault = TestGitHubVault()
        let store = GitHubCredentialStore(vault: vault)
        XCTAssertEqual(vault.reads, 0)
        XCTAssertThrowsError(try store.begin(token: syntheticToken, directInstallationConfirmed: false))
        let session = try store.begin(token: syntheticToken, directInstallationConfirmed: true)
        try store.complete(session: session, account: GitHubAccount(id: 7, login: "example"), rememberOnDevice: true)
        XCTAssertEqual(vault.stored, syntheticToken)
        store.endSession()
        XCTAssertNil(store.connection)
        XCTAssertNotNil(vault.stored)
        XCTAssertEqual(vault.reads, 0)
        try store.signOut()
        XCTAssertNil(vault.stored)
    }

    @MainActor func testCancelledConnectionCannotReappearAfterLateVerification() throws {
        let store = GitHubCredentialStore(vault: TestGitHubVault())
        let old = try store.begin(token: syntheticToken, directInstallationConfirmed: true)
        store.endSession()
        XCTAssertThrowsError(try store.complete(session: old, account: GitHubAccount(id: 1, login: "old"), rememberOnDevice: false))
        XCTAssertNil(store.connection)
    }

    @MainActor func testDeleteFailureStillRevokesMemoryCredential() throws {
        let vault = TestGitHubVault()
        let store = GitHubCredentialStore(vault: vault)
        let session = try store.begin(token: syntheticToken, directInstallationConfirmed: true)
        try store.complete(session: session, account: GitHubAccount(id: 7, login: "example"), rememberOnDevice: true)
        vault.failDelete = true
        XCTAssertThrowsError(try store.signOut())
        XCTAssertNil(store.connection)
        XCTAssertThrowsError(try session.authorizationValue())
    }

    @MainActor func testSignOutNotifiesOwnerAfterRevocationWithoutAViewObserver() throws {
        var notifications = 0
        var originalClient: GitHubClient?
        weak var observedStore: GitHubCredentialStore?
        let store = GitHubCredentialStore(vault: TestGitHubVault(), onSessionEnded: {
            notifications += 1
            XCTAssertNil(observedStore?.connection)
            XCTAssertThrowsError(try originalClient?.validateSession())
        })
        observedStore = store
        let session = try store.begin(token: syntheticToken, directInstallationConfirmed: true)
        try store.complete(session: session, account: GitHubAccount(id: 7, login: "example"), rememberOnDevice: false)
        originalClient = store.connection?.client
        try store.signOut()
        XCTAssertEqual(notifications, 1)
        store.endSession()
        XCTAssertEqual(notifications, 1, "An already ended session must not notify again")
    }

    @MainActor func testExpiryNotifiesOwnerWithoutAViewObserver() throws {
        var notifications = 0
        let store = GitHubCredentialStore(vault: TestGitHubVault(), onSessionEnded: { notifications += 1 })
        let session = try store.begin(token: syntheticToken, directInstallationConfirmed: true)
        try store.complete(session: session, account: GitHubAccount(id: 7, login: "example"), rememberOnDevice: false)
        store.endExpiredSession(now: session.expiresAt.addingTimeInterval(-1))
        XCTAssertEqual(notifications, 0)
        store.endExpiredSession(now: session.expiresAt)
        XCTAssertEqual(notifications, 1)
        XCTAssertNil(store.connection)
        XCTAssertThrowsError(try session.authorizationValue())
    }

    @MainActor func testCancelledPendingConnectionNotifiesOwnerWithoutCredentialPayload() throws {
        var notifications = 0
        let store = GitHubCredentialStore(vault: TestGitHubVault(), onSessionEnded: { notifications += 1 })
        let session = try store.begin(token: syntheticToken, directInstallationConfirmed: true)
        store.endSession()
        XCTAssertEqual(notifications, 1)
        XCTAssertThrowsError(try session.authorizationValue())
        // Callback has no payload, so credential/account/HTTP data cannot be forwarded through it.
        XCTAssertNil(store.connection)
    }

    func testAuthenticatedWorkspacesAreScopedToStableAccountID() throws {
        let session = try GitHubAuthSession(token: syntheticToken)
        let first = GitHubConnection(session: session, account: GitHubAccount(id: 7, login: "old-name"))
        let second = GitHubConnection(session: session, account: GitHubAccount(id: 8, login: "other"))
        XCTAssertEqual(first.workspace(for: "owner/repo"), "GitHub account 7: owner/repo")
        XCTAssertNotEqual(first.workspace(for: "owner/repo"), second.workspace(for: "owner/repo"))
    }
}

// Only the external Keychain boundary is replaced. Store/session logic is real.
private final class TestGitHubVault: GitHubCredentialVault {
    var stored: String?
    var reads = 0
    var failDelete = false
    func load() throws -> String? { reads += 1; return stored }
    func save(_ token: String) throws { stored = token }
    func delete() throws {
        if failDelete { throw GitHubAccessError.keychain }
        stored = nil
    }
}
