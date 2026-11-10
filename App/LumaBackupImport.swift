import Foundation
import CoreFoundation

/// Compatibility adapter only. Private Luma app source and runtime are not embedded.
/// Everything is previewed as untrusted reference; checklist items never become jobs.
enum LumaBackupImport {
    static func preview(_ json: Any, filename: String, project: String, importedAt: Date) throws -> ConversationImportPreview {
        guard let root = json as? [String: Any], let version = root["version"] as? NSNumber,
              CFGetTypeID(version) != CFBooleanGetTypeID(), version.doubleValue == 1,
              let notes = root["memories"] as? [[String: Any]], let tasks = root["tasks"] as? [[String: Any]] else {
            throw ConversationImportFailure.unsupported
        }
        guard notes.count <= 1000, tasks.count <= 3000 else { throw ConversationImportFailure.oversized }
        var seen = Set<String>()
        for record in notes + tasks {
            try Task.checkCancellation()
            let id = try text(record["id"], limit: 100)
            guard seen.insert(id).inserted else { throw ConversationImportFailure.duplicate }
        }
        var groups: [ConversationImportGroup] = []
        let precise = ISO8601DateFormatter(); precise.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let regular = ISO8601DateFormatter(); regular.formatOptions = [.withInternetDateTime]
        for record in notes {
            try Task.checkCancellation()
            let id = try text(record["id"], limit: 100)
            let body = try text(record["text"], limit: 4000)
            let timestamp = try text(record["created"], limit: 100)
            guard let date = precise.date(from: timestamp) ?? regular.date(from: timestamp),
                  (0...253_402_300_799).contains(date.timeIntervalSince1970) else { throw ConversationImportFailure.malformed }
            let uuid = ConversationImportPolicy.stableID([project, "luma-note-v1", id, body, timestamp])
            let memory = ConversationImportMemory(id: uuid, text: body,
                source: "Luma note snapshot · \(filename) · source \(id) · untrusted reference", date: date)
            groups.append(group(memory, title: "Luma note \(groups.count + 1)"))
        }
        for record in tasks {
            try Task.checkCancellation()
            let id = try text(record["id"], limit: 100)
            let goal = try text(record["goal"], limit: 300)
            let step = try text(record["text"], limit: 400)
            guard let done = record["done"] as? NSNumber, CFGetTypeID(done) == CFBooleanGetTypeID() else { throw ConversationImportFailure.malformed }
            let status = done.boolValue ? "Completed" : "Not completed"
            let body = "Luma checklist snapshot (reference only, not an executable job)\nGoal: \(goal)\nStatus: \(status)\nStep: \(step)"
            let uuid = ConversationImportPolicy.stableID([project, "luma-task-v1", id, body])
            let memory = ConversationImportMemory(id: uuid, text: body,
                source: "Luma checklist snapshot · \(filename) · source \(id) · no source timestamp; date is import time", date: importedAt)
            groups.append(group(memory, title: "\(status): \(String(goal.prefix(80)))"))
        }
        return ConversationImportPreview(project: project, filename: filename, kind: .lumaBackup,
            sourceItems: notes.count + tasks.count, groups: groups, skipped: [:], omittedBranchNodes: 0,
            missingTimestamps: tasks.count)
    }

    /// Classifies metadata only; imported prose never grants authority. Restored
    /// imports also use UUIDv8, while existing conflict copies use UUIDv5.
    /// Do not parse the source label: filenames and source IDs can contain delimiters.
    static func usesChecklistImportTime(_ note: MemoryNote) -> Bool {
        note.id.uuid.6 >> 4 == 8
            && note.text.hasPrefix("Luma checklist snapshot (reference only, not an executable job)\nGoal: ")
            && note.source.hasPrefix("Luma checklist snapshot · ")
            && note.source.hasSuffix(" · no source timestamp; date is import time")
    }

    private static func text(_ value: Any?, limit: Int) throws -> String {
        guard let value = value as? String, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              value.utf16.count <= limit else { throw ConversationImportFailure.malformed }
        guard KnowledgePolicy.isSafe(value) else { throw ConversationImportFailure.unsafe }
        return value
    }
    private static func group(_ note: ConversationImportMemory, title: String) -> ConversationImportGroup {
        ConversationImportGroup(id: note.id, title: title, messages: [], memory: note, omittedBranchNodes: 0, skippedMessages: 0)
    }
}
