import XCTest
@testable import ViewerCore

/// Hardening coverage for `TmuxControllerCore` reply-frame correlation + the
/// command FIFO, targeting the highest-severity gaps the happy-path suite
/// (`TmuxControllerCoreTests`) leaves uncovered. The theme is SILENT LOSS: an
/// awaiting caller stranded forever, a reply body swallowed, a malformed frame
/// resolving as a false empty success. The hardened core now SURFACES each of
/// these (via `Effects.droppedCommands` / `Effects.anomalies` and the FIFO's
/// `resolveReporting`) so the loss is observable, not invisible.
final class TmuxControllerCoreHardeningTests: XCTestCase {

    // MARK: - HIGH: FIFO — skipped earlier commands are surfaced, not dropped

    /// `resolveReporting` returns the SKIPPED earlier in-flight commands so the
    /// caller can fail them. The old `resolve(_:) -> Tag?` discarded them with no
    /// signal, stranding their awaiting callers forever.
    func test_fifo_resolveReporting_surfacesSkippedEntries() {
        var q = TmuxCommandQueue<String>()
        XCTAssertEqual(q.enqueue("list-windows"), 0)
        XCTAssertEqual(q.enqueue("list-panes"), 1)
        XCTAssertEqual(q.enqueue("display-message"), 2)

        // Resolve #2 while #0 and #1 are still in flight: tmux replied out of
        // FIFO order, so #0 and #1 are abandoned — and must be reported.
        let r = q.resolveReporting(2)
        XCTAssertEqual(r.matched, "display-message")
        XCTAssertEqual(r.dropped, ["list-windows", "list-panes"])
        XCTAssertEqual(q.inFlightCount, 0)
    }

    /// Resolving the HEAD of the queue drops nothing (the common in-order case).
    func test_fifo_resolveReporting_headResolve_dropsNothing() {
        var q = TmuxCommandQueue<String>()
        q.enqueue("a"); q.enqueue("b")
        let r = q.resolveReporting(0)
        XCTAssertEqual(r.matched, "a")
        XCTAssertTrue(r.dropped.isEmpty)
        XCTAssertEqual(q.inFlightCount, 1)   // "b" still in flight
    }

    /// An unknown number reports neither a match nor any drops, and leaves the
    /// queue intact.
    func test_fifo_resolveReporting_unknownNumber_isInert() {
        var q = TmuxCommandQueue<String>()
        q.enqueue("a")
        let r = q.resolveReporting(99)
        XCTAssertNil(r.matched)
        XCTAssertTrue(r.dropped.isEmpty)
        XCTAssertEqual(q.inFlightCount, 1)
    }

    /// At the CORE level: send A then B, then receive only B's reply frame. B
    /// resolves, and A is surfaced in `Effects.droppedCommands` (not silently
    /// lost as it was before).
    func test_core_outOfOrderReply_surfacesDroppedCommand() {
        var core = TmuxControllerCore()
        core.encodeCommand("A")            // cmd #0
        core.encodeCommand("B")            // cmd #1

        let fx = core.ingest([
            .beginReply(cmdNum: 1),
            .replyLine("b-body"),
            .endReply(cmdNum: 1),
        ])
        XCTAssertEqual(fx.replies.count, 1)
        XCTAssertEqual(fx.replies.first?.command, "B")
        XCTAssertEqual(fx.replies.first?.lines, ["b-body"])
        XCTAssertEqual(fx.droppedCommands, ["A"],
                       "command A's reply was skipped and must be surfaced, not stranded")
        XCTAssertEqual(core.commandQueue.inFlightCount, 0)
    }

    // MARK: - HIGH: reply-frame %begin/%end cmdNum mismatch surfaces the body

