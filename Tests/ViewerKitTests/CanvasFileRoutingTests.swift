import XCTest

@testable import ViewerKit

/// Canvas M1.S9b (TSK-1364): `.canvas` files are a first-class category
/// routed through the SOURCE lens (the canonical JSON is hand-editable
/// text; the rendered/WYSIWYG lens is M3). Routing here means the file
/// inherits the whole text pipeline — loader, autosave, hot-exit,
/// TabSnapshot — with zero canvas-specific forks.
final class CanvasFileRoutingTests: XCTestCase {

    private let url = URL(fileURLWithPath: "/tmp/design.canvas")

    func test_canvas_extension_detects_as_canvas_category() {
        XCTAssertEqual(FileTypeDetector.category(for: url), .canvas)
        // Case-insensitive like every other extension.
        XCTAssertEqual(
            FileTypeDetector.category(for: URL(fileURLWithPath: "/tmp/X.CANVAS")),
            .canvas)
    }

    func test_canvas_defaults_to_rendered_with_source_one_click_away() {
        XCTAssertTrue(ViewModeOptions.hasTextRepresentation(.canvas))
        XCTAssertFalse(ViewModeOptions.hasNativePreview(.canvas))
        // M3.S7 (TSK-1378): the WYSIWYG lens is PRIMARY (the gesture surface
        // is complete); Source remains available for hand-editing the JSON.
        XCTAssertEqual(
            ViewModeOptions.defaultMode(for: url, isRenderableText: true), .rendered)
        let modes = ViewModeOptions.availableModes(for: url, forcedCategory: nil)
        XCTAssertEqual(modes.first, .rendered, "rendered is the default lens")
        XCTAssertTrue(modes.contains(.source))
        XCTAssertTrue(modes.contains(.hex))
    }

    func test_canvas_source_highlights_as_json() {
        XCTAssertEqual(HighlightLanguage.detect(from: url), .json)
    }
}
