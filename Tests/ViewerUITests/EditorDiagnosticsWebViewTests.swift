import WebKit
import XCTest
@testable import ViewerUI

/// TSK-1146 — the render-path guard the spell-squiggle epic was missing: prove a `setDiagnostics`
/// dispatch produces a REAL `.cm-lintRange` underline in the live CM6 DOM. The Swift half
/// (SpellCheckEngine → SpellDiagnosticMapping → EditorCoordinator spell+LSP merge →
/// setEditorDiagnostics → CodeMirrorBridge.setDiagnostics) is host-tested at every layer; this
/// closes the loop at the rendered artifact (the underline). SHARED by both spell squiggles AND
/// LSP diagnostics (one render path) — so it had NO render test for either before this.
/// `#192`-gated; listed in test-in-vm.sh's webview lane.
@MainActor
final class EditorDiagnosticsWebViewTests: WebViewTestCase {

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

    private func seedDoc() async throws {
        _ = try await webView.evaluateJavaScript("""
        window.cmDispatch({ v: 2, type: "setLanguage", lang: "plain" });
        window.cmDispatch({ v: 2, type: "setText", text: "teh quick brown fox" });
        """)
    }

    func test_setDiagnostics_rendersLintRange_inTheLiveDOM() async throws {
        try await loadEditorPage()
        try await seedDoc()
        // A spell/LSP-style diagnostic over "teh" (0..3) — the exact shape
        // CodeMirrorBridge.setDiagnostics emits (from/to/severity/message/source).
        _ = try await webView.evaluateJavaScript("""
        window.cmDispatch({ v: 2, type: "setDiagnostics", diagnostics: [
          { from: 0, to: 3, severity: "info", message: "Did you mean 'the'?", source: "spell" }
        ]});
        """)
        let rendered = await evalUntil(
            "window.__mdvView.dom.querySelectorAll('.cm-lintRange').length > 0", deadline: 5)
        XCTAssertTrue(rendered,
            "a diagnostic must render a .cm-lintRange underline in the live CM6 DOM (spell/LSP squiggle)")
    }

    func test_clearingDiagnostics_removesLintRanges() async throws {
        try await loadEditorPage()
        try await seedDoc()
        _ = try await webView.evaluateJavaScript("""
        window.cmDispatch({ v: 2, type: "setDiagnostics", diagnostics: [
          { from: 0, to: 3, severity: "warning", message: "x", source: "spell" }
        ]});
        """)
        let appeared = await evalUntil(
            "window.__mdvView.dom.querySelectorAll('.cm-lintRange').length > 0", deadline: 5)
        XCTAssertTrue(appeared, "precondition: the diagnostic rendered")
        _ = try await webView.evaluateJavaScript("""
        window.cmDispatch({ v: 2, type: "setDiagnostics", diagnostics: [] });
        """)
        let cleared = await evalUntil(
            "window.__mdvView.dom.querySelectorAll('.cm-lintRange').length === 0", deadline: 5)
        XCTAssertTrue(cleared, "clearing diagnostics must remove the .cm-lintRange underlines")
    }
}
