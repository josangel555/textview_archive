import XCTest
@testable import ViewerKit

/// UX-A (#224) — pure mapping tests for `ViewModeControl`, the presentation
/// layer over `ViewMode`. These are T1m (pure value logic, host-safe): no
/// UI, no DocumentModel, no async — just the round-trip contract between the
/// toolbar's `(primary, viewOnly)` model and the underlying `ViewMode` set.
///
/// The whole point of UX-A is that this layer maps onto the EXISTING modes
/// without touching the (LOADBUG-sensitive) routing — so the contract is:
///   • `present(mode)`  collapses a ViewMode → (primary, viewOnly, isFormatted)
///   • `resolve(primary, viewOnly, available)` maps a button tap back onto a
///     concrete ViewMode the file actually offers.
final class ViewModeControlTests: XCTestCase {

    // MARK: - present(): ViewMode → toolbar projection

    func test_present_render_lenses_collapseToRenderPrimary() {
        for mode in [ViewMode.rendered, .preview, .table, .diff] {
            let p = ViewModeControl.present(mode)
            XCTAssertEqual(p.primary, .render, "\(mode) should present as Render")
            XCTAssertTrue(p.viewOnly, "\(mode) is read-only → View Only on")
            XCTAssertFalse(p.isFormatted)
        }
    }

    func test_present_source_isEditorPrimary_viewOnly() {
        // Source = Editor + View Only (the owner-resolved model).
        let p = ViewModeControl.present(.source)
        XCTAssertEqual(p.primary, .editor)
        XCTAssertTrue(p.viewOnly)
        XCTAssertFalse(p.isFormatted)
    }

    func test_present_editor_isEditorPrimary_notViewOnly() {
        let p = ViewModeControl.present(.editor)
        XCTAssertEqual(p.primary, .editor)
        XCTAssertFalse(p.viewOnly)
        XCTAssertFalse(p.isFormatted)
    }

    func test_present_hex_isHexPrimary() {
        let p = ViewModeControl.present(.hex)
        XCTAssertEqual(p.primary, .hex)
        // HEX byte-edit deferred → View Only reads on today.
        XCTAssertTrue(p.viewOnly)
    }

    func test_present_formatted_isEditorPrimary_andFlagsFormat() {
        let p = ViewModeControl.present(.formatted)
        XCTAssertEqual(p.primary, .editor)
        XCTAssertTrue(p.isFormatted)
    }

    // MARK: - resolve(): toolbar tap → ViewMode (gated by availability)

    /// Markdown: available = [.rendered, .source, .editor, .hex].
    func test_resolve_markdown_render_to_rendered() {
        let avail: [ViewMode] = [.rendered, .source, .editor, .hex]
        XCTAssertEqual(
            ViewModeControl.resolve(primary: .render, viewOnly: true, available: avail),
            .rendered)
    }

    func test_resolve_markdown_editor_viewOnly_to_source() {
        let avail: [ViewMode] = [.rendered, .source, .editor, .hex]
        XCTAssertEqual(
            ViewModeControl.resolve(primary: .editor, viewOnly: true, available: avail),
            .source, "Editor + View Only ⇒ Source (read-only text)")
    }

    func test_resolve_markdown_editor_notViewOnly_to_editor() {
        let avail: [ViewMode] = [.rendered, .source, .editor, .hex]
        XCTAssertEqual(
            ViewModeControl.resolve(primary: .editor, viewOnly: false, available: avail),
            .editor, "Editor + edit ⇒ editable CM6 .editor")
    }

    func test_resolve_hex_alwaysHex() {
        let avail: [ViewMode] = [.rendered, .source, .editor, .hex]
        XCTAssertEqual(
            ViewModeControl.resolve(primary: .hex, viewOnly: true, available: avail), .hex)
        XCTAssertEqual(
            ViewModeControl.resolve(primary: .hex, viewOnly: false, available: avail), .hex)
    }

    /// Plain text file: NO rich lens. available = [.source, .editor, .hex].
    /// Render must fall back to .source (the closest read-only rendering)
    /// rather than forcing an unavailable .rendered.
    func test_resolve_plainText_render_fallsBackToSource() {
        let avail: [ViewMode] = [.source, .editor, .hex]
        XCTAssertEqual(
            ViewModeControl.resolve(primary: .render, viewOnly: true, available: avail),
            .source)
    }

