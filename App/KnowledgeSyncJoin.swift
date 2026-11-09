import Foundation

/// Unwired foundation for a future document-v2 knowledge join. This is NOT the v1
/// merge or a cache migration: no production caller may switch semantics implicitly.
///
/// Joins one exact account/project scope. Callers must supply all retained history
/// (including base), and separately enforce document-wide scope/record/encoded-byte
/// limits. Compatible states within capacity form a remove-wins join; conflicts and
/// quota failures throw without returning a partial result. Original v1 validation,
/// including its date ceiling and time-dependent clear-before bound, remains in force.
enum KnowledgeSyncJoin {
    struct Result: Sendable {
        let snapshot: KnowledgeSyncSnapshot
        /// Newly retained markers caused by a cutoff, excluding existing markers.
        let cutoffSuppressedIDs: [String]
        /// Distinct candidate IDs hidden by the resulting suppression set.
        let removedEntryIDs: [String]
    }

    static func normalize(_ snapshot: KnowledgeSyncSnapshot) throws -> Result {
        try join([snapshot])
    }

    /// Empty identity is an empty snapshot with the same scope, not an unbound array.
    /// Diagnostics describe this invocation; only `snapshot` is the join state.
    static func join(_ snapshots: [KnowledgeSyncSnapshot]) throws -> Result {
        guard let first = snapshots.first else { throw KnowledgeFailure.invalidScope }

        // Validate every original before deletion or normalization can conceal bad data.
        for snapshot in snapshots {
            _ = try snapshot.validated()
            try validateExactBinding(snapshot)
        }
        var repository = first.repository
        var cutoff: Date?
        var suppressed = Set<String>()
        for snapshot in snapshots {
            guard wireEqual(first.accountID, snapshot.accountID), wireEqual(first.project, snapshot.project) else {
                throw KnowledgeFailure.invalidScope
            }
            if let known = repository, let incoming = snapshot.repository, !wireEqual(known, incoming) {
                throw KnowledgeFailure.invalidScope
            }
            repository = repository ?? snapshot.repository
            if let incoming = snapshot.clearBefore {
                cutoff = cutoff.map { dateMax($0, incoming) } ?? incoming
            }
            suppressed.formUnion(snapshot.suppressedIDs)
        }
        let existingSuppression = suppressed
        var entries: [String: KnowledgeEntry] = [:]
        for snapshot in snapshots {
            for entry in snapshot.entries {
                // Keep immutable compatibility fail-closed, even for hidden candidates.
                if let previous = entries[entry.id] {
                    entries[entry.id] = try mergeEntry(previous, entry)
                } else {
                    entries[entry.id] = entry
                }
                // Inspect every observation, before a later duplicate can obscure it.
                let observation = entry.kind == .selectedFile ? entry.cachedAt : entry.sourceDate
                if let cutoff, observation.timeIntervalSinceReferenceDate <= cutoff.timeIntervalSinceReferenceDate {
                    suppressed.insert(entry.id)
                }
            }
        }

        guard suppressed.count <= KnowledgePolicy.maximumTombstones else { throw KnowledgeFailure.quota }
        let removed = entries.keys.filter { suppressed.contains($0) }.sorted(by: wireLess)
        let surviving = entries.values.filter { !suppressed.contains($0.id) }.sorted { wireLess($0.id, $1.id) }
        guard surviving.count <= KnowledgePolicy.maximumRecords else { throw KnowledgeFailure.quota }
        let result = KnowledgeSyncSnapshot(accountID: first.accountID, project: first.project, repository: repository,
                                           entries: surviving, suppressedIDs: suppressed.sorted(by: wireLess), clearBefore: cutoff)
        _ = try result.validated() // Also checks the complete source-byte budget, never evicts.
        return Result(snapshot: result,
                      cutoffSuppressedIDs: suppressed.subtracting(existingSuppression).sorted(by: wireLess),
                      removedEntryIDs: removed)
    }

