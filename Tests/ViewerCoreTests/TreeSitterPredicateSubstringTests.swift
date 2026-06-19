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

    /// Predicate evaluation still gates SCREAMING_CASE → .constant and
    /// lowercase identifiers → .variable across the affected grammars.
    /// If the buffer resolver returned wrong text, `#match? "^[A-Z]"`
    /// would mis-fire and these would flip.
    func testPredicateGatedScopes_multiLanguage() {
        // lowercase identifier must NOT resolve to .type (the ^[A-Z]
        // @type predicate must reject it via the resolved text).
        let ts = "const myThing: Widget = makeThing();"
        let tsRuns = TreeSitterEngine.shared.tokenize(ts, language: .typescript)
        assertContains(tsRuns, in: ts, substring: "myThing", kind: .variable)
        assertContains(tsRuns, in: ts, substring: "Widget", kind: .type)

        // SCREAMING_CASE → .constant via #match? on the resolved text.
        let cases: [(HighlightLanguage, String, String)] = [
            (.rust,   "const MAX_SIZE: u32 = 64;\nfn main() {}", "MAX_SIZE"),
            (.java,   "class C { static final int MAX_LEN = 5; }", "MAX_LEN"),
            (.python, "MAX_SIZE = 10", "MAX_SIZE"),
        ]
        for (lang, src, name) in cases {
            let runs = TreeSitterEngine.shared.tokenize(src, language: lang)
            assertContains(runs, in: src, substring: name, kind: .constant)
        }
    }

    /// Predicate eval keys off the resolved text even with non-ASCII
    /// identifiers in the buffer. A Unicode identifier must still color
    /// as .variable (its #match? "^[A-Z]" gate fails on a lowercase /
    /// non-Latin lead) — proving the surrogate/combining-aware resolver
    /// feeds the predicate the right bytes.
    func testPredicateEval_withUnicodeIdentifiersInBuffer() {
        // The astral string literal forces surrogate pairs into the
        // buffer ahead of the gated identifier; an off-by-one in the
        // UTF-16-offset slice would mis-resolve the identifier text.
        let src = "const café = \"😀😀😀\"; const myThing = makeThing();"
        let runs = TreeSitterEngine.shared.tokenize(src, language: .javascript)
        assertContains(runs, in: src, substring: "myThing", kind: .variable)
        assertContains(runs, in: src, substring: "café", kind: .variable)
    }

    // MARK: - 3. Large predicate-dense file — no per-eval NSString churn

    /// A ~200 KB file whose every line carries a SCREAMING_CASE constant
    /// (a `#match?`-gated capture) so the predicate path runs thousands
    /// of times. The slice resolves each against the cached buffer
    /// instead of allocating an NSString substring per eval. We pin two
    /// things: (a) the gated scope still fires (correctness under load),
    /// and (b) a generous wall-clock floor catches a regression back to
    /// per-eval NSString allocation (an order-of-magnitude blowup), not
    /// single-ms drift.
    func test_largePredicateDenseFile_tokenizesAndGatesConstants() {
        let line = "const SOME_CONST_VALUE: u32 = 42; fn helper_fn() {}\n"
        var src = ""
        src.reserveCapacity(210_000)
        while src.utf8.count < 200_000 { src += line }
        XCTAssertLessThan(src.utf8.count, highlightMaxBytes,
                          "fixture must stay under the highlight cap to tokenize")

        let engine = TreeSitterEngine.shared
        _ = engine.tokenize(src, language: .rust) // warm the query compile

        // Correctness: the predicate-gated @constant still fires on this
        // dense fixture (proves the buffer resolver feeds #match? the
        // right text at scale).
        let runs = engine.tokenize(src, language: .rust)
        assertContains(runs, in: src, substring: "SOME_CONST_VALUE", kind: .constant)

        // Perf floor: 5 warm passes, median. Budget is ~10x a debug
        // headline; a revert to per-eval NSString.substring on a
        // predicate-dense 200 KB file shows up as a multiple-x blowup in
        // the query-iterate phase, which this trips, while tolerating a
        // loaded CI box.
        var samples: [Double] = []
        for _ in 0..<5 {
            let t0 = DispatchTime.now().uptimeNanoseconds
            _ = engine.tokenize(src, language: .rust)
            let t1 = DispatchTime.now().uptimeNanoseconds
            samples.append(Double(t1 &- t0) / 1_000_000.0)
        }
        samples.sort()
        let medianMs = samples[samples.count / 2]
        print("[perf-budget] tokenize(200KB predicate-dense .rust, warm): " +
              "\(String(format: "%.1f", medianMs))ms (budget 8000ms)")
        XCTAssertLessThan(medianMs, 8000.0,
            "predicate-dense 200 KB tokenize regressed to \(medianMs)ms — a " +
            "blowup suggests per-eval NSString substring allocation returned " +
            "(TSK-827 moved predicate text resolution to a cached buffer).")
    }
}
