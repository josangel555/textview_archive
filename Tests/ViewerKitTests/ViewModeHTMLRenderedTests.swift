import XCTest
@testable import ViewerKit

/// Pins the `.html` → rendered-mode wiring in `ViewModeOptions`:
///   * `.html` files offer a Rendered mode (routed to the sanitized,
///     JS-default-deny `HTMLRenderedView` in the UI layer).
///   * The default mode for `.html` stays `.source` — the CONSERVATIVE
///     choice for untrusted HTML (rendered is an explicit opt-in mode).
///   * The picker reads Source | Rendered | … (Rendered slots right
///     after Source, not at the front like markdown).
final class ViewModeHTMLRenderedTests: XCTestCase {
    private func modes(_ path: String) -> [ViewMode] {
        ViewModeOptions.availableModes(for: URL(fileURLWithPath: path))
    }

    func test_html_offersRenderedMode() {
        XCTAssertTrue(modes("/tmp/page.html").contains(.rendered))
        XCTAssertTrue(modes("/tmp/page.htm").contains(.rendered))
        XCTAssertTrue(modes("/tmp/page.xhtml").contains(.rendered))
    }

    func test_html_renderedComesAfterSource_notFront() {
        // The CONSERVATIVE ordering invariant: Source precedes Rendered
        // (Source is the default and the first pick), Rendered precedes
        // HEX. We deliberately do NOT over-constrain adjacency — the
        // `.editor` mode also slots after Source, so the real picker
        // reads Source | Editor | Rendered | Format | HEX. What matters
        // for security/UX is that Rendered is NOT first (unlike markdown).
        let m = modes("/tmp/page.html")
        guard let sourceIdx = m.firstIndex(of: .source),
              let renderedIdx = m.firstIndex(of: .rendered),
              let hexIdx = m.firstIndex(of: .hex) else {
            return XCTFail("html must offer Source, Rendered, and HEX: \(m)")
        }
        XCTAssertNotEqual(m.first, .rendered,
                          "Rendered must NOT be the first/default mode for HTML")
        XCTAssertLessThan(sourceIdx, renderedIdx, "Source must precede Rendered")
        XCTAssertLessThan(renderedIdx, hexIdx, "Rendered must precede HEX")
    }

    func test_html_defaultMode_isSource_conservative() {
        // The security-conservative default: untrusted HTML opens as
        // Source, NOT rendered. The user explicitly switches to Rendered.
        XCTAssertEqual(
            ViewModeOptions.defaultMode(for: URL(fileURLWithPath: "/tmp/page.html")),
            .source
        )
    }

    func test_html_openAsForcedRendered_defaultStillSource() {
        // Even when forced to the HTML category via "Open As…", the
        // default lands on Source (conservative) — unlike markdown which
        // defaults to rendered.
        XCTAssertEqual(
            ViewModeOptions.defaultMode(
                for: URL(fileURLWithPath: "/tmp/data.bin"),
                forcedCategory: .html
            ),
            .source
        )
    }

    func test_html_openAsForcedRendered_offersRendered() {
        let m = ViewModeOptions.availableModes(
            for: URL(fileURLWithPath: "/tmp/data.bin"),
            forcedCategory: .html
        )
        XCTAssertTrue(m.contains(.rendered))
        XCTAssertTrue(m.contains(.source))
    }

    func test_markdown_unchanged_rendersByDefault() {
        // Guard against the HTML wiring accidentally altering markdown:
        // markdown still defaults to rendered and lists rendered FIRST.
        let m = modes("/tmp/README.md")
        XCTAssertEqual(m.first, .rendered)
        XCTAssertEqual(
            ViewModeOptions.defaultMode(for: URL(fileURLWithPath: "/tmp/README.md")),
            .rendered
        )
    }
}
