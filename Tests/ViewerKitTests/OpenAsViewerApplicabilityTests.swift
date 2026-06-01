import XCTest
@testable import ViewerKit

/// WAVE 2b item 6 — the ViewerKit slice of "which viewer modes does the
/// universal Open-As menu offer for a chosen `FileCategory`". Host-safe
/// (pure functions over a URL + a forced category; no FS, no UI).
///
/// `ViewModeOptions.{availableModes,defaultMode}(for:forcedCategory:)`
/// drives the per-viewer mode picker once the user has forced a lens.
/// Existing `ViewModeEditorTests` only covers the AUTO-detect path
/// (forcedCategory == nil); this file pins the forced-lens behavior for
/// EVERY category, including the deliberately-broad rule that a binary
/// file forced to a text lens gets the full structured-mode set (not
/// just HEX) — the whole point of "Open any file as anything".
final class OpenAsViewerApplicabilityTests: XCTestCase {

    private let anyURL = URL(fileURLWithPath: "/tmp/whatever.bin")

    private func modes(_ cat: FileCategory) -> [ViewMode] {
        ViewModeOptions.availableModes(for: anyURL, forcedCategory: cat)
    }

    private func defaultMode(_ cat: FileCategory) -> ViewMode {
        ViewModeOptions.defaultMode(for: anyURL, forcedCategory: cat)
    }

    // MARK: - hasTextRepresentation partition (the gating predicate)

    func test_hasTextRepresentation_partition() {
        let textShaped: Set<FileCategory> = [.markdown, .mermaid, .plainText, .code, .html]
        for cat in FileCategory.allCases {
            XCTAssertEqual(ViewModeOptions.hasTextRepresentation(cat),
                           textShaped.contains(cat),
                           "\(cat) text-representation classification")
        }
    }

    // MARK: - Native-preview categories: Preview primary + HEX secondary

    func test_previewCategories_forced_offerPreviewThenHex() {
        // Bug B: image/audio/video/pdf/sqlite render via the `.preview`
        // document state and now expose a first-class `.preview` ViewMode as
        // their PRIMARY/default lens; HEX stays available as the raw-bytes
        // secondary lens. They must NOT default to HEX.
        for cat in [FileCategory.image, .audio, .video, .pdf, .sqlite] {
            XCTAssertEqual(modes(cat), [.preview, .hex],
                           "\(cat) forced ⇒ Preview primary, HEX secondary")
            XCTAssertEqual(defaultMode(cat), .preview, "\(cat) default ⇒ Preview")
        }
    }

    func test_binary_forced_offerHexOnly() {
        // `.binary` has NO native preview (it'd hit UnsupportedPreview), so it
        // stays HEX-only — it never gets a `.preview` mode.
        XCTAssertEqual(modes(.binary), [.hex])
        XCTAssertEqual(defaultMode(.binary), .hex)
    }

    func test_unknown_forced_offerHexOnly() {
        // `.unknown` has no text representation either.
        XCTAssertEqual(modes(.unknown), [.hex])
        XCTAssertEqual(defaultMode(.unknown), .hex)
    }

    // MARK: - Markdown / mermaid: rendered default

    func test_markdown_forced_offersRendered_andDefaultsToIt() {
        // Forcing markdown on a `.bin` file (no .md extension) must still
        // offer Rendered and default to it.
        let m = modes(.markdown)
        XCTAssertTrue(m.contains(.rendered))
        XCTAssertTrue(m.contains(.source))
        XCTAssertTrue(m.contains(.hex))
        XCTAssertEqual(defaultMode(.markdown), .rendered)
    }

    func test_mermaid_forced_offersRendered_andDefaultsToIt() {
        XCTAssertTrue(modes(.mermaid).contains(.rendered))
        XCTAssertEqual(defaultMode(.mermaid), .rendered)
    }

    // MARK: - Text lenses on a non-text-extension file get the FULL set

    func test_textLens_onBinaryExtension_offersStructuredModes() {
        // The defining "Open As… anything" behavior: a file whose real
        // extension is NOT csv/json still gets Table + Formatted + Editor
        // when the user forces a text lens, so they can inspect e.g. a
        // `.db` as a CSV grid or a `.bin` as pretty JSON.
        for cat in [FileCategory.plainText, .code, .html] {
            let m = modes(cat)
            XCTAssertTrue(m.contains(.source), "\(cat) ⇒ Source")
            XCTAssertTrue(m.contains(.editor), "\(cat) ⇒ Editor")
            XCTAssertTrue(m.contains(.table), "\(cat) ⇒ Table (forced text lens)")
            XCTAssertTrue(m.contains(.formatted), "\(cat) ⇒ Formatted (forced text lens)")
            XCTAssertTrue(m.contains(.hex), "\(cat) ⇒ HEX")
            XCTAssertEqual(defaultMode(cat), .source, "\(cat) default ⇒ Source")
        }
    }

    func test_forcedText_overridesAutoDetectedPreview() {
        // A real `.png` URL auto-detects to .image (Preview primary, HEX
        // secondary — Bug B). Forcing a text lens must flip it to the full
        // structured set — proving the forced category, not the extension,
        // drives the picker.
        let png = URL(fileURLWithPath: "/tmp/pic.png")
        let auto = ViewModeOptions.availableModes(for: png)
        XCTAssertEqual(auto, [.preview, .hex], "auto-detected .png is Preview + HEX")

        let forced = ViewModeOptions.availableModes(for: png, forcedCategory: .plainText)
        XCTAssertTrue(forced.contains(.source))
        XCTAssertTrue(forced.contains(.table))
        XCTAssertTrue(forced.contains(.formatted))
    }

    // MARK: - Editor slotting under a forced text lens

    func test_forcedText_editorSlotsAfterSource() {
        let m = modes(.code)
        guard let s = m.firstIndex(of: .source),
              let e = m.firstIndex(of: .editor) else {
            return XCTFail("expected Source + Editor under forced .code: \(m)")
        }
        XCTAssertEqual(e, s + 1, "Editor must slot directly after Source; got \(m)")
    }

    // MARK: - HEX is always the terminal entry

    func test_hex_isAlwaysLast() {
        for cat in FileCategory.allCases {
            let m = modes(cat)
            XCTAssertEqual(m.last, .hex, "\(cat) picker must end in HEX; got \(m)")
        }
    }
}
