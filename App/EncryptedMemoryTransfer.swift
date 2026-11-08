import Foundation
import CryptoKit
import CommonCrypto
import Security
import Darwin

/// Manual encrypted files only. This type has no persistence or network capability.
enum EncryptedMemoryTransfer {
    enum Format: String, CaseIterable, Identifiable, Sendable {
        case mobileBackup, desktopNotes
        var id: String { rawValue }
        var title: String {
            switch self {
            case .mobileBackup: return "Encrypted chats and notes"
            case .desktopNotes: return "Encrypted notes for desktop (no chats)"
            }
        }
        fileprivate var header: Data {
            Data((self == .mobileBackup ? "VEYRA-MOBILE\0\u{1}" : "VEYRA-MEMORY\0\u{1}").utf8)
        }
    }

    struct Decoded: Sendable {
        let backupData: Data
        let format: Format
        let noteCount: Int
        let chatCount: Int
    }

    enum Failure: LocalizedError {
        case passphrase, fileSize, format, authentication, crypto, file, incompatible
        var errorDescription: String? {
            switch self {
            case .passphrase: return "Use at least 12 characters for a new export, with a maximum of 4096 UTF-8 bytes. An import requires the original nonempty passphrase."
            case .fileSize: return "Transfer is too large. Mobile backups are limited to 5 MB of JSON; encrypted desktop files are limited to 8 MiB."
            case .format: return "This is not a supported encrypted memory file, or its version is unsupported."
            case .authentication: return "Incorrect passphrase or damaged encrypted file. No memory was imported."
            case .crypto: return "Encrypted transfer could not be prepared on this device."
            case .file: return "Choose a readable regular file, not a folder or symbolic link."
            case .incompatible: return "This file contains unsupported or incompatible memory. Desktop transfers need canonical UUID IDs, valid dates, nonempty text, and notes within the mobile limits. No memory was imported."
            }
        }
    }

    static let maximumFileBytes = 8 * 1024 * 1024
    private static let maximumMobileBytes = 5_000_000
    private static let iterations: UInt32 = 600_000
    private static let envelopeOverhead = 58 // 14-byte header + salt 16 + nonce 12 + tag 16

    static func encrypt(backupData: Data, passphrase: String, format: Format) throws -> Data {
        try validatePassphrase(passphrase, forExport: true)
        let state = try validateMobileBackup(backupData)
        let raw: Data
        switch format {
        case .mobileBackup:
            raw = try MemoryBackup.encode(state)
        case .desktopNotes:
            let rows = try state.notes.map { note -> DesktopRecord in
                try validateDesktopText(note.project)
                try validateDesktopText(note.text)
                try validateDesktopText(note.source)
                return DesktopRecord(id: note.id.uuidString.lowercased(), project: note.project,
                                     body: note.text, source: note.source, created: note.savedAt.timeIntervalSince1970)
            }.sorted { $0.id < $1.id }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            raw = try encoder.encode(DesktopSnapshot(version: 1, records: rows))
        }
        guard raw.count + envelopeOverhead <= maximumFileBytes else { throw Failure.fileSize }
        let salt = try randomBytes(count: 16)
        let nonceData = try randomBytes(count: 12)
        let prefix = format.header + salt + nonceData
        let key = try deriveKey(passphrase, salt: salt)
        let sealed = try AES.GCM.seal(raw, using: key, nonce: AES.GCM.Nonce(data: nonceData), authenticating: prefix)
        return prefix + sealed.ciphertext + sealed.tag
    }

