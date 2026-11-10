#if DEBUG
import Foundation

/// Synthetic UI runs must not inspect a developer's actual pairing or contact its host.
/// Release builds do not contain these fixture types or launch-argument handling.
@MainActor enum AssistantControlsUITestFixture {
    static func pairedDesktop(launchArguments: [String] = ProcessInfo.processInfo.arguments,
                              makeLive: @MainActor () -> PairedDesktopClient = { PairedDesktopClient() }) -> PairedDesktopClient {
        guard ChatUITestFixture.fromLaunchArguments(launchArguments) != nil else { return makeLive() }
        return PairedDesktopClient(vault: RefusingUITestPairingVault(), transport: RefusingUITestPairingTransport())
    }
}

struct RefusingUITestPairingVault: PairedDesktopVault {
    func load() throws -> PairedDesktopRecord? { nil }
    func create(_ record: PairedDesktopRecord) throws { throw PairedDesktopFailure.storage }
    func update(_ record: PairedDesktopRecord) throws { throw PairedDesktopFailure.storage }
    func delete() throws {}
}
final class RefusingUITestPairingTransport: PairedDesktopTransport {
    func send(_ request: PairedDesktopRequest) async throws -> PairedDesktopResponse { throw PairedDesktopFailure.unavailable }
    func cancel() {}
}
#endif
