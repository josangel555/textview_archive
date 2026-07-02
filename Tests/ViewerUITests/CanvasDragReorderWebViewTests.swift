import WebKit
import XCTest
import ViewerCore

@testable import ViewerUI

/// Canvas M3.S6 (TSK-1377): drag-reorder on the REAL page — only the
/// selected node drags; the drop slot resolves before/after by cursor
/// midpoint (and into containers); the dragEnded intent carries
/// {parent, beforeId}; wired to the engine the DOM and children() agree
/// post-move. `#192`-gated.
@MainActor
final class CanvasDragReorderWebViewTests: WebViewTestCase {

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
        _ = try adapter.applyDSL(
            baseRev: 0,
            """
            frame #col gap=4 {
              text #a "alpha"
              text #b "beta"
              text #c "gamma"
            }
            """)
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

    private func lastDragEnded() -> (id: String, parent: String, beforeId: String?)? {
        for case let .dragEnded(id, parent, beforeId) in inbound.reversed() {
            return (id, parent, beforeId)
        }
        return nil
    }

    /// Select #c, drag it over #a's UPPER half, drop → dragEnded carries
    /// {parent: #col, beforeId: #a} (reorder to the front).
    func test_drag_selected_node_to_front_posts_the_slot() async throws {
        host.send(.setSelection(ids: ["nd:c"]))
        js("""
            (function(){
              var c = document.querySelector('[data-cv-id="nd:c"]');
              var a = document.querySelector('[data-cv-id="nd:a"]');
              var ra = a.getBoundingClientRect();
              c.dispatchEvent(new MouseEvent('dragstart', {bubbles: true}));
              a.dispatchEvent(new MouseEvent('dragover',
                {bubbles: true, clientY: ra.top + 2}));
              a.dispatchEvent(new MouseEvent('drop', {bubbles: true}));
              return 1;
            })()
            """)
        let ok = await waitUntil(5) { self.lastDragEnded() != nil }
        XCTAssertTrue(ok, "drop must post dragEnded")
        let intent = lastDragEnded()
        XCTAssertEqual(intent?.id, "nd:c")
        XCTAssertEqual(intent?.parent, "nd:col")
        XCTAssertEqual(intent?.beforeId, "nd:a", "upper half = before the hovered node")

        // Land it in the ENGINE (what the S4 controller does) and verify the
        // DOM order follows via the real patch.
        let applied = try adapter.apply(
            baseRev: 1,
            [.move(id: "nd:c", parent: "nd:col", pos: .before("nd:a"))])
        seq += 1
        host.send(.applyPatches(seq: seq, patches: applied.patches))
        let painted = await waitUntil(5) {
            self.inbound.contains { if case .applied = $0 { return true }; return false }
        }
        XCTAssertTrue(painted)
        // Verify DOM order through geometry: #c must now sit ABOVE #a.
        seq += 1
        let replyId = seq
        host.send(.queryGeometry(replyId: replyId, ids: ["nd:c", "nd:a"]))
        _ = await waitUntil(5) {
            self.inbound.contains {
                if case .geometry(let got, _) = $0 { return got == replyId }
                return false
            }
        }
        for case let .geometry(got, boxes) in inbound where got == replyId {
            XCTAssertEqual(boxes.count, 2)
            if boxes.count == 2 {
                XCTAssertLessThan(boxes[0].y, boxes[1].y, "#c reordered above #a")
            }
        }
    }

    /// An UNSELECTED node must not drag (dragstart is refused).
    func test_unselected_node_does_not_drag() async throws {
        host.send(.setSelection(ids: ["nd:a"]))
        js("""
            (function(){
              var b = document.querySelector('[data-cv-id="nd:b"]');
              var a = document.querySelector('[data-cv-id="nd:a"]');
              b.dispatchEvent(new MouseEvent('dragstart', {bubbles: true}));
              a.dispatchEvent(new MouseEvent('dragover',
                {bubbles: true, clientY: a.getBoundingClientRect().top + 2}));
              a.dispatchEvent(new MouseEvent('drop', {bubbles: true}));
              return 1;
            })()
            """)
        _ = await waitUntil(1) { self.lastDragEnded() != nil }
        XCTAssertNil(lastDragEnded(), "unselected nodes must not produce drops")
    }

    /// Lower half of the LAST sibling = append (no beforeId).
    func test_drop_below_last_sibling_appends() async throws {
        host.send(.setSelection(ids: ["nd:a"]))
        js("""
            (function(){
              var a = document.querySelector('[data-cv-id="nd:a"]');
              var c = document.querySelector('[data-cv-id="nd:c"]');
              var rc = c.getBoundingClientRect();
              a.dispatchEvent(new MouseEvent('dragstart', {bubbles: true}));
              c.dispatchEvent(new MouseEvent('dragover',
                {bubbles: true, clientY: rc.bottom - 2}));
              c.dispatchEvent(new MouseEvent('drop', {bubbles: true}));
              return 1;
            })()
            """)
        let ok = await waitUntil(5) { self.lastDragEnded() != nil }
        XCTAssertTrue(ok)
        let intent = lastDragEnded()
        XCTAssertEqual(intent?.id, "nd:a")
        XCTAssertNil(intent?.beforeId ?? nil, "below the last sibling = append")
    }
}
