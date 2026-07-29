import XCTest
@testable import ViewerKit

/// TSK-671 — per-file-category default view-mode override threaded through
/// `ViewModeOptions.defaultMode(…, preferred:)`. The user can pin a category
/// (e.g. Markdown) to a non-built-in default (e.g. Source instead of Rendered),
/// applied to fresh opens. The override is AVAILABILITY-GATED: a pinned mode the
/// file doesn't actually offer degrades silently to the built-in default so the
/// picker can't desync from the pane.
///
/// Pure functions over a URL — host-safe (T1), no FS, no UI.
///
/// TEETH: every honored-override assertion FAILS if the `preferred` argument is
/// ignored (it would return the built-in `.rendered`/`.table`), and every
/// degrade assertion FAILS if the availability gate is dropped (it would return
/// the unavailable pinned mode).
final class ViewModeDefaultOverrideTests: XCTestCase {

    private let md   = URL(fileURLWithPath: "/tmp/README.md")     // .markdown → .rendered
    private let csv  = URL(fileURLWithPath: "/tmp/data.csv")      // .plainText → .table
    private let txt  = URL(fileURLWithPath: "/tmp/notes.txt")     // .plainText → .source
    private let code = URL(fileURLWithPath: "/tmp/main.swift")    // .code → .source

    // MARK: Baseline — no override changes nothing

    func test_emptyPreferred_isBuiltinDefault() {
        // The new parameter defaults to empty; behavior is identical to before.
        XCTAssertEqual(ViewModeOptions.defaultMode(for: md), .rendered)
        XCTAssertEqual(ViewModeOptions.defaultMode(for: csv), .table)
        XCTAssertEqual(ViewModeOptions.defaultMode(for: md, preferred: [:]), .rendered)
        XCTAssertEqual(ViewModeOptions.defaultMode(for: csv, preferred: [:]), .table)
    }

    // MARK: Honored overrides (mode is available for the file)

    func test_markdownPinnedToSource_opensSource_notRendered() {
        XCTAssertEqual(
            ViewModeOptions.defaultMode(for: md, preferred: [.markdown: .source]),
            .source,
            "pinning Markdown→Source must beat the built-in Rendered default")
    }

    func test_csvPinnedToSource_opensSource_notTable() {
        // CSV classifies as `.plainText`; the built-in default is Table.
        XCTAssertEqual(FileTypeDetector.category(for: csv), .plainText)
        XCTAssertEqual(
            ViewModeOptions.defaultMode(for: csv, preferred: [.plainText: .source]),
            .source,
            "pinning Plain Text→Source must beat the built-in Table default for CSV")
    }

    func test_override_doesNotChangeAvailableModes() {
        // The override moves only the DEFAULT, never the available set.
        let before = ViewModeOptions.availableModes(for: md)
        XCTAssertEqual(before.first, .rendered)
        // (no availableModes(preferred:) overload exists — the picker list is
        // unchanged; only `defaultMode` consults the pref.)
        XCTAssertTrue(before.contains(.source))
    }

    // MARK: Availability gate — a pinned-but-unavailable mode degrades

    func test_crossTypePin_unavailableForThisFile_degradesToBuiltin() {
        // `.plainText → .table` is valid for CSV but NOT for a .txt (no Table
        // mode). The .txt must keep its built-in Source default, not jump to a
        // Table mode it doesn't offer.
        XCTAssertEqual(FileTypeDetector.category(for: txt), .plainText)
        XCTAssertFalse(ViewModeOptions.availableModes(for: txt).contains(.table))
        XCTAssertEqual(
            ViewModeOptions.defaultMode(for: txt, preferred: [.plainText: .table]),
            .editor,   // TSK-1588: text's built-in default is now the Editor lens
            "a pinned mode the file doesn't offer must degrade to the built-in default")
    }

    func test_pinToModeNotOfferedByCategory_isIgnored() {
        // `.code → .rendered`: source code has no Rendered mode. Ignored.
        XCTAssertFalse(ViewModeOptions.availableModes(for: code).contains(.rendered))
        XCTAssertEqual(
            ViewModeOptions.defaultMode(for: code, preferred: [.code: .rendered]),
            .editor)   // TSK-1588: code's built-in default is now the Editor lens
    }

    // MARK: No-op / non-matching pins

    func test_pinEqualToBuiltin_isNoOp() {
        XCTAssertEqual(
            ViewModeOptions.defaultMode(for: md, preferred: [.markdown: .rendered]),
            .rendered)
    }

    func test_pinForDifferentCategory_doesNotLeak() {
        // A pin on `.markdown` must not affect a `.code` file.
        XCTAssertEqual(
            ViewModeOptions.defaultMode(for: code, preferred: [.markdown: .source]),
            .editor,  // code's own built-in default (TSK-1588: Editor), untouched
            "a markdown pin must not change a swift file")
        XCTAssertEqual(
            ViewModeOptions.defaultMode(for: csv, preferred: [.markdown: .source]),
            .table,
            "a markdown pin must not change the CSV default")
    }

    // MARK: Forced-category interaction (Open-As lens)

    func test_override_keysOnForcedCategory() {
        // With an explicit forced category the override is looked up under the
        // FORCED category (the effective one), and gated against the forced
        // file's available modes.
        let db = URL(fileURLWithPath: "/tmp/x.sqlite")
        XCTAssertEqual(
            ViewModeOptions.defaultMode(
                for: db, forcedCategory: .markdown, preferred: [.markdown: .source]),
            .source,
            "forced .markdown + Markdown→Source pin resolves to Source")
        // Pin that targets the file's NATURAL category is irrelevant when a
        // different category is forced.
        XCTAssertEqual(
            ViewModeOptions.defaultMode(
                for: db, forcedCategory: .markdown, preferred: [.sqlite: .hex]),
            .rendered,
            "a .sqlite pin is ignored while forced as .markdown")
    }
}
