import XCTest
@testable import AsterionVeyra

@MainActor final class VoiceEntryRequestTests: XCTestCase {
    func testRequestIsConsumedOnceWithoutStartingAudio() {
        let entry = VoiceEntryRequest()
        XCTAssertFalse(entry.consume())
        entry.request()
        XCTAssertTrue(entry.pending)
        XCTAssertTrue(entry.consume())
        XCTAssertFalse(entry.consume())
    }
}
