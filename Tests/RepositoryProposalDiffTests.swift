import XCTest
@testable import AsterionVeyra

final class RepositoryProposalDiffTests: XCTestCase {
    func testSingleReplacementKeepsExactLineNumbersAndEqualEdges() throws {
        let diff = try RepositoryProposalDiff(original: "first\nold\nlast\n", replacement: "first\nnew\nlast\n")
        XCTAssertEqual(diff.prefixLineCount, 1); XCTAssertEqual(diff.suffixLineCount, 1)
        XCTAssertEqual(diff.removedLineCount, 1); XCTAssertEqual(diff.addedLineCount, 1)
        XCTAssertEqual(diff.rendered, "- old 2 | old ⟦LF⟧\n+ new 2 | new ⟦LF⟧")
    }
    func testInsertionHasNoRemovedRows() throws {
        let diff = try RepositoryProposalDiff(original: "first\nlast\n", replacement: "first\nnew\nlast\n")
        XCTAssertEqual(diff.prefixLineCount, 1); XCTAssertEqual(diff.suffixLineCount, 1)
        XCTAssertTrue(diff.removedRows.isEmpty)
        XCTAssertEqual(diff.rendered, "+ new 2 | new ⟦LF⟧")
    }
    func testDeletionHasNoAddedRows() throws {
        let diff = try RepositoryProposalDiff(original: "first\nold\nlast\n", replacement: "first\nlast\n")
        XCTAssertEqual(diff.prefixLineCount, 1); XCTAssertEqual(diff.suffixLineCount, 1)
        XCTAssertTrue(diff.addedRows.isEmpty)
        XCTAssertEqual(diff.rendered, "- old 2 | old ⟦LF⟧")
    }
    func testIdenticalAndEmptyFilesHaveNoChangedRegion() throws {
        for text in ["", "one", "one\n", "\n\n"] {
            let diff = try RepositoryProposalDiff(original: text, replacement: text)
            XCTAssertEqual(diff.removedLineCount, 0); XCTAssertEqual(diff.addedLineCount, 0)
            XCTAssertEqual(diff.rendered, ""); XCTAssertEqual(diff.shortenedLineCount, 0)
        }
    }
    func testEmptyFileInsertionAndDeletionDoNotInventExtraLine() throws {
        let added = try RepositoryProposalDiff(original: "", replacement: "a\n")
        XCTAssertEqual(added.addedLineCount, 1); XCTAssertEqual(added.removedLineCount, 0)
        XCTAssertEqual(added.rendered, "+ new 1 | a ⟦LF⟧")
        let removed = try RepositoryProposalDiff(original: "a\n", replacement: "")
        XCTAssertEqual(removed.removedLineCount, 1)
        XCTAssertEqual(removed.rendered, "- old 1 | a ⟦LF⟧")
    }
    func testDisjointChangesIncludeEqualMiddleAndDoNotClaimMinimalDiff() throws {
        let diff = try RepositoryProposalDiff(original: "old\nsame\nbefore\n", replacement: "new\nsame\nafter\n")
        XCTAssertEqual(diff.removedLineCount, 3); XCTAssertEqual(diff.addedLineCount, 3)
        XCTAssertEqual(diff.prefixLineCount, 0); XCTAssertEqual(diff.suffixLineCount, 0)
        XCTAssertEqual(diff.removedRows.map(\.number), [1, 2, 3])
        XCTAssertEqual(diff.addedRows.map(\.number), [1, 2, 3])
        XCTAssertEqual(diff.removedRows[1].content, "same")
        XCTAssertTrue(diff.summary.contains("not a minimal diff"))
    }
    func testRepeatedLinesCannotOverlapPrefixAndSuffix() throws {
        let diff = try RepositoryProposalDiff(original: "a\na\n", replacement: "a\n")
        XCTAssertEqual(diff.prefixLineCount, 1); XCTAssertEqual(diff.suffixLineCount, 0)
        XCTAssertEqual(diff.rendered, "- old 2 | a ⟦LF⟧")
    }
    func testLineEndingOnlyChangeRemainsVisible() throws {
        let diff = try RepositoryProposalDiff(original: "same\r\n", replacement: "same\n")
        XCTAssertEqual(diff.rendered, "- old 1 | same ⟦CRLF⟧\n+ new 1 | same ⟦LF⟧")
    }
    func testMissingFinalNewlineIsNotTreatedAsEqual() throws {
        let diff = try RepositoryProposalDiff(original: "same", replacement: "same\n")
        XCTAssertEqual(diff.rendered, "- old 1 | same ⟦no newline⟧\n+ new 1 | same ⟦LF⟧")
    }
    func testBlankFinalLineIsNotConfusedWithFinalTerminator() throws {
        let diff = try RepositoryProposalDiff(original: "a\n", replacement: "a\n\n")
        XCTAssertEqual(diff.prefixLineCount, 1); XCTAssertEqual(diff.addedLineCount, 1)
        XCTAssertEqual(diff.rendered, "+ new 2 |  ⟦LF⟧")
    }
    func testCanonicalEquivalentUnicodeStillShowsDifferentBytes() throws {
        let diff = try RepositoryProposalDiff(original: "caf\u{00e9}\n", replacement: "cafe\u{0301}\n")
        XCTAssertEqual(diff.prefixLineCount, 0); XCTAssertEqual(diff.suffixLineCount, 0)
        XCTAssertEqual(Array(diff.removedRows[0].content.utf8), [99,97,102,195,169])
        XCTAssertEqual(Array(diff.addedRows[0].content.utf8), [99,97,102,101,204,129])
    }
    func testBackslashControlsUnicodeSeparatorsAndTrailingSpacesAreUnambiguous() throws {
        let diff = try RepositoryProposalDiff(original: "a\\n\t\rb\u{2028}c\u{2029}  \n", replacement: "safe\n")
        XCTAssertEqual(diff.removedRows[0].content, "a\\\\n\\t\\rb\\u{2028}c\\u{2029}\\u{0020}\\u{0020}")
        XCTAssertEqual(diff.removedLineCount, 1)
        XCTAssertFalse(diff.removedRows[0].content.contains("\t"))
        XCTAssertFalse(diff.removedRows[0].content.contains("\r"))
    }
    func testLeadingAndInteriorSpacesRemainUnchangedInPreview() throws {
        let diff = try RepositoryProposalDiff(original: "  a b\n", replacement: "new\n")
        XCTAssertEqual(diff.removedRows[0].content, "  a b")
    }
    func testEachSideKeepsItsOwnRowBudgetAndAccurateOmissions() throws {
        let old = (1...20).map { "old\($0)\n" }.joined()
        let new = (1...15).map { "new\($0)\n" }.joined()
        let diff = try RepositoryProposalDiff(original: old, replacement: new)
        XCTAssertEqual(diff.removedLineCount, 20); XCTAssertEqual(diff.addedLineCount, 15)
        XCTAssertEqual(diff.removedRows.count, 12); XCTAssertEqual(diff.addedRows.count, 12)
        XCTAssertEqual(diff.omittedRemovedLineCount, 8); XCTAssertEqual(diff.omittedAddedLineCount, 3)
        XCTAssertEqual(diff.addedRows.first?.number, 1); XCTAssertEqual(diff.addedRows.last?.number, 12)
        XCTAssertEqual(diff.shortenedLineCount, 0)
    }
    func testLongLinesShortenExplicitlyWithoutHidingOppositeSide() throws {
        let diff = try RepositoryProposalDiff(original: String(repeating: "a", count: 30_000), replacement: "new\n")
        XCTAssertEqual(diff.removedRows[0].content.utf8.count, 240)
        XCTAssertTrue(diff.removedRows[0].isShortened)
        XCTAssertEqual(diff.shortenedLineCount, 1)
        XCTAssertEqual(diff.omittedRemovedLineCount, 0)
        XCTAssertTrue(diff.rendered.contains("[line shortened]"))
        XCTAssertTrue(diff.rendered.contains("+ new 1 | new ⟦LF⟧"))
    }
    func testUnicodeClippingDoesNotSplitScalarOrExceedRenderedByteBudget() throws {
        let diff = try RepositoryProposalDiff(original: String(repeating: "🦋", count: 100), replacement: "x")
        XCTAssertEqual(diff.removedRows[0].content, String(repeating: "🦋", count: 60))
        XCTAssertTrue(diff.removedRows[0].isShortened)
        XCTAssertFalse(diff.removedRows[0].content.contains("\u{fffd}"))
    }
    func testEscapeExpansionCountsTowardRenderedLimit() throws {
        let diff = try RepositoryProposalDiff(original: String(repeating: " ", count: 100), replacement: "x")
        XCTAssertLessThanOrEqual(diff.removedRows[0].content.utf8.count, 240)
        XCTAssertEqual(diff.removedRows[0].content, String(repeating: "\\u{0020}", count: 30))
        XCTAssertTrue(diff.removedRows[0].isShortened)
    }
    func testExactRowLimitOnlyReportsActuallyOmittedRows() throws {
        let twelve = (1...12).map { "line\($0)\n" }.joined()
        let fits = try RepositoryProposalDiff(original: "", replacement: twelve)
        XCTAssertEqual(fits.addedRows.count, 12); XCTAssertEqual(fits.omittedAddedLineCount, 0)
        let exceeds = try RepositoryProposalDiff(original: "", replacement: twelve + "extra\n")
        XCTAssertEqual(exceeds.addedRows.count, 12); XCTAssertEqual(exceeds.omittedAddedLineCount, 1)
    }
    func testExactContentLimitIsNotMarkedShortenedAndEscapeTokensStayWhole() throws {
        let fits = try RepositoryProposalDiff(original: String(repeating: "a", count: 240), replacement: "new")
        XCTAssertFalse(fits.removedRows[0].isShortened)
        let exceeds = try RepositoryProposalDiff(original: String(repeating: "a", count: 241), replacement: "new")
        XCTAssertTrue(exceeds.removedRows[0].isShortened)
        let escaped = try RepositoryProposalDiff(original: String(repeating: "a", count: 239) + "\t", replacement: "new")
        XCTAssertEqual(escaped.removedRows[0].content, String(repeating: "a", count: 239))
        XCTAssertTrue(escaped.removedRows[0].isShortened)
    }
    func testWorstCaseNewlineHeavyInputKeepsOutputBounded() throws {
        let diff = try RepositoryProposalDiff(original: String(repeating: "\n", count: 30_000), replacement: String(repeating: "x\n", count: 15_000))
        XCTAssertEqual(diff.removedLineCount, 30_000); XCTAssertEqual(diff.addedLineCount, 15_000)
        XCTAssertEqual(diff.omittedRemovedLineCount, 29_988); XCTAssertEqual(diff.omittedAddedLineCount, 14_988)
        XCTAssertLessThanOrEqual(diff.rendered.utf8.count, 8_000)
    }
    func testUnsafeAndOversizedInputsFailClosedInsteadOfGeneratingPreview() {
        for input in [String(repeating: "a", count: 30_001), "a\0b", "a\u{202e}b", "password=synthetic"] {
            XCTAssertThrowsError(try RepositoryProposalDiff(original: input, replacement: "new"))
            XCTAssertThrowsError(try RepositoryProposalDiff(original: "old", replacement: input))
        }
    }
    func testComparisonIsDeterministicAndDoesNotMutateInput() throws {
        let original = "first\r\nold\t \nlast"
        let replacement = "first\r\nnew\nlast"
        let a = try RepositoryProposalDiff(original: original, replacement: replacement)
        let b = try RepositoryProposalDiff(original: original, replacement: replacement)
        XCTAssertEqual(a, b)
        XCTAssertEqual(original, "first\r\nold\t \nlast")
        XCTAssertEqual(replacement, "first\r\nnew\nlast")
    }
}
