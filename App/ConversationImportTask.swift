import Foundation

/// A detached read keeps file providers and bounded parsing off the UI actor. Cancellation
/// must explicitly reach that task; cancelling an awaiter alone does not cancel its work.
enum ConversationImportTask {
    static func value(of worker: Task<ConversationImportPreview, Error>) async throws -> ConversationImportPreview {
        try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            let result = try await worker.value
            try Task.checkCancellation()
            return result
        }, onCancel: {
            worker.cancel()
        })
    }
}
