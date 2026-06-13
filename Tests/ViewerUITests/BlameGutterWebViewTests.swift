import WebKit
import XCTest
@testable import ViewerUI

/// TSK-814 — prove the git-blame gutter markers reach the live CM6 DOM. The
/// Swift half (GitClient.blame → BlameGutterFeeder.markers → DocumentModel
/// refreshBlameMarks → editor.setEditorGutterMarkers → the `setGutterMarkers`
/// dispatch) is headless-tested; this closes the render loop at the DOM layer
/// (the `.cm-blame-marker` gutter element IS the rendered artifact — one step
/// short of pixels, sufficient). The `"blame"` kind maps to `.cm-blame-marker`
/// in codemirror.html (GUTTER_KIND_TO_CSS); the gutter's `initialSpacer` is a
/// `cm-diff-modified` element, so `.cm-blame-marker` is 0 until blame markers
/// are dispatched. Mirrors FoldGutterWebViewTests. `#192`-gated; listed in
/// `test-in-vm.sh` AND `nightly-vm.yml`.
@MainActor
final class BlameGutterWebViewTests: XCTestCase {

    private var webView: WKWebView!

    override func setUp() async throws {
        try WebViewTestTeardown.skipUnlessEnabled()
    }

    override func tearDown() async throws {
        webView = nil
        try await super.tearDown()
    }

    private func loadEditorPage() async throws {
        guard let url = Bundle.module.url(
            forResource: "codemirror", withExtension: "html") else {
            throw XCTSkip("codemirror.html not in the test bundle")
        }
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        webView = WKWebView(
            frame: NSRect(x: 0, y: 0, width: 800, height: 600),
            configuration: config)
        webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        let deadline = Date().addingTimeInterval(10)
        while webView.isLoading, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        _ = await evalUntil("Boolean(window.__mdvView)", deadline: 5)
    }

    @discardableResult
    private func evalUntil(_ expr: String, deadline seconds: TimeInterval) async -> Bool {
        let until = Date().addingTimeInterval(seconds)
        while Date() < until {
            if let ok = try? await webView.evaluateJavaScript("Boolean(\(expr))") as? Bool, ok {
                return true
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return false
    }

    private func blameMarkerCount() async throws -> Int {
        try await webView.evaluateJavaScript(
            "window.__mdvView.dom.querySelectorAll('.cm-blame-marker').length") as? Int ?? -1
    }

    /// Headless WKWebViews never fire the measure/rAF cycle the gutter repaints
    /// on; a no-op doc-change dispatch forces a synchronous repaint (same trick
    /// FoldGutterWebViewTests uses).
    private func repaintNudge() async throws {
        _ = try await webView.evaluateJavaScript("""
        (function () {
          const v = window.__mdvView;
          const end = v.state.doc.length;
          v.dispatch({ changes: { from: end, insert: " " } });
          v.dispatch({ changes: { from: end, to: end + 1 } });
        })();
        """)
    }

    func test_setGutterMarkers_blame_rendersBlameMarkers_withTooltip_inTheLiveDOM() async throws {
        try await loadEditorPage()
        _ = try await webView.evaluateJavaScript("""
        window.cmDispatch({ v: 2, type: "setLanguage", lang: "plain" });
        window.cmDispatch({ v: 2, type: "setText", text: "alpha\\nbeta\\ngamma" });
        """)
        let before = try await blameMarkerCount()
        XCTAssertEqual(before, 0, "the gutter spacer is cm-diff-modified, so no blame markers before dispatch")

        _ = try await webView.evaluateJavaScript("""
        window.cmDispatch({ v: 2, type: "setGutterMarkers", markers: [
          { line: 1, kind: "blame", tooltip: "Alice \\u00b7 3 days ago \\u00b7 Add the parser  [a1b2c3d4]" },
          { line: 2, kind: "blame", tooltip: "Bob \\u00b7 1 hour ago \\u00b7 Fix the bug  [e5f6a7b8]" }
        ]});
        """)
        try await repaintNudge()

        let appeared = await evalUntil(
            "window.__mdvView.dom.querySelectorAll('.cm-blame-marker').length > \(before)", deadline: 5)
        XCTAssertTrue(appeared,
            "blame markers must render as .cm-blame-marker in the gutter (baseline \(before))")

        // The blame DATA (author · time · summary · sha) must reach the DOM title,
        // not just a generic marker — that's what makes it git BLAME, not a dot.
        let tip = try await webView.evaluateJavaScript("""
        (function () {
          const el = window.__mdvView.dom.querySelector('.cm-blame-marker');
          return el ? el.getAttribute('title') : null;
        })();
        """) as? String
        XCTAssertNotNil(tip, "the rendered blame marker carries a title tooltip")
        XCTAssertTrue((tip ?? "").contains("Alice") && (tip ?? "").contains("a1b2c3d4"),
                      "the blame tooltip carries author + short-sha: \(tip ?? "nil")")
    }

    func test_clearingGutterMarkers_removesBlameMarkers() async throws {
        try await loadEditorPage()
        _ = try await webView.evaluateJavaScript("""
        window.cmDispatch({ v: 2, type: "setLanguage", lang: "plain" });
        window.cmDispatch({ v: 2, type: "setText", text: "alpha\\nbeta\\ngamma" });
        window.cmDispatch({ v: 2, type: "setGutterMarkers", markers: [
          { line: 1, kind: "blame", tooltip: "Alice \\u00b7 now \\u00b7 x  [a1b2c3d4]" }
        ]});
        """)
        try await repaintNudge()
        _ = await evalUntil("window.__mdvView.dom.querySelectorAll('.cm-blame-marker').length > 0", deadline: 5)
        let populated = try await blameMarkerCount()
        XCTAssertGreaterThan(populated, 0, "precondition: a blame marker is up")

        _ = try await webView.evaluateJavaScript(
            "window.cmDispatch({ v: 2, type: \"setGutterMarkers\", markers: [] });")
        try await repaintNudge()
        let cleared = await evalUntil(
            "window.__mdvView.dom.querySelectorAll('.cm-blame-marker').length === 0", deadline: 5)
        XCTAssertTrue(cleared, "empty markers must drain the blame markers (was \(populated))")
    }
}
