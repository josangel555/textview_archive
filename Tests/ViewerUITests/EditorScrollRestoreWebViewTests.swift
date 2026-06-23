import WebKit
import XCTest
@testable import ViewerUI

/// TSK-1046/1047 — the LIVE-CM6 half of EDITOR scroll-restore, closing the render
/// loop the spawned-app UAT never could (CM6's WebContent is idle/jetsam-killed
/// under the GUI-lane viaOpen launch; an IN-PROCESS WKWebView survives — proven by
/// the sibling Fold/Blame/MultiCursor WebView suites). The Swift half — building the
/// once-per-mount seed from the saved scroll line — is host-tested
/// (`DocumentModelPreviewTests` / `editorMountSelectionSeed`); THIS proves the seed,
/// once applied to a real CM6, actually scrolls the editor so the saved line is on
/// screen instead of snapping to the top (the bug).
///
/// The restore mechanism is EXACTLY what `ContentView` drives on mount:
/// `editorMountSelectionSeed` → `CMSelectionSeed(anchor:offset, head:offset,
/// scroll:true)` → `.setSelection` dispatch → `applySetSelection` →
/// `EditorView.scrollIntoView(head, {y:"center"})` (codemirror.html:1446-1452). We
/// drive that same `setSelection`+`scroll` and assert the live CM6 viewport.
///
/// `#192`-gated (`MDV_RUN_WEBVIEW_TESTS=1`, the VM/nightly WebView lane — listed in
/// `test-in-vm.sh` `run_webview_tests`).
@MainActor
final class EditorScrollRestoreWebViewTests: WebViewTestCase {

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

    /// Run a CM6 bridge dispatch. The trailing `;true` keeps the async
    /// evaluateJavaScript from throwing WKError-5 ("unsupported type") on the
    /// `undefined` a bare `cmDispatch(...)` returns.
    private func dispatch(_ js: String) async throws {
        _ = try await webView.evaluateJavaScript(js + "\n;true")
    }

    /// The 1-based document line currently at the TOP of the live CM6 viewport.
    private func viewportTopLine() async throws -> Int {
        try await webView.evaluateJavaScript(
            "window.__mdvView.state.doc.lineAt(window.__mdvView.viewport.from).number"
        ) as? Int ?? -1
    }

    /// Load a long, line-numbered doc into the live CM6 so a scroll is observable.
    private func loadLongDoc(lines: Int) async throws {
        try await dispatch("""
        window.cmDispatch({ v: 2, type: "setLanguage", lang: "plain" });
        window.cmDispatch({ v: 2, type: "setText",
          text: Array.from({length: \(lines)}, (_, i) => "line " + (i + 1) + " lorem ipsum dolor sit amet").join("\\n") });
        """)
    }

    /// THE render-path regression guard: a fresh CM6 sits at the top; applying the
    /// mount restore-seed (`setSelection` at the saved line's offset, `scroll:true`
    /// — the exact bridge `ContentView` drives from `editorMountSelectionSeed`)
    /// scrolls the editor so the saved line is ON SCREEN, not at the top.
    func test_restoreSeed_scrollsLiveCM6_toSavedLine_notTop() async throws {
        try await loadEditorPage()
        try await loadLongDoc(lines: 400)

        // Precondition: a freshly-loaded editor starts at the top.
        _ = await evalUntil("window.__mdvView.state.doc.lines >= 400", deadline: 5)
        let topBefore = try await viewportTopLine()
        XCTAssertLessThan(topBefore, 25,
            "a fresh CM6 viewport starts near the top (got top line \(topBefore))")

        // RESTORE: drive the SAME seed the mount path uses — anchor=head=offset of
        // the saved line, scroll:true → applySetSelection → scrollIntoView(center).
        let targetLine = 220
        try await dispatch("""
        (function () {
          const off = window.__mdvView.state.doc.line(\(targetLine)).from;
          window.cmDispatch({ v: 2, type: "setSelection", anchor: off, head: off, scroll: true });
        })();
        """)

        // The saved line must now be WITHIN the viewport and the top must have moved
        // well off line 1 — i.e. the scroll actually restored on the live editor.
        let landed = await evalUntil("""
        (function () {
          const v = window.__mdvView;
          const top = v.state.doc.lineAt(v.viewport.from).number;
          const bot = v.state.doc.lineAt(v.viewport.to).number;
          return top > 25 && top <= \(targetLine) && \(targetLine) <= bot;
        })()
        """, deadline: 5)
        let topAfter = try await viewportTopLine()
        XCTAssertTrue(landed,
            "restore-seed (setSelection scroll:true) must scroll live CM6 so line "
            + "\(targetLine) is in the viewport — NOT the top (viewport top after = \(topAfter))")
    }

    /// Sibling guard for the SETUP scroll the harness/editor uses: `scrollToLine`
    /// puts the requested line at the viewport top on the live editor.
    func test_scrollToLine_putsLineAtTop_onLiveCM6() async throws {
        try await loadEditorPage()
        try await loadLongDoc(lines: 400)
        _ = await evalUntil("window.__mdvView.state.doc.lines >= 400", deadline: 5)

        let targetLine = 150
        try await dispatch(
            "window.cmDispatch({ v: 2, type: \"scrollToLine\", line: \(targetLine) })")

        let reached = await evalUntil("""
        (function () {
          const top = window.__mdvView.state.doc.lineAt(window.__mdvView.viewport.from).number;
          return Math.abs(top - \(targetLine)) <= 6;
        })()
        """, deadline: 5)
        let topAfter = try await viewportTopLine()
        XCTAssertTrue(reached,
            "scrollToLine must put line \(targetLine) at the live CM6 viewport top (got \(topAfter))")
    }
}