    /// A frame that opens with `%begin 0` (accumulating a body) but closes with
    /// `%end 5` (id skew / corrupted stream) must NOT silently resolve command
    /// #5 with an EMPTY body and drop frame-0's body without a trace. The body +
    /// the skew are surfaced as a `.replyFrameCmdNumMismatch` anomaly.
    func test_core_beginEndCmdNumMismatch_surfacesBodyAndSkew() {
        var core = TmuxControllerCore()
        // Six commands in flight (#0..#5) so #5 correlates to a real command.
        for name in ["c0", "c1", "c2", "c3", "c4", "c5"] { core.encodeCommand(name) }

        let fx = core.ingest([
            .beginReply(cmdNum: 0),
            .replyLine("realbody"),
            .endReply(cmdNum: 5),          // closes a DIFFERENT command than it opened
        ])
        // #5 still resolves (FIFO correlation by close number) but with NO body…
        XCTAssertEqual(fx.replies.count, 1)
        XCTAssertEqual(fx.replies.first?.command, "c5")
        XCTAssertEqual(fx.replies.first?.lines, [],
                       "a mismatched frame must not attribute frame-0's body to c5")
        // …and the mismatch + the accumulated body are surfaced, not discarded.
        XCTAssertTrue(fx.anomalies.contains(
            .replyFrameCmdNumMismatch(openCmdNum: 0, closeCmdNum: 5,
                                      body: ["realbody"], succeeded: true)),
            "the cmdNum skew and the orphaned body must be reported: \(fx.anomalies)")
        // #0..#4 were skipped ahead of #5 → reported as dropped.
        XCTAssertEqual(fx.droppedCommands, ["c0", "c1", "c2", "c3", "c4"])
    }

    /// A mismatched %error close surfaces the accumulated ERROR text — exactly
    /// the diagnostic a user needs — rather than silently emptying it.
    func test_core_errorFrameCmdNumMismatch_surfacesErrorBody() {
        var core = TmuxControllerCore()
        for name in ["c0", "c1", "c2", "c3", "c4", "c5", "c6", "c7"] { core.encodeCommand(name) }

        let fx = core.ingest([
            .beginReply(cmdNum: 0),
            .replyLine("unknown command"),
            .errorReply(cmdNum: 7),
        ])
        XCTAssertEqual(fx.replies.first?.command, "c7")
        XCTAssertEqual(fx.replies.first?.succeeded, false)
        XCTAssertEqual(fx.replies.first?.lines, [])
        XCTAssertTrue(fx.anomalies.contains(
            .replyFrameCmdNumMismatch(openCmdNum: 0, closeCmdNum: 7,
                                      body: ["unknown command"], succeeded: false)),
            "the error text on a mismatched close must be reported: \(fx.anomalies)")
    }

    // MARK: - MEDIUM: orphan frame terminator (no %begin)

    /// An `%end <n>` with `n` in flight but NO preceding `%begin` resolves the
    /// command (a body may have been intended, but is unknowable) AND is flagged
    /// as `.orphanFrameClose` — so a malformed stream's "false empty success"
    /// isn't invisible.
    func test_core_orphanEndClose_resolvesButFlagsAnomaly() {
        var core = TmuxControllerCore()
        core.encodeCommand("A")             // cmd #0

        let fx = core.ingest([.endReply(cmdNum: 0)])   // no %begin first
        XCTAssertEqual(fx.replies.count, 1)
        XCTAssertEqual(fx.replies.first?.command, "A")
        XCTAssertEqual(fx.replies.first?.lines, [])
        XCTAssertTrue(fx.anomalies.contains(.orphanFrameClose(cmdNum: 0, succeeded: true)),
                      "an end-without-begin must be flagged: \(fx.anomalies)")
    }

