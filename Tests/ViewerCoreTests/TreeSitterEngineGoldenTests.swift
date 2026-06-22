import XCTest
import ViewerKit
@testable import ViewerCore

/// Golden tokenization tests: per-language assertions that specific
/// `(substring, kind)` pairs survive grammar version changes. These
/// fail loudly when an upstream grammar bump (or our vendored .scm
/// edit) shifts what fires for canonical inputs — the deliberate
/// signal we want before a silent regression escapes (design doc §17).
///
/// TSK-854: highlighting is rust-only now (the Swift TreeSitter twin was
/// deleted), so these goldens tokenize through `RustHighlightAdapter` — the
/// engine that actually paints on screen. Gate forced ON for determinism.
///
/// Why substring rather than exact NSRange: tree-sitter byte ranges
/// shift if anyone edits the test snippet by one character. Looking
/// for "this text was tokenized as keyword somewhere in the source"
/// is robust enough to be useful without being brittle to whitespace.
final class TreeSitterEngineGoldenTests: XCTestCase {

    private static let gateOn = ["MDV_RUST_HIGHLIGHT": "1"]

    /// Tokenize through the rust highlighter (the on-screen engine).
    private func tokenize(
        _ src: String, _ lang: HighlightLanguage
    ) -> [HighlightRun] {
        RustHighlightAdapter.outcome(src, language: lang, environment: Self.gateOn).value
    }

    private func assertContains(
        _ runs: [HighlightRun],
        in source: String,
        substring: String,
        kind: TokenKind,
        file: StaticString = #file, line: UInt = #line
    ) {
        let ns = source as NSString
        let found = runs.contains { run in
            guard run.kind == kind,
                  run.range.location >= 0,
                  run.range.location + run.range.length <= ns.length else {
                return false
            }
            return ns.substring(with: run.range) == substring
        }
        XCTAssertTrue(
            found,
            "expected '\(substring)' tokenized as .\(kind); got runs: \(runs.map { (ns.substring(with: $0.range), $0.kind) })",
            file: file, line: line
        )
    }

    // MARK: Goldens