    /// Image / media: available = [.preview, .hex] (no text lens).
    func test_resolve_media_render_to_preview() {
        let avail: [ViewMode] = [.preview, .hex]
        XCTAssertEqual(
            ViewModeControl.resolve(primary: .render, viewOnly: true, available: avail),
            .preview)
    }

    func test_resolve_media_editor_fallsBackToPreview() {
        // No .source/.editor for media — Editor degrades to the natural lens.
        let avail: [ViewMode] = [.preview, .hex]
        XCTAssertEqual(
            ViewModeControl.resolve(primary: .editor, viewOnly: true, available: avail),
            .preview)
        XCTAssertEqual(
            ViewModeControl.resolve(primary: .editor, viewOnly: false, available: avail),
            .preview)
    }

    /// Binary / unknown: available = [.hex] only.
    func test_resolve_binary_everything_to_hex() {
        let avail: [ViewMode] = [.hex]
        for primary in ViewModeControl.Primary.allCases {
            XCTAssertEqual(
                ViewModeControl.resolve(primary: primary, viewOnly: true, available: avail),
                .hex, "binary file: \(primary) must resolve to the only lens, .hex")
        }
    }

    /// CSV: available = [.table, .source, .editor, .hex]. Render ⇒ Table.
    func test_resolve_csv_render_to_table() {
        let avail: [ViewMode] = [.table, .source, .editor, .hex]
        XCTAssertEqual(
            ViewModeControl.resolve(primary: .render, viewOnly: true, available: avail),
            .table)
    }

    /// Diff: available = [.diff, .source, .hex] (no .editor for diffs).
    /// Editor + edit must degrade to .source (diff offers no editable buffer).
    func test_resolve_diff_editor_edit_degradesToSource() {
        let avail: [ViewMode] = [.diff, .source, .hex]
        XCTAssertEqual(
            ViewModeControl.resolve(primary: .editor, viewOnly: false, available: avail),
            .source)
    }

    func test_resolve_emptyAvailable_returnsNil() {
        XCTAssertNil(
            ViewModeControl.resolve(primary: .render, viewOnly: true, available: []))
    }

    // MARK: - button-visibility gating

    func test_showsFormat_onlyWhenFormattedAvailable() {
        XCTAssertTrue(ViewModeControl.showsFormat(available: [.source, .formatted, .hex]))
        XCTAssertFalse(ViewModeControl.showsFormat(available: [.source, .editor, .hex]))
    }

    func test_showsRender_falseForPlainText_trueForRichLenses() {
        XCTAssertFalse(ViewModeControl.showsRender(available: [.source, .editor, .hex]))
        XCTAssertTrue(ViewModeControl.showsRender(available: [.rendered, .source, .hex]))
        XCTAssertTrue(ViewModeControl.showsRender(available: [.preview, .hex]))
        XCTAssertTrue(ViewModeControl.showsRender(available: [.table, .source, .hex]))
        XCTAssertTrue(ViewModeControl.showsRender(available: [.diff, .source, .hex]))
    }

    func test_showsEditor_falseForMediaAndBinary() {
        XCTAssertTrue(ViewModeControl.showsEditor(available: [.source, .editor, .hex]))
        XCTAssertFalse(ViewModeControl.showsEditor(available: [.preview, .hex]))
        XCTAssertFalse(ViewModeControl.showsEditor(available: [.hex]))
    }

    // MARK: - round trip: present(resolve(...)) is stable for the canonical taps

    func test_roundTrip_editorViewOnly_stable() {
        let avail: [ViewMode] = [.rendered, .source, .editor, .hex]
        let mode = ViewModeControl.resolve(primary: .editor, viewOnly: true, available: avail)!
        let p = ViewModeControl.present(mode)
        XCTAssertEqual(p.primary, .editor)
        XCTAssertTrue(p.viewOnly)
    }

    func test_roundTrip_editorEdit_stable() {
        let avail: [ViewMode] = [.rendered, .source, .editor, .hex]
        let mode = ViewModeControl.resolve(primary: .editor, viewOnly: false, available: avail)!
        let p = ViewModeControl.present(mode)
        XCTAssertEqual(p.primary, .editor)
        XCTAssertFalse(p.viewOnly)
    }
}
