import XCTest
import ViewerKit
@testable import ViewerCore

/// TSK-897 / TSK-854 — the load-bearing guard for
/// `HighlightLanguage.isHighlightable`.
///
/// `isHighlightable` lives in ViewerKit (so the menu / Settings can read it
/// without dragging the engine across module boundaries), but its *truth* is
/// owned by the View-mode highlighter. TSK-854 deleted the Swift TreeSitter
/// highlighter; highlighting now runs EXCLUSIVELY through the Rust core
/// (`RustHighlightAdapter`). So these tests cross-check the declaration
/// against the rust path — the engine that actually paints on screen — so
/// the two can never drift. That is exactly the regression TSK-897 fixed,
/// where the enum advertised `.go`, `.html`, `.css`, `.sql`, `.ruby`,
/// `.kotlin` as "supported" yet nothing colored them, so they rendered PLAIN
/// despite appearing as selectable Language-Mode menu items.
///
/// If the rust core later covers + the UI advertises a gap language, this
/// test fails until `isHighlightable` is flipped to match — forcing the
/// menu/Settings to stay honest about "what can we color".
///
/// Gate forced ON so the rust engine runs deterministically regardless of
/// any persisted Settings toggle on the test host.
final class HighlightLanguageGrammarParityTests: XCTestCase {

    private static let gateOn = ["MDV_RUST_HIGHLIGHT": "1"]

    private static func runs(
        _ src: String, _ lang: HighlightLanguage
    ) -> [HighlightRun] {
        RustHighlightAdapter.outcome(src, language: lang, environment: gateOn).value
    }

    /// Representative source per language, used to prove the rust highlighter
    /// actually fires (a grammar that loads but matches nothing would read as
    /// "no grammar"). Covers every non-plainText case so both directions can
    /// probe the rust path.
    private static let sample: [HighlightLanguage: String] = [
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
        // Gap languages — probed too, to assert they stay hidden.
        .go:     "package main\nfunc main() {}",
        .html:   "<html><body>hi</body></html>",
        .css:    "body { color: red; }",
        .sql:    "SELECT * FROM t WHERE id = 1;",
        .ruby:   "def f(x)\n  x + 1\nend",
        .kotlin: "fun main() { val x = 42 }",
        .yaml:   "key: value\nlist:\n  - a\n  - b",
    ]

    /// Every language the enum claims is highlightable MUST actually produce
    /// runs through the rust highlighter. Empty runs here means we're
    /// advertising a mode that renders plain — the TSK-897 bug.
    func test_highlightableLanguages_produceRustRuns() {
        for lang in HighlightLanguage.allCases where lang.isHighlightable {
            guard let src = Self.sample[lang] else {
                XCTFail("no sample for highlightable \(lang.displayName) — add one")
                continue
            }
            XCTAssertFalse(
                Self.runs(src, lang).isEmpty,
                "\(lang.displayName).isHighlightable == true but the rust core produced NO runs — it would render plain. Either fix coverage or flip isHighlightable to false.")
        }
    }

    /// The exact TSK-897 regression set, pinned by name + behaviour: these
    /// are NOT advertised as selectable modes. (The rust core CAN parse
    /// several of them — that's why this asserts the UI contract, not the
    /// engine: they stay off the menu until TSK-897 promotes them.)
    func test_tsk897_gapLanguages_areNotSelectableModes() {
        let cases: [HighlightLanguage] = [.go, .html, .css, .sql, .ruby, .kotlin, .yaml]
        for lang in cases {
            XCTAssertFalse(lang.isHighlightable,
                           "\(lang.displayName) is a documented gap — must report isHighlightable == false")
            XCTAssertFalse(HighlightLanguage.supportedForDisplay.contains(lang),
                           "\(lang.displayName) must not be a selectable Language Mode (TSK-897)")
        }
    }

    /// Every language the menu/Settings offers must produce at least one
    /// highlight run on representative source through the rust path. Proves
    /// the list never advertises a dead mode.
    func test_everySelectableMode_actuallyHighlights() {
        for lang in HighlightLanguage.supportedForDisplay {
            guard let src = Self.sample[lang] else {
                XCTFail("no sample source for selectable mode \(lang.displayName) — add one")
                continue
            }
            XCTAssertFalse(
                Self.runs(src, lang).isEmpty,
                "\(lang.displayName) is a selectable mode but the rust core produced no highlight runs")
        }
    }
}
