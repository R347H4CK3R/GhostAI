import XCTest
@testable import AsterionVeyra

final class VoicePolicyTests: XCTestCase {
    func testConversationRequiresForegroundOptInAndIdleTurn() {
        XCTAssertTrue(VoicePolicy.shouldListen(conversationEnabled: true, foreground: true, busy: false))
        XCTAssertFalse(VoicePolicy.shouldListen(conversationEnabled: false, foreground: true, busy: false))
        XCTAssertFalse(VoicePolicy.shouldListen(conversationEnabled: true, foreground: false, busy: false))
        XCTAssertFalse(VoicePolicy.shouldListen(conversationEnabled: true, foreground: true, busy: true))
    }

    func testBackgroundTurnsRequireExplicitOptIn() {
        XCTAssertFalse(VoicePolicy.shouldListen(conversationEnabled: true, foreground: false, busy: false))
        XCTAssertTrue(VoicePolicy.shouldListen(conversationEnabled: true, foreground: false, busy: false, allowsBackgroundVoice: true))
        XCTAssertFalse(VoicePolicy.shouldListen(conversationEnabled: false, foreground: false, busy: false, allowsBackgroundVoice: true))
        XCTAssertFalse(VoicePolicy.shouldListen(conversationEnabled: true, foreground: false, busy: true, allowsBackgroundVoice: true))
    }

    func testBackgroundRecognitionCannotRequestPermission() {
        XCTAssertTrue(VoicePolicy.mayRecognize(foreground: false, allowsBackgroundVoice: true, speechAuthorized: true, microphoneAuthorized: true))
        XCTAssertFalse(VoicePolicy.mayRecognize(foreground: false, allowsBackgroundVoice: false, speechAuthorized: true, microphoneAuthorized: true))
        XCTAssertFalse(VoicePolicy.mayRecognize(foreground: false, allowsBackgroundVoice: true, speechAuthorized: false, microphoneAuthorized: true))
        XCTAssertFalse(VoicePolicy.mayRecognize(foreground: false, allowsBackgroundVoice: true, speechAuthorized: true, microphoneAuthorized: false))
        XCTAssertFalse(VoicePolicy.mayRecognize(foreground: true, allowsBackgroundVoice: false, speechAuthorized: false, microphoneAuthorized: true))
    }

    func testInterruptionNeverAutomaticallyResumes() {
        XCTAssertFalse(VoicePolicy.resumeAfterInterruption)
    }

    func testTranscriptTrimsAndRejectsEmptyOrOversizedInput() {
        XCTAssertEqual(VoicePolicy.acceptedTranscript("  hello \n"), "hello")
        XCTAssertNil(VoicePolicy.acceptedTranscript(" \n"))
        XCTAssertNil(VoicePolicy.acceptedTranscript(String(repeating: "x", count: VoicePolicy.maximumCharacters + 1)))
        XCTAssertNotNil(VoicePolicy.acceptedTranscript(String(repeating: "x", count: VoicePolicy.maximumCharacters)))
    }

    func testAudioLimitsAreBounded() {
        XCTAssertEqual(VoicePolicy.maximumListeningSeconds, 45)
        XCTAssertEqual(VoicePolicy.silenceSeconds, 2)
        XCTAssertEqual(VoicePolicy.maximumSpokenCharacters, 4_000)
    }
}
