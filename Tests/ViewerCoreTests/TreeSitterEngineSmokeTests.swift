import XCTest
import ViewerKit
@testable import ViewerCore

/// Engine-level smoke tests for the Swift `TreeSitterEngine`.
///
/// TSK-854: this engine no longer drives HIGHLIGHTING (that is rust-only via
/// `RustHighlightAdapter` — see `HighlightGrammarCoverageTests` for the
/// full-language coverage proof). It survives ONLY for code-FOLDS +
/// structural search, so it bundles exactly the grammars those features need:
/// swift/json/markdown (eager) + xml/javascript/typescript/tsx (lazy). These
/// smokes confirm each RETAINED grammar still loads + tokenizes (the
/// `languageHandle` → `Query` compile path folds also depend on), rather than
/// silently returning [] (the "grammar failed to load" path).
final class TreeSitterEngineSmokeTests: XCTestCase {

    func testEachRetainedGrammarProducesRuns() {
        // Exactly the languages `TreeSitterEngine.languageHandle` still
        // resolves (the fold/structural-search grammar set). The 8
        // highlight-only grammars were removed in TSK-854.
        let cases: [(HighlightLanguage, String)] = [
            (.swift,      "let x: Int = 42"),
            (.json,       #"{ "n": 42 }"#),
            (.markdown,   "# Title\n\n**bold**"),
            (.xml,        "<root attr=\"v\">hi</root>"),
            (.javascript, "const x = 42; function f() {}"),
            (.typescript, "const x: number = 42; function f(): void {}"),
            (.tsx,        "const x: number = 1; function F() { return <div/>; }"),
        ]
        for (lang, src) in cases {
            let runs = TreeSitterEngine.shared.tokenize(src, language: lang)
            XCTAssertFalse(
                runs.isEmpty,
                "\(lang) produced no runs — likely grammar failed to load or query missing"
            )
        }
    }

    /// The 8 highlight-only grammars were removed from the Swift engine in
    /// TSK-854 — `languageHandle` returns nil so `tokenize` is empty. (They
    /// still highlight on screen via the rust core; this pins that the Swift
    /// twin no longer carries them.)
    func testRemovedGrammarsTokenizeEmpty() {
        let removed: [HighlightLanguage] = [
            .python, .shell, .java, .c, .cpp, .csharp, .rust, .lua,
        ]
        for lang in removed {
            XCTAssertNil(
                TreeSitterEngine.shared.languageHandle(for: lang),
                "\(lang) grammar should have been removed from the Swift engine (TSK-854)"
            )
            XCTAssertTrue(
                TreeSitterEngine.shared.tokenize("x = 1", language: lang).isEmpty,
                "\(lang) produced Swift-engine runs — its grammar should be gone"
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
