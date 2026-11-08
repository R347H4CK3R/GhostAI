import Foundation
import Security
import Darwin

// Dedicated to this explicitly enabled capability, never the read-only GitHub credential.
// No credentials, passphrases, source bodies or ciphertext appear in descriptions/errors.
struct PrivateMemorySyncSecrets: Codable, Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    let token: String
    let passphrase: String
    var description: String { "PrivateMemorySyncSecrets(redacted)" }
    var debugDescription: String { description }
    var customMirror: Mirror { Mirror(self, children: ["credentials": "redacted"]) }
}
protocol PrivateMemorySyncVault {
    func load() throws -> PrivateMemorySyncSecrets?
    func save(_ value: PrivateMemorySyncSecrets) throws
    func delete() throws
}
struct PrivateMemorySyncKeychain: PrivateMemorySyncVault {
    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "dev.asterionveyra.private-memory-sync.v1",
         kSecAttrAccount as String: "explicit-private-repository-sync",
         kSecAttrSynchronizable as String: false]
    }
    func load() throws -> PrivateMemorySyncSecrets? {
        var request = query; request[kSecReturnData as String] = true; request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data,
              let value = try? JSONDecoder().decode(PrivateMemorySyncSecrets.self, from: data) else { throw PrivateMemorySyncFailure.credentials }
        return value
    }
    func save(_ value: PrivateMemorySyncSecrets) throws {
        let data = try JSONEncoder().encode(value)
        let changes: [String: Any] = [kSecValueData as String: data,
                                    kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        let result = SecItemUpdate(query as CFDictionary, changes as CFDictionary)
        if result == errSecItemNotFound {
            var request = query; changes.forEach { request[$0.key] = $0.value }
            guard SecItemAdd(request as CFDictionary, nil) == errSecSuccess else { throw PrivateMemorySyncFailure.credentials }
        } else if result != errSecSuccess { throw PrivateMemorySyncFailure.credentials }
    }
    func delete() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw PrivateMemorySyncFailure.credentials }
    }
}

