import XCTest
import ViewerKit
@testable import ViewerCore

/// Engine-level smoke tests. Confirms each v1 language tokenizes
/// something rather than silently returning [] (the "language failed
/// to load" path). Golden tokenization tests come later (task #82).
final class TreeSitterEngineSmokeTests: XCTestCase {

    func testEachLanguageProducesRuns() {
        let cases: [(HighlightLanguage, String)] = [
            (.swift,      "let x: Int = 42"),
            (.json,       #"{ "n": 42 }"#),
            (.xml,        "<root attr=\"v\">hi</root>"),
            (.python,     "def f(x): return x + 1"),
            (.javascript, "const x = 42; function f() {}"),
            (.typescript, "const x: number = 42; function f(): void {}"),
            (.markdown,   "# Title\n\n**bold**"),
            (.shell,      "echo $HOME; if [ -f x ]; then ls; fi"),
            // Phase 5 grammars.
            (.java,       "class C { int x = 42; }"),
            (.c,          "int main(void) { return 0; }"),
            (.cpp,        "#include <vector>\nstd::vector<int> v;"),
            (.csharp,     "class C { int X { get; set; } }"),
            (.rust,       "fn main() { let x: i32 = 42; }"),
            (.lua,        "local x = 42\nfunction f() return x end"),
        ]
        for (lang, src) in cases {
            let runs = TreeSitterEngine.shared.tokenize(src, language: lang)
            XCTAssertFalse(
                runs.isEmpty,
                "\(lang) produced no runs — likely language failed to load or query missing"
            )
        }
    }

    func testPlainTextReturnsEmpty() {
        let runs = TreeSitterEngine.shared.tokenize("hello", language: .plainText)
        XCTAssertTrue(runs.isEmpty)
    }

    func testOversizedFileReturnsEmpty() async {
        let huge = String(repeating: "x", count: highlightMaxBytes + 1)
        let runs = TreeSitterEngine.shared.tokenize(huge, language: .json)
        XCTAssertTrue(runs.isEmpty, "expected oversized cap to suppress highlighting")
    }
}
