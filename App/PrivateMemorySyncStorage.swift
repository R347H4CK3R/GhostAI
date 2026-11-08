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

// Closed diagnostics: retain only the operation, stage and numeric POSIX code.
// Never retain an underlying NSError, URL, repository, payload or credential.
struct PrivateMemorySyncStorageFailure: LocalizedError, Sendable {
    enum Operation: String, Sendable { case readConfiguration, writeConfiguration, readJournal, writeJournal }
    enum Stage: String, Sendable {
        case validatePath, openContainer, openDirectory, createDirectory, openFile, inspectFile
        case readFile, createTemporary, writeTemporary, syncTemporary, replaceFile, decode
    }
    let operation: Operation
    let stage: Stage
    var code: Int32? = nil
    var errorDescription: String? {
        let detail: String
        switch operation {
        case .readConfiguration, .writeConfiguration:
            detail = "Private sync settings could not be saved or read. Your local memory remains on this device; sync is paused."
        case .readJournal, .writeJournal:
            detail = PrivateMemorySyncFailure.storage.localizedDescription
        }
        let reason = code.map { " (errno \($0))" } ?? ""
        return detail + " Diagnostic: \(operation.rawValue)/\(stage.rawValue)" + reason + "."
    }
    static func posixCode(_ error: Error) -> Int32? {
        let value = error as NSError
        if value.domain == NSPOSIXErrorDomain { return Int32(exactly: value.code) }
        if let underlying = value.userInfo[NSUnderlyingErrorKey] as? NSError, underlying.domain == NSPOSIXErrorDomain {
            return Int32(exactly: underlying.code)
        }
        return nil
    }
}

