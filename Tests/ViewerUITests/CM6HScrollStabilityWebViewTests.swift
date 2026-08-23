import WebKit
import XCTest
@testable import ViewerUI

/// Owner bug 2026-08-23 — the horizontal scrollbar "keeps jumping as I type" with wrapping OFF.
/// Root cause is upstream CM6 behavior: only viewport lines are rendered, and CM6's own width
/// floor (DocView.minWidth) is DROPPED when an edit touches the remembered range or the height
/// oracle refreshes on a font-metric change — while the widest line is outside the render
/// window, the content width (= the h-scrollbar range) snaps down and the scrollLeft clamp
/// yanks the text sideways. The fix ratchets `.cm-content`'s min-width at the buffer's measured
/// high-water — outside CM6's floor logic, so it survives every drop path — cleared on
/// setText / font change / wrap-on. The teeth test forces the internal drop directly
/// (`docView.minWidth = 0`, the state every drop path produces) because the natural triggers
/// need heterogeneous glyph metrics that don't reproduce deterministically in a synthetic doc.
/// `#192`-gated; listed in test-in-vm.sh's webview lane.
@MainActor
final class CM6HScrollStabilityWebViewTests: WebViewTestCase {

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
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 500, height: 260), configuration: config)
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

    private func contentWidth() async -> Double {
        let v = try? await webView.evaluateJavaScript(
            "window.__mdvView.contentDOM.getBoundingClientRect().width")
        return (v as? NSNumber)?.doubleValue ?? -1
    }

    /// Where the long line sits and how far to scroll to render it. The long line must be
    /// FARTHER from the top than CM6's vertical render margin (~1000px) + viewport, or
    /// scrolling back to the top re-renders it and its natural width masks any floor drop.
    private static let longLineScrollTop = 2700

    /// Seed a wrap-off doc: 300 short lines with ONE long line at 150 (~2.8k px down —
    /// far outside the render window both initially and after scrolling back to the top).
    private func seedDoc() async throws {
        var lines: [String] = []
        for i in 1...300 {
            lines.append(i == 150 ? "long " + String(repeating: "x", count: 400) : "line \(i)")
        }
        let text = lines.joined(separator: "\\n")
        _ = try await webView.evaluateJavaScript("""
        window.cmDispatch({ v: 2, type: "setWordWrap", enabled: false });
        window.cmDispatch({ v: 2, type: "setText", text: "\(text)", resetHistory: true });
        """)
        try? await Task.sleep(for: .milliseconds(200)) // let the initial measure cycle settle
    }

    func test_contentWidth_neverShrinks_whileEditingUnwrappedBuffer() async throws {
        try await loadEditorPage()
        try await seedDoc()

        let narrow = await contentWidth()
        guard narrow > 0 else { throw XCTSkip("content width unreadable (\(narrow))") }

        // Typing among the short lines must never DECREASE the width (the jump).
        var prev = narrow
        for i in 0..<6 {
            _ = try await webView.evaluateJavaScript(
                "window.__mdvView.dispatch(window.__mdvView.state.replaceSelection('t\(i)')); true;")
            try? await Task.sleep(for: .milliseconds(60))
            let w = await contentWidth()
            XCTAssertGreaterThanOrEqual(w, prev - 0.5,
                "content width shrank while typing (\(prev) → \(w)) — the h-scrollbar jump")
            prev = w
        }

        // Scroll the long line into the render window: width grows to the true max…
        _ = try await webView.evaluateJavaScript("window.__mdvView.scrollDOM.scrollTop = \(Self.longLineScrollTop); true;")
        let grew = await evalUntil(
            "window.__mdvView.contentDOM.getBoundingClientRect().width > \(narrow + 100)", deadline: 5)
        guard grew else {
            throw XCTSkip("long line never widened the content — viewport assumptions off in this lane")
        }
        let wide = await contentWidth()

        // …then scroll back so the long line leaves the render window, and type.
        // WITHOUT the ratchet CM6 shrinks the width back to the short-line max here
        // (the teeth: this assertion fails on the pre-fix page).
        _ = try await webView.evaluateJavaScript("window.__mdvView.scrollDOM.scrollTop = 0; true;")
        try? await Task.sleep(for: .milliseconds(200))
        _ = try await webView.evaluateJavaScript(
            "window.__mdvView.dispatch(window.__mdvView.state.replaceSelection('zz')); true;")
        try? await Task.sleep(for: .milliseconds(200))
        let after = await contentWidth()
        XCTAssertGreaterThanOrEqual(after, wide - 0.5,
            "width collapsed (\(wide) → \(after)) once the long line left the render window — the scrollbar/scrollLeft jump the ratchet exists to prevent")
    }

    /// THE teeth test — red without the ratchet. Ratchet up on the long line, scroll it out of
    /// the render window, then force CM6's internal floor drop (the state that typing inside the
    /// remembered range / an oracle refresh produces) and edit. Without the pinned min-width the
    /// content collapses to the rendered-lines width; with it the range holds.
    func test_ratchetHolds_whenCM6DropsItsInternalWidthFloor() async throws {
        try await loadEditorPage()
        try await seedDoc()

        let narrow = await contentWidth()
        guard narrow > 0 else { throw XCTSkip("content width unreadable (\(narrow))") }

        // Render the long line once so both floors (CM6's and ours) record it…
        _ = try await webView.evaluateJavaScript("window.__mdvView.scrollDOM.scrollTop = \(Self.longLineScrollTop); true;")
        let grew = await evalUntil(
            "window.__mdvView.contentDOM.getBoundingClientRect().width > \(narrow + 100)", deadline: 5)
        guard grew else { throw XCTSkip("long line never widened the content — viewport assumptions off") }
        let wide = await contentWidth()

        // …scroll it back out of the render window…
        _ = try await webView.evaluateJavaScript("window.__mdvView.scrollDOM.scrollTop = 0; true;")
        try? await Task.sleep(for: .milliseconds(200))

        // …then force the internal drop and type. docView is CM6's (unminified) private view
        // component; zeroing its minWidth is exactly what the range-touch / oracle-refresh
        // paths do before the next update.
        let forced = (try? await webView.evaluateJavaScript("""
        (function () {
          const dv = window.__mdvView.docView;
          if (!dv || typeof dv.minWidth !== "number") return false;
          dv.minWidth = dv.minWidthFrom = dv.minWidthTo = 0;
          window.__mdvView.dispatch(window.__mdvView.state.replaceSelection("x"));
          return true;
        })()
        """) as? Bool) ?? false
        guard forced else {
            throw XCTSkip("docView.minWidth not reachable in this CM6 build — cannot force the internal floor drop")
        }
        try? await Task.sleep(for: .milliseconds(250))
        let after = await contentWidth()
        XCTAssertGreaterThanOrEqual(after, wide - 0.5,
            "width collapsed (\(wide) → \(after)) after CM6 dropped its internal floor — the ratchet must hold the h-scrollbar range")
    }

    func test_wrapOn_clearsTheWidthFloor() async throws {
        try await loadEditorPage()
        try await seedDoc()

        // Ratchet up to the long line's width first.
        _ = try await webView.evaluateJavaScript("window.__mdvView.scrollDOM.scrollTop = \(Self.longLineScrollTop); true;")
        _ = await evalUntil("parseFloat(window.__mdvView.contentDOM.style.minWidth) > 0", deadline: 5)

        // Turning wrap ON must clear the pinned floor — otherwise the wrapped buffer
        // keeps a phantom horizontal scrollbar.
        _ = try await webView.evaluateJavaScript(
            "window.cmDispatch({ v: 2, type: \"setWordWrap\", enabled: true }); true;")
        let cleared = await evalUntil(
            "window.__mdvView.contentDOM.style.minWidth === ''", deadline: 3)
        XCTAssertTrue(cleared, "wrap-on must clear .cm-content's pinned min-width")
    }

    func test_setText_resetsTheWidthFloor() async throws {
        try await loadEditorPage()
        try await seedDoc()

        _ = try await webView.evaluateJavaScript("window.__mdvView.scrollDOM.scrollTop = \(Self.longLineScrollTop); true;")
        let pinned = await evalUntil(
            "parseFloat(window.__mdvView.contentDOM.style.minWidth) > 300", deadline: 5)
        guard pinned else { throw XCTSkip("floor never pinned to the long line — cannot exercise reset") }

        // Replacing the document (new buffer) must drop the old floor: the new
        // short-only content re-ratchets from its own width.
        _ = try await webView.evaluateJavaScript(
            "window.cmDispatch({ v: 2, type: \"setText\", text: \"short\\none\\ntwo\", resetHistory: true }); true;")
        let dropped = await evalUntil("""
        (window.__mdvView.contentDOM.style.minWidth === '' ||
         parseFloat(window.__mdvView.contentDOM.style.minWidth) < 300)
        """, deadline: 3)
        XCTAssertTrue(dropped, "a whole-document setText must not carry the prior buffer's width floor")
    }
}
