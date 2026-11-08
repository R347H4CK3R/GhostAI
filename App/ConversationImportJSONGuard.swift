import Foundation

/// JSONSerialization accepts duplicate object keys by keeping one value. This bounded
/// lexical pass rejects those ambiguities (including escaped spellings of the same key)
/// before Foundation parses the archive. It never reports key names or source snippets.
enum ConversationImportJSONGuard {
    static func validate(_ data: Data) throws {
        try Task.checkCancellation()
        guard data.count <= ConversationImportPolicy.maximumFileBytes else { throw ConversationImportFailure.oversized }
        var scanner = Scanner(bytes: Array(data))
        try scanner.value(depth: 0)
        try scanner.whitespace()
        guard scanner.index == scanner.bytes.count else { throw ConversationImportFailure.malformed }
    }
    private struct Scanner {
        let bytes: [UInt8]
        var index = 0
        var tokens = 0
        mutating func whitespace() throws {
            while index < bytes.count, [9, 10, 13, 32].contains(bytes[index]) {
                if index & 0xfff == 0 { try Task.checkCancellation() }
                index += 1
            }
        }
        mutating func value(depth: Int) throws {
            try Task.checkCancellation()
            tokens += 1
            guard depth <= 64, tokens <= 300_000 else { throw ConversationImportFailure.oversized }
            try whitespace()
            guard index < bytes.count else { throw ConversationImportFailure.malformed }
            switch bytes[index] {
            case 123: // object
                index += 1; try whitespace()
                if take(125) { return }
                var keys = Set<String>()
                while true {
                    let range = try string()
                    let key: String
                    do { key = try JSONDecoder().decode(String.self, from: Data(bytes[range])) }
                    catch { throw ConversationImportFailure.malformed }
                    guard keys.insert(key).inserted else { throw ConversationImportFailure.duplicate }
                    try whitespace(); guard take(58) else { throw ConversationImportFailure.malformed }
                    try value(depth: depth + 1); try whitespace()
                    if take(125) { return }
                    guard take(44) else { throw ConversationImportFailure.malformed }; try whitespace()
                }
            case 91: // array
                index += 1; try whitespace()
                if take(93) { return }
                while true {
                    try value(depth: depth + 1); try whitespace()
                    if take(93) { return }
                    guard take(44) else { throw ConversationImportFailure.malformed }
                }
            case 34: _ = try string()
            default:
                let start = index
                while index < bytes.count, ![9, 10, 13, 32, 44, 93, 125].contains(bytes[index]) {
                    index += 1
                    guard index - start <= 128 else { throw ConversationImportFailure.malformed }
                }
                guard index > start else { throw ConversationImportFailure.malformed }
                // Foundation validates numeric and literal syntax after structural checks.
            }
        }
        mutating func take(_ byte: UInt8) -> Bool {
            guard index < bytes.count, bytes[index] == byte else { return false }
            index += 1; return true
        }
        mutating func string() throws -> Range<Int> {
            let start = index
            guard take(34) else { throw ConversationImportFailure.malformed }
            var checkAfter = index + 4_096
            while index < bytes.count {
                if index >= checkAfter { try Task.checkCancellation(); checkAfter = index + 4_096 }
                let byte = bytes[index]; index += 1
                guard index - start <= 800_000 else { throw ConversationImportFailure.oversized }
                if byte == 34 { return start..<index }
                if byte == 92 {
                    guard index < bytes.count else { throw ConversationImportFailure.malformed }
                    index += 1
                } else if byte < 32 { throw ConversationImportFailure.malformed }
            }
            throw ConversationImportFailure.malformed
        }
    }
}
