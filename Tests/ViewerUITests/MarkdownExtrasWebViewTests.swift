import WebKit
import XCTest
import ViewerCore
@testable import ViewerUI

/// Render rung for the 2026-07-31 markdown gap-closures (footnotes, GFM
/// alerts, definition lists, sup/sub): the host tier proves the MARKUP; this
/// proves the PAINT — a live WKWebView lays the new constructs out with real
/// geometry and the shipped CSS actually applies (computed styles, not just
/// class names in the source). Markup-with-dead-CSS is this feature's
/// false-green shape: the classes are new, so a missing stylesheet rule
/// renders alerts as plain blockquotes and nobody notices.
///
/// `#192`-gated (`MDV_RUN_WEBVIEW_TESTS=1` — the VM webview lane).
@MainActor
final class MarkdownExtrasWebViewTests: WebViewTestCase {

    private var webView: WKWebView!

    override func setUp() async throws {
        try WebViewTestTeardown.skipUnlessEnabled()
    }

    override func tearDown() async throws {
        webView = nil
        try await super.tearDown()
    }

    private func loadRendered(_ markdown: String) async {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        webView = WKWebView(
            frame: NSRect(x: 0, y: 0, width: 900, height: 600), configuration: config)
        let page = HTMLRenderer().renderPage(
            markdown, stylesheet: MarkdownStylesheet.cached)
        webView.loadHTMLString(page, baseURL: nil)
        let deadline = Date().addingTimeInterval(10)
        while webView.isLoading, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    private func evalDouble(_ js: String) async -> Double {
        await withCheckedContinuation { (cont: CheckedContinuation<Double, Never>) in
            webView.evaluateJavaScript(js) { v, _ in
                cont.resume(returning: (v as? NSNumber)?.doubleValue ?? -1)
            }
        }
    }

    private func evalString(_ js: String) async -> String {
        await withCheckedContinuation { (cont: CheckedContinuation<String, Never>) in
            webView.evaluateJavaScript(js) { v, _ in
                cont.resume(returning: (v as? String) ?? "")
            }
        }
    }

    /// Owner bug 2026-08-26 — links rendered BLACK: every `--mdv-*`
    /// system-color var was an invalid comma list (`-apple-system-blue,
    /// #0066cc`), so var() consumers fell back to inheritance (links = body
    /// black; h5/h6 lost their secondary grey the same way). Pin the PAINT:
    /// computed anchor color must differ from body text and be
    /// blue-dominant; the secondary-heading grey must differ from body too.
    func test_links_paintBlue_notBodyText() async throws {
        await loadRendered("[a link](https://example.com) and text\n\n##### fine print\n")
        let linkColor = await evalString(
            "getComputedStyle(document.querySelector('a')).color")
        let bodyColor = await evalString(
            "getComputedStyle(document.body).color")
        XCTAssertFalse(linkColor.isEmpty, "anchor missing from the render")
        XCTAssertNotEqual(linkColor, bodyColor,
            "a link must not paint in the body text color (the invalid-var inherit bug)")
        // Blue-dominance (works for both appearances: #0066cc / #419cff).
        // Computed form is `rgb(r, g, b)`; parse defensively — the inequality
        // pins above are the hard teeth.
        let comps = linkColor.dropFirst(4).dropLast()
            .split(separator: ",")
            .compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        if comps.count == 3 {
            XCTAssertGreaterThan(comps[2], comps[0], "link color must be blue-dominant")
            XCTAssertGreaterThan(comps[2], comps[1], "link color must be blue-dominant")
        }
        let h5Color = await evalString(
            "getComputedStyle(document.querySelector('h5')).color")
        XCTAssertNotEqual(h5Color, bodyColor,
            "h5 must paint the secondary grey, not the body color (same invalid-var class)")
    }

    /// Class tripwire (host-cheap, runs in this lane anyway): no `--mdv-*`
    /// custom property may hold a `-apple-system-*, fallback` comma list —
    /// that value is invalid at computed-value time and silently reverts
    /// every consumer to inheritance.
    func test_stylesheet_hasNoInvalidCommaListSystemColorVars() {
        let css = MarkdownStylesheet.cached
        let pattern = #"--mdv-[a-z-]+:\s*-apple-system-[a-z-]+\s*,"#
        XCTAssertNil(css.range(of: pattern, options: .regularExpression),
            "markdown.css regressed to the invalid `-apple-system-x, fallback` var pattern")
    }

    func test_gfmAlert_paintsTintedBoxWithColoredTitle() async throws {
        await loadRendered("> [!WARNING]\n> mind the gap\n")
        let h = await evalDouble(
            "document.querySelector('.mdv-alert-warning')?.getBoundingClientRect().height ?? -1")
        XCTAssertGreaterThan(h, 20, "the alert box must LAY OUT (height \(h))")
        // The CSS actually applied: a translucent tint, not the default
        // transparent blockquote background.
        let bg = await evalString(
            "getComputedStyle(document.querySelector('.mdv-alert-warning')).backgroundColor")
        XCTAssertFalse(bg.isEmpty || bg == "rgba(0, 0, 0, 0)",
            "the alert tint must paint — got '\(bg)' (stylesheet rule missing?)")
        let titleWeight = await evalString(
            "getComputedStyle(document.querySelector('.mdv-alert-title')).fontWeight")
        XCTAssertTrue(["600", "700", "bold"].contains(titleWeight),
            "the title row reads as a title (weight \(titleWeight))")
    }

    func test_footnote_markerAndSectionLayOut_andAnchorsResolve() async throws {
        await loadRendered("fact[^a] more\n\n[^a]: the source\n")
        let marker = await evalDouble(
            "document.querySelector('.mdv-fnref a')?.getBoundingClientRect().width ?? -1")
        XCTAssertGreaterThan(marker, 2, "the superscript marker is clickable ink (\(marker))")
        let section = await evalDouble(
            "document.querySelector('.mdv-footnotes')?.getBoundingClientRect().height ?? -1")
        XCTAssertGreaterThan(section, 10, "the collected section lays out (\(section))")
        // Both hops of the round-trip resolve to real elements.
        let hops = await evalDouble("""
            (document.getElementById('mdv-fn-a') ? 1 : 0)
            + (document.getElementById('mdv-fnref-a') ? 1 : 0)
            """)
        XCTAssertEqual(hops, 2, "marker→note and note→marker anchors must both resolve")
    }

    func test_supSub_typesetSmallerThanProse() async throws {
        await loadRendered("a ^up^ and ~down~ end")
        let proseSize = await evalDouble(
            "parseFloat(getComputedStyle(document.querySelector('p')).fontSize)")
        let supSize = await evalDouble(
            "parseFloat(getComputedStyle(document.querySelector('sup')).fontSize)")
        let subSize = await evalDouble(
            "parseFloat(getComputedStyle(document.querySelector('sub')).fontSize)")
        XCTAssertGreaterThan(supSize, 1, "sup must exist and lay out")
        XCTAssertLessThan(supSize, proseSize, "sup typesets smaller than prose")
        XCTAssertLessThan(subSize, proseSize, "sub typesets smaller than prose")
    }

    func test_wikilink_paintsAsDottedUnderlineLink() async throws {
        await loadRendered("see [[Design Notes]] here")
        let w = await evalDouble(
            "document.querySelector('a.mdv-wikilink')?.getBoundingClientRect().width ?? -1")
        XCTAssertGreaterThan(w, 20, "the wikilink lays out as real link ink (\(w))")
        let deco = await evalString(
            "getComputedStyle(document.querySelector('a.mdv-wikilink')).textDecorationStyle")
        XCTAssertEqual(deco, "dotted",
            "the wikilink's distinguishing style must apply (got '\(deco)')")
    }

    func test_definitionList_titleReadsBold() async throws {
        await loadRendered("Term\n: the definition\n")
        let dtWeight = await evalString(
            "getComputedStyle(document.querySelector('dt')).fontWeight")
        XCTAssertTrue(["600", "700", "bold"].contains(dtWeight),
            "dt must read as the term (weight '\(dtWeight)' — stylesheet rule missing?)")
        let ddIndent = await evalDouble(
            "document.querySelector('dd')?.getBoundingClientRect().left ?? -1")
        let dtLeft = await evalDouble(
            "document.querySelector('dt')?.getBoundingClientRect().left ?? -1")
        XCTAssertGreaterThan(ddIndent, dtLeft, "the definition indents under its term")
    }
}