    private static func validateExactBinding(_ snapshot: KnowledgeSyncSnapshot) throws {
        // The legacy validator uses Swift's canonical-equivalent String equality.
        // Preserve its constraints and strengthen bindings to exact stored bytes.
        if let repository = snapshot.repository {
            let expected: String
            if snapshot.project.hasPrefix("GitHub account ") {
                guard let separator = snapshot.project.range(of: ": ") else { throw KnowledgeFailure.invalidScope }
                expected = String(snapshot.project[separator.upperBound...])
            } else {
                expected = snapshot.project
            }
            guard wireEqual(repository, expected) else { throw KnowledgeFailure.invalidScope }
        }
        for entry in snapshot.entries where entry.source.origin == .repository {
            guard wireEqual(entry.source.repositoryName, snapshot.repository) else { throw KnowledgeFailure.invalidScope }
        }
    }

    private static func mergeEntry(_ left: KnowledgeEntry, _ right: KnowledgeEntry) throws -> KnowledgeEntry {
        guard wireEqual(left.id, right.id), left.kind == right.kind,
              wireEqual(left.text, right.text), left.byteCount == right.byteCount else { throw KnowledgeFailure.changedSource }
        let source: KnowledgeSource
        let sourceDate: Date
        switch left.kind {
        case .selectedFile:
            guard left.source.origin == .selectedFile, right.source.origin == .selectedFile,
                  left.source.revision != nil, wireEqual(left.source.revision, right.source.revision),
                  left.source.repositoryName == nil, right.source.repositoryName == nil else { throw KnowledgeFailure.changedSource }
            let leftLength = left.source.label.utf8.count, rightLength = right.source.label.utf8.count
            source = leftLength < rightLength || (leftLength == rightLength && wireLess(left.source.label, right.source.label))
                ? left.source : right.source
            sourceDate = dateMin(left.sourceDate, right.sourceDate)
        case .research:
            guard sourceEqual(left.source, right.source) else { throw KnowledgeFailure.changedSource }
            source = left.source; sourceDate = dateMin(left.sourceDate, right.sourceDate)
        case .conversation, .action:
            guard sourceEqual(left.source, right.source),
                  left.sourceDate.timeIntervalSinceReferenceDate.bitPattern == right.sourceDate.timeIntervalSinceReferenceDate.bitPattern else {
                throw KnowledgeFailure.changedSource
            }
            source = left.source; sourceDate = left.sourceDate
        }
        return KnowledgeEntry(id: left.id, kind: left.kind, text: left.text, source: source, sourceDate: sourceDate,
                              cachedAt: dateMin(left.cachedAt, right.cachedAt), byteCount: left.byteCount)
    }

    private static func sourceEqual(_ lhs: KnowledgeSource, _ rhs: KnowledgeSource) -> Bool {
        lhs.origin == rhs.origin && wireEqual(lhs.label, rhs.label)
            && wireEqual(lhs.revision, rhs.revision) && wireEqual(lhs.repositoryName, rhs.repositoryName)
    }

    private static func wireEqual(_ lhs: String, _ rhs: String) -> Bool { lhs.utf8.elementsEqual(rhs.utf8) }

    private static func wireEqual(_ lhs: String?, _ rhs: String?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil): return true
        case let (left?, right?): return wireEqual(left, right)
        default: return false
        }
    }

    private static func wireLess(_ lhs: String, _ rhs: String) -> Bool { lhs.utf8.lexicographicallyPrecedes(rhs.utf8) }

    private static func dateLess(_ lhs: Date, _ rhs: Date) -> Bool {
        let left = lhs.timeIntervalSinceReferenceDate, right = rhs.timeIntervalSinceReferenceDate
        return left == right ? left.bitPattern < right.bitPattern : left < right
    }

    // Return the original Date. Never round-trip through Unix seconds or invent bits.
    private static func dateMin(_ lhs: Date, _ rhs: Date) -> Date { dateLess(lhs, rhs) ? lhs : rhs }
    private static func dateMax(_ lhs: Date, _ rhs: Date) -> Date { dateLess(lhs, rhs) ? rhs : lhs }
}
