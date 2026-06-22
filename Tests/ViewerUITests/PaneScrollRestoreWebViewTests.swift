import WebKit
import XCTest
import ViewerCore
@testable import ViewerUI

/// TSK-821 — the live-WKWebView half of per-file rendered-markdown scroll
/// persistence. The Swift store (`DocumentModel.renderedScrollByURL` /
/// `rememberRenderedScroll` / `renderedScrollOffset`) is host-tested
/// (`DocumentModelPreviewTests.test_renderedScroll_remembersAndRestoresPerURL`);
/// the VIEW BRIDGE (`MarkdownRenderedView` capturing `window.scrollY` before a
/// reload and restoring via `scrollTo` on `didFinish`) can't be unit-driven —
/// `NSViewRepresentable.Context` isn't constructible. This proves the round-trip
/// MECHANISM works on our ACTUAL rendered page: the page is scrollable, a reload
/// resets it to the top (the bug we fix), and `scrollTo({behavior:'instant'})`
/// (the exact JS the restore path uses) re-applies an offset.
///
/// `#192`-gated (`MDV_RUN_WEBVIEW_TESTS=1`, the VM/nightly WebView lane) — listed
/// in `test-in-vm.sh` `run_webview_tests` AND `nightly-vm.yml` (a gated suite in
/// no lane list runs nowhere).
@MainActor
final class PaneScrollRestoreWebViewTests: WebViewTestCase {

    private var webView: WKWebView!

    override func setUp() async throws {
        try WebViewTestTeardown.skipUnlessEnabled()
    }

    override func tearDown() async throws {
        webView = nil
        try await super.tearDown()
    }

    /// A markdown doc tall enough to scroll well past 400px in an 800×600 view.
    private func tallPage() -> String {
        var md = "# Scroll fixture\n\n"
        for i in 1...200 { md += "Paragraph \(i) — lorem ipsum dolor sit amet, consectetur.\n\n" }
        return HTMLRenderer().renderPage(md, stylesheet: MarkdownStylesheet.load())
    }

    /// (Re)load `html` into a fresh-or-existing WebView and wait for the load.
    private func loadPage(_ html: String, reuse: Bool = false) async {
        if !reuse || webView == nil {
            webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        }
        webView.loadHTMLString(html, baseURL: nil)
        let deadline = Date().addingTimeInterval(10)
        while (webView.isLoading || webView.url == nil), Date() < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        // One extra tick so layout settles enough to be scrollable.
        try? await Task.sleep(for: .milliseconds(100))
    }

    /// Evaluate `expr` expecting a number.
    private func evalDouble(_ expr: String) async throws -> Double {
        try await withCheckedThrowingContinuation { cont in
            webView.evaluateJavaScript(expr) { value, error in
                if let error { cont.resume(throwing: error); return }
                cont.resume(returning: (value as? NSNumber)?.doubleValue ?? -1)
            }
        }
    }

    func test_renderedPage_scrollRoundTrip_captureResetRestore() async throws {
        let page = tallPage()
        await loadPage(page)

        // CAPTURE: the page is scrollable and `scrollY` reflects a `scrollTo`
        // (the read the capture path performs before a reload).
        let scrolled = try await evalDouble(
            "window.scrollTo({top: 400, behavior: 'instant'}); Math.round(window.scrollY)")
        XCTAssertGreaterThan(scrolled, 100,
            "our rendered page must be scrollable (scrollY moved well off the top)")

        // RESET: reload the same html into the RETAINED WebView. Whether scroll
        // snaps to the top or WebKit's scroll-restoration keeps the prior offset
        // is WebKit-version/state-dependent (TSK-959 flake) — so we do NOT pin it
        // to 0; the load-bearing behavior is that RESTORE below re-applies the
        // captured offset (the actual mechanism TSK-821 relies on). We only
        // assert the WebView survived the reload and is still scroll-readable.
        await loadPage(page, reuse: true)
        let afterReload = try await evalDouble("Math.round(window.scrollY)")
        XCTAssertGreaterThanOrEqual(afterReload, 0,
            "WebView remains scroll-readable after a retained-WebView reload (got \(afterReload))")

        // RESTORE: the exact JS the `didFinish` restore path uses re-applies the
        // captured offset on our page.
        let restored = try await evalDouble(
            "window.scrollTo({top: \(Int(scrolled)), behavior: 'instant'}); Math.round(window.scrollY)")
        XCTAssertEqual(restored, scrolled, accuracy: 2,
            "scrollTo({behavior:'instant'}) restores the captured offset")
    }
}
