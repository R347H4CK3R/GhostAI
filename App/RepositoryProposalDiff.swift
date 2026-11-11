import Foundation

/// Local review aid only. Identical leading/trailing lines are excluded; the
/// remaining middle is one region, deliberately not a minimal edit script.
struct RepositoryProposalDiff: Equatable, Sendable {
    struct Row: Equatable, Sendable {
        let number: Int
        let content: String
        let ending: String
        let isShortened: Bool

        fileprivate func rendered(side: String) -> String {
            "\(side) \(number) | \(content)\(isShortened ? " … [line shortened]" : "") ⟦\(ending)⟧"
        }
    }
    let prefixLineCount: Int
    let suffixLineCount: Int
    let removedLineCount: Int
    let addedLineCount: Int
    let removedRows: [Row]
    let addedRows: [Row]
    var omittedRemovedLineCount: Int { removedLineCount - removedRows.count }
    var omittedAddedLineCount: Int { addedLineCount - addedRows.count }
    var shortenedLineCount: Int { (removedRows + addedRows).filter(\.isShortened).count }
    var rendered: String {
        (removedRows.map { $0.rendered(side: "- old") } + addedRows.map { $0.rendered(side: "+ new") }).joined(separator: "\n")
    }
    var summary: String {
        "One changed region, not a minimal diff: \(removedLineCount) old lines and \(addedLineCount) new lines. "
        + "\(prefixLineCount) identical leading and \(suffixLineCount) identical trailing lines are outside this region. "
        + "Equal lines between separate edits remain inside it."
    }
    var limitsSummary: String {
        "Preview shows \(removedRows.count) of \(removedLineCount) old lines and \(addedRows.count) of \(addedLineCount) new lines. "
        + "Omitted: \(omittedRemovedLineCount) old and \(omittedAddedLineCount) new lines. "
        + "Shortened displayed lines: \(shortenedLineCount). Review both complete files below."
    }

    init(original: String, replacement: String) throws {
        // Use the same eligibility boundary as publication, including size and
        // possible-secret checks, before allocating line/preview structures.
        try RepositoryProposalPolicy.validateText(original)
        try RepositoryProposalPolicy.validateText(replacement)
        let old = Self.lines(original), new = Self.lines(replacement)
        var prefix = 0
        while prefix < min(old.count, new.count), old[prefix].bytes == new[prefix].bytes { prefix += 1 }
        var suffix = 0
        while suffix < min(old.count, new.count) - prefix,
              old[old.count - 1 - suffix].bytes == new[new.count - 1 - suffix].bytes { suffix += 1 }
        prefixLineCount = prefix; suffixLineCount = suffix
        removedLineCount = old.count - prefix - suffix
        addedLineCount = new.count - prefix - suffix
        removedRows = old[prefix..<(old.count - suffix)].prefix(12).enumerated().map {
            Self.row($0.element, number: prefix + $0.offset + 1)
        }
        addedRows = new[prefix..<(new.count - suffix)].prefix(12).enumerated().map {
            Self.row($0.element, number: prefix + $0.offset + 1)
        }
    }

    private struct Line {
        let bytes: [UInt8] // Exact source bytes, including the line terminator.
        let text: String
        let ending: String
    }
    private static func lines(_ text: String) -> [Line] {
        let bytes = Array(text.utf8)
        var result: [Line] = [], start = 0
        for end in bytes.indices where bytes[end] == 10 {
            let crlf = end > start && bytes[end - 1] == 13
            result.append(Line(bytes: Array(bytes[start...end]),
                text: String(decoding: bytes[start..<(crlf ? end - 1 : end)], as: UTF8.self),
                ending: crlf ? "CRLF" : "LF"))
            start = end + 1
        }
        if start < bytes.count {
            result.append(Line(bytes: Array(bytes[start...]), text: String(decoding: bytes[start...], as: UTF8.self), ending: "no newline"))
        }
        return result
    }
    private static func row(_ line: Line, number: Int) -> Row {
        let scalars = Array(line.text.unicodeScalars)
        var trailingSpaces = scalars.count
        while trailingSpaces > 0, scalars[trailingSpaces - 1].value == 32 { trailingSpaces -= 1 }
        var content = "", bytes = 0, consumed = 0
        for (index, scalar) in scalars.enumerated() {
            let token: String
            switch scalar.value {
            case 92: token = "\\\\"
            case 9: token = "\\t"
            case 13: token = "\\r"
            case 0x2028: token = "\\u{2028}"
            case 0x2029: token = "\\u{2029}"
            case 32 where index >= trailingSpaces: token = "\\u{0020}"
            default: token = String(scalar)
            }
            let count = token.utf8.count
            guard bytes + count <= 240 else { break }
            content += token; bytes += count; consumed += 1
        }
        return Row(number: number, content: content, ending: line.ending, isShortened: consumed < scalars.count)
    }
}