struct PrivateMemorySyncDisk: Sendable {
    let root: URL
    // This anchor must come from the OS (or an explicitly trusted caller), never
    // from imported data or a user-selected sync path. iOS owns its ancestors.
    private let container: URL
    init(root: URL, container: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)) {
        self.root = root; self.container = container
    }
    var configurationURL: URL { root.appendingPathComponent("configuration.json") }
    var journalURL: URL { root.appendingPathComponent("queue.veyra") }
    func loadConfiguration() throws -> PrivateMemorySyncConfiguration? {
        guard let data = try read(configurationURL, maximum: 16_384, operation: .readConfiguration) else { return nil }
        do { return try JSONDecoder().decode(PrivateMemorySyncConfiguration.self, from: data).validated() }
        catch { throw PrivateMemorySyncStorageFailure(operation: .readConfiguration, stage: .decode) }
    }
    func saveConfiguration(_ value: PrivateMemorySyncConfiguration) throws {
        _ = try value.validated()
        try write(JSONEncoder().encode(value), name: configurationURL.lastPathComponent, operation: .writeConfiguration)
    }
    func loadJournal(passphrase: String, repositoryID: Int) throws -> PrivateMemorySyncJournal? {
        guard let data = try read(journalURL, maximum: PrivateMemorySyncPolicy.maximumJournalBytes + 58, operation: .readJournal) else { return nil }
        let raw = try EncryptedMemoryTransfer.decryptSyncPayload(data, passphrase: passphrase)
        let journal: PrivateMemorySyncJournal
        do { journal = try JSONDecoder().decode(PrivateMemorySyncJournal.self, from: raw) }
        catch { throw PrivateMemorySyncStorageFailure(operation: .readJournal, stage: .decode) }
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
        try write(encrypted, name: journalURL.lastPathComponent, operation: .writeJournal)
    }
    func saveJournal(_ journal: PrivateMemorySyncJournal, passphrase: String) throws {
        try writeEncryptedJournal(Self.encryptJournal(journal, passphrase: passphrase))
    }
    /// Compare only known system aliases, without reading /var, /tmp or their
    /// targets. Do not resolve any symlink in the app-controlled portion.
    private func components(_ url: URL, operation: PrivateMemorySyncStorageFailure.Operation) throws -> [String] {
        let path = url.path
        let parts = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard url.isFileURL, path.hasPrefix("/"), !path.contains("\0"),
              !parts.contains(".."), !parts.contains(".") else {
            throw PrivateMemorySyncStorageFailure(operation: operation, stage: .validatePath)
        }
        if parts.first == "var" || parts.first == "tmp" { return ["private"] + parts }
        return parts
    }
    /// Open the trusted app container directly. Reading / or system ancestors is
    /// not permitted by every iOS sandbox, even when the container is accessible.
    /// Every component below the anchor still uses descriptor-relative no-follow
    /// operations, so a replaced app-controlled ancestor cannot redirect access.
    private func openDirectory(create: Bool, operation: PrivateMemorySyncStorageFailure.Operation) throws -> Int32? {
        let path = try components(root, operation: operation)
        let anchor = try components(container, operation: operation)
        guard !anchor.isEmpty, path.count > anchor.count, path.starts(with: anchor) else {
            throw PrivateMemorySyncStorageFailure(operation: operation, stage: .validatePath)
        }
        var descriptor = Darwin.open(container.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw PrivateMemorySyncStorageFailure(operation: operation, stage: .openContainer, code: errno) }
        for component in path.dropFirst(anchor.count) {
            var next = component.withCString { Darwin.openat(descriptor, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
            if next < 0, errno == ENOENT, create {
                let made = component.withCString { Darwin.mkdirat(descriptor, $0, mode_t(0o700)) }
                if made != 0, errno != EEXIST {
                    let code = errno; Darwin.close(descriptor)
                    throw PrivateMemorySyncStorageFailure(operation: operation, stage: .createDirectory, code: code)
                }
                next = component.withCString { Darwin.openat(descriptor, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
            }
            if next < 0 {
                let code = errno; Darwin.close(descriptor)
                if code == ENOENT && !create { return nil }
                throw PrivateMemorySyncStorageFailure(operation: operation, stage: .openDirectory, code: code)
            }
            Darwin.close(descriptor); descriptor = next
        }
        return descriptor
    }
    private func read(_ url: URL, maximum: Int, operation: PrivateMemorySyncStorageFailure.Operation) throws -> Data? {
        guard let directory = try openDirectory(create: false, operation: operation) else { return nil }
        defer { Darwin.close(directory) }
        let descriptor = url.lastPathComponent.withCString { Darwin.openat(directory, $0, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC) }
        if descriptor < 0, errno == ENOENT { return nil }
        guard descriptor >= 0 else { throw PrivateMemorySyncStorageFailure(operation: operation, stage: .openFile, code: errno) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw PrivateMemorySyncStorageFailure(operation: operation, stage: .inspectFile, code: errno) }
        guard (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG), info.st_size >= 0, info.st_size <= off_t(maximum) else {
            throw PrivateMemorySyncStorageFailure(operation: operation, stage: .inspectFile)
        }
        var data = Data()
        do {
            while data.count <= maximum {
                let part = try handle.read(upToCount: min(65_536, maximum + 1 - data.count)) ?? Data()
                if part.isEmpty { break }; data.append(part)
            }
        } catch { throw PrivateMemorySyncStorageFailure(operation: operation, stage: .readFile, code: PrivateMemorySyncStorageFailure.posixCode(error)) }
        guard data.count <= maximum else { throw PrivateMemorySyncStorageFailure(operation: operation, stage: .readFile) }; return data
    }
    private func write(_ data: Data, name: String, operation: PrivateMemorySyncStorageFailure.Operation) throws {
        guard let directory = try openDirectory(create: true, operation: operation) else {
            throw PrivateMemorySyncStorageFailure(operation: operation, stage: .openDirectory)
        }
        defer { Darwin.close(directory) }
        var existing = stat()
        let inspected = name.withCString { fstatat(directory, $0, &existing, AT_SYMLINK_NOFOLLOW) }
        if inspected < 0, errno != ENOENT { throw PrivateMemorySyncStorageFailure(operation: operation, stage: .inspectFile, code: errno) }
        if inspected == 0, (existing.st_mode & mode_t(S_IFMT)) != mode_t(S_IFREG) {
            throw PrivateMemorySyncStorageFailure(operation: operation, stage: .inspectFile)
        }
        let temporary = ".pending-" + UUID().uuidString
        let descriptor = temporary.withCString { Darwin.openat(directory, $0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600)) }
        guard descriptor >= 0 else { throw PrivateMemorySyncStorageFailure(operation: operation, stage: .createTemporary, code: errno) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close(); _ = temporary.withCString { unlinkat(directory, $0, 0) } }
        do { try handle.write(contentsOf: data) }
        catch { throw PrivateMemorySyncStorageFailure(operation: operation, stage: .writeTemporary, code: PrivateMemorySyncStorageFailure.posixCode(error)) }
        guard fsync(descriptor) == 0 else { throw PrivateMemorySyncStorageFailure(operation: operation, stage: .syncTemporary, code: errno) }
        let result = temporary.withCString { temporaryPath in
            name.withCString { finalPath in renameat(directory, temporaryPath, directory, finalPath) }
        }
        guard result == 0 else { throw PrivateMemorySyncStorageFailure(operation: operation, stage: .replaceFile, code: errno) }
        // The rename is already committed. Directory fsync support varies across Apple
        // filesystems; failure must not report that the completed atomic replace did not run.
        _ = fsync(directory)
    }
}
