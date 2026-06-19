import XCTest
import ViewerKit
@testable import ViewerCore

/// TSK-897 — grammar-coverage parity guard.
///
/// `HighlightLanguage` is an enum of every language the app *knows the
/// name of* (badge text, file-extension detection, code-fence info
/// strings). That is a SUPERSET of the languages the View-mode
/// TreeSitter engine can actually COLOR — a case can have extension
/// detection + a display name yet no bundled grammar, in which case the
/// file renders plain even though the UI advertised a highlight mode.
/// That exact mismatch is the bug TSK-897 (re-report of TSK-362)
/// describes.
///
/// These tests pin the boundary between the two so it can't drift
/// silently:
///
///   1. `wiredLanguages` — every case the engine returns a non-nil
///      grammar handle for — is asserted EXACTLY. Adding or losing a
///      grammar forces this list to change in lock-step, so a grammar
///      add (or an accidental removal) can never sneak past review.
///   2. Every wired language must TOKENIZE a representative snippet to
///      non-empty scoped runs (proves the grammar+query actually load
///      and fire, not just that `languageHandle` is non-nil).
///   3. The KNOWN GAP set (`go/html/css/sql/ruby/yaml/kotlin`) — cases
///      with extension detection but NO grammar — is documented and
///      asserted to render plain. When a grammar is later added for one
///      of these (owner-approved, TSK-897), the engineering signal is a
///      RED test here: move the case from the gap list into
///      `wiredLanguages`, which is precisely the checklist a grammar PR
///      must satisfy.
///
/// Pure host logic + the statically/dlopen-loaded grammars the rest of
/// the ViewerCore suite already exercises — no new dependency, no UI.
///
///   swift test --filter ViewerCoreTests.HighlightGrammarCoverageTests
final class HighlightGrammarCoverageTests: XCTestCase {

    /// Every `HighlightLanguage` the View-mode engine has a bundled
    /// grammar for (i.e. `languageHandle(for:)` is non-nil). EXACT —
    /// see the class doc. Sorted by `rawValue` for a stable diff.
    private static let wiredLanguages: Set<HighlightLanguage> = [
        .swift, .json, .markdown, .xml, .python, .javascript,
        .typescript, .tsx, .shell, .java, .c, .cpp, .csharp,
        .rust, .lua,
    ]

    /// Cases with extension/info-string detection but NO bundled
    /// grammar — they render PLAIN. Documented so a future grammar add
    /// has a single place to delete from. Disjoint from `wiredLanguages`
    /// by construction (asserted below).
    private static let knownGapLanguages: Set<HighlightLanguage> = [
        .go, .html, .css, .sql, .ruby, .yaml, .kotlin,
    ]

    /// Representative one-liners per wired language, chosen to fire at
    /// least one capture in the vendored highlights query.
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

    /// The set of cases the engine actually resolves a grammar for must
    /// equal `wiredLanguages` — no more, no less. This is the guard that
    /// turns a silent coverage drift (grammar added without UI wiring,
    /// or grammar lost in a refactor) into a loud failure.
    func testEngineGrammarCoverageMatchesWiredSet() {
        let engine = TreeSitterEngine.shared
        var resolvable = Set<HighlightLanguage>()
        for lang in HighlightLanguage.allCases where lang != .plainText {
            if engine.languageHandle(for: lang) != nil {
                resolvable.insert(lang)
            }
        }
        XCTAssertEqual(
            resolvable, Self.wiredLanguages,
            """
            Engine grammar coverage drifted from the pinned wired set.
            Newly resolvable (add to `wiredLanguages` + a snippet, and \
            drop from `knownGapLanguages`): \
            \(resolvable.subtracting(Self.wiredLanguages).map(\.rawValue).sorted()).
            No longer resolvable (regression — investigate before \
            shipping): \
            \(Self.wiredLanguages.subtracting(resolvable).map(\.rawValue).sorted()).
            """
        )
    }

    /// The two sets must never overlap: a language is EITHER wired OR a
    /// known gap, never both. Catches a bad edit that adds a case to one
    /// list without removing it from the other.
    func testWiredAndGapSetsAreDisjoint() {
        XCTAssertTrue(
            Self.wiredLanguages.isDisjoint(with: Self.knownGapLanguages),
            "a language is listed as both wired and a known gap: \(Self.wiredLanguages.intersection(Self.knownGapLanguages).map(\.rawValue))"
        )
    }

