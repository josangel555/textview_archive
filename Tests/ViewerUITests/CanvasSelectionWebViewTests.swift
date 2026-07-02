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

    /// M4.S9: the measured stage on the REAL page — a maxH-constrained box
    /// with overflowing content flags `overflow`; near-background text flags
    /// `low-contrast`; clean nodes stay quiet.
    func test_measured_lint_flags_overflow_and_contrast() async throws {
        // Grow the doc: an overflowing constrained frame + low-contrast text.
        let applied = try adapter.apply(baseRev: 1, [
            .insert(id: "nd:tight", kind: "frame", parent: "nd:col", pos: .last,
                    props: [("maxH", .num(24))]),
            .insert(id: "nd:stuffed", kind: "text", parent: "nd:tight", pos: .last,
                    props: [("text", .str(String(repeating: "overflowing content ", count: 30)))]),
            .insert(id: "nd:ghost", kind: "text", parent: "nd:col", pos: .last,
                    props: [("text", .str("barely visible")),
                            ("color", .str("#f4f4f6"))]),
        ])
        seq += 1
        host.send(.applyPatches(seq: seq, patches: applied.patches))
        _ = await waitUntil(5) {
            self.inbound.contains {
                if case .applied(let got, _, _, _, _) = $0 { return got == self.seq }
                return false
            }
        }
        // M5.S2: an ARTBOARD fixture — the existing measured stage must
        // flag content wider than the artboard's viewport (the responsive
        // check's foundation), with the ordinary overflow rule (no new code).
        let artboard = try adapter.applyDSL(
            baseRev: try adapter.currentRev(),
            "frame #board role=artboard note=\"Mobile\" minW=120 maxW=120 {\n" +
            "  text #wide \"unbreakablerunoftextfarwiderthanthemobileartboardviewport\"\n}")
        seq += 1
        host.send(.applyPatches(seq: seq, patches: artboard.patches))
        _ = await waitUntil(5) {
            self.inbound.contains {
                if case .applied(let got, _, _, _, _) = $0 { return got == self.seq }
                return false
            }
        }
        seq += 1
        let replyId = seq
        host.send(.measureLint(replyId: replyId))
        let ok = await waitUntil(5) {
            self.inbound.contains {
                if case .measuredLint(let got, _) = $0 { return got == replyId }
                return false
            }
        }
        XCTAssertTrue(ok, "measured lint must reply")
        for case let .measuredLint(got, findings) in inbound where got == replyId {
            XCTAssertTrue(findings.contains { $0.code == "overflow" && $0.id == "nd:tight" },
                          "constrained overflow flagged: \(findings)")
            XCTAssertTrue(findings.contains { $0.code == "low-contrast" && $0.id == "nd:ghost" },
                          "near-bg text flagged: \(findings)")
            XCTAssertFalse(findings.contains { $0.id == "nd:r0" },
                           "clean nodes stay quiet: \(findings)")
            XCTAssertTrue(findings.contains { $0.code == "overflow" && $0.id == "nd:board" },
                          "artboard-overflow (the responsive check) flags: \(findings)")
        }
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
