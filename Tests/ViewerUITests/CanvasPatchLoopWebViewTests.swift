import WebKit
import XCTest
import ViewerCore

@testable import ViewerUI

/// Canvas M0.S3 (TSK-1354) — the E2E patch-loop proof + latency harness, on the
/// REAL production pieces: `CanvasDemoAdapter` (Rust core over FFI) →
/// `CanvasWebViewHost` (CV envelope) → `canvas.js` (DOM applier) → readback.
/// This is the loop the whole epic bets on (docs/canvas/plans/M0-PLAN.md §S3);
/// the M0 KILL CRITERION reads its numbers (06-MILESTONES-UAT.md §M0).
///
/// `#192`-gated (`MDV_RUN_WEBVIEW_TESTS=1`, the VM webview lane) — self-skips
/// in the host headless gate like every in-process WKWebView suite.
@MainActor
final class CanvasPatchLoopWebViewTests: WebViewTestCase {

    private var host: CanvasWebViewHost!
    private var adapter: CanvasDemoAdapter!
    private var inbound: [CVInboundMessage] = []
    private var window: NSWindow?

    override func setUp() async throws {
        try WebViewTestTeardown.skipUnlessEnabled()
        inbound = []
        adapter = try CanvasDemoAdapter()
        host = CanvasWebViewHost()
        host.onInbound = { [weak self] msg in self?.inbound.append(msg) }
        // M0.S3 VM finding: an INVISIBLE WKWebView's WebContent process gets
        // suspended/reaped mid-test under the GUI-lane session (every eval →
        // WKError-5, permanently). Hosting it in a real window keeps WebKit
        // treating it as foreground. The VM GUI lane exists for exactly this;
        // the suite still self-skips on the host (no window ever opens there).
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
            // Recovery path for the VM's dropped-reply flake (M0.S3 finding):
            // after ~100ms of silence, pull-drain the JS outbox.
            if polls % 5 == 0 { host.drainMissedReplies() }
        }
        return condition()
    }

    /// Push the core's full lowering into the page and await the ack.
    private func setInitialContent(seq: UInt64 = 1) async throws -> Int {
        let html = try adapter.html()
        host.send(.setContent(seq: seq, html: html))
        let ok = await waitUntil(5) {
            self.inbound.contains {
                if case .contentSet(let s, _, _) = $0 { return s == seq }
                return false
            }
        }
        if !ok {
            // Decisive diagnosis: did the eval RUN (DOM mutated) despite no ack?
            let domCount = await withCheckedContinuation { (c: CheckedContinuation<String, Never>) in
                host.probe("document.querySelectorAll('[data-cv-id]').length") { c.resume(returning: $0) }
            }
            let dispatchDefined = await withCheckedContinuation { (c: CheckedContinuation<String, Never>) in
                host.probe("typeof window.cvDispatch") { c.resume(returning: $0) }
            }
            // Resource-staleness detector: __cvDrain + outbox length prove the
            // REBUILT canvas.js is in the bundle; a stale resource means the
            // drain silently no-ops.
            let outboxState = await withCheckedContinuation { (c: CheckedContinuation<String, Never>) in
                host.probe(
                    "typeof window.__cvDrain + ':' + (window.__cvOutbox ? window.__cvOutbox.length : -1)"
                ) { c.resume(returning: $0) }
            }
            XCTFail(
                "no contentSet ack; lastSendError=\(host.lastSendError ?? "none"); "
                    + "domCount=\(domCount); cvDispatch=\(dispatchDefined); outbox=\(outboxState)")
        }
        for case let .contentSet(s, nodeCount, _) in inbound where s == seq {
            return nodeCount
        }
        return -1
    }

    /// Core-apply `ops`, forward the plan to JS, await the applied ack.
    /// Returns (coreSeconds, e2eSeconds, jsApplyMs).
    @discardableResult
    private func applyRoundTrip(
        _ ops: [CanvasDemoOp], seq: UInt64
    ) async throws -> (core: TimeInterval, e2e: TimeInterval, jsMs: Double) {
        let t0 = Date()
        let result = try adapter.apply(ops)
        let coreDt = Date().timeIntervalSince(t0)
        XCTAssertTrue(result.rejected.isEmpty, "unexpected rejects: \(result.rejected)")
        host.send(.applyPatches(seq: seq, patches: result.patches))
        let ok = await waitUntil(5) {
            self.inbound.contains {
                if case .applied(let s, _, _, _, _) = $0 { return s == seq }
                return false
            }
        }
        if !ok {
            let jsState = await withCheckedContinuation { (c: CheckedContinuation<String, Never>) in
                host.probe(
                    "(window.__cvOutbox ? window.__cvOutbox.length : -1) + ':' + (typeof window.__cvDrain)"
                ) { c.resume(returning: $0) }
            }
            XCTFail(
                "no applied ack for seq \(seq); lastSendError=\(host.lastSendError ?? "none"); "
                    + "chain[\(host.chainCounters)]; jsOutbox=\(jsState); "
                    + "contentProcessDied=\(host.contentProcessDied)")
        }
        let e2eDt = Date().timeIntervalSince(t0)
        for case let .applied(s, applied, missing, _, applyMs) in inbound where s == seq {
            XCTAssertEqual(applied, ops.count, "patch count mismatch")
            XCTAssertTrue(missing.isEmpty, "JS could not find nodes: \(missing)")
            return (coreDt, e2eDt, applyMs)
        }
        return (coreDt, e2eDt, -1)
    }

    /// Read one node's live textContent back out of the DOM.
    private func textOf(id: UInt32, replyId: UInt64) async -> String? {
        host.send(.queryText(replyId: replyId, id: id))
        _ = await waitUntil(5) {
            self.inbound.contains {
                if case .text(let r, _, _) = $0 { return r == replyId }
                return false
            }
        }
        for case let .text(r, found, text) in inbound where r == replyId {
            return found ? text : nil
        }
        return nil
    }

    // MARK: - the E2E proof

    func test_patchLoop_mutatesExactlyTheTargetNode() async throws {
        let nodeCount = try await setInitialContent()
        XCTAssertEqual(nodeCount, 201, "core lowering must land 201 stamped DOM nodes")

        // Baseline: node 3 = "Row 0.0", node 4 = "Row 0.1".
        let before3 = await textOf(id: 3, replyId: 100)
        let before4 = await textOf(id: 4, replyId: 101)
        XCTAssertEqual(before3, "Row 0.0")
        XCTAssertEqual(before4, "Row 0.1")

        try await applyRoundTrip([.setText(id: 3, text: "patched-by-loop")], seq: 2)

        // Exactness: the target changed, the neighbor did not.
        let after3 = await textOf(id: 3, replyId: 102)
        let after4 = await textOf(id: 4, replyId: 103)
        XCTAssertEqual(after3, "patched-by-loop", "the patch loop must reach the DOM")
        XCTAssertEqual(after4, "Row 0.1", "no collateral DOM mutation")
    }

    func test_geometry_returnsFlowSaneBoxes() async throws {
        _ = try await setInitialContent()
        host.send(.queryGeometry(replyId: 200, ids: [2, 3, 4]))
        let ok = await waitUntil(5) {
            self.inbound.contains {
                if case .geometry(let r, _) = $0 { return r == 200 }
                return false
            }
        }
        XCTAssertTrue(ok, "no geometry reply")
        for case let .geometry(r, boxes) in inbound where r == 200 {
            XCTAssertEqual(boxes.count, 3)
            for box in boxes {
                XCTAssertGreaterThan(box.w, 0, "zero-width box for \(box.id)")
                XCTAssertGreaterThan(box.h, 0, "zero-height box for \(box.id)")
            }
            // Flow guarantee: successive column children stack downward.
            let ys = boxes.map(\.y)
            XCTAssertEqual(ys, ys.sorted(), "column children must not overlap upward")
        }
    }

    func test_domSurvivesDetachReattach() async throws {
        _ = try await setInitialContent()
        try await applyRoundTrip([.setText(id: 5, text: "survives-park")], seq: 3)

        // Park/re-attach: move the webview between containers (the TSK-1046
        // class — state must live in the page, not the attachment).
        let containerA = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let containerB = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        containerA.addSubview(host.webView)
        host.webView.removeFromSuperview()
        containerB.addSubview(host.webView)

        let after = await textOf(id: 5, replyId: 300)
        XCTAssertEqual(after, "survives-park", "DOM state must survive detach/re-attach")
    }

    // MARK: - the latency harness (the kill-criterion numbers)

    func test_latencyHarness_50ops_reportsPercentiles() async throws {
        _ = try await setInitialContent()

        // Warm-up (JIT, first-paint) — excluded from the measurement.
        try await applyRoundTrip([.setText(id: 10, text: "warmup")], seq: 10)

        var coreTimes: [Double] = []
        var e2eTimes: [Double] = []
        var jsTimes: [Double] = []
        for i in 0..<50 {
            // TEXT rows only (section 0 rows = ids 3...20): setText on a FRAME
            // id would wipe its subtree via textContent — a real M1 fence rule
            // (op-target kind check), sidestepped in the M0 harness.
            let id = UInt32(3 + (i % 18))
            let (core, e2e, js) = try await applyRoundTrip(
                [.setText(id: id, text: "op-\(i)")], seq: UInt64(1000 + i))
            coreTimes.append(core * 1000)
            e2eTimes.append(e2e * 1000)
            jsTimes.append(js)
        }

        func pct(_ values: [Double], _ p: Double) -> Double {
            let sorted = values.sorted()
            let idx = min(sorted.count - 1, Int(Double(sorted.count) * p))
            return sorted[idx]
        }
        let corP50 = pct(coreTimes, 0.5), corP95 = pct(coreTimes, 0.95)
        let e2eP50 = pct(e2eTimes, 0.5), e2eP95 = pct(e2eTimes, 0.95)
        let jsP50 = pct(jsTimes, 0.5), jsP95 = pct(jsTimes, 0.95)

        // The M0 verdict data (S4 records these on the board):
        print("CANVAS-M0-LATENCY core(ms) p50=\(corP50) p95=\(corP95)")
        print("CANVAS-M0-LATENCY e2e(ms)  p50=\(e2eP50) p95=\(e2eP95)")
        print("CANVAS-M0-LATENCY jsApply(ms) p50=\(jsP50) p95=\(jsP95)")

        // Budget asserts (06-MILESTONES-UAT §M0): p95 E2E < 50ms hard;
        // p50 < 16ms is REPORTED, not hard-asserted (machine variance).
        XCTAssertLessThan(e2eP95, 50, "M0 KILL CRITERION: e2e p95 over budget")
        XCTAssertLessThan(corP95, 10, "core-side apply should be far under the e2e budget")
    }
}