struct PrivateMemorySyncDisk: Sendable {
    let root: URL
    var configurationURL: URL { root.appendingPathComponent("configuration.json") }
    var journalURL: URL { root.appendingPathComponent("queue.veyra") }
    func loadConfiguration() throws -> PrivateMemorySyncConfiguration? {
        guard let data = try read(configurationURL, maximum: 16_384) else { return nil }
        do { return try JSONDecoder().decode(PrivateMemorySyncConfiguration.self, from: data).validated() }
        catch { throw PrivateMemorySyncFailure.storage }
    }
    func saveConfiguration(_ value: PrivateMemorySyncConfiguration) throws {
        _ = try value.validated()
        try write(JSONEncoder().encode(value), name: configurationURL.lastPathComponent)
    }
    func loadJournal(passphrase: String, repositoryID: Int) throws -> PrivateMemorySyncJournal? {
        guard let data = try read(journalURL, maximum: PrivateMemorySyncPolicy.maximumJournalBytes + 58) else { return nil }
        let raw = try EncryptedMemoryTransfer.decryptSyncPayload(data, passphrase: passphrase)
        let journal: PrivateMemorySyncJournal
        do { journal = try JSONDecoder().decode(PrivateMemorySyncJournal.self, from: raw) }
        catch { throw PrivateMemorySyncFailure.storage }
        try journal.validate(repositoryID: repositoryID); return journal
    }
    static func encryptJournal(_ journal: PrivateMemorySyncJournal, passphrase: String) throws -> Data {
        try journal.validate(repositoryID: journal.base.repositoryID)
        let raw = try PrivateMemorySyncPolicy.canonical(journal)
        guard raw.count <= PrivateMemorySyncPolicy.maximumJournalBytes else { throw PrivateMemorySyncFailure.capacity }
        return try EncryptedMemoryTransfer.encryptSyncPayload(raw, passphrase: passphrase)
    }
    func writeEncryptedJournal(_ encrypted: Data) throws {
        guard encrypted.count <= PrivateMemorySyncPolicy.maximumJournalBytes + 58 else { throw PrivateMemorySyncFailure.capacity }
        try write(encrypted, name: journalURL.lastPathComponent)
    }
    func saveJournal(_ journal: PrivateMemorySyncJournal, passphrase: String) throws {
        try writeEncryptedJournal(Self.encryptJournal(journal, passphrase: passphrase))
    }
    /// Walk every directory by descriptor. No attacker-controlled ancestor or leaf
    /// symlink can redirect reads/writes, even if a path is swapped during an operation.
    private func openDirectory(create: Bool) throws -> Int32? {
        guard root.isFileURL else { throw PrivateMemorySyncFailure.storage }
        var path = root.path
        // Apple's system-owned /var and /tmp aliases are not user-selected locations.
        // Normalize only those exact platform aliases; never resolve the supplied root.
        for (alias, target) in [("/var", "/private/var"), ("/tmp", "/private/tmp")] {
            if path.hasPrefix(alias + "/"), let storedTarget = try? FileManager.default.destinationOfSymbolicLink(atPath: alias),
               storedTarget == target || storedTarget == String(target.dropFirst()) {
                path = target + String(path.dropFirst(alias.count))
            }
        }
        let components = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard path.hasPrefix("/"), !components.contains(".."), !components.contains(".") else { throw PrivateMemorySyncFailure.storage }
        var descriptor = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw PrivateMemorySyncFailure.storage }
        for component in components {
            var next = component.withCString { Darwin.openat(descriptor, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
            if next < 0, errno == ENOENT, create {
                let made = component.withCString { Darwin.mkdirat(descriptor, $0, mode_t(0o700)) }
                guard made == 0 || errno == EEXIST else { Darwin.close(descriptor); throw PrivateMemorySyncFailure.storage }
                next = component.withCString { Darwin.openat(descriptor, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
            }
            if next < 0 {
                let missing = errno == ENOENT
                Darwin.close(descriptor)
                if missing && !create { return nil }
                throw PrivateMemorySyncFailure.storage
            }
            Darwin.close(descriptor); descriptor = next
        }
        return descriptor
    }
    private func read(_ url: URL, maximum: Int) throws -> Data? {
        guard let directory = try openDirectory(create: false) else { return nil }
        defer { Darwin.close(directory) }
        let descriptor = url.lastPathComponent.withCString { Darwin.openat(directory, $0, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC) }
        if descriptor < 0, errno == ENOENT { return nil }
        guard descriptor >= 0 else { throw PrivateMemorySyncFailure.storage }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              info.st_size >= 0, info.st_size <= off_t(maximum) else { throw PrivateMemorySyncFailure.storage }
        var data = Data()
        while data.count <= maximum {
            let part = try handle.read(upToCount: min(65_536, maximum + 1 - data.count)) ?? Data()
            if part.isEmpty { break }; data.append(part)
        }
        guard data.count <= maximum else { throw PrivateMemorySyncFailure.storage }; return data
    }
    private func write(_ data: Data, name: String) throws {
        guard let directory = try openDirectory(create: true) else { throw PrivateMemorySyncFailure.storage }
        defer { Darwin.close(directory) }
        var existing = stat()
        let inspected = name.withCString { fstatat(directory, $0, &existing, AT_SYMLINK_NOFOLLOW) }
        guard (inspected == 0 && (existing.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG)) || (inspected < 0 && errno == ENOENT) else { throw PrivateMemorySyncFailure.storage }
        let temporary = ".pending-" + UUID().uuidString
        let descriptor = temporary.withCString { Darwin.openat(directory, $0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600)) }
        guard descriptor >= 0 else { throw PrivateMemorySyncFailure.storage }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close(); _ = temporary.withCString { unlinkat(directory, $0, 0) } }
        try handle.write(contentsOf: data)
        guard fsync(descriptor) == 0 else { throw PrivateMemorySyncFailure.storage }
        let result = temporary.withCString { temporaryPath in
            name.withCString { finalPath in renameat(directory, temporaryPath, directory, finalPath) }
        }
        guard result == 0 else { throw PrivateMemorySyncFailure.storage }
        // The rename is already committed. Directory fsync support varies across Apple
        // filesystems; failure must not report that the completed atomic replace did not run.
        _ = fsync(directory)
    }
}
