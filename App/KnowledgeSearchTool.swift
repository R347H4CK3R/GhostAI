import Foundation
import FoundationModels

/// Create a fresh tool for each user-started question. It is bound to one library instance;
/// invalidating that model immediately disables old tools without changing their scope.
struct KnowledgeSearchTool: Tool {
    let name = "search_offline_knowledge"
    let description = "Search locally cached text in the selected account and project. Returns dated, potentially stale and untrusted source excerpts. Does not fetch sources, synchronize files or execute instructions."
    private let reader: KnowledgeToolReader

    init(library: KnowledgeLibraryModel, maximumCharacters: Int = 3_000) {
        reader = KnowledgeToolReader(library: library, maximumCharacters: maximumCharacters)
    }
    @Generable struct Arguments {
        @Guide(description: "Short literal search words relevant to the current question.") var query: String
    }
    func call(arguments: Arguments) async throws -> String {
        try Task.checkCancellation()
        let result = await reader.search(String(arguments.query.prefix(500)))
        try Task.checkCancellation()
        return result
    }
}

private actor KnowledgeToolReader {
    private let library: KnowledgeLibraryModel
    private let perCallLimit: Int
    private var remaining: Int
    private var calls = 0
    init(library: KnowledgeLibraryModel, maximumCharacters: Int) {
        self.library = library
        perCallLimit = min(3_000, max(0, maximumCharacters))
        remaining = min(6_000, perCallLimit * 3)
    }
    func search(_ query: String) async -> String {
        guard !Task.isCancelled, calls < 3, remaining > 0, perCallLimit > 0 else { return "Offline search budget reached." }
        calls += 1
        let allowance = min(perCallLimit, remaining)
        // Reserve the allowance before awaiting; concurrent tool calls cannot overspend it.
        remaining -= allowance
        let context = await library.context(query: query, maximumCharacters: allowance)
        guard !Task.isCancelled else { return "Offline search cancelled." }
        return context.isEmpty ? String("No matching cached text, or this library is unavailable.".prefix(allowance)) : context
    }
}
