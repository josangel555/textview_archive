import WebKit
import XCTest
@testable import ViewerUI

/// TSK-1259 — the LIVE-CM6 guard that the editor caret does NOT blink (owner
/// request: steady caret in both vim NORMAL (block) and INSERT (line) modes).
///
/// `codemirror.html` configures `drawSelection({ cursorBlinkRate: 0 })`. CM6's
/// cursor layer sets `style.animationDuration = cursorBlinkRate + "ms"` on mount
/// (`Fd()` in @codemirror/view), so a 0 rate renders a steady caret. We assert
/// the live cursor layer's COMPUTED `animationDuration` is `0s` — which would be
/// `1.2s` if the config regressed to a bare `drawSelection()` (the teeth).
///
/// This also covers the vim NORMAL block ("fat") cursor transitively: the vim
/// package's `setBlinkRate()` reads the SAME `cursorBlinkRate` facet (combine =
/// `Math.min`), so a 0 here is the single source of truth for both cursors.
///
/// `#192`-gated (`MDV_RUN_WEBVIEW_TESTS=1`, the VM/nightly WebView lane); an
/// in-process WKWebView (not the spawned-app UAT) because CM6's WebContent is
/// jetsam-killed under the GUI-lane viaOpen launch.
@MainActor
final class EditorCursorBlinkWebViewTests: WebViewTestCase {

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

    // Completion-handler evaluateJavaScript (see EditorScrollRestoreWebViewTests
    // for why the async variant is avoided — WKError-5 flakiness).
    private func evalBool(_ js: String) async -> Bool {
        await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            webView.evaluateJavaScript(js) { value, _ in
                cont.resume(returning: ((value as? NSNumber)?.boolValue) ?? (value as? Bool ?? false))
            }
        }
    }

    private func evalString(_ js: String) async -> String {
        await withCheckedContinuation { (cont: CheckedContinuation<String, Never>) in
            webView.evaluateJavaScript(js) { value, _ in
                cont.resume(returning: (value as? String) ?? "")
            }
        }
    }

    @discardableResult
    private func evalUntil(_ expr: String, deadline seconds: TimeInterval) async -> Bool {
        let until = Date().addingTimeInterval(seconds)
        while Date() < until {
            if await evalBool("Boolean(\(expr))") { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return false
    }

    /// THE render-path guard: every live CM6 cursor layer renders steady
    /// (`animationDuration: 0s`), i.e. no blink.
    func test_caret_doesNotBlink_cursorBlinkRateIsZero() async throws {
        try await loadEditorPage()
        // Focus + a non-empty doc so the cursor layer is mounted and measurable.
        try await dispatch("""
        window.cmDispatch({ v: 2, type: "setText", text: "hello cursor" });
        if (window.__mdvView) window.__mdvView.focus();
        """)
        let appeared = await evalUntil(
            "document.querySelector('.cm-cursorLayer')", deadline: 5)
        XCTAssertTrue(appeared, "the CM6 cursor layer never mounted in the live editor")

        // Read the computed animationDuration of EVERY cursor layer; return the
        // first non-zero one (the blink that should not be there), else "0s".
        let durations = await evalString("""
        (function () {
          const layers = document.querySelectorAll('.cm-cursorLayer');
          if (!layers.length) return 'none';
          for (const l of layers) {
            const d = getComputedStyle(l).animationDuration;
            if (d !== '0s' && d !== '0ms') return d;
          }
          return '0s';
        })()
        """)
        XCTAssertEqual(durations, "0s",
            "CM6 cursor layer animationDuration must be 0s (steady caret); "
            + "got \(durations) — drawSelection cursorBlinkRate regressed to a blink")
    }

    private func dispatch(_ js: String) async throws {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            webView.evaluateJavaScript(js) { _, _ in cont.resume() }
        }
    }
}