    /// A stray `.replyLine` with no open frame is dropped without affecting a
    /// later, well-formed frame.
    func test_core_strayReplyLine_noOpenFrame_doesNotCorruptLaterFrame() {
        var core = TmuxControllerCore()
        core.encodeCommand("A")             // cmd #0

        let fx = core.ingest([
            .replyLine("orphan-line"),      // no frame open → dropped
            .beginReply(cmdNum: 0),
            .replyLine("real"),
            .endReply(cmdNum: 0),
        ])
        XCTAssertEqual(fx.replies.count, 1)
        XCTAssertEqual(fx.replies.first?.lines, ["real"],
                       "the orphan line must not bleed into the real frame")
    }

    // MARK: - LOW: re-opened (nested) %begin abandons the prior frame, surfaced

    /// A `%begin` while a frame is still open abandons the prior frame's body —
    /// reasonable as a defensive choice, but it must be SURFACED (the prior body
    /// is lost) and the still-pending command must be observable as a leak via
    /// `inFlightCount`.
    func test_core_reopenedFrame_abandonsPriorFrame_surfacesIt() {
        var core = TmuxControllerCore()
        core.encodeCommand("A")             // cmd #0
        core.encodeCommand("B")             // cmd #1

        let fx = core.ingest([
            .beginReply(cmdNum: 0),
            .replyLine("abandoned"),
            .beginReply(cmdNum: 1),         // re-opens before closing #0
            .replyLine("kept"),
            .endReply(cmdNum: 1),
        ])
        // Only B resolves; its body is "kept".
        XCTAssertEqual(fx.replies.count, 1)
        XCTAssertEqual(fx.replies.first?.command, "B")
        XCTAssertEqual(fx.replies.first?.lines, ["kept"])
        // A's abandoned frame is surfaced.
        XCTAssertTrue(fx.anomalies.contains(
            .reopenedFrame(abandonedCmdNum: 0, newCmdNum: 1, body: ["abandoned"])),
            "the abandoned re-opened frame must be reported: \(fx.anomalies)")
        // A (#0) was skipped ahead of B (#1) → dropped (it's no longer leaked
        // in flight, but the caller IS notified its reply was lost).
        XCTAssertEqual(fx.droppedCommands, ["A"])
        XCTAssertEqual(core.commandQueue.inFlightCount, 0)
    }

    // MARK: - End-to-end: %extended-output demuxes through the core

    /// The HIGH inbound `%extended-output` fix, exercised end-to-end: a raw
    /// control-mode stream that uses flow-controlled output must demux into the
    /// pane's parser exactly as `%output` does. Before the fix this fell to
    /// `.unknown` and `screen(forPane:)` stayed nil (the pane froze on screen).
    func test_endToEnd_extendedOutput_demuxesIntoPaneScreen() {
        var parser = TmuxControlParser()
        var core = TmuxControllerCore(rows: 24, cols: 80)

        let wire =
            "%window-add @1\n" +
            "%layout-change @1 abcd,80x24,0,0,3\n" +
            "%extended-output %3 12 : hi\\033[m\n"

        let events = parser.feed(Array(wire.utf8))
        let fx = core.ingest(events)

        XCTAssertEqual(fx.updatedPanes, [TmuxPaneID(3)])
        XCTAssertEqual(core.screen(forPane: TmuxPaneID(3))?.line(0).prefix(2), "hi",
                       "flow-controlled pane output must reach the pane's screen")
    }

    // MARK: - MEDIUM: closing the ACTIVE window re-resolves the input target

