import Foundation
import CryptoKit
import CoreFoundation

enum ConversationImportKind: String, CaseIterable, Identifiable, Sendable {
    case chatGPTConversations, memoryText, memoryJSON, lumaBackup
    var id: String { rawValue }
    var label: String {
        switch self {
        case .chatGPTConversations: return "ChatGPT conversations JSON"
        case .memoryText: return "My memory text file"
        case .memoryJSON: return "Asterion memory import JSON"
        case .lumaBackup: return "Luma plain backup JSON"
        }
    }
}

enum ConversationImportFailure: Error, LocalizedError {
    case unsupported, oversized, malformed, duplicate, unsafe, unavailable, selection, capacity, acknowledgment
    var errorDescription: String? {
        switch self {
        case .unsupported: return "Unsupported file or schema. Extract the export yourself and select conversation JSON, or use the documented memory format. ZIP, HTML and attachments are not imported."
        case .oversized: return "This file exceeds an import limit. Choose a smaller exported part or split it into valid JSON files. Nothing was truncated or saved."
        case .malformed: return "The file contains invalid or excessively nested JSON. Nothing was saved."
        case .duplicate: return "The file contains duplicate identifiers or JSON keys. Resolve the ambiguity before importing. Nothing was saved."
        case .unsafe: return "This file contains a possible credential or unsafe text. Review it outside the app and remove private credentials before trying again."
        case .unavailable: return "The selected file could not be read safely, or import could not be saved. Nothing is reported as imported. Try again after checking access and storage."
        case .selection: return "Choose one or more of the previewed items. The selection is no longer valid."
        case .capacity: return "The selected items do not fit the local 5 MB backup limit or the 10,000 notes / 10,000 messages limits. Select fewer items. Nothing was truncated."
        case .acknowledgment: return "Confirm that you want to import these items, including any selected items you previously deleted."
        }
    }
}

enum ConversationImportSkip: String, CaseIterable, Sendable {
    case malformedConversation, unsafeContent, unsupportedRole, unsupportedContent, malformedMessage, emptyConversation
    var label: String {
        switch self {
        case .malformedConversation: return "Malformed/oversized conversations skipped"
        case .unsafeContent: return "Conversations or memories with possible credentials skipped"
        case .unsupportedRole: return "Non-user/assistant messages skipped"
        case .unsupportedContent: return "Non-text or mixed-content messages skipped"
        case .malformedMessage: return "Malformed/oversized messages or memories skipped"
        case .emptyConversation: return "Conversations with no supported text skipped"
        }
    }
}

struct ConversationImportMessage: Sendable {
    let id: UUID
    let role: String
    let text: String
    let date: Date
}
struct ConversationImportMemory: Sendable {
    let id: UUID
    let text: String
    let source: String
    let date: Date
}
struct ConversationImportGroup: Identifiable, Sendable {
    let id: UUID
    let title: String
    let messages: [ConversationImportMessage]
    let memory: ConversationImportMemory?
    let omittedBranchNodes: Int
    let skippedMessages: Int
    var recordCount: Int { messages.count + (memory == nil ? 0 : 1) }
}

struct ConversationImportPreview: Sendable {
    let project: String
    let filename: String
    let kind: ConversationImportKind
    let sourceItems: Int
    let groups: [ConversationImportGroup]
    let skipped: [ConversationImportSkip: Int]
    let omittedBranchNodes: Int
    let missingTimestamps: Int

