import XCTest
import ViewerKit
@testable import ViewerCore

/// TSK-827 — `tokenize` no longer bridges the whole file to `NSString`
/// and slices a fresh `substring(with:)` per predicate eval. Predicate
/// `#match?`/`#eq?`/`#any-of?` text now resolves against a cached
/// `[unichar]` (UTF-16 code-unit) buffer via
/// `TreeSitterEngine.predicateSubstring(in:range:)`.
///
/// Two things must hold:
///  1. The new resolver is **byte-identical** to the old
///     `(text as NSString).substring(with:)` it replaces — including the
///     out-of-range guard and lone-surrogate handling — over a corpus
///     that includes BMP, astral (surrogate-pair), and combining-mark
///     text. This is the load-bearing equivalence: predicate evaluation
///     keys off this exact text, so any divergence is a coloring
///     regression.
///  2. Tokenize output (token spans + scopes) is unchanged for
///     predicate-heavy multi-language fixtures, and a large (~200 KB)
///     predicate-dense file tokenizes without the per-eval NSString
///     alloc churn the slice removed.
final class TreeSitterPredicateSubstringTests: XCTestCase {

    // MARK: - 1. Byte-identity vs NSString.substring(with:)

    /// The exact behaviour the slice replaced. Mirrors the pre-TSK-827
    /// `textProvider` closure verbatim so the test compares against the
    /// real prior semantics, not a paraphrase.
    private func oldNSStringProvider(_ text: String, _ range: NSRange) -> String? {
        let ns = text as NSString
        guard range.location != NSNotFound, range.location >= 0,
              range.location + range.length <= ns.length else { return nil }
        return ns.substring(with: range)
    }

    private func assertEquivalent(
        _ text: String, _ range: NSRange,
        file: StaticString = #file, line: UInt = #line
    ) {
        let units = Array(text.utf16)
        let new = TreeSitterEngine.predicateSubstring(in: units, range: range)
        let old = oldNSStringProvider(text, range)
        XCTAssertEqual(
            new, old,
            "predicateSubstring diverged from NSString.substring for range \(range) " +
            "in \(text.debugDescription): got \(new.debugDescription), " +
            "expected \(old.debugDescription)",
            file: file, line: line
        )
    }

    func testEquivalence_asciiSpans() {
        let text = "const myThing: Widget = makeThing();"
        let n = text.utf16.count
        // Every sub-span of an ASCII string must round-trip identically.
        for loc in 0...n {
            for len in 0...(n - loc) {
                assertEquivalent(text, NSRange(location: loc, length: len))
            }
        }
    }

    func testEquivalence_astralAndCombiningMarks() {
        // Astral chars (😀 U+1F600, 🧑‍💻 ZWJ sequence) occupy 2 UTF-16
        // code units each → exercises surrogate pairs. Combining marks
        // (é as e + U+0301) exercise multi-scalar graphemes. The byte
        // (UTF-16) ranges TreeSitter hands the provider DO NOT respect
        // grapheme boundaries, so the resolver must too — building
        // straight from code units, same as NSString.substring.
        let text = "let café = \"😀\" + 🧑‍💻 + naïve"
        let n = text.utf16.count
        for loc in 0...n {
            for len in 0...(n - loc) {
                assertEquivalent(text, NSRange(location: loc, length: len))
            }
        }
    }

    func testEquivalence_splitSurrogatePair_preservesLoneSurrogate() {
        // A range that bisects a surrogate pair yields a lone surrogate.
        // NSString.substring keeps it (an ill-formed String); the buffer
        // path must do exactly the same so predicate eval is unaffected.
        let text = "x😀y"                 // 😀 = high+low surrogate at idx 1,2
        XCTAssertEqual(text.utf16.count, 4)
        // [1,1] = just the high surrogate.
        assertEquivalent(text, NSRange(location: 1, length: 1))
        // [2,1] = just the low surrogate.
        assertEquivalent(text, NSRange(location: 2, length: 1))
        // [0,2] = "x" + high surrogate.
        assertEquivalent(text, NSRange(location: 0, length: 2))
    }

