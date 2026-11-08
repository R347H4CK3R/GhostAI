import XCTest
import CryptoKit
import CommonCrypto
@testable import AsterionVeyra

final class EncryptedTransferTests: XCTestCase {
    // Public synthetic test data only. Never use this passphrase for real memory.
    private let passphrase = "correct horse café fixture"
    private let mobileFixture = "VkVZUkEtTU9CSUxFAAEAAQIDBAUGBwgJCgsMDQ4PEBESExQVFhcYGRobqovobve5ZkRoReCvPB0dL263YdU2RumlQn6UctW/nhchQ5SBFhWJPmqieAP0T3GL/FqAmhX168M03Um8mys6vDjWAntJ54gTLdJGyOygkJuzZ5/tK7x+uLrQLHXNr2u7oW2G1bRcBok8t4P51NfvB18yrx5cXUOr8MgOaZVQ8k85yc+Tf+DvffdisebSKqKDlWjE5Pkw/3Mkis2jSMAFDbsfSO0WCyy7Mc1WEvxkwjVzTdFKe2jsG6hbAdk/FO5m"
    private let desktopFixture = "VkVZUkEtTUVNT1JZAAEAAQIDBAUGBwgJCgsMDQ4PEBESExQVFhcYGRobqov5Y/WiZwIhPIfYZVEQNG+9YdVPfqqqeimeYIG0jUxyE8/QVUGbYDviIke6VXCYrRvR1lSmuNk/3k24ni09tCrKECcZ4YZUdIRVwP3yzNXwKsC5NuIl9+aKfm/MvCrp4yXXovdGDYw9soD20df9G1Fgrh5DSkO68MgOaZVQ8k85ycLSMvbjaeZip+biJLEyXy2JuL06/2U139KjB9IqWLsUcLNHFCanYJ4IAda4oVcWaXsrZDHYAQTvTDs="

    private func exampleBackup() throws -> Data {
        var note = MemoryNote(project: "fixture/mobile", text: "Café offline memory", source: "fixture")
        note.id = UUID(uuidString: "12345678-1234-5678-1234-567812345678")!
        note.savedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let chat = ChatEntry(project: "fixture/mobile", role: "user", text: "This chat must not reach the desktop")
        return try MemoryBackup.encode(SavedState(notes: [note], chats: [chat]))
    }

    func testFullBackupPreservesNotesAndChats() throws {
        let encrypted = try EncryptedMemoryTransfer.encrypt(backupData: exampleBackup(), passphrase: passphrase, format: .mobileBackup)
        XCTAssertNil(encrypted.range(of: Data("Café offline memory".utf8)))
        let result = try EncryptedMemoryTransfer.decrypt(encrypted, passphrase: passphrase)
        XCTAssertEqual(result.format, .mobileBackup)
        let state = try MemoryBackup.decode(result.backupData)
        XCTAssertEqual(state.notes.first?.text, "Café offline memory")
        XCTAssertEqual(state.chats.first?.text, "This chat must not reach the desktop")
    }

