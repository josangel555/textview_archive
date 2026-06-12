import WebKit
import XCTest
@testable import ViewerUI

/// TSK-639 — multi-cursor in the live CM6 editor. The behavior pin:
/// `EditorState.allowMultipleSelections.of(true)` is what PERMITS a
/// multi-range selection — without it CM silently COLLAPSES to the main
/// range, so asserting `ranges.length == 2` after dispatching two ranges
/// is a true on/off detector (the teeth mutation is removing the facet).
/// ⌥-click/⌘D/⌥-drag all ride this facet via CM built-ins (searchKeymap's
/// selectNextOccurrence, rectangularSelection) — keystroke synthesis into
/// WKWebView is unreliable headless, so the facet + built-in wiring is
/// the regression surface. `#192`-gated; listed in `test-in-vm.sh` AND
/// `nightly-vm.yml`.
@MainActor
final class MultiCursorWebViewTests: XCTestCase {

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
        // The page builds the editor at load; wait for the global.
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

    func test_twoRangeSelection_survives_allowMultipleSelections() async throws {
        try await loadEditorPage()
        let script = """
        (function () {
          try {
            window.__mdvView.dispatch({ changes: { from: 0, to: window.__mdvView.state.doc.length,
                                       insert: "alpha beta alpha gamma" } });
            const S = CM.EditorSelection;
            window.__mdvView.dispatch({ selection: S.create(
              [S.range(0, 5), S.range(11, 16)], 0) });
            return window.__mdvView.state.selection.ranges.length;
          } catch (e) { return "err:" + String(e); }
        })();
        """
        let result = try await webView.evaluateJavaScript(script)
        XCTAssertEqual(result as? Int, 2,
            "two dispatched ranges must SURVIVE — a collapse to 1 means "
            + "allowMultipleSelections is gone from baseExtensions (TSK-639): \(String(describing: result))")
    }

    func test_withoutFacet_cmCollapses_documentsTheDetector() async throws {
        // The control experiment, run in a THROWAWAY state built without
        // the facet: CM collapses to one range. Proves the assertion above
        // detects exactly the facet, not some other plumbing.
        try await loadEditorPage()
        let script = """
        (function () {
          try {
            const S = CM.EditorSelection;
            const bare = CM.EditorState.create({ doc: "alpha beta alpha" });
            const tr = bare.update({ selection: S.create(
              [S.range(0, 5), S.range(11, 16)], 0) });
            return tr.state.selection.ranges.length;
          } catch (e) { return "err:" + String(e); }
        })();
        """
        let result = try await webView.evaluateJavaScript(script)
        XCTAssertEqual(result as? Int, 1,
            "a facet-less state collapses multi-range — the detector works: \(String(describing: result))")
    }
}
