import XCTest
@testable import ViewerUI

/// TSK-1606 (owner 2026-07-25) — two CM6 host-page contracts:
///
///  1. **Hover line is pointer-gated.** A bare CSS `:hover` follows where the
///     pointer physically sits, so Enter / arrows / scroll slid a DIFFERENT
///     line under a stationary mouse and lit it grey — a phantom second
///     "current line" fighting the blue one. The rule must be scoped to
///     `body.cm-pointer-live`, and the page must drop that class on caret /
///     doc / scroll changes, restoring it only on real pointer MOVEMENT.
///  2. **Active indent guide.** The caret's own nesting level is drawn
///     highlighted so a deep block's column is traceable.
///
/// Source-contract pins (the live pixels are the VM/WebView rung): these keep
/// a silent revert to the bare `:hover` — or a dropped gate wiring — RED on
/// the host gate.
final class EditorHoverAndIndentGuideTests: XCTestCase {

    private func hostHTML() throws -> String {
        let url = try XCTUnwrap(CodeMirrorResources.hostHTMLURL, "codemirror.html missing")
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func hostCSS() throws -> String {
        let url = try XCTUnwrap(CodeMirrorResources.hostCSSURL, "codemirror.css missing")
        return try String(contentsOf: url, encoding: .utf8)
    }

    // MARK: - Hover-line gating

    func test_hoverLineRule_isGatedOnPointerLive_notBareHover() throws {
        let css = try hostCSS()
        XCTAssertTrue(css.contains("body.cm-pointer-live .cm-line:hover"),
                      "the hover line must be scoped to the pointer-live class")
        // No UNGATED `.cm-line:hover` rule may survive — that's the bug.
        for line in css.split(separator: "\n") {
            let s = line.trimmingCharacters(in: .whitespaces)
            guard s.contains(".cm-line:hover"), !s.hasPrefix("*"), !s.hasPrefix("/*") else { continue }
            XCTAssertTrue(s.contains("cm-pointer-live"),
                          "ungated hover rule would reintroduce the phantom line: \(s)")
        }
    }

    func test_page_suppressesHoverOnCaretDocAndScrollChanges() throws {
        let html = try hostHTML()
        XCTAssertTrue(html.contains("cmSuppressHoverLine"),
                      "the page needs an explicit hover-suppress path")
        XCTAssertTrue(html.contains("hoverLineGateExtension"),
                      "a CM6 update listener must drive the suppression")
        // The listener must react to all three content-moving events.
        XCTAssertTrue(
            html.contains("u.docChanged || u.selectionSet || u.viewportChanged"),
            "caret moves, edits AND scrolls must all hide the hover line")
        // And the gate must actually be installed in the extension list.
        XCTAssertTrue(html.contains("hoverLineGateExtension(),"),
                      "the gate extension must be wired into baseExtensions")
        for evt in ["\"wheel\"", "\"scroll\"", "\"keydown\""] {
            XCTAssertTrue(html.contains(evt),
                          "\(evt) must also suppress the stale hover highlight")
        }
    }

    func test_hoverReturnsOnlyOnRealPointerMovement() throws {
        let html = try hostHTML()
        // WebKit fires mousemove when content scrolls under a still pointer;
        // honoring those would reintroduce the bug, so the handler must
        // compare coordinates before re-enabling.
        XCTAssertTrue(
            html.contains("e.clientX === cmPointerX && e.clientY === cmPointerY"),
            "a mousemove with UNCHANGED coordinates must not re-enable hover")
        XCTAssertTrue(html.contains("classList.add(\"cm-pointer-live\")"),
                      "real movement re-enables the hover line")
    }

    // MARK: - Active indent guide

    func test_indentGuides_haveAnActiveLevel() throws {
        let html = try hostHTML()
        XCTAssertTrue(html.contains("--mdv-indent-active"),
                      "the caret's indent level is painted with the active color")
        XCTAssertTrue(html.contains("activeDepth"),
                      "the plugin must compute which level is active")
        // The active guide must follow the CARET, so selection changes have to
        // recompute the decoration.
        XCTAssertTrue(html.contains("u.docChanged || u.viewportChanged || u.selectionSet"),
                      "indent guides must recompute on caret moves too")
        let css = try hostCSS()
        XCTAssertTrue(css.contains("--mdv-indent-active"),
                      "the active guide color must be theme-aware")
        XCTAssertTrue(css.contains("body.dark { --mdv-indent-active"),
                      "…with a dark-appearance override")
    }

    /// TSK-1607 — THE regression the owner caught: guides must PAINT, never
    /// occupy layout. The old widget decoration (`display:inline-block`, width
    /// depth×unit, inserted at line start) sat BEFORE the real leading
    /// whitespace and pushed the text right, so indents rendered ~doubled and
    /// no guide lined up with the text.
    func test_indentGuides_paintWithoutAddingSpace() throws {
        let html = try hostHTML()
        XCTAssertFalse(html.contains("IndentGuideWidget"),
                       "the space-occupying guide widget must be gone")
        XCTAssertTrue(html.contains("function indentGuideStyle("),
                      "guides are drawn as background layers")
        XCTAssertTrue(
            html.contains("attributes: { style: indentGuideStyle(depth, unitSize, active) },"),
            "guides must be a LINE decoration (no layout width), not a widget")
        XCTAssertTrue(html.contains("background-origin:content-box"),
                      "CM6 pads .cm-line — without content-box origin every "
                      + "guide sits right of the true text origin")
    }

    /// TSK-1607 — a literal tab's RENDERED width is the CSS `tab-size`
    /// property; CM6's `tabSize` facet only drives its own column math. With
    /// the CSS property unset, tabs fell back to the browser default (4) and
    /// ignored a configured indent of 2.
    func test_cssTabSize_followsTheConfiguredIndentWidth() throws {
        let html = try hostHTML()
        XCTAssertTrue(html.contains("function applyCSSTabSize("),
                      "the page must set the CSS tab-size property")
        XCTAssertTrue(html.contains("content.style.tabSize = String(size)"),
                      "…on the content element, from the configured size")
        XCTAssertTrue(html.contains("applyCSSTabSize(size);"),
                      "setIndentation must apply it")
        XCTAssertTrue(html.contains("applyCSSTabSize(detectIndentUnitSize(view.state));"),
                      "and it must be applied at BOOT, before Swift pushes a setting")
    }

    func test_indentDepthHelper_isSharedBetweenGuideAndActiveProbe() throws {
        let html = try hostHTML()
        XCTAssertTrue(html.contains("function indentDepthOf("),
                      "one depth helper keeps the drawn guides and the active "
                      + "level from disagreeing")
        // Both call sites use it.
        let uses = html.components(separatedBy: "indentDepthOf(").count - 1
        XCTAssertGreaterThanOrEqual(uses, 3,
            "the helper should back both the guide builder and the active probe")
    }

    func test_multiCursor_hasNoSingleActiveLevel() throws {
        let html = try hostHTML()
        XCTAssertTrue(html.contains("if (sel.ranges.length !== 1) return -1;"),
                      "with multiple cursors there is no ONE active indent level")
    }
}
