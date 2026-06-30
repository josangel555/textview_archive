import WebKit
import XCTest
@testable import ViewerUI

/// TSK-1136 / TSK-463 — render-path guard for editor autocomplete: prove that triggering
/// completion INVOKES the editor bridge (a `requestCompletion` post — the literal TSK-463 fix,
/// "never invoked from the editor") AND that injecting a response RENDERS the CM6 autocomplete
/// popup in the live DOM. Drives the real wiring: `startCompletion` (now exposed on window.CM via
/// the entry.js rebundle) → the @codemirror/autocomplete override source → requestCompletionFromSwift
/// → post("requestCompletion") → (inject) `completionResponse` → `.cm-tooltip-autocomplete`.
/// The Swift half (handleCompletionRequest + codec) is host-tested; this is the JS render half.
/// `#192`-gated; listed in test-in-vm.sh's webview lane.
@MainActor
final class EditorCompletionWebViewTests: WebViewTestCase {

    private var webView: WKWebView!

    override func setUp() async throws {
        try WebViewTestTeardown.skipUnlessEnabled()
    }

    override func tearDown() async throws {
        webView = nil
        try await super.tearDown()
    }

    private func loadEditorPage() async throws {
        guard let url = Bundle.module.url(forResource: "codemirror", withExtension: "html") else {
            throw XCTSkip("codemirror.html not in the test bundle")
        }
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: config)
        webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        let deadline = Date().addingTimeInterval(10)
        while webView.isLoading, Date() < deadline { try? await Task.sleep(for: .milliseconds(50)) }
        _ = await evalUntil("Boolean(window.__mdvView) && Boolean(window.CM && window.CM.startCompletion)",
                            deadline: 5)
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

    func test_startCompletion_invokesBridge_andResponseRendersPopup() async throws {
        try await loadEditorPage()
        // Capture the editor→Swift bridge so we can observe the completion request + reply to it.
        _ = try await webView.evaluateJavaScript("""
        window.__captured = [];
        window.webkit = window.webkit || {};
        window.webkit.messageHandlers = window.webkit.messageHandlers || {};
        window.webkit.messageHandlers.mdvEditor = { postMessage: function (b) { window.__captured.push(b); } };
        true;
        """)
        // Seed a doc + put the cursor at the end of an identifier.
        _ = try await webView.evaluateJavaScript("""
        window.cmDispatch({ v: 2, type: "setLanguage", lang: "plain" });
        window.cmDispatch({ v: 2, type: "setText", text: "alpha alphabet" });
        (function () { const v = window.__mdvView; v.dispatch({ selection: { anchor: v.state.doc.length } }); })();
        """)
        // Trigger completion explicitly (the exposed command).
        // Wrap so the eval returns a serializable value — startCompletion's return is not
        // bridgeable ("unsupported type"), which would throw out of evaluateJavaScript.
        _ = try await webView.evaluateJavaScript("window.CM.startCompletion(window.__mdvView); true;")

        // 1) The editor INVOKED completion — a requestCompletion was posted over the bridge.
        let posted = await evalUntil(
            "window.__captured.some(function (b) { return b.type === 'requestCompletion'; })",
            deadline: 3)
        XCTAssertTrue(posted,
            "startCompletion must invoke the editor completion bridge (requestCompletion post) — the TSK-463 fix")

        // 2) Replying with items RENDERS the CM6 autocomplete popup in the live DOM.
        _ = try await webView.evaluateJavaScript("""
        (function () {
          const req = window.__captured.find(function (b) { return b.type === 'requestCompletion'; });
          if (!req) return;
          window.cmDispatch({ v: 2, type: 'completionResponse', replyId: req.replyId,
            items: [{ label: 'alphabet' }, { label: 'alphanumeric' }] });
        })();
        """)
        let rendered = await evalUntil(
            "window.__mdvView.dom.querySelectorAll('.cm-tooltip-autocomplete').length > 0",
            deadline: 3)
        XCTAssertTrue(rendered,
            "the completion response must render the CM6 autocomplete popup (.cm-tooltip-autocomplete)")
    }
}