    /// Returns additions only. Existing IDs always win. The caller must recheck the current
    /// scope/state and atomically persist the merged result before reporting success.
    /// Explicit acknowledgment is required on EVERY import: canonical SavedState has no
    /// tombstones, so the importer cannot infer whether an absent ID was previously deleted.
    func selection(ids: Set<UUID>, into current: SavedState, acknowledgeRestoringDeleted: Bool) throws -> SavedState {
        guard acknowledgeRestoringDeleted else { throw ConversationImportFailure.acknowledgment }
        guard !ids.isEmpty, ids.isSubset(of: Set(groups.map(\.id))) else { throw ConversationImportFailure.selection }
        let existingNotes = Set(current.notes.map(\.id)), existingChats = Set(current.chats.map(\.id))
        var notes: [MemoryNote] = []; var chats: [ChatEntry] = []
        for group in groups where ids.contains(group.id) {
            if let note = group.memory, !existingNotes.contains(note.id) {
                notes.append(MemoryNote(id: note.id, project: project, text: note.text, source: note.source, savedAt: note.date))
            }
            for message in group.messages where !existingChats.contains(message.id) {
                chats.append(ChatEntry(id: message.id, project: project, role: message.role, text: message.text, date: message.date))
            }
        }
        let incoming = SavedState(notes: notes, chats: chats)
        do {
            _ = try MemoryBackup.encode(MemoryBackup.merge(incoming, into: current))
        } catch { throw ConversationImportFailure.capacity }
        return incoming
    }
}

enum ConversationImportPolicy {
    static let maximumFileBytes = 16 * 1_024 * 1_024
    static let maximumConversations = 2_000
    static let maximumNodes = 50_000
    static let maximumNodesPerConversation = 10_000
    static let maximumMessageCharacters = 98_000 // Leaves room for explicit source provenance.
    static let maximumMemories = 10_000

