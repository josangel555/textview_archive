import Testing
import Foundation
@testable import ViewerCore

/// Host coverage for the spell → CM6 diagnostic mapping (TSK-1146). The squiggle
/// RENDER (setDiagnostics → lintGutter) is already built + VM-validated; this is
/// the host-validated producer the editor surface feeds into it.
struct SpellDiagnosticMappingTests {

    private func issue(_ word: String, loc: Int, len: Int,
                       suggestions: [String] = []) -> SpellingIssue {
        // `loc` may be NSNotFound (Int.max) for the invalid-range case — guard
        // the column derivation against an Int overflow trap.
        let col = loc == NSNotFound ? 1 : loc + 1
        return SpellingIssue(word: word, range: NSRange(location: loc, length: len),
                             line: 1, column: col, suggestions: suggestions)
    }

    @Test func mapsRangeToFromTo_infoSeverity_spellSource() {
        let d = SpellDiagnosticMapping.cmDiagnostics(from: [issue("teh", loc: 10, len: 3)])
        #expect(d.count == 1)
        #expect(d[0].from == 10)          // range.location → UTF-16 offset (CM6 coord)
        #expect(d[0].to == 13)            // location + length
        #expect(d[0].severity == .info)   // spelling is advisory, not an error
        #expect(d[0].source == "spell")   // distinguishes from LSP diagnostics
        #expect(d[0].message.contains("teh"))
    }

    @Test func suggestions_appendDidYouMean() {
        let d = SpellDiagnosticMapping.cmDiagnostics(
            from: [issue("teh", loc: 0, len: 3, suggestions: ["the", "tech"])])
        #expect(d[0].message.contains("did you mean"))
        #expect(d[0].message.contains("the"))
    }

    @Test func noSuggestions_noSuffix() {
        let d = SpellDiagnosticMapping.cmDiagnostics(from: [issue("zzx", loc: 0, len: 3)])
        #expect(!d[0].message.contains("did you mean"))
    }

    @Test func suggestionsCappedAtThree() {
        let d = SpellDiagnosticMapping.cmDiagnostics(
            from: [issue("teh", loc: 0, len: 3, suggestions: ["s1", "s2", "s3", "s4", "s5"])])
        #expect(d[0].message.contains("s1, s2, s3"))
        #expect(!d[0].message.contains("s4"))   // capped at 3
    }

    @Test func dropsNotFoundRange() {
        let d = SpellDiagnosticMapping.cmDiagnostics(from: [issue("x", loc: NSNotFound, len: 1)])
        #expect(d.isEmpty)
    }

    @Test func dropsEmptyRange() {
        let d = SpellDiagnosticMapping.cmDiagnostics(from: [issue("x", loc: 5, len: 0)])
        #expect(d.isEmpty)
    }

    @Test func multipleIssues_preserveOrder() {
        let d = SpellDiagnosticMapping.cmDiagnostics(from: [
            issue("aaa", loc: 0, len: 3), issue("bbb", loc: 10, len: 3),
        ])
        #expect(d.count == 2)
        #expect(d[0].from == 0)
        #expect(d[1].from == 10)
    }
}
