import Foundation

/// An editable note subtype, not a scheduler or an execution request. Keeping the
/// envelope inside note text lets older clients and v1 backups retain every byte.
struct EditableChecklist: Codable, Sendable {
    struct Origin: Codable, Sendable {
        let snapshotID: UUID
        let text: String
        let source: String
    }
    static let header = "Jarvis checklist (editable reference, not an executable job)\n"
    static let source = "Jarvis editable checklist · reviewed Luma copy"
    var version = 1
    var goal: String
    var step: String
    var done: Bool
    let origin: Origin

    private func validated() throws -> Self {
        guard version == 1,
              Self.validField(goal, limit: 300), Self.validField(step, limit: 400),
              !origin.text.isEmpty, origin.text.utf8.count <= 4_096,
              !origin.source.isEmpty, origin.source.utf8.count <= 2_000,
              KnowledgePolicy.isSafe(origin.text), KnowledgePolicy.isSafe(origin.source) else {
            throw AppFailure.message("Use a goal of 1–300 and a step of 1–400 UTF-16 units, without credentials or hidden controls. The original source must remain intact.")
        }
        return self
    }
    private static func validField(_ value: String, limit: Int) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && value.utf16.count <= limit && KnowledgePolicy.isSafe(value)
    }
    private func payload() throws -> Data {
        _ = try validated()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(self)
        guard data.count <= 16_000 else { throw ConversationImportFailure.capacity }
        return data
    }
    /// A classifier only. A recognized envelope is still untrusted user data.
    /// Outer note ID is authoritative; conflict/restoration IDs remain editable.
    static func decode(_ note: MemoryNote) -> Self? {
        guard note.source.utf8.elementsEqual(source.utf8), note.text.hasPrefix(header),
              note.text.utf8.count <= 16_000 + header.utf8.count,
              !note.project.isEmpty, note.project.count <= 300, KnowledgePolicy.isSafe(note.project),
              PrivateMemorySyncPolicy.validDate(note.savedAt) else { return nil }
        let data = Data(note.text.dropFirst(header.count).utf8)
        do {
            try ConversationImportJSONGuard.validate(data)
            let value = try JSONDecoder().decode(Self.self, from: data)
            // Exact canonical round trip rejects unknown keys, alternate representations
            // and future versions without rewriting or concealing the original note.
            guard try value.payload() == data else { return nil }
            return value
        } catch { return nil }
    }
    func note(project: String, importedAt: Date) throws -> MemoryNote {
        let id = ConversationImportPolicy.stableID([project, "jarvis-editable-checklist-v1",
            origin.snapshotID.uuidString.lowercased(), origin.source])
        let value = MemoryNote(id: id, project: project,
            text: Self.header + String(decoding: try payload(), as: UTF8.self), source: Self.source, savedAt: importedAt)
        guard Self.decode(value) != nil else { throw ConversationImportFailure.malformed }
        return value
    }
    static func edit(_ note: MemoryNote, goal: String, step: String, done: Bool) throws -> MemoryNote {
        guard var value = decode(note) else { throw AppFailure.message("This note is not a supported editable checklist. Its original bytes have been preserved.") }
        value.goal = goal; value.step = step; value.done = done
        var result = note
        result.text = header + String(decoding: try value.payload(), as: UTF8.self)
        // savedAt remains creation/import time. Origin, outer identity and workspace
        // cannot be altered by the editor, and no source snapshot is rewritten.
        return result
    }
    static func usesImportTime(_ note: MemoryNote) -> Bool {
        note.id.uuid.6 >> 4 == 8 && decode(note) != nil
    }
}
