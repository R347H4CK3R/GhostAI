import Foundation
import CryptoKit

/// Explicit user-confirmed import is different from a stale device replay. Restored
/// generations get stable new IDs; old deletion markers remain permanent and unchanged.
enum PrivateMemorySyncRestore {
    static func prepare(_ incoming: SavedState, current: SavedState, history: PrivateMemorySyncDocument) throws -> SavedState {
        try history.validate()
        var deleted = Set(history.tombstones)
        let liveNotes = Set(current.notes.map(\.id)), liveChats = Set(current.chats.map(\.id))
        // Include local deletions that have not reached the durable/network queue yet.
        for note in history.notes where !liveNotes.contains(note.id) { deleted.insert("note:" + note.id.uuidString.lowercased()) }
        for chat in history.chats where !liveChats.contains(chat.id) { deleted.insert("chat:" + chat.id.uuidString.lowercased()) }
        let notes = try incoming.notes.map { note -> MemoryNote in
            var restored = note; restored.id = try identity(note.id, kind: "note", deleted: deleted); return restored
        }
        let chats = try incoming.chats.map { chat -> ChatEntry in
            var restored = chat; restored.id = try identity(chat.id, kind: "chat", deleted: deleted); return restored
        }
        let result = SavedState(notes: notes, chats: chats)
        _ = try MemoryBackup.encode(result)
        _ = try MemoryBackup.encode(MemoryBackup.merge(result, into: current))
        return result
    }
    static func addingRemoteMarkers(_ remote: PrivateMemorySyncDocument, to history: PrivateMemorySyncDocument) throws -> PrivateMemorySyncDocument {
        guard history.repositoryID == remote.repositoryID else { throw PrivateMemorySyncFailure.repositoryChanged }
        var result = history
        let deleted = Set(history.tombstones + remote.tombstones)
        result.tombstones = Array(deleted)
        result.notes.removeAll { deleted.contains("note:" + $0.id.uuidString.lowercased()) }
        result.chats.removeAll { deleted.contains("chat:" + $0.id.uuidString.lowercased()) }
        result.chatOrder = result.chatOrder.filter { !deleted.contains("chat:" + $0.uuidString.lowercased()) }
        try result.validate(); return result
    }
    private static func identity(_ original: UUID, kind: String, deleted: Set<String>) throws -> UUID {
        var value = original, visited = Set<UUID>()
        while deleted.contains(kind + ":" + value.uuidString.lowercased()) {
            guard visited.insert(value).inserted, visited.count <= PrivateMemorySyncPolicy.maximumTombstones else { throw PrivateMemorySyncFailure.capacity }
            let domain = "Veyra explicit import restoration v1\0" + kind + "\0" + value.uuidString.lowercased()
            var bytes = Array(SHA256.hash(data: Data(domain.utf8)).prefix(16))
            bytes[6] = (bytes[6] & 0x0f) | 0x80; bytes[8] = (bytes[8] & 0x3f) | 0x80
            let hex = bytes.map { String(format: "%02x", $0) }.joined()
            let text = "\(hex.prefix(8))-\(hex.dropFirst(8).prefix(4))-\(hex.dropFirst(12).prefix(4))-\(hex.dropFirst(16).prefix(4))-\(hex.dropFirst(20))"
            guard let next = UUID(uuidString: text) else { throw PrivateMemorySyncFailure.invalid }
            value = next
        }
        return value
    }
}
