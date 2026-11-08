import XCTest
import Darwin
@testable import AsterionVeyra

final class PrivateMemorySyncStorageTests: XCTestCase {
    private let passphrase = "synthetic shared recovery words"
    private var configuration: PrivateMemorySyncConfiguration {
        .init(repository: "owner/private-memory", repositoryID: 123, accountID: 456, branch: "main", includePrivateWorkspaces: false)
    }

    // Models a permitted container below a searchable but unreadable system ancestor.
    // This is a POSIX permission regression, not proof of a physical iOS sandbox profile.
    private func withContainer(_ body: (URL, URL) throws -> Void) throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let container = parent.appendingPathComponent("container", isDirectory: true)
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        defer { _ = chmod(parent.path, 0o700); try? FileManager.default.removeItem(at: parent) }
        XCTAssertEqual(chmod(parent.path, 0o111), 0)
        let denied = Darwin.open(parent.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        if denied >= 0 { Darwin.close(denied); XCTFail("The fixture must deny ancestor reads"); return }
        XCTAssertEqual(errno, EACCES)
        try body(container, container.appendingPathComponent("Library/Application Support/PrivateMemorySync"))
    }

    func testMissingConfigurationCanBeReadWithoutReadingContainerAncestors() throws {
        try withContainer { container, root in
            let disk = PrivateMemorySyncDisk(root: root, container: container)
            XCTAssertNil(try disk.loadConfiguration())
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        }
    }

    func testConfigurationAtomicReplacementDoesNotReadContainerAncestors() throws {
        try withContainer { container, root in
            let disk = PrivateMemorySyncDisk(root: root, container: container)
            try disk.saveConfiguration(configuration)
            var paused = configuration; paused.enabled = false
            try disk.saveConfiguration(paused)
            let reopened = PrivateMemorySyncDisk(root: root, container: container)
            XCTAssertEqual(try reopened.loadConfiguration()?.repositoryID, 123)
            XCTAssertEqual(try reopened.loadConfiguration()?.enabled, false)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["configuration.json"])
        }
    }

    func testEncryptedJournalReplacementPreservesDeletionHistoryWithoutAncestorReads() throws {
        try withContainer { container, root in
            let disk = PrivateMemorySyncDisk(root: root, container: container)
            var document = PrivateMemorySyncDocument.empty(repositoryID: 123)
            document.tombstones = ["note:12345678-1234-4234-8234-123456789012"]
            var journal = PrivateMemorySyncJournal(base: document, pending: nil)
            try disk.saveJournal(journal, passphrase: passphrase)
            journal.attempts = 2
            try disk.saveJournal(journal, passphrase: passphrase)
            let reopened = PrivateMemorySyncDisk(root: root, container: container)
            let restored = try XCTUnwrap(reopened.loadJournal(passphrase: passphrase, repositoryID: 123))
            XCTAssertEqual(restored.base.tombstones, ["note:12345678-1234-4234-8234-123456789012"])
            XCTAssertEqual(restored.attempts, 2)
            XCTAssertNil(try Data(contentsOf: disk.journalURL).range(of: Data(document.tombstones[0].utf8)))
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["queue.veyra"])
        }
    }

    func testContainerBoundaryRejectsSiblingAndParentTraversal() throws {
        try withContainer { container, _ in
            let sibling = container.deletingLastPathComponent().appendingPathComponent("container-other")
            let traversal = URL(fileURLWithPath: container.path + "/../container-other")
            for root in [sibling, traversal] {
                let disk = PrivateMemorySyncDisk(root: root, container: container)
                XCTAssertThrowsError(try disk.loadConfiguration())
                XCTAssertThrowsError(try disk.saveConfiguration(configuration))
                XCTAssertFalse(FileManager.default.fileExists(atPath: sibling.path))
            }
        }
    }

    func testContainerRelativeSymlinksCannotRedirectReadsOrWrites() throws {
        try withContainer { container, root in
            let outside = container.appendingPathComponent("other")
            try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
            let sentinel = outside.appendingPathComponent("configuration.json")
            let bytes = Data("preserved synthetic data".utf8); try bytes.write(to: sentinel)
            let linked = container.appendingPathComponent("linked")
            try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: outside)
            for target in [linked, linked.appendingPathComponent("nested")] {
                let disk = PrivateMemorySyncDisk(root: target, container: container)
                XCTAssertThrowsError(try disk.loadConfiguration())
                XCTAssertThrowsError(try disk.saveConfiguration(configuration))
            }
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let disk = PrivateMemorySyncDisk(root: root, container: container)
            try FileManager.default.createSymbolicLink(at: disk.configurationURL, withDestinationURL: sentinel)
            XCTAssertThrowsError(try disk.loadConfiguration())
            XCTAssertThrowsError(try disk.saveConfiguration(configuration))
            XCTAssertEqual(try Data(contentsOf: sentinel), bytes)
            XCTAssertFalse(FileManager.default.fileExists(atPath: outside.appendingPathComponent("nested").path))
        }
    }

    func testFailedAtomicConfigurationWritePreservesExistingFile() throws {
        try withContainer { container, root in
            let disk = PrivateMemorySyncDisk(root: root, container: container)
            try disk.saveConfiguration(configuration)
            let original = try Data(contentsOf: disk.configurationURL)
            XCTAssertEqual(chmod(root.path, 0o500), 0)
            defer { _ = chmod(root.path, 0o700) }
            var paused = configuration; paused.enabled = false
            XCTAssertThrowsError(try disk.saveConfiguration(paused)) { error in
                let failure = error as? PrivateMemorySyncStorageFailure
                XCTAssertEqual(failure?.operation, .writeConfiguration)
                XCTAssertEqual(failure?.stage, .createTemporary)
                XCTAssertEqual(failure?.code, EACCES)
            }
            XCTAssertEqual(try Data(contentsOf: disk.configurationURL), original)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["configuration.json"])
        }
    }

    func testSymlinkCannotReplaceTheTrustedContainerItself() throws {
        try withContainer { container, _ in
            let real = container.appendingPathComponent("real")
            let linked = container.appendingPathComponent("linked")
            try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: real)
            let disk = PrivateMemorySyncDisk(root: linked.appendingPathComponent("sync"), container: linked)
            XCTAssertThrowsError(try disk.loadConfiguration())
            XCTAssertThrowsError(try disk.saveConfiguration(configuration))
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: real.path).isEmpty)
        }
    }

    func testStorageDiagnosticsIdentifyOperationAndErrnoWithoutPrivateDetails() throws {
        try withContainer { container, root in
            let disk = PrivateMemorySyncDisk(root: root, container: container)
            try disk.saveConfiguration(configuration)
            XCTAssertEqual(chmod(disk.configurationURL.path, 0), 0)
            defer { _ = chmod(disk.configurationURL.path, 0o600) }
            XCTAssertThrowsError(try disk.loadConfiguration()) { error in
                let failure = error as? PrivateMemorySyncStorageFailure
                XCTAssertEqual(failure?.operation, .readConfiguration)
                XCTAssertEqual(failure?.stage, .openFile)
                XCTAssertEqual(failure?.code, EACCES)
                let report = error.localizedDescription + String(reflecting: error)
                for privateValue in [container.path, root.path, configuration.repository, passphrase] {
                    XCTAssertFalse(report.contains(privateValue))
                }
            }
        }
    }
}
