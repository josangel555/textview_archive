import WebKit
import XCTest
import ViewerCore

@testable import ViewerUI

/// Canvas M3.S5 (TSK-1376): inline text editing on the REAL page —
/// dblclick enters edit mode, blur/Enter commits the textEdited intent,
/// Escape reverts without posting, setEditable is the programmatic entry,
/// and Enter never commits mid-IME-composition. `#192`-gated.
@MainActor
final class CanvasInlineEditWebViewTests: WebViewTestCase {

    private var host: CanvasWebViewHost!
    private var adapter: CanvasDocAdapter!
    private var inbound: [CVInboundMessage] = []
    private var seq: UInt64 = 0

    override func setUp() async throws {
        try WebViewTestTeardown.skipUnlessEnabled()
        inbound = []
        seq = 0
        adapter = try CanvasDocAdapter()
        host = CanvasWebViewHost()
        host.webView.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        host.onInbound = { [weak self] msg in self?.inbound.append(msg) }
        host.load()
        let ok = await waitUntil(10) { self.host.isReady }
        try XCTSkipUnless(ok, "runtime never ready")
        _ = try adapter.applyDSL(baseRev: 0, "text #t \"original copy\"")
        seq += 1
        host.send(.setContent(seq: seq, html: try adapter.html()))
        let mounted = await waitUntil(5) {
            self.inbound.contains { if case .contentSet = $0 { return true }; return false }
        }
        try XCTSkipUnless(mounted, "content never mounted")
    }

    override func tearDown() async throws {
        host?.teardown()
        host = nil
        adapter = nil
        try await super.tearDown()
    }

    private func waitUntil(
        _ seconds: TimeInterval, _ condition: @MainActor () -> Bool
    ) async -> Bool {
        let until = Date().addingTimeInterval(seconds)
        var polls = 0
        while Date() < until {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
            polls += 1
            if polls % 5 == 0 { host.drainMissedReplies() }
        }
        return condition()
    }

    private func js(_ script: String) {
        host.probe(script) { _ in }
    }

    private func lastTextEdited() -> (id: String, text: String)? {
        for case let .textEdited(id, text) in inbound.reversed() {
            return (id, text)
        }
        return nil
    }

    func test_dblclick_edit_type_blur_commits_the_intent() async throws {
        js("""
            (function(){
              var el = document.querySelector('[data-cv-id="nd:t"]');
              el.dispatchEvent(new MouseEvent('dblclick', {bubbles: true}));
              return 1;
            })()
            """)
        let editable = await waitUntil(5) { self.inbound.isEmpty || true }
        _ = editable
        // Type (replace content) + blur → commit.
        js("""
            (function(){
              var el = document.querySelector('[data-cv-id="nd:t"]');
              if (el.getAttribute('contenteditable') !== 'true') return 0;
              el.textContent = "hand-typed";
              el.blur();
              return 1;
            })()
            """)
        let committed = await waitUntil(5) { self.lastTextEdited() != nil }
        XCTAssertTrue(committed, "blur must commit")
        XCTAssertEqual(lastTextEdited()?.id, "nd:t")
        XCTAssertEqual(lastTextEdited()?.text, "hand-typed")
    }

    func test_escape_reverts_without_posting() async throws {
        // Programmatic entry (the S8 inspector path) — also covers setEditable.
        host.send(.setEditable(id: "nd:t", on: true))
        js("""
            (function(){
              var el = document.querySelector('[data-cv-id="nd:t"]');
              el.textContent = "abandoned typing";
              window.dispatchEvent(new KeyboardEvent('keydown',
                {key: 'Escape', bubbles: true}));
              return 1;
            })()
            """)
        // The revert is observable through the standard text query.
        seq += 1
        let replyId = seq
        var reverted = false
        let sendQuery = { [self] in
            host.send(.queryText(replyId: replyId, id: "nd:t"))
        }
        _ = await waitUntil(1) { false } // let the escape land
        sendQuery()
        let ok = await waitUntil(5) {
            for case let .text(got, _, text) in self.inbound where got == replyId {
                reverted = (text == "original copy")
                return true
            }
            return false
        }
        XCTAssertTrue(ok && reverted, "Escape must revert to the original")
        XCTAssertNil(lastTextEdited(), "no textEdited intent on revert")
        // And the edit-mode Escape did NOT clear a selection (stopPropagation):
        XCTAssertFalse(inbound.contains { $0 == .escapePressed },
                       "edit-Escape must not double as selection-Escape")
    }

    func test_enter_commits_but_not_mid_composition() async throws {
        host.send(.setEditable(id: "nd:t", on: true))
        // Mid-composition Enter (isComposing: true) must NOT commit.
        js("""
            (function(){
              var el = document.querySelector('[data-cv-id="nd:t"]');
              el.textContent = "ime draft";
              var ev = new KeyboardEvent('keydown', {key: 'Enter', bubbles: true});
              Object.defineProperty(ev, 'isComposing', { value: true });
              window.dispatchEvent(ev);
              return 1;
            })()
            """)
        _ = await waitUntil(1) { self.lastTextEdited() != nil }
        XCTAssertNil(lastTextEdited(), "composition Enter must not commit")
        // Plain Enter commits.
        js("""
            (function(){
              window.dispatchEvent(new KeyboardEvent('keydown',
                {key: 'Enter', bubbles: true}));
              return 1;
            })()
            """)
        let committed = await waitUntil(5) { self.lastTextEdited() != nil }
        XCTAssertTrue(committed)
        XCTAssertEqual(lastTextEdited()?.text, "ime draft")
    }
}
