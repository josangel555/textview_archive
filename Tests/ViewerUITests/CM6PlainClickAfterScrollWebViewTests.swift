import WebKit
import XCTest
@testable import ViewerUI

/// TSK-1188 — BEHAVIORAL render guard for the plain-click-after-scroll bug: clicking a line,
/// scrolling, then plain-clicking elsewhere must place a COLLAPSED caret (not extend a selection
/// from the stale prior anchor, and not jump the viewport back). The fix (c0fd1543) deferred the
/// re-entrant view.dispatch in the TSK-894/890 mouse handlers to a microtask. A host grep-guard
/// pins the deferral; this attempts the actual behavior in-process by synthesizing the mouse
/// gesture via dispatchEvent (testing the prior "not tractable in the webview lane" assumption).
/// `#192`-gated; listed in test-in-vm.sh's webview lane.
@MainActor
final class CM6PlainClickAfterScrollWebViewTests: WebViewTestCase {

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
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 700, height: 300), configuration: config)
        webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        let deadline = Date().addingTimeInterval(10)
        while webView.isLoading, Date() < deadline { try? await Task.sleep(for: .milliseconds(50)) }
        _ = await evalUntil("Boolean(window.__mdvView)", deadline: 5)
    }

    @discardableResult
    private func evalUntil(_ expr: String, deadline seconds: TimeInterval) async -> Bool {
        let until = Date().addingTimeInterval(seconds)
        while Date() < until {
            if let ok = try? await webView.evaluateJavaScript("Boolean(\(expr))") as? Bool, ok { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return false
    }

    /// Robust numeric read — WKWebView bridges a JS number to NSNumber, and a plain `as? Int` can
    /// miss a double-bridged value; go through NSNumber.intValue. Returns -1 on failure.
    private func evalInt(_ expr: String) async -> Int {
        let v = try? await webView.evaluateJavaScript(expr)
        return (v as? NSNumber)?.intValue ?? -1
    }

    func test_plainClickAfterScroll_placesCollapsedCaret_TSK1188() async throws {
        try await loadEditorPage()
        // A tall doc so a scroll moves the first click off-screen.
        var lines: [String] = []
        for i in 1...60 { lines.append("line \(i) ........................................") }
        let text = lines.joined(separator: "\\n")
        _ = try await webView.evaluateJavaScript("""
        window.cmDispatch({ v: 2, type: "setLanguage", lang: "plain" });
        window.cmDispatch({ v: 2, type: "setText", text: "\(text)" });
        """)

        // Synthesize a plain mouse click at a given 1-based line (mousedown→mouseup→click at the
        // line's on-screen coords). Returns true if it dispatched.
        let clickFn = """
        window.__clickLine = function (lineNo) {
          const v = window.__mdvView;
          const line = v.state.doc.line(lineNo);
          const c = v.coordsAtPos(line.from);
          if (!c) return false;
          const x = c.left + 3, y = (c.top + c.bottom) / 2;
          const el = v.contentDOM;
          for (const t of ['mousedown','mouseup','click']) {
            el.dispatchEvent(new MouseEvent(t, { clientX: x, clientY: y, button: 0,
              buttons: t === 'mousedown' ? 1 : 0, bubbles: true, cancelable: true,
              view: window, detail: 1 }));
          }
          return true;
        };
        true;
        """
        _ = try await webView.evaluateJavaScript(clickFn)

        // 1) Click line 3 (sets the anchor).
        let did1 = (try? await webView.evaluateJavaScript("window.__clickLine(3)") as? Bool) ?? false
        try? await Task.sleep(for: .milliseconds(80))   // let the deferred (microtask) dispatch settle

        // FAITHFULNESS GATE: the synthesized click must actually move CM6's caret to line 3. If it
        // doesn't, the synthesis isn't faithful — skip honestly rather than false-green on a
        // collapsed-by-default selection.
        let caretLine1 = await evalInt(
            "window.__mdvView.state.doc.lineAt(window.__mdvView.state.selection.main.head).number")
        guard did1, caretLine1 == 3 else {
            throw XCTSkip("synthesized click didn't faithfully drive CM6's caret (landed on line \(caretLine1)) — behavioral repro isn't tractable in the webview lane; the host grep-guard + owner/spawned-app UAT cover TSK-1188")
        }

        // 2) Scroll down so line 3 leaves the viewport.
        _ = try await webView.evaluateJavaScript("window.__mdvView.scrollDOM.scrollTop = 600; true;")
        try? await Task.sleep(for: .milliseconds(120))
        // 3) Pick a line that's actually VISIBLE at the viewport center — CM6 virtualizes, so an
        // off-screen line has no coords (that's why a fixed faraway line couldn't be clicked).
        let targetLine = await evalInt("""
        (function () {
          const v = window.__mdvView;
          const r = v.scrollDOM.getBoundingClientRect();
          const pos = v.posAtCoords({ x: r.left + 20, y: r.top + r.height / 2 });
          return pos == null ? -1 : v.state.doc.lineAt(pos).number;
        })()
        """)
        guard targetLine > 5 else {
            throw XCTSkip("couldn't resolve a visible target line after scroll (got \(targetLine))")
        }
        // Plain-click the visible target line.
        let did2 = (try? await webView.evaluateJavaScript("window.__clickLine(\(targetLine))") as? Bool) ?? false
        try? await Task.sleep(for: .milliseconds(120))
        guard did2 else { throw XCTSkip("second synthesized click failed to dispatch at line \(targetLine)") }

        let main = "window.__mdvView.state.selection.main"
        let collapsed = (try? await webView.evaluateJavaScript("\(main).empty") as? Bool) ?? false
        let caretLine2 = await evalInt("window.__mdvView.state.doc.lineAt(\(main).head).number")
        // The plain second click must (a) leave a COLLAPSED selection (no range from the stale
        // line-3 anchor) and (b) land at line 30 (proving the click drove CM6, not a default).
        XCTAssertTrue(collapsed,
            "a plain click after scrolling must place a COLLAPSED caret, not extend a selection from the prior anchor (TSK-1188)")
        XCTAssertEqual(caretLine2, targetLine,
            "the collapsed caret must land where the plain click was (line \(targetLine)), proving the click drove CM6")
    }
}
