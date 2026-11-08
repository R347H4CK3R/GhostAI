import XCTest
@testable import AsterionVeyra

@MainActor final class KnowledgeImportRouteTests: XCTestCase {
    private func root() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }
    private func route(_ store: AssistantStore) -> MemoryView.ConversationImportRoute {
        MemoryView.ConversationImportRoute(project: store.project, workspaceEpoch: store.workspaceEpoch, savedState: store.saved)
    }
    func testRouteKeepsCapturedProjectEpochAndStateSnapshot() throws {
        let directory = root(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = AssistantStore(root: directory, launchArguments: [])
        let captured = route(store)
        let incoming = SavedState(notes: [], chats: [ChatEntry(project: "General", role: "user", text: "imported orchid")])
        try captured.apply(incoming, to: store)
        XCTAssertEqual(store.saved.chats.count, 1)
        XCTAssertTrue(captured.savedState.chats.isEmpty)
        store.switchProject("Another project")
        XCTAssertEqual(captured.project, "General")
        XCTAssertNotEqual(captured.workspaceEpoch, store.workspaceEpoch)
    }
    func testSameNameSwitchRejectsCapturedRouteWithoutMutation() throws {
        let directory = root(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = AssistantStore(root: directory, launchArguments: [])
        let captured = route(store)
        store.switchProject("General")
        let incoming = SavedState(notes: [], chats: [ChatEntry(project: captured.project, role: "user", text: "stale orchid")])
        XCTAssertThrowsError(try captured.apply(incoming, to: store))
        XCTAssertTrue(store.saved.chats.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("state.json").path))
    }
    func testAccountChangeCannotRetargetCapturedPrivateImport() throws {
        let directory = root(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = AssistantStore(root: directory, launchArguments: [])
        store.switchProject("GitHub account 1: owner/private")
        let captured = route(store)
        let incoming = SavedState(notes: [], chats: [ChatEntry(project: captured.project, role: "user", text: "private orchid")])
        store.switchProject("GitHub account 2: owner/private")
        XCTAssertThrowsError(try captured.apply(incoming, to: store))
        store.switchProject(captured.project)
        XCTAssertThrowsError(try captured.apply(incoming, to: store))
        XCTAssertTrue(store.saved.chats.isEmpty)
    }
    func testOrdinaryCancellationDoesNotRetargetOrInvalidateCurrentRoute() throws {
        let directory = root(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = AssistantStore(root: directory, launchArguments: [])
        let captured = route(store)
        store.cancel()
        let incoming = SavedState(notes: [], chats: [ChatEntry(project: captured.project, role: "user", text: "valid orchid")])
        XCTAssertNoThrow(try captured.apply(incoming, to: store))
        XCTAssertEqual(store.saved.chats.first?.text, "valid orchid")
    }
    func testEachOpeningHasFreshSheetIdentity() throws {
        let directory = root(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = AssistantStore(root: directory, launchArguments: [])
        XCTAssertNotEqual(route(store).id, route(store).id)
    }
}