    /// Authenticates and validates the whole file before returning any importable bytes.
    static func decrypt(_ encrypted: Data, passphrase: String) throws -> Decoded {
        try validatePassphrase(passphrase, forExport: false)
        let format = try identify(encrypted)
        let salt = encrypted.subdata(in: 14..<30)
        let nonce = encrypted.subdata(in: 30..<42)
        let prefix = encrypted.prefix(42)
        let key = try deriveKey(passphrase, salt: salt)
        let raw: Data
        do {
            let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: nonce),
                                           ciphertext: encrypted.subdata(in: 42..<(encrypted.count - 16)),
                                           tag: encrypted.suffix(16))
            raw = try AES.GCM.open(box, using: key, authenticating: prefix)
        } catch {
            throw Failure.authentication
        }
        let state: SavedState
        switch format {
        case .mobileBackup: state = try validateMobileBackup(raw)
        case .desktopNotes: state = try convertDesktopSnapshot(raw)
        }
        // Re-encode typed, checked data. Unknown fields never cross the import boundary.
        let backup = try MemoryBackup.encode(state)
        return Decoded(backupData: backup, format: format, noteCount: state.notes.count, chatCount: state.chats.count)
    }

    /// Bounded reads even if a file grows after its size was inspected. The caller owns
    /// its security-scoped URL access. O_NOFOLLOW rejects the selected symlink itself.
    static func readFile(at url: URL) throws -> Data {
        guard url.isFileURL else { throw Failure.file }
        let descriptor = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return Darwin.open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        }
        guard descriptor >= 0 else { throw Failure.file }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) else { throw Failure.file }
        guard info.st_size >= off_t(envelopeOverhead), info.st_size <= off_t(maximumFileBytes) else { throw Failure.fileSize }
        var data = Data()
        while data.count <= maximumFileBytes {
            let chunk = try handle.read(upToCount: min(65_536, maximumFileBytes + 1 - data.count)) ?? Data()
            if chunk.isEmpty { break }
            data.append(chunk)
        }
        _ = try identify(data)
        return data
    }

    private static func identify(_ encrypted: Data) throws -> Format {
        guard encrypted.count >= envelopeOverhead, encrypted.count <= maximumFileBytes else { throw Failure.fileSize }
        guard let format = Format.allCases.first(where: { encrypted.starts(with: $0.header) }) else { throw Failure.format }
        if format == .mobileBackup, encrypted.count > maximumMobileBytes + envelopeOverhead { throw Failure.fileSize }
        return format
    }

    private static func validatePassphrase(_ passphrase: String, forExport: Bool) throws {
        guard !passphrase.isEmpty, passphrase.utf8.count <= 4096 else { throw Failure.passphrase }
        if forExport {
            guard passphrase.count >= 12, !passphrase.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw Failure.passphrase }
        }
        // Preserve exact UTF-8, including whitespace and Unicode normalization, for desktop compatibility.
    }

    private static func randomBytes(count: Int) throws -> Data {
        var data = Data(count: count)
        let status = data.withUnsafeMutableBytes { bytes in
            SecRandomCopyBytes(kSecRandomDefault, count, bytes.baseAddress!)
        }
        guard status == errSecSuccess else { throw Failure.crypto }
        return data
    }

    private static func deriveKey(_ passphrase: String, salt: Data) throws -> SymmetricKey {
        var password = Data(passphrase.utf8)
        var derived = Data(count: 32)
        defer {
            password.resetBytes(in: password.startIndex..<password.endIndex)
            derived.resetBytes(in: derived.startIndex..<derived.endIndex)
        }
        let status = password.withUnsafeBytes { passwordBytes in
            salt.withUnsafeBytes { saltBytes in
                derived.withUnsafeMutableBytes { output in
                    CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), passwordBytes.bindMemory(to: CChar.self).baseAddress,
                                        password.count, saltBytes.bindMemory(to: UInt8.self).baseAddress, salt.count,
                                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), iterations,
                                        output.bindMemory(to: UInt8.self).baseAddress, 32)
                }
            }
        }
        guard status == kCCSuccess else { throw Failure.crypto }
        return SymmetricKey(data: derived)
    }

    private static func validateMobileBackup(_ data: Data) throws -> SavedState {
        guard data.count <= maximumMobileBytes else { throw Failure.fileSize }
        try checkKeys(data, root: ["version", "notes", "chats"], collections: [
            "notes": ["id", "project", "text", "source", "savedAt"],
            "chats": ["id", "project", "role", "text", "date"]
        ])
        let state = try MemoryBackup.decode(data)
        for note in state.notes {
            guard MemorySearch.canSave(note.project), validDate(note.savedAt) else { throw Failure.incompatible }
        }
        for chat in state.chats {
            guard MemorySearch.canSave(chat.project), validDate(chat.date) else { throw Failure.incompatible }
        }
        return state
    }

    private struct DesktopSnapshot: Codable {
        let version: Int
        let records: [DesktopRecord]
    }
    private struct DesktopRecord: Codable {
        let id: String
        let project: String
        let body: String
        let source: String
        let created: Double
    }

    private static func convertDesktopSnapshot(_ data: Data) throws -> SavedState {
        try checkKeys(data, root: ["version", "records"], collections: ["records": ["id", "project", "body", "source", "created"]])
        let snapshot = try JSONDecoder().decode(DesktopSnapshot.self, from: data)
        guard snapshot.version == 1, snapshot.records.count <= 10_000 else { throw Failure.incompatible }
        let notes = try snapshot.records.map { row -> MemoryNote in
            guard let id = UUID(uuidString: row.id), id.uuidString.lowercased() == row.id else { throw Failure.incompatible }
            try validateDesktopText(row.project)
            try validateDesktopText(row.body)
            try validateDesktopText(row.source)
            let date = Date(timeIntervalSince1970: row.created)
            guard validDate(date) else { throw Failure.incompatible }
            return MemoryNote(id: id, project: row.project, text: row.body, source: row.source, savedAt: date)
        }
        // The existing mobile validator enforces per-field limits and duplicate IDs.
        return try validateMobileBackup(MemoryBackup.encode(SavedState(notes: notes, chats: [])))
    }

    private static func validDate(_ date: Date) -> Bool {
        let seconds = date.timeIntervalSince1970
        return seconds.isFinite && seconds >= 0 && seconds <= 253_402_300_799
    }

    private static func validateDesktopText(_ text: String) throws {
        let credential = #"(?i)gh[pousr]_|github_pat_|-----BEGIN (?:[A-Z]+ )*PRIVATE KEY-----|\b(?:password|api_key|access_token|secret)\s*[:=]"#
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              text.utf8.count <= 65_536, MemorySearch.canSave(text),
              text.range(of: credential, options: .regularExpression) == nil else { throw Failure.incompatible }
    }

    private static func checkKeys(_ data: Data, root: Set<String>, collections: [String: Set<String>]) throws {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == root else { throw Failure.incompatible }
        for (name, keys) in collections {
            guard let rows = object[name] as? [[String: Any]], rows.count <= 10_000,
                  rows.allSatisfy({ Set($0.keys) == keys }) else { throw Failure.incompatible }
        }
    }
}
