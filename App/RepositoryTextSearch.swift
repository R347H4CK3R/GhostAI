import Foundation

/// Deterministic local excerpts from an already verified and screened file.
/// This value has no transport, cache, credential or authority of its own.
struct RepositoryTextSearch {
    private let query: [Unicode.Scalar]

    init(query: String) throws {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              query.utf8.count <= 128, MemorySearch.canSave(query),
              query.unicodeScalars.allSatisfy({
                  !CharacterSet.controlCharacters.contains($0) && !CharacterSet.newlines.contains($0)
                      && !CharacterSet.illegalCharacters.contains($0)
                      && ![0x202A, 0x202B, 0x202C, 0x202D, 0x202E, 0x2066, 0x2067, 0x2068, 0x2069].contains($0.value)
              }) else { throw RepositoryToolFailure.invalidQuery }
        // Do not trim, fold case or normalize the actual literal.
        self.query = Array(query.unicodeScalars)
    }

    func excerpt(from text: String) -> String {
        // CRLF is one Swift Character: split LF scalars, not Characters.
        let raw = text.unicodeScalars.split(separator: "\n", omittingEmptySubsequences: false)
        var lines = raw.enumerated().map { index, part -> [Unicode.Scalar] in
            var scalars = Array(part)
            if index < raw.count - 1 && scalars.last == "\r" { scalars.removeLast() }
            return scalars
        }
        if lines.isEmpty { lines = [[]] }
        var matchingLines = 0
        var anchors: [Int] = []
        for (index, line) in lines.enumerated() {
            if firstMatch(in: line) != nil {
                matchingLines += 1
                if anchors.count < 3 { anchors.append(index) }
            }
        }
        guard !anchors.isEmpty else {
            return "Literal search inspected all \(lines.count) lines in this one file: no matching lines. No other files were searched."
        }
        var selected = Set<Int>()
        for anchor in anchors {
            for index in max(0, anchor - 1)...min(lines.count - 1, anchor + 1) { selected.insert(index) }
        }
        var output = ["Literal search in this one file. Matching lines: \(matchingLines); selected anchors: \(anchors.count). No other files were searched."]
        if matchingLines > anchors.count {
            let extra = matchingLines - anchors.count
            output.append("\(extra) additional matching \(extra == 1 ? "line not selected as an anchor" : "lines not selected as anchors"); context may include them.")
        }
        var previous: Int?
        for index in selected.sorted() {
            if let previous, index > previous + 1 { output.append("[Non-context lines omitted]") }
            output.append("L\(index + 1): " + render(lines[index], match: firstMatch(in: lines[index])))
            previous = index
        }
        return output.joined(separator: "\n")
    }

    private func firstMatch(in line: [Unicode.Scalar]) -> Int? {
        guard line.count >= query.count else { return nil }
        // At most 60,000 source bytes × 128 query bytes. Exact scalar comparison
        // avoids String's canonical-equivalence matching and regex behavior.
        for start in 0...(line.count - query.count) where line[start] == query[0] {
            if line[start..<(start + query.count)].elementsEqual(query) { return start }
        }
        return nil
    }

    private func render(_ line: [Unicode.Scalar], match: Int?) -> String {
        let start = max(0, (match ?? 0) - 56)
        let end = min(line.count, start + 240)
        let body = line[start..<end].map { scalar -> String in
            switch scalar.value {
            case 0x0D: return "\\r"
            case 0x2028: return "\\u{2028}"
            case 0x2029: return "\\u{2029}"
            default: return String(scalar)
            }
        }.joined()
        return (start > 0 ? "[line prefix omitted] " : "") + body
            + (end < line.count ? " [line suffix omitted]" : "")
    }
}
