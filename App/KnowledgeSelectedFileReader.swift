import Foundation
import Darwin

/// Only call for a URL supplied by the user through the system document picker, while its
/// security-scoped access and file coordination are held. No bookmarks or paths are saved.
enum KnowledgeSelectedFileReader {
    static func read(_ selected: URL) throws -> Data {
        // Inspect the opened object, not pre-open path metadata: replacing the leaf with a
        // symlink or FIFO cannot redirect the read or block the main actor during open.
        let descriptor = open(selected.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw KnowledgeFailure.unsupportedFile }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var before = stat()
        guard fstat(descriptor, &before) == 0, (before.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG), before.st_size >= 0 else {
            throw KnowledgeFailure.unsupportedFile
        }
        guard before.st_size <= off_t(KnowledgePolicy.maximumDocumentBytes) else { throw KnowledgeFailure.oversizedFile }
        var bytes = Data()
        while bytes.count <= KnowledgePolicy.maximumDocumentBytes {
            let next = try handle.read(upToCount: min(16_384, KnowledgePolicy.maximumDocumentBytes + 1 - bytes.count)) ?? Data()
            if next.isEmpty { break }
            bytes.append(next)
        }
        guard bytes.count <= KnowledgePolicy.maximumDocumentBytes else { throw KnowledgeFailure.oversizedFile }
        var after = stat()
        guard fstat(descriptor, &after) == 0, before.st_size == after.st_size, after.st_size == off_t(bytes.count),
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec else { throw KnowledgeFailure.unavailable }
        return bytes
    }
}
