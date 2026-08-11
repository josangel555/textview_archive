import WebKit
import XCTest
@testable import ViewerUI

/// O-6 flush-before-read — the LIVE-page half of the handshake, in the real
/// CM6 bundle: after typing (which only ARMS the ~200ms debounced emit),
/// dispatching `flushChanges{nonce}` must deliver the pending text change
/// BEFORE the `flushAck{nonce}` — the ordering guarantee the Swift-side
/// bounded wait (`CMEditorTextSync`, host-tested) relies on to declare the
/// mirror current. Mirrors the `EditorReplaceWebViewTests` harness;
/// `#192`-gated; runs in the VM webview lane.
@MainActor
final class EditorFlushWebViewTests: WebViewTestCase {

    /// Records every message the page posts to the `mdvEditor` bridge, in
    /// arrival order — the order IS the assertion surface here.
    private final class MessageRecorder: NSObject, WKScriptMessageHandler {
        var bodies: [[String: Any]] = []
        func userContentController(
            _ controller: WKUserContentController, didReceive message: WKScriptMessage
        ) {
            if let d = message.body as? [String: Any] { bodies.append(d) }
        }
    }

    private var webView: WKWebView!
    private var recorder: MessageRecorder!

    override func setUp() async throws {
        try WebViewTestTeardown.skipUnlessEnabled()
    }

    override func tearDown() async throws {
        webView?.configuration.userContentController
            .removeScriptMessageHandler(forName: "mdvEditor")
        webView = nil
        recorder = nil
        try await super.tearDown()
    }

    private func loadEditorPage() async throws {
        guard let url = Bundle.module.url(
            forResource: "codemirror", withExtension: "html") else {
            throw XCTSkip("codemirror.html not in the test bundle")
        }
        recorder = MessageRecorder()
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        config.userContentController.add(recorder, name: "mdvEditor")
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

    func test_flushChanges_deliversPendingText_beforeTheAck() async throws {
        try await loadEditorPage()
        recorder.bodies.removeAll()

        // Type WITHOUT waiting out the debounce: dispatch a change straight
        // into the live view (arms the ~200ms emit timer), then immediately
        // request the flush handshake.
        _ = try await webView.evaluateJavaScript(
            "window.__mdvView.dispatch({changes: {from: 0, insert: 'FLUSHED-EDIT '}}); 1")
        _ = try await webView.evaluateJavaScript(
            "window.cmDispatch({v: 2, type: 'flushChanges', nonce: 99}); 1")

        // The ack must arrive (bounded), carrying our nonce.
        let acked = await pollRecorder(deadline: 5) { bodies in
            bodies.contains { $0["type"] as? String == "flushAck" && $0["nonce"] as? Int == 99 }
        }
        XCTAssertTrue(acked, "the page must ack a nonce'd flushChanges")

        // ORDER — the load-bearing property: the text change (carrying the
        // typed content) sits STRICTLY BEFORE the ack in the message stream,
        // so a Swift waiter that has seen the ack has provably consumed the
        // text. (No timing-window negative control here — on a loaded VM the
        // debounce could fire naturally first; order holds either way.)
        let bodies = recorder.bodies
        let ackIdx = bodies.firstIndex {
            $0["type"] as? String == "flushAck" && $0["nonce"] as? Int == 99
        }
        let changeIdx = bodies.firstIndex { body in
            let t = body["type"] as? String
            guard t == "change" || t == "incrementalChange" else { return false }
            // Full-text envelope carries the text; incremental carries edits.
            if let text = body["text"] as? String { return text.contains("FLUSHED-EDIT") }
            return true
        }
        XCTAssertNotNil(changeIdx, "the pending edit must have been emitted")
        if let a = ackIdx, let c = changeIdx {
            XCTAssertLessThan(c, a,
                "the text change must be delivered BEFORE its flush ack")
        }
    }

    func test_flushChanges_withoutNonce_staysSilent() async throws {
        try await loadEditorPage()
        // Let any load-time emissions settle, then flush with NO nonce (the
        // drift-recovery form) on a CLEAN doc: no ack may be posted (a
        // spurious ack could satisfy a future waiter's pruned-set edge).
        try? await Task.sleep(for: .milliseconds(300))
        recorder.bodies.removeAll()
        _ = try await webView.evaluateJavaScript(
            "window.cmDispatch({v: 2, type: 'flushChanges'}); 1")
        try? await Task.sleep(for: .milliseconds(200))
        let acks = recorder.bodies.filter { $0["type"] as? String == "flushAck" }
        XCTAssertTrue(acks.isEmpty, "a nonce-less flush must not ack")
    }

    private func pollRecorder(
        deadline seconds: TimeInterval,
        until predicate: ([[String: Any]]) -> Bool
    ) async -> Bool {
        let until = Date().addingTimeInterval(seconds)
        while Date() < until {
            if predicate(recorder.bodies) { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return predicate(recorder.bodies)
    }
}