    func testDesktopModeExportsNotesOnlyAndPreservesIDsAndUnixTime() throws {
        let encrypted = try EncryptedMemoryTransfer.encrypt(backupData: exampleBackup(), passphrase: passphrase, format: .desktopNotes)
        let result = try EncryptedMemoryTransfer.decrypt(encrypted, passphrase: passphrase)
        XCTAssertEqual(result.format, .desktopNotes)
        let state = try MemoryBackup.decode(result.backupData)
        XCTAssertEqual(state.notes.count, 1)
        XCTAssertTrue(state.chats.isEmpty)
        XCTAssertEqual(state.notes[0].id.uuidString.lowercased(), "12345678-1234-5678-1234-567812345678")
        XCTAssertEqual(state.notes[0].savedAt.timeIntervalSince1970, 1_700_000_000)

        // CI exports this attachment and verifies it with the real companion importer.
        let attachment = XCTAttachment(data: encrypted, uniformTypeIdentifier: "public.data")
        attachment.name = "swift-desktop-transfer.veyra"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testDecryptsIndependentPythonFixturesInBothFormats() throws {
        for (encoded, expectedFormat) in [(mobileFixture, EncryptedMemoryTransfer.Format.mobileBackup), (desktopFixture, .desktopNotes)] {
            let result = try EncryptedMemoryTransfer.decrypt(XCTUnwrap(Data(base64Encoded: encoded)), passphrase: passphrase)
            XCTAssertEqual(result.format, expectedFormat)
            let state = try MemoryBackup.decode(result.backupData)
            XCTAssertEqual(state.notes.first?.project, "fixture/mobile")
            XCTAssertEqual(state.notes.first?.text, "Café offline memory")
            XCTAssertEqual(state.notes.first?.savedAt.timeIntervalSince1970, 1_700_000_000)
            XCTAssertTrue(state.chats.isEmpty)
        }
    }

    func testFreshExportsRandomizeSaltAndNonce() throws {
        let raw = try exampleBackup()
        let first = try EncryptedMemoryTransfer.encrypt(backupData: raw, passphrase: passphrase, format: .mobileBackup)
        let second = try EncryptedMemoryTransfer.encrypt(backupData: raw, passphrase: passphrase, format: .mobileBackup)
        XCTAssertNotEqual(first.subdata(in: 14..<30), second.subdata(in: 14..<30))
        XCTAssertNotEqual(first.subdata(in: 30..<42), second.subdata(in: 30..<42))
        XCTAssertNotEqual(first, second)
    }

    func testWrongPasswordAndEveryEnvelopeComponentRejectsBeforeImport() throws {
        let fixture = try XCTUnwrap(Data(base64Encoded: desktopFixture))
        XCTAssertThrowsError(try EncryptedMemoryTransfer.decrypt(fixture, passphrase: "wrong passphrase"))
        for position in [0, 13, 14, 30, 42, fixture.count - 1] {
            var corrupt = fixture
            corrupt[position] ^= 1
            XCTAssertThrowsError(try EncryptedMemoryTransfer.decrypt(corrupt, passphrase: passphrase))
        }
        // No persistence is available to decrypt; callers receive no partial backup on failure.
    }

    func testBoundsAndPassphraseRequirementsRejectUnsafeInput() throws {
        let raw = try exampleBackup()
        for value in ["", "short", String(repeating: " ", count: 20), String(repeating: "é", count: 2049)] {
            XCTAssertThrowsError(try EncryptedMemoryTransfer.encrypt(backupData: raw, passphrase: value, format: .mobileBackup))
        }
        XCTAssertThrowsError(try EncryptedMemoryTransfer.encrypt(backupData: Data(repeating: 0, count: 5_000_001), passphrase: passphrase, format: .mobileBackup))
        for bad in [Data(), Data(repeating: 0, count: 57), Data(repeating: 0, count: 8 * 1024 * 1024 + 1)] {
            XCTAssertThrowsError(try EncryptedMemoryTransfer.decrypt(bad, passphrase: passphrase))
        }
        XCTAssertThrowsError(try EncryptedMemoryTransfer.decrypt(XCTUnwrap(Data(base64Encoded: mobileFixture)), passphrase: String(repeating: "a", count: 4097)))
    }

    func testDesktopImportRejectsIncompatibleRecordsWithoutReturningPartialBackup() throws {
        let valid: [String: Any] = ["id": "12345678-1234-5678-1234-567812345678", "project": "fixture/mobile", "body": "offline note", "source": "fixture", "created": 1_700_000_000]
        let mutations: [(String, Any)] = [("id", "legacy-non-uuid"), ("project", "password=private"), ("project", String(repeating: "p", count: 301)), ("body", String(repeating: "n", count: 20_001)), ("source", String(repeating: "s", count: 2001)), ("created", -1), ("created", true), ("unexpected", "value")]
        for (key, value) in mutations {
            var invalid = valid; invalid[key] = value
            // A valid first row must not escape if a later row is incompatible.
            invalid["id"] = key == "id" ? value : "22345678-1234-5678-1234-567812345678"
            let data = try authenticatedDesktopPayload(["version": 1, "records": [valid, invalid]])
            XCTAssertThrowsError(try EncryptedMemoryTransfer.decrypt(data, passphrase: passphrase), "Unexpected acceptance of \(key)")
        }
        let invalidPayloads: [[String: Any]] = [["version": 2, "records": [valid]], ["version": true, "records": [valid]], ["version": 1, "records": [valid, valid]], ["version": 1, "records": [], "tasks": []]]
        for payload in invalidPayloads {
            XCTAssertThrowsError(try EncryptedMemoryTransfer.decrypt(authenticatedDesktopPayload(payload), passphrase: passphrase))
        }
    }

    func testDesktopExportRejectsNotesThatTheCompanionWouldReject() throws {
        for text in ["", "  ", "password:", String(repeating: "😀", count: 17_000)] {
            let state = SavedState(notes: [MemoryNote(project: "work", text: text, source: "manual")], chats: [])
            XCTAssertThrowsError(try EncryptedMemoryTransfer.encrypt(backupData: JSONEncoder().encode(state), passphrase: passphrase, format: .desktopNotes))
        }
    }

    func testFileReadRejectsSymlinksAndOversizedFiles() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("fixture.veyra")
        let fixture = try XCTUnwrap(Data(base64Encoded: desktopFixture))
        try fixture.write(to: file)
        XCTAssertEqual(try EncryptedMemoryTransfer.readFile(at: file), fixture)
        let link = directory.appendingPathComponent("link.veyra")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        XCTAssertThrowsError(try EncryptedMemoryTransfer.readFile(at: link))
        XCTAssertThrowsError(try EncryptedMemoryTransfer.readFile(at: directory))
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: 8 * 1024 * 1024 + 1)
        try handle.close()
        XCTAssertThrowsError(try EncryptedMemoryTransfer.readFile(at: file))
    }

    // Independent authenticated malformed-payload builder, never a production escape hatch.
    private func authenticatedDesktopPayload(_ payload: [String: Any]) throws -> Data {
        let salt = Data(0..<16), nonce = Data(16..<28)
        var key = [UInt8](repeating: 0, count: 32)
        let password = Array(passphrase.utf8)
        let status = password.withUnsafeBytes { passwordBytes in
            salt.withUnsafeBytes { saltBytes in
                CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), passwordBytes.bindMemory(to: CChar.self).baseAddress, password.count, saltBytes.bindMemory(to: UInt8.self).baseAddress, salt.count, CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), 600_000, &key, 32)
            }
        }
        XCTAssertEqual(status, Int32(kCCSuccess))
        let prefix = Data("VEYRA-MEMORY\0\u{1}".utf8) + salt + nonce
        let box = try AES.GCM.seal(JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]), using: SymmetricKey(data: key), nonce: AES.GCM.Nonce(data: nonce), authenticating: prefix)
        return prefix + box.ciphertext + box.tag
    }
}