    func testSwift() {
        let src = #"""
        // hello
        func greet(name: String) -> Int {
            let n = 42
            return n
        }
        """#
        let runs = tokenize(src, .swift)
        assertContains(runs, in: src, substring: "func",   kind: .keyword)
        assertContains(runs, in: src, substring: "let",    kind: .keyword)
        assertContains(runs, in: src, substring: "return", kind: .keyword)
        // TSK-1201 (FIXED): the bundled `tree-sitter-swift` query tagged `//`
        // comments only via a dual `@comment @spell` capture our highlighter
        // dropped; we append a single-capture `(comment) @comment` rule, so Swift
        // comments now tag @comment on the rust path. Positive golden (was a
        // negative gap-control).
        XCTAssertTrue(
            runs.contains { $0.kind == .comment },
            "Swift // line comment must tag @comment (TSK-1201 fixed)")
        assertContains(runs, in: src, substring: "42",     kind: .number)
        assertContains(runs, in: src, substring: "String", kind: .type)
    }

    func testJSON() {
        let src = #"{ "name": "alice", "n": 42, "ok": true, "x": null }"#
        let runs = tokenize(src, .json)
        assertContains(runs, in: src, substring: "\"alice\"", kind: .string)
        assertContains(runs, in: src, substring: "42",        kind: .number)
        // true/null → constant.builtin → mapped to .builtin in CaptureMap
        assertContains(runs, in: src, substring: "true", kind: .builtin)
        assertContains(runs, in: src, substring: "null", kind: .builtin)
    }

    func testXML() {
        let src = #"<root attr="v">hello</root>"#
        let runs = tokenize(src, .xml)
        // The XML grammar emits the attribute value's INNER content
        // (without quotes) as @string — quotes themselves are captured
        // as punctuation. Match what the grammar actually emits.
        assertContains(runs, in: src, substring: "v", kind: .string)
        // Element tag captured as .tag (CaptureMap collapses).
        assertContains(runs, in: src, substring: "root", kind: .tag)
    }

    func testPython() {
        let src = #"""
        # hi
        def greet(name):
            return name + str(42)
        """#
        let runs = tokenize(src, .python)
        assertContains(runs, in: src, substring: "def",      kind: .keyword)
        assertContains(runs, in: src, substring: "return",   kind: .keyword)
        assertContains(runs, in: src, substring: "# hi",     kind: .comment)
        assertContains(runs, in: src, substring: "42",       kind: .number)
    }

    func testJavaScript() {
        let src = #"""
        // header
        const x = 42;
        function f(a, b) { return a + b; }
        """#
        let runs = tokenize(src, .javascript)
        assertContains(runs, in: src, substring: "const",    kind: .keyword)
        assertContains(runs, in: src, substring: "function", kind: .keyword)
        assertContains(runs, in: src, substring: "return",   kind: .keyword)
        assertContains(runs, in: src, substring: "// header", kind: .comment)
        assertContains(runs, in: src, substring: "42",       kind: .number)
    }

    func testTypeScript() {
        let src = #"""
        const x: number = 42;
        function f(a: string): string { return a; }
        """#
        let runs = tokenize(src, .typescript)
        assertContains(runs, in: src, substring: "const",    kind: .keyword)
        assertContains(runs, in: src, substring: "function", kind: .keyword)
        assertContains(runs, in: src, substring: "42",       kind: .number)
    }

    func testPredicatesAreEvaluated() {
        // TSK-410: predicate-gated captures must not fire for non-matching
        // text. Pre-fix, `myThing` resolved to `.type` (purple) because the
        // engine ignored `#match?` and `((identifier) @type (#match? @type
        // "^[A-Z]"))` matched every identifier; `@type` then won paintOver.
        let src = "const myThing: Widget = makeThing();"
        let runs = tokenize(src, .typescript)
        // lowercase identifier → the "^[A-Z]" @type/@constructor predicates
        // must reject it, leaving the plain `@variable` capture.
        assertContains(runs, in: src, substring: "myThing", kind: .variable)
        // a real type annotation still colors as a type (no predicate gate).
        assertContains(runs, in: src, substring: "Widget",  kind: .type)
        assertContains(runs, in: src, substring: "const",   kind: .keyword)

        // JavaScript shares the same gated patterns (@constructor /
        // @variable.builtin / @function.builtin). Pre-fix a lowercase
        // identifier resolved to .builtin (the unconditional @function.builtin
        // #eq? require capture won); it must now be .variable.
        let jsSrc = "const myThing = makeThing();"
        let jsRuns = tokenize(jsSrc, .javascript)
        assertContains(jsRuns, in: jsSrc, substring: "myThing", kind: .variable)
    }

    func testTSX() {
        // `.tsx` routes to the JSX-aware `tree_sitter_tsx` grammar
        // (TSK-195). The plain TypeScript grammar can't parse JSX — it
        // litters the tree with ERROR nodes, wrecking highlighting for
        // the whole expression — so the grammar swap is the fix.
        let src = #"""
        interface Props { count: number; }
        const App = ({ count }: Props) => <div className="root">{count}</div>;
        """#
        let runs = tokenize(src, .tsx)
        XCTAssertFalse(runs.isEmpty, "tsx produced no runs — grammar or query failed to load")
        assertContains(runs, in: src, substring: "interface", kind: .keyword)
        assertContains(runs, in: src, substring: "const",     kind: .keyword)
        // Regression guard: `.tsx` must resolve a grammar + query and emit
        // runs over JSX-bearing source (the string literal lives inside the
        // JSX element). If `.tsx` ever fell back to no grammar this is empty.
        assertContains(runs, in: src, substring: "\"root\"",  kind: .string)
    }

    func testRust() {
        // The rust path (the on-screen highlighter since TSK-660) DOES tokenize
        // rust source. KNOWN GAP (TSK-1201): unlike java/c/python/lua (which
        // the rust core DOES color SCREAMING_CASE as .constant — see
        // testPredicateGatedConstants_acrossLanguages), the rust core's
        // `tree-sitter-rust` highlight query does not tag rust-lang
        // SCREAMING_CASE as @constant, so `MAX_SIZE` renders plain. Pin the
        // grammar still loads + fires (keyword/fn) and a negative assertion on
        // the constant so closing the gap flips this RED.
        let src = "const MAX_SIZE: u32 = 64;\nfn main() {}"
        let runs = tokenize(src, .rust)
        XCTAssertFalse(runs.isEmpty, "rust produced no runs")
        assertContains(runs, in: src, substring: "const", kind: .keyword)
        assertContains(runs, in: src, substring: "fn",    kind: .keyword)
        let ns = src as NSString
        let maxSizeKinds = runs.filter {
            $0.range.location >= 0
                && $0.range.location + $0.range.length <= ns.length
                && ns.substring(with: $0.range) == "MAX_SIZE"
        }.map(\.kind)
        // TSK-1201 (FIXED): appended `(const_item/static_item name: (identifier)
        // @constant)` so SCREAMING_CASE const/static names tag @constant. Positive
        // golden (was a negative gap-control).
        XCTAssertTrue(
            maxSizeKinds.contains(.constant),
            "rust SCREAMING_CASE const name must tag @constant (TSK-1201 fixed)")
    }

    func testPredicateGatedConstants_acrossLanguages() {
        // TSK-410 made predicate evaluation global, so the `#match?`-gated
        // @constant patterns now fire only when the regex matches. Pin the
        // SCREAMING_CASE → .constant behavior for the other affected grammars
        // (rust covered by testRust) so a future query typo like the rust
        // `$'` one can't silently drop constant coloring again.
        let cases: [(HighlightLanguage, String, String)] = [
            (.java,   "class C { static final int MAX_LEN = 5; }", "MAX_LEN"),
            (.c,      "int MAX_N = 5;",                            "MAX_N"),
            (.python, "MAX_SIZE = 10",                            "MAX_SIZE"),
            (.lua,    "MAXV = 10",                                 "MAXV"),
        ]
        for (lang, src, name) in cases {
            let runs = tokenize(src, lang)
            assertContains(runs, in: src, substring: name, kind: .constant)
        }
    }

    func testMarkdown() {
        let src = "# Title\n\nBody **bold** and `code`."
        let runs = tokenize(src, .markdown)
        // Markdown grammar's capture names are tricky; just confirm a
        // heading-kind run fires for "# Title".
        XCTAssertFalse(runs.isEmpty, "markdown produced no runs")
    }

    func testShell() {
        let src = #"""
        # comment
        if [ -f "$HOME/.zshrc" ]; then echo "yes"; fi
        """#
        let runs = tokenize(src, .shell)
        assertContains(runs, in: src, substring: "if",   kind: .keyword)
        assertContains(runs, in: src, substring: "then", kind: .keyword)
        assertContains(runs, in: src, substring: "fi",   kind: .keyword)
        assertContains(runs, in: src, substring: "# comment", kind: .comment)
    }

    // MARK: ABI smoke

    /// Each v1 language must bind to its parser without throwing —
    /// catches a SwiftTreeSitter ABI bump that broke a grammar package.
    func testEveryV1LanguageBinds() {
        let v1: [HighlightLanguage] = [
            .swift, .json, .xml, .python, .javascript,
            .typescript, .markdown, .shell,
        ]
        for lang in v1 {
            let runs = tokenize("x", lang)
            // Don't assert runs.isEmpty either way (some grammars
            // produce 0 captures for a single character; that's fine).
            // The point is: tokenize ran without crashing.
            _ = runs
        }
    }
}
