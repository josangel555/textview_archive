import XCTest
import ViewerKit
@testable import ViewerCore

/// TSK-897 / TSK-854 — grammar-coverage parity guard.
///
/// `HighlightLanguage` is an enum of every language the app *knows the
/// name of* (badge text, file-extension detection, code-fence info
/// strings). That is a SUPERSET of the languages the View-mode highlighter
/// can actually COLOR — a case can have extension detection + a display
/// name yet no bundled grammar, in which case the file renders plain even
/// though the UI advertised a highlight mode. That exact mismatch is the
/// bug TSK-897 (re-report of TSK-362) describes.
///
/// TSK-854 deleted the Swift TreeSitter highlighter; highlighting now runs
/// EXCLUSIVELY through the Rust core via `RustHighlightAdapter`. So these
/// tests pin coverage against the RUST path — the actual on-screen
/// highlighter — not the retired Swift engine (which survives only for
/// code-folds + structural search). They tokenize with the gate forced ON
/// so the rust engine runs deterministically regardless of any persisted
/// Settings toggle.
///
///   1. `wiredLanguages` — every case the rust core produces highlight runs
///      for — is asserted EXACTLY. Adding or losing grammar coverage forces
///      this list to change in lock-step, so a coverage drift can never
///      sneak past review.
///   2. Every wired language must TOKENIZE a representative snippet to
///      non-empty scoped runs (proves the grammar+query actually load and
///      fire, not just that the case is "supported").
///   3. The KNOWN GAP set (`go/html/css/sql/ruby/yaml/kotlin`) — cases the
///      UI does NOT advertise as highlightable — is documented. (The rust
///      core can actually parse several of these; they stay gaps pending
///      the UI-advertise decision in TSK-897.)
///
/// Pure host logic + the in-proc rust core — no UI.
///
///   swift test --filter ViewerCoreTests.HighlightGrammarCoverageTests
final class HighlightGrammarCoverageTests: XCTestCase {

    /// Force the highlight gate ON so the rust engine runs deterministically
    /// regardless of any persisted Settings toggle on the test host.
    private static let gateOn = ["MDV_RUST_HIGHLIGHT": "1"]

    private static func tokenize(
        _ src: String, _ lang: HighlightLanguage
    ) -> [HighlightRun] {
        RustHighlightAdapter.outcome(src, language: lang, environment: gateOn).value
    }

    /// Every `HighlightLanguage` the View-mode highlighter (the rust core)
    /// produces runs for. This is exactly the app's advertised highlightable
    /// set (`isHighlightable == true`). EXACT — see the class doc. The rust
    /// core covers a superset (go/html/css/sql/ruby/yaml/kotlin parse there
    /// too) but those stay un-advertised gaps until TSK-897.
    private static let wiredLanguages: Set<HighlightLanguage> = [
        .swift, .json, .markdown, .xml, .python, .javascript,
        .typescript, .tsx, .shell, .java, .c, .cpp, .csharp,
        .rust, .lua,
    ]

    /// Cases with extension/info-string detection but NOT advertised as a
    /// selectable highlight mode (`isHighlightable == false`). Disjoint from
    /// `wiredLanguages` by construction (asserted below).
    private static let knownGapLanguages: Set<HighlightLanguage> = [
        .go, .html, .css, .sql, .ruby, .yaml, .kotlin,
    ]

    /// Representative one-liners per wired language, chosen to fire at
    /// least one capture.
    private static let snippets: [HighlightLanguage: String] = [
        .swift:      "let x: Int = 42",
        .json:       #"{ "n": 42 }"#,
        .markdown:   "# Title\n\n**bold**",
        .xml:        "<root attr=\"v\">hi</root>",
        .python:     "def f(x): return x + 1",
        .javascript: "const x = 42; function f() {}",
        .typescript: "const x: number = 42; function f(): void {}",
        .tsx:        "const x: number = 1; function F() { return <div/>; }",
        .shell:      "echo $HOME; if [ -f x ]; then ls; fi",
        .java:       "class C { int x = 42; }",
        .c:          "int main(void) { return 0; }",
        .cpp:        "class C { auto x = nullptr; };",
        .csharp:     "class C { int X { get; set; } }",
        .rust:       "fn main() { let x: i32 = 42; }",
        .lua:        "local x = 42\nfunction f() return x end",
    ]

    // MARK: - The boundary is exact

    /// Every ADVERTISED highlightable language MUST be covered by the rust
    /// highlighter (produces runs) — the load-bearing direction: the UI never
    /// offers a mode the engine can't color. The rust core actually covers a
    /// SUPERSET (the gap languages parse there too — TSK-854 finding), so this
    /// asserts subset-coverage of the wired set, not equality. A grammar
    /// dropped from the rust build that the UI still advertises trips this.
    func testWiredLanguagesAreAllRustCovered() {
        var uncovered: [String] = []
        for lang in Self.wiredLanguages {
            let src = Self.snippets[lang] ?? "x = 1"
            if Self.tokenize(src, lang).isEmpty {
                uncovered.append(lang.rawValue)
            }
        }
        XCTAssertTrue(
            uncovered.isEmpty,
            """
            Advertised highlightable language(s) produce NO runs via the rust \
            core — they would render plain on screen: \(uncovered.sorted()). \
            Fix rust coverage or drop them from the advertised set.
            """
        )
    }