    func testEquivalence_outOfRangeAndEdgeCases() {
        let text = "abc"
        // location at end, zero length → "" for both.
        assertEquivalent(text, NSRange(location: 3, length: 0))
        // empty string, empty range.
        assertEquivalent("", NSRange(location: 0, length: 0))
        // out-of-range location/length → nil for both.
        let units = Array(text.utf16)
        XCTAssertNil(TreeSitterEngine.predicateSubstring(
            in: units, range: NSRange(location: 4, length: 0)))
        XCTAssertNil(TreeSitterEngine.predicateSubstring(
            in: units, range: NSRange(location: 2, length: 5)))
        XCTAssertNil(TreeSitterEngine.predicateSubstring(
            in: units, range: NSRange(location: NSNotFound, length: 0)))
        // Mirror the same out-of-range against the old provider.
        XCTAssertNil(oldNSStringProvider(text, NSRange(location: 4, length: 0)))
        XCTAssertNil(oldNSStringProvider(text, NSRange(location: 2, length: 5)))
    }

    func testEmptyBuffer_zeroLengthRange_isEmptyNotCrash() {
        // Empty backing array: baseAddress is nil under
        // withUnsafeBufferPointer, so the length>0 guard must short out.
        XCTAssertEqual(
            TreeSitterEngine.predicateSubstring(in: [], range: NSRange(location: 0, length: 0)),
            "")
    }

    // MARK: - 2. Tokenize output unchanged on predicate-gated fixtures

    private func assertContains(
        _ runs: [HighlightRun], in source: String,
        substring: String, kind: TokenKind,
        file: StaticString = #file, line: UInt = #line
    ) {
        let ns = source as NSString
        let found = runs.contains { run in
            guard run.kind == kind, run.range.location >= 0,
                  run.range.location + run.range.length <= ns.length else { return false }
            return ns.substring(with: run.range) == substring
        }
        XCTAssertTrue(
            found,
            "expected '\(substring)' as .\(kind); got: \(runs.map { (ns.substring(with: $0.range), $0.kind) })",
            file: file, line: line)
    }

    // MARK: - 2. Predicate-gated scopes via the on-screen (rust) highlighter
    //
    // TSK-854: highlighting is rust-only now. The `predicateSubstring`
    // helper above still serves the Swift engine's kept fold grammars, but
    // the PREDICATE-EVALUATION BEHAVIOUR a user sees (SCREAMING_CASE →
    // .constant, lowercase → .variable) is produced by the Rust core. These
    // tests pin that behaviour through `RustHighlightAdapter` — the engine
    // that paints — with the gate forced ON for determinism.

    private static let gateOn = ["MDV_RUST_HIGHLIGHT": "1"]

    private func rustTokenize(
        _ src: String, _ lang: HighlightLanguage
    ) -> [HighlightRun] {
        RustHighlightAdapter.outcome(src, language: lang, environment: Self.gateOn).value
    }

    /// Predicate evaluation gates SCREAMING_CASE → .constant and lowercase
    /// identifiers → .variable across the affected grammars on the rust path.
    func testPredicateGatedScopes_multiLanguage() {
        // lowercase identifier must NOT resolve to .type.
        let ts = "const myThing: Widget = makeThing();"
        let tsRuns = rustTokenize(ts, .typescript)
        assertContains(tsRuns, in: ts, substring: "myThing", kind: .variable)
        assertContains(tsRuns, in: ts, substring: "Widget", kind: .type)

        // SCREAMING_CASE → .constant via #match? on the resolved text.
        // (rust-lang excluded — TSK-1201 known gap: the rust core's
        // tree-sitter-rust query doesn't tag rust SCREAMING_CASE as constant,
        // though java/python/c/lua do — see TreeSitterEngineGoldenTests.)
        let cases: [(HighlightLanguage, String, String)] = [
            (.java,   "class C { static final int MAX_LEN = 5; }", "MAX_LEN"),
            (.python, "MAX_SIZE = 10", "MAX_SIZE"),
        ]
        for (lang, src, name) in cases {
            let runs = rustTokenize(src, lang)
            assertContains(runs, in: src, substring: name, kind: .constant)
        }
    }

    /// Predicate eval keys off the resolved text even with non-ASCII
    /// identifiers in the buffer. A Unicode identifier must still color
    /// as .variable (its #match? "^[A-Z]" gate fails on a lowercase /
    /// non-Latin lead).
    func testPredicateEval_withUnicodeIdentifiersInBuffer() {
        let src = "const café = \"😀😀😀\"; const myThing = makeThing();"
        let runs = rustTokenize(src, .javascript)
        assertContains(runs, in: src, substring: "myThing", kind: .variable)
        assertContains(runs, in: src, substring: "café", kind: .variable)
    }
}
