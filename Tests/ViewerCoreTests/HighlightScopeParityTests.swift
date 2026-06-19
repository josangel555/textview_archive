import XCTest
import ViewerKit
@testable import ViewerCore

/// TSK-962 — Source(TreeSitter) ↔ Edit(CM6/Lezer) highlight SCOPE parity.
///
/// `SyntaxThemeCMPaletteTests` pins COLOR parity (kind → hex). This suite pins
/// the SCOPE → kind half: the single canonical `HighlightScopeMap` is
/// self-consistent, the Source path's `CaptureMap` is actually derived from it
/// (no behavior drift), and every scope the Source path emits over a language
/// corpus is REACHABLE on the CM6 path (has a Lezer-tag mapping). A divergence
/// at the model layer fails HERE on the host gate; pixel parity is the VM tail
/// (`EditorThemeParityTests`).
final class HighlightScopeParityTests: XCTestCase {

    // MARK: - Canonical map self-consistency

    /// The single source of truth must declare every `TokenKind` exactly once,
    /// with BOTH a TreeSitter-capture mapping (Source path can emit it) and a
    /// Lezer-tag mapping (CM6 path can paint it). Any gap = a path that can
    /// never produce/paint that scope = a guaranteed divergence.
    func test_canonicalMap_isFullCoverageAndConsistent() {
        let cov = HighlightParityHarness.coverage()
        XCTAssertTrue(cov.isParity, """
            HighlightScopeMap is not parity-complete:
              missing entry:        \(cov.kindsMissingEntry)
              missing captures:     \(cov.kindsMissingCaptures)
              missing lezer tags:   \(cov.kindsMissingLezerTags)
              duplicate kinds:      \(cov.duplicateKinds)
            """)
    }

    /// Every `TokenKind` appears once — explicit count guard so adding a kind
    /// without a row trips immediately (not just via `coverage`).
    func test_everyTokenKindHasExactlyOneEntry() {
        let kinds = HighlightScopeMap.entries.map(\.kind)
        XCTAssertEqual(Set(kinds).count, kinds.count,
                       "duplicate TokenKind row in HighlightScopeMap")
        XCTAssertEqual(Set(kinds), Set(TokenKind.allCases),
                       "HighlightScopeMap must cover all TokenKinds exactly")
    }

    // MARK: - CaptureMap derives from the canonical map

    /// `CaptureMap.table` IS the canonical capture table — proving the Source
    /// path sources the one map (not a stale parallel copy).
    func test_captureMap_derivesFromCanonical() {
        XCTAssertEqual(CaptureMap.table, HighlightScopeMap.captureTable)
    }

    /// Behavior pin: the dotted-walk resolution preserves the historical
    /// special cases that order-sensitivity depends on. `string.special.key`
    /// (JSON keys) must beat the coarser `string`; `constant.builtin` must beat
    /// `constant`; `function.builtin` must beat `function`. Guards against a
    /// canonical-map edit silently changing the Source path's coloring.
    func test_captureResolution_specificBeatsGeneric() {
        XCTAssertEqual(CaptureMap.kind(forCapture: "string"), .string)
        XCTAssertEqual(CaptureMap.kind(forCapture: "string.special.key"),
                       .tagAttribute)
        XCTAssertEqual(CaptureMap.kind(forCapture: "string.escape"), .escape)
        XCTAssertEqual(CaptureMap.kind(forCapture: "constant"), .constant)
        XCTAssertEqual(CaptureMap.kind(forCapture: "constant.builtin"),
                       .builtin)
        XCTAssertEqual(CaptureMap.kind(forCapture: "function"), .function)
        XCTAssertEqual(CaptureMap.kind(forCapture: "function.builtin"),
                       .builtin)
        XCTAssertEqual(CaptureMap.kind(forCapture: "type.builtin"), .builtin)
        // Fallback walk: an unknown dotted suffix drops to its known prefix.
        XCTAssertEqual(CaptureMap.kind(forCapture: "keyword.control.return"),
                       .keyword)
        // Wholly unknown → nil (theme default renders it).
        XCTAssertNil(CaptureMap.kind(forCapture: "totally.unknown.scope"))
    }

