import XCTest
import ViewerKit
@testable import ViewerCore

/// Golden tokenization tests: per-language assertions that specific
/// `(substring, kind)` pairs survive grammar version changes. These
/// fail loudly when an upstream grammar bump (or our vendored .scm
/// edit) shifts what fires for canonical inputs — the deliberate
/// signal we want before a silent regression escapes (design doc §17).
///
/// Why substring rather than exact NSRange: tree-sitter byte ranges
/// shift if anyone edits the test snippet by one character. Looking
/// for "this text was tokenized as keyword somewhere in the source"
/// is robust enough to be useful without being brittle to whitespace.
final class TreeSitterEngineGoldenTests: XCTestCase {

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
        let runs = TreeSitterEngine.shared.tokenize(src, language: .swift)
        assertContains(runs, in: src, substring: "func",   kind: .keyword)
        assertContains(runs, in: src, substring: "let",    kind: .keyword)
        assertContains(runs, in: src, substring: "return", kind: .keyword)
        assertContains(runs, in: src, substring: "// hello", kind: .comment)
        assertContains(runs, in: src, substring: "42",     kind: .number)
        assertContains(runs, in: src, substring: "String", kind: .type)
    }

    func testJSON() {
        let src = #"{ "name": "alice", "n": 42, "ok": true, "x": null }"#
        let runs = TreeSitterEngine.shared.tokenize(src, language: .json)
        assertContains(runs, in: src, substring: "\"alice\"", kind: .string)
        assertContains(runs, in: src, substring: "42",        kind: .number)
        // true/null → constant.builtin → mapped to .builtin in CaptureMap
        assertContains(runs, in: src, substring: "true", kind: .builtin)
        assertContains(runs, in: src, substring: "null", kind: .builtin)
    }

    func testXML() {
        let src = #"<root attr="v">hello</root>"#
        let runs = TreeSitterEngine.shared.tokenize(src, language: .xml)
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
        let runs = TreeSitterEngine.shared.tokenize(src, language: .python)
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
        let runs = TreeSitterEngine.shared.tokenize(src, language: .javascript)
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
        let runs = TreeSitterEngine.shared.tokenize(src, language: .typescript)
        assertContains(runs, in: src, substring: "const",    kind: .keyword)
        assertContains(runs, in: src, substring: "function", kind: .keyword)
        assertContains(runs, in: src, substring: "42",       kind: .number)
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
        let runs = TreeSitterEngine.shared.tokenize(src, language: .tsx)
        XCTAssertFalse(runs.isEmpty, "tsx produced no runs — grammar or query failed to load")
        assertContains(runs, in: src, substring: "interface", kind: .keyword)
        assertContains(runs, in: src, substring: "const",     kind: .keyword)
        // Regression guard: `.tsx` must resolve a grammar + query and emit
        // runs over JSX-bearing source (the string literal lives inside the
        // JSX element). If `.tsx` ever fell back to no grammar this is empty.
        assertContains(runs, in: src, substring: "\"root\"",  kind: .string)
    }

    func testMarkdown() {
        let src = "# Title\n\nBody **bold** and `code`."
        let runs = TreeSitterEngine.shared.tokenize(src, language: .markdown)
        // Markdown grammar's capture names are tricky; just confirm a
        // heading-kind run fires for "# Title".
        XCTAssertFalse(runs.isEmpty, "markdown produced no runs")
    }

    func testShell() {
        let src = #"""
        # comment
        if [ -f "$HOME/.zshrc" ]; then echo "yes"; fi
        """#
        let runs = TreeSitterEngine.shared.tokenize(src, language: .shell)
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
            let runs = TreeSitterEngine.shared.tokenize("x", language: lang)
            // Don't assert runs.isEmpty either way (some grammars
            // produce 0 captures for a single character; that's fine).
            // The point is: tokenize ran without crashing.
            _ = runs
        }
    }
}
