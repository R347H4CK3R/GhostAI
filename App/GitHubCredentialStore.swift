import Foundation
import Combine
import Security

// These errors deliberately contain no URL, HTTP response body, OS error details or credential.
enum GitHubAccessError: LocalizedError {
    case invalidToken, expired, untrustedDestination, directInstallRequired, keychain, cancelled, transport, oversized, invalidResponse
    var errorDescription: String? {
        switch self {
        case .invalidToken: return "Enter a fine-grained GitHub token. Classic tokens and whitespace are not accepted."
        case .expired: return "This GitHub session ended. Connect again explicitly; no anonymous retry was made."
        case .untrustedDestination: return "Blocked a GitHub request outside the fixed HTTPS API destination."
        case .directInstallRequired: return "Private GitHub access is for a directly installed app only. Do not enter tokens in Strata or another host."
        case .keychain: return "The device Keychain operation failed. No credential details were recorded. If removing a saved token failed, retry Sign out and remove saved token."
        case .cancelled: return "The GitHub connection was cancelled."
        case .transport: return "GitHub could not be reached securely. Check your connection and retry."
        case .oversized: return "GitHub response exceeds the size budget."
        case .invalidResponse: return "GitHub returned an unsupported response."
        }
    }
}

/// Shared revocation is essential: old repository/model-tool clients must never adopt a new account.
/// Swift strings cannot guarantee memory zeroization. No token is encoded, logged or exposed in descriptions.
final class GitHubAuthSession: @unchecked Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    let id = UUID()
    let expiresAt: Date
    private let lock = NSLock()
    private var token: String?
    private var transports: [UUID: URLSession] = [:]
    var description: String { "GitHubAuthSession(redacted)" }
    var debugDescription: String { description }
    var customMirror: Mirror { Mirror(self, children: ["credential": "redacted"]) }

    init(token: String, expiresAt: Date = Date().addingTimeInterval(8 * 60 * 60)) throws {
        guard (25...255).contains(token.utf8.count),
              token.hasPrefix("github_pat_"),
              token.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 95 }) else {
            throw GitHubAccessError.invalidToken
        }
        self.token = token
        self.expiresAt = expiresAt
    }

    func authorizationValue() throws -> String {
        lock.lock()
        guard Date() < expiresAt, let token else {
            lock.unlock()
            revoke()
            throw GitHubAccessError.expired
        }
        let value = "Bearer " + token
        lock.unlock()
        return value
    }

    func register(_ transport: URLSession) throws -> UUID {
        lock.lock()
        guard token != nil, Date() < expiresAt else {
            lock.unlock()
            transport.invalidateAndCancel()
            revoke()
            throw GitHubAccessError.expired
        }
        let key = UUID()
        transports[key] = transport
        lock.unlock()
        return key
    }

    func unregister(_ key: UUID) { lock.lock(); transports.removeValue(forKey: key); lock.unlock() }
    func revoke() {
        lock.lock()
        token = nil
        let active = Array(transports.values)
        transports.removeAll()
        lock.unlock()
        active.forEach { $0.invalidateAndCancel() }
    }
    deinit { revoke() }
}

struct GitHubAccount: Decodable, Equatable, Sendable {
    let id: Int
    let login: String
}

struct GitHubConnection: Identifiable, Sendable {
    let session: GitHubAuthSession
    let account: GitHubAccount
    let client: GitHubClient
    var id: UUID { session.id }
    init(session: GitHubAuthSession, account: GitHubAccount) {
        self.session = session; self.account = account
        client = GitHubClient(authentication: session)
    }
    // Stable GitHub account IDs isolate authenticated context from public mode and other accounts.
    func workspace(for repository: String) -> String { "GitHub account \(account.id): \(repository)" }
}

protocol GitHubCredentialVault {
    func load() throws -> String?
    func save(_ token: String) throws
    func delete() throws
}

struct GitHubDeviceKeychain: GitHubCredentialVault {
    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "dev.asterionveyra.github.readonly.v1",
         kSecAttrAccount as String: "explicit-fine-grained-token",
         kSecAttrSynchronizable as String: false]
    }
    func load() throws -> String? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data,
              let token = String(data: data, encoding: .utf8) else { throw GitHubAccessError.keychain }
        return token
    }
    func save(_ token: String) throws {
        try delete()
        var request = query
        request[kSecValueData as String] = Data(token.utf8)
        request[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        guard SecItemAdd(request as CFDictionary, nil) == errSecSuccess else { throw GitHubAccessError.keychain }
    }
    func delete() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw GitHubAccessError.keychain }
    }
}

@MainActor final class GitHubCredentialStore: ObservableObject {
    @Published private(set) var connection: GitHubConnection?
    private let vault: GitHubCredentialVault
    private let onSessionEnded: (@MainActor () -> Void)?
    private var pending: GitHubAuthSession?
    private var pendingToken: String?
    private var expiryTask: Task<Void, Never>?
    init(vault: GitHubCredentialVault = GitHubDeviceKeychain(), onSessionEnded: (@MainActor () -> Void)? = nil) {
        self.vault = vault
        self.onSessionEnded = onSessionEnded
    }

    deinit {
        expiryTask?.cancel()
        pending?.revoke()
        connection?.session.revoke()
    }

    // Calling init never reads the Keychain. Restore requires a fresh visible user action.
    func begin(token: String, directInstallationConfirmed: Bool) throws -> GitHubAuthSession {
        guard directInstallationConfirmed else { throw GitHubAccessError.directInstallRequired }
        endSession()
        let session = try GitHubAuthSession(token: token)
        pending = session; pendingToken = token
        return session
    }
    func beginSaved(directInstallationConfirmed: Bool) throws -> GitHubAuthSession {
        guard directInstallationConfirmed else { throw GitHubAccessError.directInstallRequired }
        guard let token = try vault.load() else { throw AppFailure.message("No GitHub token is saved on this device.") }
        return try begin(token: token, directInstallationConfirmed: true)
    }
    func complete(session: GitHubAuthSession, account: GitHubAccount, rememberOnDevice: Bool) throws {
        guard pending?.id == session.id, let token = pendingToken else { throw GitHubAccessError.cancelled }
        _ = try session.authorizationValue()
        guard account.id > 0, !account.login.isEmpty, account.login.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 }) else {
            endSession(); throw GitHubAccessError.invalidResponse
        }
        do {
            if rememberOnDevice { try vault.save(token) }
            else { try vault.delete() } // Do not leave another account's saved credential behind.
        } catch { endSession(); throw GitHubAccessError.keychain }
        pending = nil; pendingToken = nil
        connection = GitHubConnection(session: session, account: account)
        expiryTask = Task { [weak self] in
            let remaining = max(0, session.expiresAt.timeIntervalSinceNow)
            try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
            guard !Task.isCancelled, self?.connection?.id == session.id else { return }
            self?.endSession()
        }
    }
    func endExpiredSession(now: Date = Date()) {
        if let connection, now >= connection.session.expiresAt { endSession() }
    }
    func endSession() {
        let hadSession = pending != nil || connection != nil
        expiryTask?.cancel(); expiryTask = nil
        pending?.revoke(); pending = nil; pendingToken = nil
        connection?.session.revoke(); connection = nil
        // Lifecycle notification is synchronous, has no data payload and does not depend on a visible view.
        if hadSession { onSessionEnded?() }
    }
    func signOut() throws {
        endSession() // Revoke even when Keychain deletion fails.
        try vault.delete()
    }
}