    /// Closing the active window (not just a pane) must leave the input target
    /// in a DEFINED state: it switches to the neighbor window, whose target is
    /// nil until ITS layout arrives — then resolves once the layout lands. This
    /// pins the interim "input stranded until layout" window as known behaviour.
    func test_core_closeActiveWindow_inputTargetReResolvesOnLayout() {
        var core = TmuxControllerCore()
        core.ingest([
            .windowAdd(1),
            .layoutChange(window: 1, layout: "abcd,80x24,0,0,1"),
            .windowAdd(2),                  // @2 added, no layout yet
        ])
        XCTAssertEqual(core.session.activeWindowId, 1)
        XCTAssertEqual(core.activeInputTarget, TmuxPaneID(1))

        // Close the active window @1 → active becomes @2 (its left neighbor in
        // selection terms), which has no layout → no input target yet.
        core.ingest([.windowClose(1)])
        XCTAssertEqual(core.session.activeWindowId, 2)
        XCTAssertNil(core.activeInputTarget,
                     "with @2 lacking a layout, the input target is (defined as) nil")

        // @2's layout arrives → the input target resolves.
        core.ingest([.layoutChange(window: 2, layout: "abcd,80x24,0,0,9")])
        XCTAssertEqual(core.activeInputTarget, TmuxPaneID(9))

        // Reaping after the close drops @1's pane parser if it had one; @2's
        // pane survives once it produces output.
        core.ingest([.output(paneId: 9, bytes: Array("x".utf8))])
        let reaped = core.reapClosedPanes()
        XCTAssertFalse(reaped.contains(TmuxPaneID(9)), "the live pane must survive reaping")
    }

    // MARK: - MEDIUM: %window-pane-changed for a pane absent from the layout

    /// tmux may report an active pane id BEFORE the matching `%layout-change`
    /// lands (notification ordering isn't guaranteed). The interim policy:
    /// `keyRoutingTarget` falls back to the FIRST pane when the reported active
    /// pane isn't in the current layout. Pinned so the fallback window is a
    /// known, tested behaviour (not a silent mis-route surprise).
    func test_core_activePaneNotInLayout_fallsBackToFirst_thenFollows() {
        var core = TmuxControllerCore()
        core.ingest([
            .windowAdd(1),
            .layoutChange(window: 1, layout: "abcd,80x24,0,0,1"),  // only %1
            .windowPaneChanged(window: 1, pane: 2),                // %2 not in layout yet
        ])
        // Interim: routes to the first (only) pane %1, NOT the absent %2.
        XCTAssertEqual(core.inputTarget(inWindow: 1), TmuxPaneID(1))

        // The layout catches up and includes %2 → routing follows to %2.
        core.ingest([.layoutChange(window: 1, layout: "abcd,80x24,0,0{40x24,0,0,1,39x24,41,0,2}")])
        XCTAssertEqual(core.inputTarget(inWindow: 1), TmuxPaneID(2),
                       "once %2 exists, the already-reported active pane routes there")
    }

    // MARK: - MEDIUM: straggler %output after a pane is reaped

    /// A late `%output` for a pane that was already reaped re-allocates a parser
    /// (the lazy-allocate behaviour). This pins it as KNOWN behaviour so a future
    /// policy change (drop output for panes absent from a non-empty topology) is
    /// a deliberate, test-visible decision rather than a silent flap.
    func test_core_stragglerOutputAfterReap_currentlyResurrectsPane_pinned() {
        var core = TmuxControllerCore()
        core.ingest([
            .windowAdd(1),
            .layoutChange(window: 1, layout: "abcd,80x24,0,0,1"),
            .output(paneId: 1, bytes: Array("x".utf8)),
        ])
        // Kill %1: re-lay the window to a different single pane %2.
        core.ingest([.layoutChange(window: 1, layout: "abcd,80x24,0,0,2")])
        let reaped = core.reapClosedPanes()
        XCTAssertEqual(reaped, [TmuxPaneID(1)])
        XCTAssertNil(core.screen(forPane: TmuxPaneID(1)))

        // A straggler frame for the now-dead %1 currently re-creates its parser.
        core.ingest([.output(paneId: 1, bytes: Array("y".utf8))])
        XCTAssertTrue(core.activePanes.contains(TmuxPaneID(1)),
                      "pinned: a straggler %output currently resurrects a reaped pane")
        // The next reap reclaims it again (it's absent from topology).
        let reapedAgain = core.reapClosedPanes()
        XCTAssertEqual(reapedAgain, [TmuxPaneID(1)])
    }
}