    /// The wired set must exactly equal the app's advertised highlightable set
    /// (`isHighlightable == true`). Keeps the test's pinned list honest against
    /// the enum so a new advertised language can't sneak in unverified.
    func testWiredSetMatchesAdvertisedHighlightable() {
        let advertised = Set(HighlightLanguage.allCases.filter(\.isHighlightable))
        XCTAssertEqual(
            Self.wiredLanguages, advertised,
            "wiredLanguages drifted from HighlightLanguage.isHighlightable — reconcile the two"
        )
    }

    /// The two sets must never overlap: a language is EITHER wired OR a
    /// known gap, never both.
    func testWiredAndGapSetsAreDisjoint() {
        XCTAssertTrue(
            Self.wiredLanguages.isDisjoint(with: Self.knownGapLanguages),
            "a language is listed as both wired and a known gap: \(Self.wiredLanguages.intersection(Self.knownGapLanguages).map(\.rawValue))"
        )
    }

    /// Every non-plainText case must be classified — either wired or a
    /// known gap.
    func testEveryLanguageIsClassified() {
        for lang in HighlightLanguage.allCases where lang != .plainText {
            XCTAssertTrue(
                Self.wiredLanguages.contains(lang) || Self.knownGapLanguages.contains(lang),
                "\(lang.rawValue) is neither wired nor a known gap — classify it"
            )
        }
    }

    // MARK: - Wired languages actually tokenize

    /// Each wired language tokenizes its snippet to non-empty scoped runs
    /// through the rust path — the "grammar + query really load and fire"
    /// proof at the layer that actually paints on screen.
    func testWiredLanguagesTokenizeToScopedRuns() {
        for lang in Self.wiredLanguages {
            guard let src = Self.snippets[lang] else {
                XCTFail("no snippet for wired language \(lang.rawValue) — add one")
                continue
            }
            let runs = Self.tokenize(src, lang)
            XCTAssertFalse(
                runs.isEmpty,
                "\(lang.rawValue) produced no runs via the rust core — grammar dropped, query missing, or matched nothing"
            )
            XCTAssertTrue(
                runs.allSatisfy { $0.range.length > 0 },
                "\(lang.rawValue) emitted a zero-length run"
            )
        }
    }

    /// Every wired language has a snippet (keeps `snippets` and
    /// `wiredLanguages` in lock-step).
    func testEveryWiredLanguageHasASnippet() {
        for lang in Self.wiredLanguages {
            XCTAssertNotNil(
                Self.snippets[lang],
                "wired language \(lang.rawValue) is missing a snippet"
            )
        }
    }

    // MARK: - Known gaps are not advertised as highlight modes

    /// Minimal snippets in each gap language (also reused by the coverage
    /// probe above for the unadvertised set).
    private static let gapSnippets: [HighlightLanguage: String] = [
        .go:     "package main\nfunc main() {}",
        .html:   "<html><body>hi</body></html>",
        .css:    "body { color: red; }",
        .sql:    "SELECT id FROM users WHERE id = 1;",
        .ruby:   "def greet(name)\n  puts name\nend",
        .yaml:   "key: value\nlist:\n  - a\n  - b",
        .kotlin: "fun main() { val x = 42 }",
    ]

    /// The known-gap languages must NOT be advertised as highlightable
    /// modes. (Even though the rust core can parse some, the UI keeps them
    /// off the menu pending TSK-897 — this pins that contract.)
    func testKnownGapLanguagesNotAdvertised() {
        for lang in Self.knownGapLanguages {
            XCTAssertFalse(
                lang.isHighlightable,
                "\(lang.rawValue) is a known gap but isHighlightable == true — promote it into wiredLanguages or keep it hidden"
            )
            XCTAssertFalse(
                HighlightLanguage.supportedForDisplay.contains(lang),
                "\(lang.rawValue) is a known gap but advertised in supportedForDisplay"
            )
        }
    }

    // MARK: - UI never advertises a no-grammar mode

    /// `supportedForDisplay` drives the Language Mode menu + Settings. Per
    /// TSK-897 the UI must not offer a mode that renders plain. The
    /// advertised set must be a subset of what the rust highlighter actually
    /// covers — i.e. every advertised mode is wired.
    func testAdvertisedModesAreAllWired() {
        let advertised = Set(HighlightLanguage.supportedForDisplay)
        XCTAssertTrue(
            advertised.isSubset(of: Self.wiredLanguages),
            "supportedForDisplay advertises a non-wired mode: \(advertised.subtracting(Self.wiredLanguages).map(\.rawValue))"
        )
    }
}
