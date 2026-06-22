import WebKit
import XCTest
@testable import ViewerUI

/// TSK-770 — prove the editor Find bar's Replace / ReplaceAll actually EDIT the
/// live CM6 document, not just that the dispatch fires. The Swift half (model
/// editorReplaceNext/showEditorReplaceBar, FindBar ReplaceConfig, the
/// replaceNext/replaceAll dispatch) is host-tested (FindBarTests); this closes
/// the behavior loop in the real editor: setSearchQuery{query,replace} →
/// replaceAll/replaceNext → the doc text changes. Mirrors
/// FoldGutterWebViewTests. `#192`-gated; listed in test-in-vm.sh + nightly-vm.yml.
@MainActor
final class EditorReplaceWebViewTests: WebViewTestCase {

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

    private func docText() async throws -> String {
        try await webView.evaluateJavaScript("window.__mdvView.state.doc.toString()") as? String ?? "<nil>"
    }

    func test_replaceAll_replacesEveryMatch_inTheLiveDoc() async throws {
        try await loadEditorPage()
        _ = try await webView.evaluateJavaScript("""
        window.cmDispatch({ v: 2, type: "setLanguage", lang: "plain" });
        window.cmDispatch({ v: 2, type: "setText", text: "foo foo foo" });
        // openSearch configures the search state CM's replace commands read.
        window.cmDispatch({ v: 2, type: "openSearch" });
        window.cmDispatch({ v: 2, type: "setSearchQuery", query: "foo", replace: "bar" });
        window.cmDispatch({ v: 2, type: "replaceAll" });
        """)
        let done = await evalUntil(
            "window.__mdvView.state.doc.toString() === 'bar bar bar'", deadline: 5)
        let text = try await docText()
        XCTAssertTrue(done, "replaceAll must turn every 'foo' into 'bar' — got '\(text)'")
    }

    func test_replaceNext_replacesOneMatch_notAll() async throws {
        try await loadEditorPage()
        // CM6 replaceNext is SELECT-then-replace: it replaces the current
        // selection IFF it matches the query, then finds the next. So the real
        // find-bar flow selects a match first (findNext on query type) before
        // Replace; mirror that — findNext selects the first "foo", then
        // replaceNext replaces exactly it. (replaceNext with no prior selection
        // only selects, replacing nothing — not a product bug.)
        _ = try await webView.evaluateJavaScript("""
        window.cmDispatch({ v: 2, type: "setLanguage", lang: "plain" });
        window.cmDispatch({ v: 2, type: "setText", text: "foo foo foo" });
        window.cmDispatch({ v: 2, type: "openSearch" });
        window.cmDispatch({ v: 2, type: "setSearchQuery", query: "foo", replace: "bar" });
        window.cmDispatch({ v: 2, type: "findNext" });
        window.cmDispatch({ v: 2, type: "replaceNext" });
        """)
        // Exactly one 'foo' becomes 'bar': "bar" appears once, "foo" still twice.
        let one = await evalUntil("""
        (function () {
          const t = window.__mdvView.state.doc.toString();
          return (t.split("bar").length - 1) === 1 && (t.split("foo").length - 1) === 2;
        })()
        """, deadline: 5)
        let text = try await docText()
        XCTAssertTrue(one, "replaceNext must replace exactly one match (not all) — got '\(text)'")
    }
}
