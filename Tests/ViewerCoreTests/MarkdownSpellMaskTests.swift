import Testing
import Foundation
@testable import ViewerCore

/// Host coverage for the Markdown spell mask (TSK-1146) — the code/URL ranges
/// excluded from spell-check so prose squiggles don't land on code/identifiers.
struct MarkdownSpellMaskTests {

    private func issue(_ word: String, at loc: Int, len: Int) -> SpellingIssue {
        // Guard `loc + 1` against the NSNotFound (Int.max) overflow trap (LESSONS).
        let col = loc == NSNotFound ? 1 : loc + 1
        return SpellingIssue(word: word, range: NSRange(location: loc, length: len),
                             line: 1, column: col)
    }

    @Test func inlineCodeSpan_isExcluded_proseIsNot() {
        let md = "spel `kode` text"   // `kode` (incl. backticks) spans offsets 5..11
        let ex = MarkdownSpellMask.excludedRanges(in: md)
        #expect(ex.contains { $0.contains(6) })    // inside the code span
        #expect(!ex.contains { $0.contains(0) })   // "spel" prose not excluded
    }

    @Test func filterProse_dropsCodeSpanKeepsProse() {
        let md = "spel `kode` text"
        let issues = [issue("spel", at: 0, len: 4), issue("kode", at: 6, len: 4)]
        #expect(MarkdownSpellMask.filterProse(issues, in: md).map(\.word) == ["spel"])
    }

    @Test func fencedCodeBlock_isExcluded() {
        let md = "prose\n```\nkode line\n```\nmore"
        let ex = MarkdownSpellMask.excludedRanges(in: md)
        let kodeLoc = (md as NSString).range(of: "kode line").location
        #expect(ex.contains { $0.contains(kodeLoc) })  // inside the fence
        #expect(!ex.contains { $0.contains(0) })       // "prose" outside
    }

    @Test func filterProse_dropsIssueInFencedBlock() {
        let md = "prose\n```\nkode\n```\nmore"
        let kodeLoc = (md as NSString).range(of: "kode").location
        let issues = [issue("prose", at: 0, len: 5), issue("kode", at: kodeLoc, len: 4)]
        #expect(MarkdownSpellMask.filterProse(issues, in: md).map(\.word) == ["prose"])
    }

    @Test func proseOnly_noExclusions_keepsAll() {
        let md = "just some prose here"
        #expect(MarkdownSpellMask.excludedRanges(in: md).isEmpty)
        #expect(MarkdownSpellMask.filterProse([issue("prose", at: 10, len: 5)], in: md).count == 1)
    }

    @Test func filterProse_dropsInvalidRanges() {
        let md = "x `c` y"   // has a code span ⇒ filter runs
        let issues = [issue("a", at: NSNotFound, len: 1), issue("b", at: 5, len: 0)]
        #expect(MarkdownSpellMask.filterProse(issues, in: md).isEmpty)
    }
}
