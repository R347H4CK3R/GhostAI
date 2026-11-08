import XCTest
@testable import AsterionVeyra

final class ConversationImportCancellationTests: XCTestCase {
    func testCancelledTasksRejectParserJSONGuardAndFileReaderBeforeProcessing() async {
        let operations: [@Sendable () throws -> Void] = [
            { _ = try ConversationImporter.preview(Data("[]".utf8), kind: .chatGPTConversations, filename: "conversations.json", project: "General") },
            { _ = try ConversationImporter.preview(Data("synthetic memory".utf8), kind: .memoryText, filename: "memory.txt", project: "General") },
            { try ConversationImportJSONGuard.validate(Data("[]".utf8)) },
            { _ = try ConversationImportSelectedFileReader.read(URL(fileURLWithPath: "/nonexistent-synthetic-import.json")) }
        ]
        for operation in operations {
            let task = Task.detached {
                withUnsafeCurrentTask { $0?.cancel() }
                do { try operation(); return false }
                catch { return error is CancellationError }
            }
            let cancelled = await task.value
            XCTAssertTrue(cancelled, "Cancellation must win before parsing or opening the selected source.")
        }
    }
    func testCancellingAwaiterAlsoCancelsDetachedReaderTask() async {
        let gate = ConversationImportTestGate()
        let worker = Task.detached {
            await gate.wait()
            return try ConversationImporter.preview(Data("[]".utf8), kind: .chatGPTConversations, filename: "conversations.json", project: "General")
        }
        let awaiter = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await ConversationImportTask.value(of: worker)
        }
        do { _ = try await awaiter.value; XCTFail("A cancelled awaiter must not publish a preview.") }
        catch { XCTAssertTrue(error is CancellationError) }
        await gate.release()
        do { _ = try await worker.value; XCTFail("The actual detached reader must be cancelled too.") }
        catch { XCTAssertTrue(error is CancellationError) }
    }
}

private actor ConversationImportTestGate {
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if released { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func release() {
        released = true
        let pending = waiters; waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }
}