    // MARK: - Parity harness over a real corpus

    /// The corpus: small but scope-diverse fixtures per language. Each is
    /// host-tokenizable (the grammars dlopen from the prior `swift build`).
    private static let corpus: [(HighlightLanguage, String)] = [
        (.swift, """
        // a comment
        import Foundation
        func greet(name: String) -> Int {
            let n = 42
            return n
        }
        """),
        (.json, #"{ "name": "alice", "n": 42, "ok": true, "x": null }"#),
        (.python, """
        # hi
        def greet(name):
            return name + str(42)
        """),
        (.javascript, """
        // header
        const x = 42;
        function f(a, b) { return a + b; }
        """),
        (.typescript, """
        const x: number = 42;
        function f(a: string): string { return a; }
        """),
        (.shell, """
        # comment
        if [ -f "$HOME/.zshrc" ]; then echo "yes"; fi
        """),
        (.markdown, "# Title\n\nBody **bold** and `code`."),
    ]

    /// THE parity assertion: every scope the Source path emits over the corpus
    /// is reachable on the CM6 path. If the Source path can produce a
    /// `TokenKind` the editor's Lezer mapping can't paint, the two views
    /// diverge for that scope — fail with the offending kinds.
    func test_everySourceScopeIsReachableOnEditorPath() {
        for (lang, src) in Self.corpus {
            let unreachable = HighlightParityHarness.unreachableKinds(
                for: src, language: lang)
            XCTAssertTrue(unreachable.isEmpty, """
                \(lang.displayName): Source path emits scope(s) the CM6 editor \
                cannot paint (no Lezer mapping): \(unreachable). \
                Add the Lezer tag(s) to HighlightScopeMap + codemirror.html.
                """)
        }
    }

    /// The harness produces a non-trivial, ordered `(range, kind)` sequence —
    /// the comparable form the epic specifies. Pin that it's actually ordered
    /// and that representative scopes show up (so the corpus is exercising the
    /// path, not silently empty).
    func test_sourceScopeSequence_isOrderedAndPopulated() {
        let swift = Self.corpus.first { $0.0 == .swift }!.1
        let seq = HighlightParityHarness.sourceScopeSequence(
            for: swift, language: .swift)
        XCTAssertFalse(seq.isEmpty, "swift corpus produced no scope sequence")

        // Strictly non-decreasing by start offset (paint-over already
        // coalesces; harness sorts).
        for i in 1..<seq.count {
            XCTAssertLessThanOrEqual(
                seq[i - 1].range.location, seq[i].range.location,
                "scope sequence not ordered by start offset")
        }

        let kinds = Set(seq.map(\.kind))
        XCTAssertTrue(kinds.contains(.keyword), "expected a keyword scope")
        XCTAssertTrue(kinds.contains(.comment), "expected a comment scope")
        XCTAssertTrue(kinds.contains(.number),  "expected a number scope")
    }

    /// Every Lezer tag in the canonical map is well-formed: either a bare
    /// `t.<name>` identifier or a single-arg modifier call
    /// `t.<mod>(t.<name>)`. Guards the format the `ViewerUITests` drift test
    /// (which greps the HTML literal) relies on.
    func test_lezerTags_areWellFormed() {
        let bare = try! NSRegularExpression(pattern: #"^t\.[A-Za-z]+$"#)
        let call = try! NSRegularExpression(
            pattern: #"^t\.[A-Za-z]+\(t\.[A-Za-z]+\)$"#)
        for entry in HighlightScopeMap.entries {
            for tag in entry.lezerTags {
                let r = NSRange(tag.startIndex..., in: tag)
                let ok = bare.firstMatch(in: tag, range: r) != nil
                    || call.firstMatch(in: tag, range: r) != nil
                XCTAssertTrue(ok, "malformed Lezer tag '\(tag)' for \(entry.kind)")
            }
        }
    }
}
