import WebKit
import XCTest
import ViewerCore

@testable import ViewerUI

/// Canvas M1.S5c (TSK-1360, ex-M0.S3 suite) — the E2E patch loop on the REAL
/// engine: `CanvasDocAdapter` (rust ops/fence/lowering over FFI) →
/// `CanvasWebViewHost` (CV envelope) → `canvas.js` (7-verb applier) → DOM
/// readback. The suite BUILDS ITS OWN DOCUMENT through the op API — no
/// hardcoded demo content (that was the M0 spike, retired).
///
/// `#192`-gated (`MDV_RUN_WEBVIEW_TESTS=1`, the VM webview lane) — self-skips
/// in the host headless gate. VM reliability context: LESSONS 2026-07-02 +
/// TSK-1365.
@MainActor
final class CanvasPatchLoopWebViewTests: WebViewTestCase {

    private var host: CanvasWebViewHost!
    private var adapter: CanvasDocAdapter!
    private var inbound: [CVInboundMessage] = []
    private var window: NSWindow?
    private var rev: UInt64 = 0
    private var seq: UInt64 = 0

    override func setUp() async throws {
        try WebViewTestTeardown.skipUnlessEnabled()
        inbound = []
        rev = 0
        seq = 0
        adapter = try CanvasDocAdapter()
        host = CanvasWebViewHost()
        host.onInbound = { [weak self] msg in self?.inbound.append(msg) }
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled], backing: .buffered, defer: false)
        w.contentView = host.webView
        w.orderFrontRegardless()
        window = w
        host.load()
        let ok = await waitUntil(5) { self.host.isReady }
        try XCTSkipUnless(ok, "canvas.html runtime never posted ready")
    }

    override func tearDown() async throws {
        host?.teardown()
        window?.orderOut(nil)
        window = nil
        host = nil
        adapter = nil
        try await super.tearDown()
    }

    // MARK: - helpers

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

    private func nextSeq() -> UInt64 {
        seq += 1
        return seq
    }

    /// Apply ops in the ENGINE, forward the engine's patches to JS, await the
    /// applied ack. Returns (coreSeconds, e2eSeconds, jsApplyMs).
    @discardableResult
    private func applyRoundTrip(
        _ ops: [CanvasDocOp]
    ) async throws -> (core: TimeInterval, e2e: TimeInterval, jsMs: Double) {
        let s = nextSeq()
        let t0 = Date()
        let applied = try adapter.apply(baseRev: rev, ops)
        rev = applied.rev
        let coreDt = Date().timeIntervalSince(t0)
        host.send(.applyPatches(seq: s, patches: applied.patches))
        let ok = await waitUntil(5) {
            self.inbound.contains {
                if case .applied(let got, _, _, _, _) = $0 { return got == s }
                return false
            }
        }
        XCTAssertTrue(
            ok, "no applied ack for seq \(s); lastSendError=\(host.lastSendError ?? "none")")
        let e2eDt = Date().timeIntervalSince(t0)
        for case let .applied(got, appliedCount, missing, _, applyMs) in inbound where got == s {
            XCTAssertEqual(appliedCount, applied.patches.count, "patch count mismatch")
            XCTAssertTrue(missing.isEmpty, "JS could not find nodes: \(missing)")
            return (coreDt, e2eDt, applyMs)
        }
        return (coreDt, e2eDt, -1)
    }

    /// Push the engine's full lowering as the page content.
    private func setInitialContent() async throws -> Int {
        let s = nextSeq()
        host.send(.setContent(seq: s, html: try adapter.html()))
        let ok = await waitUntil(5) {
            self.inbound.contains {
                if case .contentSet(let got, _, _) = $0 { return got == s }
                return false
            }
        }
        XCTAssertTrue(ok, "no contentSet ack; lastSendError=\(host.lastSendError ?? "none")")
        for case let .contentSet(got, nodeCount, _) in inbound where got == s {
            return nodeCount
        }
        return -1
    }

    private func textOf(id: String) async -> String? {
        let r = nextSeq()
        host.send(.queryText(replyId: r, id: id))
        _ = await waitUntil(5) {
            self.inbound.contains {
                if case .text(let got, _, _) = $0 { return got == r }
                return false
            }
        }
        for case let .text(got, found, text) in inbound where got == r {
            return found ? text : nil
        }
        return nil
    }

    /// Seed a small doc THROUGH THE ENGINE and mount it: a column frame with
    /// `rows` text rows. Returns after the DOM carries it all.
    private func seedAndMount(rows: Int) async throws {
        var ops: [CanvasDocOp] = [
            .insert(
                id: "nd:col", kind: "frame", parent: CanvasDocAdapter.rootPage, pos: .last,
                props: [("gap", .num(4)), ("padding", .num(16))])
        ]
        for i in 0..<rows {
            ops.append(
                .insert(
                    id: "nd:r\(i)", kind: "text", parent: "nd:col", pos: .last,
                    props: [("text", .str("Row \(i)"))]))
        }
        let applied = try adapter.apply(baseRev: rev, ops)
        rev = applied.rev
        let count = try await setInitialContent()
        XCTAssertEqual(count, rows + 2, "page + frame + rows in the DOM")
    }

    // MARK: - the E2E proofs

    func test_engineBuiltDoc_patchLoop_mutatesExactlyTheTargetNode() async throws {
        try await seedAndMount(rows: 4)
        let before = await textOf(id: "nd:r1")
        XCTAssertEqual(before, "Row 1")

        try await applyRoundTrip([
            .update(id: "nd:r1", set: [("text", .str("patched-by-engine"))], unset: [])
        ])

        let after1 = await textOf(id: "nd:r1")
        let after2 = await textOf(id: "nd:r2")
        XCTAssertEqual(after1, "patched-by-engine", "the loop must reach the DOM")
        XCTAssertEqual(after2, "Row 2", "no collateral DOM mutation")
    }

    func test_insert_move_remove_verbs_reshape_the_live_dom() async throws {
        try await seedAndMount(rows: 3)
        // Insert between r0 and r1 via the engine; the DOM must show it.
        try await applyRoundTrip([
            .insert(
                id: "nd:mid", kind: "text", parent: "nd:col", pos: .before("nd:r1"),
                props: [("text", .str("inserted-live"))])
        ])
        let mid = await textOf(id: "nd:mid")
        XCTAssertEqual(mid, "inserted-live")
        // Move r2 first, then remove r0 — same batch (apply-time anchors).
        try await applyRoundTrip([
            .move(id: "nd:r2", parent: "nd:col", pos: .first),
            .remove(id: "nd:r0"),
        ])
        let removed = await textOf(id: "nd:r0")
        XCTAssertNil(removed, "removed node must leave the DOM")
        let moved = await textOf(id: "nd:r2")
        XCTAssertEqual(moved, "Row 2")
    }

    func test_geometry_returnsFlowSaneBoxes() async throws {
        try await seedAndMount(rows: 3)
        let r = nextSeq()
        host.send(.queryGeometry(replyId: r, ids: ["nd:r0", "nd:r1", "nd:r2"]))
        let ok = await waitUntil(5) {
            self.inbound.contains {
                if case .geometry(let got, _) = $0 { return got == r }
                return false
            }
        }
        XCTAssertTrue(ok, "no geometry reply")
        for case let .geometry(got, boxes) in inbound where got == r {
            XCTAssertEqual(boxes.count, 3)
            for box in boxes {
                XCTAssertGreaterThan(box.w, 0)
                XCTAssertGreaterThan(box.h, 0)
            }
            let ys = boxes.map(\.y)
            XCTAssertEqual(ys, ys.sorted(), "column children stack downward")
        }
    }

    func test_latencyHarness_50ops_reportsPercentiles() async throws {
        try await seedAndMount(rows: 60)
        try await applyRoundTrip([
            .update(id: "nd:r0", set: [("text", .str("warmup"))], unset: [])
        ])

        var coreTimes: [Double] = []
        var e2eTimes: [Double] = []
        var jsTimes: [Double] = []
        for i in 0..<50 {
            let target = "nd:r\(i % 60)"
            let (core, e2e, js) = try await applyRoundTrip([
                .update(id: target, set: [("text", .str("op-\(i)"))], unset: [])
            ])
            coreTimes.append(core * 1000)
            e2eTimes.append(e2e * 1000)
            jsTimes.append(js)
        }

        func pct(_ values: [Double], _ p: Double) -> Double {
            let sorted = values.sorted()
            let idx = min(sorted.count - 1, Int(Double(sorted.count) * p))
            return sorted[idx]
        }
        print("CANVAS-M1-LATENCY core(ms) p50=\(pct(coreTimes, 0.5)) p95=\(pct(coreTimes, 0.95))")
        print("CANVAS-M1-LATENCY e2e(ms)  p50=\(pct(e2eTimes, 0.5)) p95=\(pct(e2eTimes, 0.95))")
        print("CANVAS-M1-LATENCY jsApply(ms) p50=\(pct(jsTimes, 0.5)) p95=\(pct(jsTimes, 0.95))")
        XCTAssertLessThan(pct(e2eTimes, 0.95), 50, "e2e p95 over the 50ms budget")
        XCTAssertLessThan(pct(coreTimes, 0.95), 10, "engine-side apply over budget")
    }
}
