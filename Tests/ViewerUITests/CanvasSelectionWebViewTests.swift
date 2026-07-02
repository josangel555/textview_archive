import WebKit
import XCTest
import ViewerCore

@testable import ViewerUI

/// Canvas M3.S3 (TSK-1374): the selection runtime on the REAL page —
/// synthesized clicks hit-test to nodeClicked intents; setSelection glues
/// the single overlay box to the target's rect (verified through the same
/// geometry query the app uses); reflow keeps it glued; Escape posts the
/// intent. `#192`-gated (VM webview lane; local in-process is the current
/// validation vehicle per M3-PLAN while TSK-1365's residual is open).
@MainActor
final class CanvasSelectionWebViewTests: WebViewTestCase {

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
        try XCTSkipUnless(ok, "canvas.html runtime never posted ready")
        // Mount real content: a column with three rows.
        _ = try adapter.applyDSL(
            baseRev: 0,
            """
            frame #col gap=4 padding=16 {
              text #r0 "row zero"
              text #r1 "row one"
              text #r2 "row two"
            }
            """)
        seq += 1
        host.send(.setContent(seq: seq, html: try adapter.html()))
        let mounted = await waitUntil(5) {
            self.inbound.contains {
                if case .contentSet = $0 { return true }
                return false
            }
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

    private func boxes(for ids: [String]) async -> [CVBox] {
        seq += 1
        let replyId = seq
        host.send(.queryGeometry(replyId: replyId, ids: ids))
        _ = await waitUntil(5) {
            self.inbound.contains {
                if case .geometry(let got, _) = $0 { return got == replyId }
                return false
            }
        }
        for case let .geometry(got, result) in inbound where got == replyId {
            return result
        }
        return []
    }

    func test_click_hitTests_to_nodeClicked_intent() async throws {
        // Synthesize a real click on #r1 (bubbling, like a user's).
        host.probe(
            """
            (function(){
              var el = document.querySelector('[data-cv-id="nd:r1"]');
              el.dispatchEvent(new MouseEvent('click', {bubbles: true}));
              return 1;
            })()
            """
        ) { _ in }
        let ok = await waitUntil(5) {
            self.inbound.contains {
                if case .nodeClicked(let id, _) = $0 { return id == "nd:r1" }
                return false
            }
        }
        XCTAssertTrue(ok, "click must hit-test to the nodeClicked intent")
    }

    func test_setSelection_glues_the_overlay_to_the_target_and_tracks_reflow() async throws {
        host.send(.setSelection(ids: ["nd:r1"]))
        // The overlay is addressable as "cv-overlay" through the SAME
        // geometry query the app uses — no eval-return dependence.
        var target = await boxes(for: ["nd:r1", "cv-overlay"])
        XCTAssertEqual(target.count, 2, "target + overlay both measurable")
        if target.count == 2 {
            XCTAssertEqual(target[0].y, target[1].y, accuracy: 3, "overlay glued (y)")
            XCTAssertEqual(target[0].h, target[1].h, accuracy: 5, "overlay sized (h)")
        }

        // Reflow: grow row zero's text via a REAL engine patch; r1 moves,
        // the overlay must follow.
        let before = await boxes(for: ["nd:r1"])
        let applied = try adapter.apply(
            baseRev: 1,
            [.update(
                id: "nd:r0",
                set: [("text", .str(String(repeating: "wrap me ", count: 40)))],
                unset: [])])
        seq += 1
        host.send(.applyPatches(seq: seq, patches: applied.patches))
        let moved = await waitUntil(5) {
            self.inbound.contains {
                if case .applied = $0 { return true }
                return false
            }
        }
        XCTAssertTrue(moved, "patch must apply")
        target = await boxes(for: ["nd:r1", "cv-overlay"])
        XCTAssertEqual(target.count, 2)
        if target.count == 2, let old = before.first {
            XCTAssertGreaterThan(target[0].y, old.y, "r1 moved down (reflow happened)")
            XCTAssertEqual(target[0].y, target[1].y, accuracy: 3, "overlay FOLLOWED the reflow")
        }

        // Clear hides it (display:none → geometry reports no box).
        host.send(.clearSelection)
        let afterClear = await boxes(for: ["cv-overlay"])
        XCTAssertTrue(
            afterClear.isEmpty || afterClear[0].w == 0,
            "cleared overlay is not measurable: \(afterClear)")
    }

    func test_escape_posts_the_intent() async throws {
        host.probe(
            """
            (function(){
              window.dispatchEvent(new KeyboardEvent('keydown', {key: 'Escape'}));
              return 1;
            })()
            """
        ) { _ in }
        let ok = await waitUntil(5) {
            self.inbound.contains { $0 == .escapePressed }
        }
        XCTAssertTrue(ok, "Escape must post the escapePressed intent")
    }
}
