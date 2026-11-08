import XCTest
import Darwin
@testable import AsterionVeyra

final class ConversationImportFileTests: XCTestCase {
    func testSelectedReaderRefusesSymlinksDirectoriesFIFOsAndOversizedFiles() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let regular = directory.appendingPathComponent("conversations.json")
        try Data("[]".utf8).write(to: regular)
        XCTAssertEqual(try ConversationImportSelectedFileReader.read(regular), Data("[]".utf8))
        let link = directory.appendingPathComponent("link.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: regular)
        XCTAssertThrowsError(try ConversationImportSelectedFileReader.read(link))
        XCTAssertThrowsError(try ConversationImportSelectedFileReader.read(directory))
        let fifo = directory.appendingPathComponent("fifo.json")
        XCTAssertEqual(mkfifo(fifo.path, mode_t(0o600)), 0)
        XCTAssertThrowsError(try ConversationImportSelectedFileReader.read(fifo))
        try Data(repeating: 32, count: ConversationImportPolicy.maximumFileBytes + 1).write(to: regular)
        XCTAssertThrowsError(try ConversationImportSelectedFileReader.read(regular))
    }
}
