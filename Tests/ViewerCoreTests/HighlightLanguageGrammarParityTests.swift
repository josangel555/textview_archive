import XCTest
import ViewerKit
@testable import ViewerCore

/// TSK-897 — the load-bearing guard for `HighlightLanguage.isHighlightable`.
///
/// `isHighlightable` lives in ViewerKit (so the menu / Settings can read it
/// without dragging the engine across module boundaries), but its *truth* is
/// owned by the View-mode engine in ViewerCore: a language is highlightable iff
/// `TreeSitterEngine.languageHandle(for:)` can resolve a grammar for it. These
/// tests cross-check the declaration against the real engine so the two can
/// never drift — exactly the regression TSK-897 fixed, where the enum advertised
/// `.go`, `.html`, `.css`, `.sql`, `.ruby`, `.kotlin` as "supported" yet the
/// engine had no grammar for them, so they rendered PLAIN despite appearing as
/// selectable Language-Mode menu items.
///
/// If a grammar is later bundled (e.g. tree-sitter-go), `languageHandle` starts
/// returning non-nil for `.go`; this test then fails until `isHighlightable` is
/// flipped to `true` for `.go` — forcing the menu/Settings to pick it up. The
/// reverse (a grammar dropped from the build) fails the highlightable→non-nil
/// direction. Either way the UI's "what can we color" claim stays honest.
final class HighlightLanguageGrammarParityTests: XCTestCase {

    /// Every language the enum claims is highlightable MUST resolve to a real
    /// grammar in the engine. A nil handle here means we're advertising a mode
    /// that renders plain — the TSK-897 bug.
    func test_highlightableLanguages_haveARealGrammar() {
        for lang in HighlightLanguage.allCases where lang.isHighlightable {
            XCTAssertNotNil(
                TreeSitterEngine.shared.languageHandle(for: lang),
                "\(lang.displayName).isHighlightable == true but the engine has no grammar (languageHandle == nil) — it would render plain. Either bundle the grammar or flip isHighlightable to false.")
        }
    }

    /// Every language the enum claims is NOT highlightable MUST have NO grammar
    /// in the engine. A non-nil handle here means the flag is needlessly hiding a
    /// language we could actually color — flip it to true so the menu offers it.
    func test_nonHighlightableLanguages_haveNoGrammar() {
        for lang in HighlightLanguage.allCases where !lang.isHighlightable {
            XCTAssertNil(
                TreeSitterEngine.shared.languageHandle(for: lang),
                "\(lang.displayName).isHighlightable == false but the engine DOES resolve a grammar — it can be highlighted; flip isHighlightable to true so it appears in the Language Mode menu.")
        }
    }

    /// The exact TSK-897 regression set, pinned by name + behaviour: these
    /// detect (so the mode badge names them) but produce ZERO highlight runs —
    /// they render plain. They must therefore be excluded from the selectable
    /// modes. Asserting the tokenize behaviour (not just the handle) so the guard
    /// has teeth at the same layer the user feels the bug.
    func test_tsk897_languagesWithoutGrammar_produceNoRuns() {
        let cases: [(HighlightLanguage, String)] = [
            (.go,     "package main\nfunc main() {}"),
            (.html,   "<html><body>hi</body></html>"),
            (.css,    "body { color: red; }"),
            (.sql,    "SELECT * FROM t WHERE id = 1;"),
            (.ruby,   "def f(x)\n  x + 1\nend"),
            (.kotlin, "fun main() { val x = 42 }"),
            (.yaml,   "key: value\nlist:\n  - a\n  - b"),
        ]
        for (lang, src) in cases {
            XCTAssertFalse(lang.isHighlightable,
                           "\(lang.displayName) has no bundled grammar — must report isHighlightable == false")
            XCTAssertFalse(HighlightLanguage.supportedForDisplay.contains(lang),
                           "\(lang.displayName) renders plain — must not be a selectable Language Mode")
            let runs = TreeSitterEngine.shared.tokenize(src, language: lang)
            XCTAssertTrue(runs.isEmpty,
                          "\(lang.displayName) produced runs unexpectedly — a grammar may have been bundled; revisit isHighlightable")
        }
    }

    /// The complement: every language the menu/Settings offers must produce at
    /// least one highlight run on representative source. Proves the list never
    /// advertises a dead mode (the inverse of the bug above).
    func test_everySelectableMode_actuallyHighlights() {
        let sample: [HighlightLanguage: String] = [
            .swift:      "let x: Int = 42",
            .json:       #"{ "n": 42 }"#,
            .xml:        "<root attr=\"v\">hi</root>",
            .python:     "def f(x): return x + 1",
            .javascript: "const x = 42",
            .typescript: "const x: number = 42",
            .tsx:        "const App = () => <div/>;",
            .markdown:   "# Title\n\n**bold**",
            .shell:      "echo $HOME",
            .java:       "class C { int x = 42; }",
            .c:          "int main(void) { return 0; }",
            .cpp:        "class C { auto x = nullptr; };",
            .csharp:     "class C { int X { get; set; } }",
            .rust:       "fn main() { let x: i32 = 42; }",
            .lua:        "local x = 42",
        ]
        for lang in HighlightLanguage.supportedForDisplay {
            guard let src = sample[lang] else {
                XCTFail("no sample source for selectable mode \(lang.displayName) — add one so this guard stays exhaustive")
                continue
            }
            let runs = TreeSitterEngine.shared.tokenize(src, language: lang)
            XCTAssertFalse(runs.isEmpty,
                           "\(lang.displayName) is a selectable mode but produced no highlight runs")
        }
    }
}
