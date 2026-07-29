import XCTest
@testable import ViewerKit

/// TSK-1467 — the canonical `FileCategory → default lens` table is THE single
/// source of truth. Before this, the category→lens decision was re-derived
/// ad-hoc inside `builtinDefaultMode` (and mirrored implicitly in
/// `ViewModeControl.present`), which is the "feels arbitrary / inconsistent"
/// divergence the ticket names. `ViewModeOptions.canonicalDefaultLens(for:)`
/// now owns it and `builtinDefaultMode` delegates.
///
/// TEETH: this suite pins the mapping EXHAUSTIVELY (every `FileCategory` case)
/// and pins that `defaultMode` still reproduces the pre-refactor behavior for
/// representative URLs including the extension refinements (csv→table,
/// diff→diff) and the sniff-hint upgrade. Flip any arm of `canonicalDefaultLens`
/// and the exhaustive assert goes RED; break the delegation and the
/// behavior-preservation asserts go RED. Pure functions — host-safe (T1).
final class ViewModeCanonicalLensTests: XCTestCase {

    /// THE authority. Every category maps here; the switch in
    /// `canonicalDefaultLens` must match this table exactly.
    private let expected: [FileCategory: ViewMode] = [
        .markdown: .rendered,
        .mermaid:  .rendered,
        .canvas:   .rendered,
        // TSK-1588 (owner): text families open EDITABLE by default — the
        // View-Only toggle reads OFF. Files past the CM6 cap are coerced back
        // to .source at open time (DocumentModel.editorDefaultSizeCoercion).
        .plainText: .editor,
        .code:      .editor,
        // html keeps the conservative read-only Source default.
        .html:      .source,
        .image:   .preview,
        .audio:   .preview,
        .video:   .preview,
        .pdf:     .preview,
        .sqlite:  .preview,
        .archive: .preview,
        .binary:  .hex,
        .unknown: .hex,
    ]

    func test_canonicalDefaultLens_isExhaustiveAndCorrect() {
        // No category may be missing from the expectation map — if a new
        // FileCategory is added, this forces the author to decide its lens.
        for cat in FileCategory.allCases {
            guard let want = expected[cat] else {
                XCTFail("FileCategory.\(cat) has no canonical lens expectation — "
                        + "add it to the table + this test")
                continue
            }
            XCTAssertEqual(ViewModeOptions.canonicalDefaultLens(for: cat), want,
                           "canonical lens for \(cat)")
        }
        // And the map must cover exactly the enum (no stale rows).
        XCTAssertEqual(Set(expected.keys), Set(FileCategory.allCases),
                       "expectation table must match FileCategory.allCases exactly")
    }

    // MARK: - defaultMode behaviour preserved through the delegation

    func test_defaultMode_categoryDrivenLenses() {
        // Pure category defaults (no extension refinement).
        XCTAssertEqual(ViewModeOptions.defaultMode(for: url("README.md")), .rendered)
        XCTAssertEqual(ViewModeOptions.defaultMode(for: url("diagram.mmd")), .rendered)
        XCTAssertEqual(ViewModeOptions.defaultMode(for: url("board.canvas")), .rendered)
        // TSK-1588: text families open EDITABLE by default.
        XCTAssertEqual(ViewModeOptions.defaultMode(for: url("notes.txt")), .editor)
        XCTAssertEqual(ViewModeOptions.defaultMode(for: url("main.swift")), .editor)
        // html defaults to Source — Rendered is an explicit opt-in, never default.
        XCTAssertEqual(ViewModeOptions.defaultMode(for: url("page.html")), .source)
        XCTAssertEqual(ViewModeOptions.defaultMode(for: url("pic.png")), .preview)
        XCTAssertEqual(ViewModeOptions.defaultMode(for: url("db.sqlite")), .preview)
        XCTAssertEqual(ViewModeOptions.defaultMode(for: url("blob.xyzzy")), .hex)
    }

    func test_defaultMode_extensionRefinementsOverrideCategory() {
        // csv/tsv are .plainText but the extension refines the default to Table;
        // diff/patch refine to Diff. These layer ON TOP of the canonical table.
        XCTAssertEqual(ViewModeOptions.defaultMode(for: url("data.csv")), .table)
        XCTAssertEqual(ViewModeOptions.defaultMode(for: url("data.tsv")), .table)
        XCTAssertEqual(ViewModeOptions.defaultMode(for: url("change.diff")), .diff)
        XCTAssertEqual(ViewModeOptions.defaultMode(for: url("fix.patch")), .diff)
    }

    func test_defaultMode_sniffHintUpgradesHexToSource() {
        let blob = url("blob.xyzzy")  // .unknown → canonical .hex
        XCTAssertEqual(ViewModeOptions.defaultMode(for: blob), .hex)
        XCTAssertEqual(ViewModeOptions.defaultMode(for: blob, isRenderableText: true), .source,
                       "sniff hint upgrades the HEX default to Source (unchanged by refactor)")
    }

    func test_defaultMode_forcedCategoryUsesCanonicalTable() {
        // An "Open As…" forced category ignores the extension and lands on the
        // canonical lens for the chosen category.
        let anyURL = url("mystery.bin")
        XCTAssertEqual(ViewModeOptions.defaultMode(for: anyURL, forcedCategory: .markdown), .rendered)
        XCTAssertEqual(ViewModeOptions.defaultMode(for: anyURL, forcedCategory: .plainText), .editor)
        XCTAssertEqual(ViewModeOptions.defaultMode(for: anyURL, forcedCategory: .image), .preview)
        XCTAssertEqual(ViewModeOptions.defaultMode(for: anyURL, forcedCategory: .unknown), .hex)
    }

    // MARK: - per-category override (TSK-671) still layers on top

    func test_perCategoryOverride_stillHonoredThroughCanonicalDefault() {
        // The user pins Markdown to open as Source instead of the canonical
        // Rendered. defaultMode must honor it (it's an available mode) — proving
        // the override layering survived the single-source refactor.
        let md = url("README.md")
        XCTAssertEqual(ViewModeOptions.defaultMode(for: md), .rendered,
                       "baseline is the canonical Rendered")
        XCTAssertEqual(
            ViewModeOptions.defaultMode(for: md, preferred: [.markdown: .source]),
            .source,
            "a per-category pin overrides the canonical default when available")
        // A pin to an UNAVAILABLE mode degrades to the canonical default.
        XCTAssertEqual(
            ViewModeOptions.defaultMode(for: md, preferred: [.markdown: .table]),
            .rendered,
            "a stale/cross-type pin (Table on Markdown) degrades to the canonical default")
    }

    private func url(_ name: String) -> URL {
        URL(fileURLWithPath: "/tmp/\(name)")
    }
}
