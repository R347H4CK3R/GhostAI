#if DEBUG
import XCTest
import Foundation
@testable import AsterionVeyra

@MainActor final class AssistantControlsFixtureTests: XCTestCase {
    func testSyntheticChatBootstrapNeverConstructsLivePairingClient() async {
        var liveCalls = 0
        let client = AssistantControlsUITestFixture.pairedDesktop(launchArguments: ["--uitest-chat", "success"]) {
            liveCalls += 1
            return PairedDesktopClient(vault: RefusingUITestPairingVault(), transport: RefusingUITestPairingTransport())
        }
        XCTAssertEqual(liveCalls, 0, "Synthetic tests must not read a real pairing or create a network transport")
        XCTAssertNil(client.record)
        XCTAssertFalse(client.storageUnavailable)
        client.setScreen(id: UUID(), visible: true, foreground: true)
        await client.refresh()
        XCTAssertNil(client.record)
        XCTAssertFalse(client.busy)
    }

    func testOrdinaryOrMalformedLaunchUsesTheExistingLiveConstructionPath() {
        for arguments in [[], ["--uitest-chat"], ["--uitest-chat", "not-a-fixture"]] {
            var liveCalls = 0
            let expected = PairedDesktopClient(vault: RefusingUITestPairingVault(), transport: RefusingUITestPairingTransport())
            let client = AssistantControlsUITestFixture.pairedDesktop(launchArguments: arguments) {
                liveCalls += 1; return expected
            }
            XCTAssertEqual(liveCalls, 1)
            XCTAssertTrue(client === expected)
        }
    }

    func testSyntheticTransportAlwaysFailsLocally() async {
        let transport = RefusingUITestPairingTransport()
        do {
            _ = try await transport.send(PairedDesktopRequest(origin: "https://invalid.example", pin: "not-a-real-pin", route: "/v1/pair/begin", headers: [:], body: Data()))
            XCTFail("A synthetic fixture must never deliver a pairing request")
        } catch PairedDesktopFailure.unavailable {
            // Expected local refusal.
        } catch { XCTFail("Unexpected failure: \(error)") }
    }
}
#endif
