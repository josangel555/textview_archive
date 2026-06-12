import WebKit
import XCTest
@testable import ViewerUI

/// TSK-466 — the render-path gap its drain note named: prove
/// `setFoldingRanges` produces REAL fold-gutter markers in the live CM6
/// DOM. The Swift half (DocumentModel producer → ContentView wire →
/// Coordinator dispatch) is covered by the 7 headless tests; this closes
/// the loop at the pixel-adjacent layer (DOM markers — one step short of
/// pixels, sufficient: the gutter element IS the rendered artifact).
/// `#192`-gated; listed in `test-in-vm.sh` AND `nightly-vm.yml`.
@MainActor
final class FoldGutterWebViewTests: XCTestCase {

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
            if let ok = try? await webView.evaluateJavaScript("Boolean(\(expr))") as? Bool,
               ok {
                return true
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return false
    }

    /// Count NON-EMPTY fold-gutter markers in the live DOM.
    private func foldMarkerCount() async throws -> Int {
        let script = """
        (function () {
          // CM keeps an invisible SIZING element holding a marker span —
          // exclude visibility:hidden parents so only real line markers count.
          const els = window.__mdvView.dom.querySelectorAll(
            ".cm-foldGutter .cm-gutterElement [title]");
          let n = 0;
          els.forEach(function (sp) {
            const parent = sp.closest(".cm-gutterElement");
            if (parent && parent.style.visibility !== "hidden") n += 1;
          });
          return n;
        })();
        """
        return try await webView.evaluateJavaScript(script) as? Int ?? -1
    }

    func test_setFoldingRanges_rendersFoldGutterMarkers_inTheLiveDOM() async throws {
        try await loadEditorPage()
        // A plain paragraph: markdown's default folding has nothing to
        // fold here, so the BEFORE state is marker-free — the delta below
        // is attributable to setFoldingRanges alone.
        let seed = """
        window.cmDispatch({ v: 2, type: "setLanguage", lang: "plain" });
        window.cmDispatch({ v: 2, type: "setText",
                            text: "alpha\\n  beta\\n  gamma\\nomega" });
        """
        _ = try await webView.evaluateJavaScript(seed)
        // CM renders one persistent sizing element in the fold gutter, so
        // absolute zero is unattainable — the DELTA is the detector.
        let before = try await foldMarkerCount()

        // Fold offsets: "alpha" ends at 5; the range to the end of
        // "  gamma" (5..22) is a valid LSP-style fold of lines 1-3.
        let setRanges = """
        window.cmDispatch({ v: 2, type: "setFoldingRanges",
                            ranges: [ { from: 5, to: 22 } ] });
        // Headless WKWebViews never fire the measure/rAF cycle the gutter
        // repaints on — a doc-change dispatch repaints synchronously.
        (function () {
          const v = window.__mdvView;
          const end = v.state.doc.length;
          v.dispatch({ changes: { from: end, insert: " " } });
          v.dispatch({ changes: { from: end, to: end + 1 } });
        })();
        """
        _ = try await webView.evaluateJavaScript(setRanges)
        // The compartment reconfigure re-queries the fold service async
        // of the dispatch; poll briefly.
        let appeared = await evalUntil("""
        (function () {
          // CM keeps an invisible SIZING element holding a marker span —
          // exclude visibility:hidden parents so only real line markers count.
          const els = window.__mdvView.dom.querySelectorAll(
            ".cm-foldGutter .cm-gutterElement [title]");
          let n = 0;
          els.forEach(function (sp) {
            const parent = sp.closest(".cm-gutterElement");
            if (parent && parent.style.visibility !== "hidden") n += 1;
          });
          return n > \(before);
        })()
        """, deadline: 5)
        if !appeared {
            let dump = try await webView.evaluateJavaScript("""
            (function () {
              const v = window.__mdvView;
              const els = v.dom.querySelectorAll(".cm-foldGutter .cm-gutterElement");
              const texts = [];
              els.forEach(function (el) { texts.push(JSON.stringify(el.textContent)); });
              return "docLen=" + v.state.doc.length
                + " gutters=" + texts.join(",");
            })();
            """) as? String
            XCTFail("no marker delta (baseline \(before)): \(dump ?? "nil")")
        }
    }

    func test_clearingRanges_removesTheMarkers() async throws {
        try await loadEditorPage()
        _ = try await webView.evaluateJavaScript("""
        window.cmDispatch({ v: 2, type: "setLanguage", lang: "plain" });
        window.cmDispatch({ v: 2, type: "setText",
                            text: "alpha\\n  beta\\n  gamma\\nomega" });
        window.cmDispatch({ v: 2, type: "setFoldingRanges",
                            ranges: [ { from: 5, to: 22 } ] });
        (function () {
          const v = window.__mdvView;
          const end = v.state.doc.length;
          v.dispatch({ changes: { from: end, insert: " " } });
          v.dispatch({ changes: { from: end, to: end + 1 } });
        })();
        """)
        // Wait until the range-driven marker is actually up, capture the
        // populated count, then clear and assert it DROPS back.
        _ = await evalUntil(
            "window.__mdvView.dom.querySelector('.cm-foldGutter') !== null",
            deadline: 5)
        let populated = try await foldMarkerCount()
        XCTAssertGreaterThan(populated, 0)
        _ = try await webView.evaluateJavaScript("""
        window.cmDispatch({ v: 2, type: "setFoldingRanges", ranges: [] });
        (function () {
          const v = window.__mdvView;
          const end = v.state.doc.length;
          v.dispatch({ changes: { from: end, insert: " " } });
          v.dispatch({ changes: { from: end, to: end + 1 } });
        })();
        """)
        let cleared = await evalUntil("""
        (function () {
          // CM keeps an invisible SIZING element holding a marker span —
          // exclude visibility:hidden parents so only real line markers count.
          const els = window.__mdvView.dom.querySelectorAll(
            ".cm-foldGutter .cm-gutterElement [title]");
          let n = 0;
          els.forEach(function (sp) {
            const parent = sp.closest(".cm-gutterElement");
            if (parent && parent.style.visibility !== "hidden") n += 1;
          });
          return n < \(populated);
        })()
        """, deadline: 5)
        XCTAssertTrue(cleared,
            "empty ranges must drain the range-driven markers (was \(populated))")
    }
}
