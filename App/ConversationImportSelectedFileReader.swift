import Foundation
import Darwin

/// No ZIP decompression, folder traversal, retained bookmarks or URL fetching. The only
/// production entry point is a URL the user selected in the system document picker.
enum ConversationImportSelectedFileReader {
    static func previewSelected(_ url: URL, kind: ConversationImportKind, project: String) throws -> ConversationImportPreview {
        try Task.checkCancellation()
        try ConversationImportPolicy.validateFilename(url.lastPathComponent, kind: kind)
        guard url.startAccessingSecurityScopedResource() else { throw ConversationImportFailure.unavailable }
        defer { url.stopAccessingSecurityScopedResource() }
        var coordinationError: NSError?
        var outcome: Result<Data, Error> = .failure(ConversationImportFailure.unavailable)
        NSFileCoordinator().coordinate(readingItemAt: url, options: .withoutChanges, error: &coordinationError) { selected in
            outcome = Result { try read(selected) }
        }
        try Task.checkCancellation()
        guard coordinationError == nil else { throw ConversationImportFailure.unavailable }
        return try ConversationImporter.preview(outcome.get(), kind: kind, filename: url.lastPathComponent, project: project)
    }

    /// Caller holds coordination and security-scoped access. Kept separate for file-type
    /// regression tests; never use this to scan user folders or resolve arbitrary paths.
    static func read(_ url: URL) throws -> Data {
        try Task.checkCancellation()
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw ConversationImportFailure.unavailable }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var before = stat()
        guard fstat(descriptor, &before) == 0, (before.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG), before.st_size >= 0 else {
            throw ConversationImportFailure.unsupported
        }
        let maximum = ConversationImportPolicy.maximumFileBytes
        guard before.st_size <= off_t(maximum) else { throw ConversationImportFailure.oversized }
        var bytes = Data()
        while bytes.count <= maximum {
            try Task.checkCancellation()
            let next = try handle.read(upToCount: min(65_536, maximum + 1 - bytes.count)) ?? Data()
            if next.isEmpty { break }
            bytes.append(next)
        }
        try Task.checkCancellation()
        guard bytes.count <= maximum else { throw ConversationImportFailure.oversized }
        var after = stat()
        guard fstat(descriptor, &after) == 0, before.st_size == after.st_size, after.st_size == off_t(bytes.count),
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec, before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec, before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else {
            throw ConversationImportFailure.unavailable
        }
        return bytes
    }
}