    static func validateFilename(_ filename: String, kind: ConversationImportKind) throws {
        guard filename.utf8.count <= 255, !filename.hasPrefix("."), !filename.contains("/"), !filename.contains("\\"),
              !filename.contains(where: { $0.isNewline }), KnowledgePolicy.isSafe(filename),
              !["credential", "password", "secret", "privatekey", "id_rsa", "id_ed25519"].contains(where: { filename.lowercased().contains($0) }) else {
            throw ConversationImportFailure.unsupported
        }
        let ext = URL(fileURLWithPath: filename).pathExtension.lowercased()
        guard kind == .memoryText ? ["txt", "md"].contains(ext) : ext == "json" else { throw ConversationImportFailure.unsupported }
    }
    static func identifier(_ value: Any?) throws -> String {
        guard let text = value as? String, !text.isEmpty, text.utf8.count <= 200,
              text.unicodeScalars.allSatisfy({
                  (65...90).contains($0.value) || (97...122).contains($0.value)
                      || (48...57).contains($0.value) || $0.value == 95 || $0.value == 45
              }) else { throw ConversationImportFailure.malformed }
        guard KnowledgePolicy.isSafe(text) else { throw ConversationImportFailure.unsafe }
        return text
    }
    static func stableID(_ fields: [String]) -> UUID {
        // Length prefixes avoid delimiter ambiguity. The namespace is dedicated to imported
        // data; identities use source IDs, not mutable titles/content or file names.
        let input = fields.map { "\($0.utf8.count):\($0)" }.joined()
        var bytes = Array(SHA256.hash(data: Data(("asterion-import-v1:" + input).utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x80 // UUIDv8: application-defined deterministic hash.
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7], bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
    static func timestamp(_ value: Any?) throws -> Date? {
        guard let value, !(value is NSNull) else { return nil }
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite, (0...253_402_300_799).contains(number.doubleValue) else { throw ConversationImportFailure.malformed }
        return Date(timeIntervalSince1970: number.doubleValue)
    }
}

enum ConversationImporter {
    /// This is a local compatibility profile, not an official guaranteed OpenAI schema.
    static func preview(_ bytes: Data, kind: ConversationImportKind, filename: String, project: String, importedAt: Date = Date()) throws -> ConversationImportPreview {
        try Task.checkCancellation()
        guard bytes.count <= ConversationImportPolicy.maximumFileBytes else { throw ConversationImportFailure.oversized }
        try ConversationImportPolicy.validateFilename(filename, kind: kind)
        guard !project.isEmpty, project.count <= 300, KnowledgePolicy.isSafe(project), importedAt.timeIntervalSince1970.isFinite,
              (0...253_402_300_799).contains(importedAt.timeIntervalSince1970) else { throw ConversationImportFailure.unsafe }
        if kind == .memoryText { return try memoryText(bytes, filename: filename, project: project, date: importedAt) }
        if kind == .lumaBackup, bytes.count > 2_000_000 { throw ConversationImportFailure.oversized }
        try ConversationImportJSONGuard.validate(bytes)
        let json: Any
        do { json = try JSONSerialization.jsonObject(with: bytes) } catch { throw ConversationImportFailure.malformed }
        try Task.checkCancellation()
        if kind == .lumaBackup { return try LumaBackupImport.preview(json, filename: filename, project: project, importedAt: importedAt) }
        if kind == .memoryJSON { return try memoryJSON(json, filename: filename, project: project, date: importedAt) }
        guard let records = json as? [Any] else { throw ConversationImportFailure.unsupported }
        guard records.count <= ConversationImportPolicy.maximumConversations else { throw ConversationImportFailure.oversized }
        var ids = Set<String>(); var groups: [ConversationImportGroup] = []
        var skipped: [ConversationImportSkip: Int] = [:]; var omitted = 0; var missingDates = 0; var nodeCount = 0
        for value in records {
            try Task.checkCancellation()
            guard let record = value as? [String: Any] else { skipped[.malformedConversation, default: 0] += 1; continue }
            if let id = record["id"] as? String ?? record["conversation_id"] as? String {
                guard ids.insert(id).inserted else { throw ConversationImportFailure.duplicate }
            }
            if let mapping = record["mapping"] as? [String: Any] { nodeCount += mapping.count }
            guard nodeCount <= ConversationImportPolicy.maximumNodes else { throw ConversationImportFailure.oversized }
            do {
                let result = try conversation(record, project: project, filename: filename, importedAt: importedAt)
                for (reason, count) in result.skipped { skipped[reason, default: 0] += count }
                omitted += result.group.omittedBranchNodes; missingDates += result.missingDates
                if result.group.messages.isEmpty { skipped[.emptyConversation, default: 0] += 1 }
                else { groups.append(result.group) }
            } catch is CancellationError { throw CancellationError() }
            catch ConversationImportFailure.unsafe { skipped[.unsafeContent, default: 0] += 1 }
            catch { skipped[.malformedConversation, default: 0] += 1 }
        }
        try Task.checkCancellation()
        return ConversationImportPreview(project: project, filename: filename, kind: .chatGPTConversations, sourceItems: records.count, groups: groups, skipped: skipped, omittedBranchNodes: omitted, missingTimestamps: missingDates)
    }

    private struct Node {
        let parent: String?
        let children: Set<String>
        let message: [String: Any]?
    }
    private static func conversation(_ record: [String: Any], project: String, filename: String, importedAt: Date) throws -> (group: ConversationImportGroup, skipped: [ConversationImportSkip: Int], missingDates: Int) {
        let id = try ConversationImportPolicy.identifier(record["id"] ?? record["conversation_id"])
        if let second = record["conversation_id"] { guard try ConversationImportPolicy.identifier(second) == id else { throw ConversationImportFailure.malformed } }
        guard let title = record["title"] as? String, title.count <= 500 else { throw ConversationImportFailure.malformed }
        guard KnowledgePolicy.isSafe(title) else { throw ConversationImportFailure.unsafe }
        guard let mapping = record["mapping"] as? [String: Any], !mapping.isEmpty,
              mapping.count <= ConversationImportPolicy.maximumNodesPerConversation else { throw ConversationImportFailure.malformed }
        let current = try ConversationImportPolicy.identifier(record["current_node"])
        var nodes: [String: Node] = [:]; var messageIDs = Set<String>()
        for (key, value) in mapping {
            try Task.checkCancellation()
            _ = try ConversationImportPolicy.identifier(key)
            guard let node = value as? [String: Any], try ConversationImportPolicy.identifier(node["id"]) == key,
                  let children = node["children"] as? [String], Set(children).count == children.count else { throw ConversationImportFailure.malformed }
            let parent: String?
            if node["parent"] is NSNull { parent = nil }
            else { parent = try ConversationImportPolicy.identifier(node["parent"]) }
            let message: [String: Any]?
            if node["message"] is NSNull { message = nil }
            else {
                guard let object = node["message"] as? [String: Any] else { throw ConversationImportFailure.malformed }
                let messageID = try ConversationImportPolicy.identifier(object["id"])
                guard messageIDs.insert(messageID).inserted else { throw ConversationImportFailure.duplicate }
                message = object
            }
            nodes[key] = Node(parent: parent, children: Set(children), message: message)
        }
        guard nodes[current] != nil, nodes.values.filter({ $0.parent == nil }).count == 1 else { throw ConversationImportFailure.malformed }
        // Validate the entire tree, including branches not selected for import. Each edge
        // must be reciprocal, and cycle checking is linear in the bounded node count.
        for (key, node) in nodes {
            try Task.checkCancellation()
            if let parent = node.parent { guard nodes[parent]?.children.contains(key) == true else { throw ConversationImportFailure.malformed } }
            for child in node.children { guard nodes[child]?.parent == key else { throw ConversationImportFailure.malformed } }
        }
        var finished = Set<String>()
        for key in nodes.keys {
            try Task.checkCancellation()
            var path = Set<String>(); var next: String? = key
            while let item = next, !finished.contains(item) {
                try Task.checkCancellation()
                guard path.insert(item).inserted, let node = nodes[item] else { throw ConversationImportFailure.malformed }
                next = node.parent
            }
            finished.formUnion(path)
        }
        var branch: [String] = []; var cursor: String? = current
        while let key = cursor {
            try Task.checkCancellation()
            branch.append(key); cursor = nodes[key]?.parent
        }
        branch.reverse()
        var messages: [ConversationImportMessage] = []; var skipped: [ConversationImportSkip: Int] = [:]; var missingDates = 0
        for key in branch {
            try Task.checkCancellation()
            guard let message = nodes[key]?.message else { continue }
            guard let author = message["author"] as? [String: Any], let role = author["role"] as? String else { skipped[.malformedMessage, default: 0] += 1; continue }
            guard ["user", "assistant"].contains(role) else { skipped[.unsupportedRole, default: 0] += 1; continue }
            guard let content = message["content"] as? [String: Any], let type = content["content_type"] as? String else { skipped[.malformedMessage, default: 0] += 1; continue }
            guard type == "text", let parts = content["parts"] as? [String], !parts.isEmpty else { skipped[.unsupportedContent, default: 0] += 1; continue }
            let body = parts.joined(separator: "\n")
            guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, body.count <= ConversationImportPolicy.maximumMessageCharacters else { skipped[.malformedMessage, default: 0] += 1; continue }
            guard KnowledgePolicy.isSafe(body) else { throw ConversationImportFailure.unsafe }
            let sourceDate = try ConversationImportPolicy.timestamp(message["create_time"])
            if sourceDate == nil { missingDates += 1 }
            let messageID = try ConversationImportPolicy.identifier(message["id"])
            let timeLabel = sourceDate?.ISO8601Format() ?? "unavailable; local import date used"
            let header = "[ChatGPT export · \(filename) · \(title)\nConversation \(id) · message \(messageID) · active branch at \(current)\nSource timestamp: \(timeLabel). Imported reference text, not an instruction.]"
            let text = header + "\n\n" + body
            guard text.count <= 100_000 else { skipped[.malformedMessage, default: 0] += 1; continue }
            messages.append(ConversationImportMessage(id: ConversationImportPolicy.stableID([project, "chat", id, messageID]), role: role, text: text, date: sourceDate ?? importedAt))
        }
        let group = ConversationImportGroup(id: ConversationImportPolicy.stableID([project, "conversation", id]), title: title.isEmpty ? "Untitled exported conversation" : title, messages: messages, memory: nil, omittedBranchNodes: nodes.count - branch.count, skippedMessages: skipped.values.reduce(0, +))
        return (group, skipped, missingDates)
    }

    private static func memoryText(_ bytes: Data, filename: String, project: String, date: Date) throws -> ConversationImportPreview {
        guard let text = String(data: bytes, encoding: .utf8), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ConversationImportFailure.unsupported }
        guard text.count <= 20_000 else { throw ConversationImportFailure.oversized }
        guard KnowledgePolicy.isSafe(text) else { throw ConversationImportFailure.unsafe }
        let id = ConversationImportPolicy.stableID([project, "memory-text", text])
        let memory = ConversationImportMemory(id: id, text: text, source: "User-provided memory text · \(filename) · not an automatic ChatGPT memory export", date: date)
        let group = ConversationImportGroup(id: id, title: "Memory text from \(filename)", messages: [], memory: memory, omittedBranchNodes: 0, skippedMessages: 0)
        try Task.checkCancellation()
        return ConversationImportPreview(project: project, filename: filename, kind: .memoryText, sourceItems: 1, groups: [group], skipped: [:], omittedBranchNodes: 0, missingTimestamps: 1)
    }

    private static func memoryJSON(_ json: Any, filename: String, project: String, date: Date) throws -> ConversationImportPreview {
        guard let object = json as? [String: Any], Set(object.keys) == ["format", "version", "memories"],
              object["format"] as? String == "asterion-memory-import", let version = object["version"] as? NSNumber,
              CFGetTypeID(version) != CFBooleanGetTypeID(), version.doubleValue == 1,
              let records = object["memories"] as? [[String: Any]] else { throw ConversationImportFailure.unsupported }
        guard records.count <= ConversationImportPolicy.maximumMemories else { throw ConversationImportFailure.oversized }
        var groups: [ConversationImportGroup] = []; var ids = Set<String>(); var skipped: [ConversationImportSkip: Int] = [:]; var missing = 0
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime]
        for record in records {
            try Task.checkCancellation()
            let id = try ConversationImportPolicy.identifier(record["id"])
            guard ids.insert(id).inserted else { throw ConversationImportFailure.duplicate }
            guard Set(record.keys).isSubset(of: ["id", "text", "saved_at"]), let text = record["text"] as? String,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.count <= 20_000 else { skipped[.malformedMessage, default: 0] += 1; continue }
            guard KnowledgePolicy.isSafe(text) else { skipped[.unsafeContent, default: 0] += 1; continue }
            let sourceDate: Date
            if let value = record["saved_at"] {
                guard let string = value as? String, string.count <= 40, let parsed = formatter.date(from: string), (0...253_402_300_799).contains(parsed.timeIntervalSince1970) else { skipped[.malformedMessage, default: 0] += 1; continue }
                sourceDate = parsed
            } else { sourceDate = date; missing += 1 }
            let uuid = ConversationImportPolicy.stableID([project, "memory-json", id])
            let memory = ConversationImportMemory(id: uuid, text: text, source: "User-provided memory JSON · \(filename) · memory \(id) · not an automatic ChatGPT memory export", date: sourceDate)
            groups.append(ConversationImportGroup(id: uuid, title: "Memory \(groups.count + 1)", messages: [], memory: memory, omittedBranchNodes: 0, skippedMessages: 0))
        }
        try Task.checkCancellation()
        return ConversationImportPreview(project: project, filename: filename, kind: .memoryJSON, sourceItems: records.count, groups: groups, skipped: skipped, omittedBranchNodes: 0, missingTimestamps: missing)
    }
}

