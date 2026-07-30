import WebKit
import XCTest
import ViewerCore
@testable import ViewerUI

/// Partial-T6 rung for LaTeX math (2026-07-29): the host tier proves the
/// MARKUP (`<math>` reaches the page); this proves the RENDER — a live
/// WKWebView lays the MathML out with real, non-zero geometry, i.e. WebKit's
/// native MathML Core actually paints it. Markup presence with zero-size
/// layout is exactly the false green the test pyramid warns about.
///
/// `#192`-gated (`MDV_RUN_WEBVIEW_TESTS=1` — the VM webview lane).
@MainActor
final class MathRenderWebViewTests: WebViewTestCase {

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

    func test_inlineMath_paintsWithRealGeometry() async throws {
        await loadRendered("Euler: $e^{i\\pi} + 1 = 0$ in prose")
        let h = await evalDouble(
            "document.querySelector('math')?.getBoundingClientRect().height ?? -1")
        let w = await evalDouble(
            "document.querySelector('math')?.getBoundingClientRect().width ?? -1")
        XCTAssertGreaterThan(h, 5, "MathML must LAY OUT, not just parse (height \(h))")
        XCTAssertGreaterThan(w, 20, "the equation occupies real width (\(w))")
    }

    func test_displayMath_paintsTallerThanInline_withAFractionBar() async throws {
        await loadRendered("$$\\frac{-b \\pm \\sqrt{b^2 - 4ac}}{2a}$$")
        let h = await evalDouble(
            "document.querySelector('math[display=\"block\"]')?.getBoundingClientRect().height ?? -1")
        XCTAssertGreaterThan(h, 20,
            "a display fraction is a tall box — near-zero means WebKit didn't render it (\(h))")
        let fracH = await evalDouble(
            "document.querySelector('mfrac')?.getBoundingClientRect().height ?? -1")
        XCTAssertGreaterThan(fracH, 15, "the fraction structure itself has geometry (\(fracH))")
    }

    /// Two failure shapes, probed live (2026-07-30 — the first version of
    /// this test assumed a third that doesn't exist):
    /// - `$\frac{$` never LEXES as math → stays literal prose;
    /// - a lexed-but-invalid expression renders the engine's `<merror>`,
    ///   which must have real on-screen geometry (the author SEES it).
    func test_brokenTex_staysProse_orShowsAVisibleError() async throws {
        await loadRendered("broken: $\\frac{$ end")
        let literal = await evalDouble(
            "document.body.innerText.includes('$\\\\frac{$') ? 1 : 0")
        XCTAssertEqual(literal, 1, "unlexable pseudo-math stays visible prose")

        await loadRendered("see $\\notacommand{x}$ here")
        let errH = await evalDouble(
            "document.querySelector('merror')?.getBoundingClientRect().height ?? -1")
        XCTAssertGreaterThan(errH, 5,
            "a lexed-but-invalid expression must paint a visible merror (\(errH))")
    }
}