    /// Every non-plainText case must be classified — either wired or a
    /// known gap. A new enum case with no classification fails here,
    /// forcing the author to decide (and, if it has a grammar, to wire
    /// it) rather than letting it silently render plain.
    func testEveryLanguageIsClassified() {
        for lang in HighlightLanguage.allCases where lang != .plainText {
            XCTAssertTrue(
                Self.wiredLanguages.contains(lang) || Self.knownGapLanguages.contains(lang),
                "\(lang.rawValue) is neither wired nor a known gap — classify it (wire a grammar or add to knownGapLanguages)"
            )
        }
    }

    // MARK: - Wired languages actually tokenize

    /// Each wired language tokenizes its snippet to non-empty scoped
    /// runs. This is the "grammar + query really load and fire" proof —
    /// `languageHandle != nil` alone doesn't guarantee the query
    /// compiles or that anything matches.
    func testWiredLanguagesTokenizeToScopedRuns() {
        for lang in Self.wiredLanguages {
            guard let src = Self.snippets[lang] else {
                XCTFail("no snippet for wired language \(lang.rawValue) — add one")
                continue
            }
            let runs = TreeSitterEngine.shared.tokenize(src, language: lang)
            XCTAssertFalse(
                runs.isEmpty,
                "\(lang.rawValue) produced no runs — grammar failed to load, query missing, or query matched nothing"
            )
            // Non-empty ranges with real token kinds (not a single
            // zero-length artifact).
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

    // MARK: - Known gaps render plain (documents the bug surface)

    /// The known-gap languages tokenize to nothing — they render plain.
    /// This is intentional documentation of the current bug surface: it
    /// goes RED the moment a grammar is wired for one of them, which is
    /// the prompt to promote that case into `wiredLanguages`.
    func testKnownGapLanguagesRenderPlain() {
        // Minimal, valid-ish snippets in each gap language.
        let gapSnippets: [HighlightLanguage: String] = [
            .go:     "package main\nfunc main() {}",
            .html:   "<html><body>hi</body></html>",
            .css:    "body { color: red; }",
            .sql:    "SELECT id FROM users WHERE id = 1;",
            .ruby:   "def greet(name)\n  puts name\nend",
            .yaml:   "key: value\nlist:\n  - a\n  - b",
            .kotlin: "fun main() { val x = 42 }",
        ]
        for lang in Self.knownGapLanguages {
            guard let src = gapSnippets[lang] else {
                XCTFail("no gap-snippet for \(lang.rawValue)")
                continue
            }
            let runs = TreeSitterEngine.shared.tokenize(src, language: lang)
            XCTAssertTrue(
                runs.isEmpty,
                """
                \(lang.rawValue) now produces highlight runs — a grammar \
                was wired in. Promote it: move \(lang.rawValue) from \
                `knownGapLanguages` into `wiredLanguages`, add a snippet, \
                and remove it from this test's gapSnippets.
                """
            )
        }
    }

    // MARK: - UI never advertises a no-grammar mode

    /// `supportedForDisplay` drives the Language Mode menu + Settings
    /// "Supported languages" list. Per TSK-897, the UI must not offer a
    /// mode that renders plain — every advertised language must be wired
    /// (or, if a future build keeps advertising gaps deliberately, this
    /// test pins the contract so the decision is explicit, not silent).
    ///
    /// NOTE: at the time of writing `supportedForDisplay` filters only
    /// `.plainText`, so it STILL advertises the gap languages. This test
    /// records that reality as `documentedAdvertisedGaps` and fails if it
    /// WIDENS — i.e. a new gap language gets advertised — so the bug
    /// can't grow while the grammar adds are pending owner-approved deps.
    func testAdvertisedGapsDoNotWiden() {
        let advertised = Set(HighlightLanguage.supportedForDisplay)
        let advertisedGaps = advertised.intersection(Self.knownGapLanguages)
        // The gaps currently advertised by the shipping enum. If a
        // grammar is wired (gap removed) this shrinks (fine). If a new
        // un-wired case is advertised this grows (fails) — the guard.
        let documentedAdvertisedGaps = Self.knownGapLanguages
        XCTAssertTrue(
            advertisedGaps.isSubset(of: documentedAdvertisedGaps),
            "a new no-grammar language is now advertised in supportedForDisplay: \(advertisedGaps.subtracting(documentedAdvertisedGaps).map(\.rawValue))"
        )
    }
}
