import XCTest
@testable import ViewerCore

/// Host coverage for `TmuxControllerCore` (TSK-1018, re-landed controller
/// host-logic core), the command-number correlation FIFO, and the per-pane
/// `%output` demultiplexing — the pure seams TSK-1018 mandates be pinned by
/// injecting a fake `[ControlModeEvent]` stream and asserting (a) topology
/// updates, (b) `%output` bytes land in the correct per-pane buffer, (c) the
/// active-pane input target resolves correctly, and (d) pane add/close
/// re-routes. The live `tmux -CC` spawn + stdout pump + SwiftUI split render
/// are the injected edges (VM-tail follow-up) and are NOT exercised here.
final class TmuxControllerCoreTests: XCTestCase {

    // MARK: - (a) Topology updates from injected events

    func test_ingest_windowAdd_close_drivesSessionTopology() {
        var core = TmuxControllerCore()
        let added = core.ingest([.windowAdd(1), .windowAdd(2), .windowAdd(3)])
        XCTAssertTrue(added.topologyChanged)
        XCTAssertEqual(core.session.windows.map(\.id), [1, 2, 3])

        // Duplicate add is a no-op (idempotent → no topology change).
        let dup = core.ingest([.windowAdd(2)])
        XCTAssertFalse(dup.topologyChanged)
        XCTAssertEqual(core.session.windows.count, 3)

        // Close the middle one; order of the rest is stable.
        let closed = core.ingest([.windowClose(2)])
        XCTAssertTrue(closed.topologyChanged)
        XCTAssertEqual(core.session.windows.map(\.id), [1, 3])

        // Closing a non-existent window is a no-op.
        let noop = core.ingest([.windowClose(99)])
        XCTAssertFalse(noop.topologyChanged)
    }

    func test_ingest_rename_andSessionChange_flagTopology() {
        var core = TmuxControllerCore()
        core.ingest([.windowAdd(1)])
        let renamed = core.ingest([.windowRenamed(1, "editor")])
        XCTAssertTrue(renamed.topologyChanged)
        XCTAssertEqual(core.session.window(id: 1)?.name, "editor")

        let sess = core.ingest([.sessionChanged(7, "work")])
        XCTAssertTrue(sess.topologyChanged)
        XCTAssertEqual(core.session.sessionId, 7)
        XCTAssertEqual(core.session.sessionName, "work")
    }

    // MARK: - (b) %output demux into the correct per-pane buffer (THE core pin)

    func test_demux_routesBytesToCorrectPaneParser_noCrossTalk() {
        var core = TmuxControllerCore(rows: 24, cols: 80)
        // Inject a fake event stream: pane 1 gets "AB", pane 2 gets "XY",
        // then pane 1 gets "C".
        let fx = core.ingest([
            .output(paneId: 1, bytes: Array("AB".utf8)),
            .output(paneId: 2, bytes: Array("XY".utf8)),
            .output(paneId: 1, bytes: Array("C".utf8)),
        ])
        XCTAssertEqual(fx.updatedPanes, [TmuxPaneID(1), TmuxPaneID(2)])

        // Pane 1's screen shows ABC; pane 2's shows XY — no cross-talk.
        XCTAssertEqual(core.screen(forPane: TmuxPaneID(1))?.line(0).prefix(3), "ABC")
        XCTAssertEqual(core.screen(forPane: TmuxPaneID(2))?.line(0).prefix(2), "XY")
        // A pane that never got output has no parser.
        XCTAssertNil(core.screen(forPane: TmuxPaneID(3)))
        XCTAssertEqual(core.activePanes, [TmuxPaneID(1), TmuxPaneID(2)])
    }

    func test_demux_lazilyAllocatesPanes() {
        var core = TmuxControllerCore()
        XCTAssertTrue(core.activePanes.isEmpty)
        core.ingest([.output(paneId: 9, bytes: Array("hi".utf8))])
        XCTAssertEqual(core.activePanes, [TmuxPaneID(9)])
    }

    func test_demux_dropPane_reclaims() {
        var core = TmuxControllerCore()
        core.ingest([.output(paneId: 1, bytes: Array("z".utf8))])
        XCTAssertNotNil(core.screen(forPane: TmuxPaneID(1)))
        core.dropPane(TmuxPaneID(1))
        XCTAssertNil(core.screen(forPane: TmuxPaneID(1)))
    }

    func test_demux_resizePane_appliesToParser() {
        var core = TmuxControllerCore(rows: 24, cols: 80)
        core.ingest([.output(paneId: 1, bytes: Array("x".utf8))])
        core.resizePane(TmuxPaneID(1), rows: 10, cols: 40)
        XCTAssertEqual(core.screen(forPane: TmuxPaneID(1))?.rows, 10)
        XCTAssertEqual(core.screen(forPane: TmuxPaneID(1))?.cols, 40)
    }

    // MARK: - (c) Active-pane input target resolution

    func test_inputTarget_resolvesToReportedActivePane() {
        var core = TmuxControllerCore()
        // A two-pane horizontal layout: panes %1 and %2.
        core.ingest([
            .windowAdd(1),
            .layoutChange(window: 1, layout: "abcd,80x24,0,0{40x24,0,0,1,39x24,41,0,2}"),
        ])
        // With no %window-pane-changed yet, the layout seeded the FIRST pane
        // as active — so input routes to %1.
        XCTAssertEqual(core.inputTarget(inWindow: 1), TmuxPaneID(1))

        // tmux reports the active pane moved to %2 → input follows.
        core.ingest([.windowPaneChanged(window: 1, pane: 2)])
        XCTAssertEqual(core.inputTarget(inWindow: 1), TmuxPaneID(2))

        // The session's active window is window 1 (first added) → the
        // convenience accessor resolves to the same target.
        XCTAssertEqual(core.activeInputTarget, TmuxPaneID(2))
    }

    func test_inputTarget_unknownWindowOrNoLayout_isNil() {
        var core = TmuxControllerCore()
        XCTAssertNil(core.inputTarget(inWindow: 1))     // no window at all
        core.ingest([.windowAdd(1)])                    // window, but no layout
        XCTAssertNil(core.inputTarget(inWindow: 1))
        XCTAssertNil(core.activeInputTarget)
    }

    // MARK: - (d) Pane add/close re-routes the input target

    func test_paneClose_reroutesInputTarget_andReapsBuffer() {
        var core = TmuxControllerCore()
        // Start with a two-pane layout, active pane = %2.
        core.ingest([
            .windowAdd(1),
            .layoutChange(window: 1, layout: "abcd,80x24,0,0{40x24,0,0,1,39x24,41,0,2}"),
            .windowPaneChanged(window: 1, pane: 2),
            // Both panes produce output → both get parsers.
            .output(paneId: 1, bytes: Array("a".utf8)),
            .output(paneId: 2, bytes: Array("b".utf8)),
        ])
        XCTAssertEqual(core.inputTarget(inWindow: 1), TmuxPaneID(2))
        XCTAssertEqual(core.activePanes, [TmuxPaneID(1), TmuxPaneID(2)])

        // Pane %2 is killed: tmux re-lays the window to just %1 (a new
        // single-pane layout). The stale active pane (%2) no longer exists,
        // so the routing target falls back to the surviving pane %1.
        core.ingest([.layoutChange(window: 1, layout: "abcd,80x24,0,0,1")])
        XCTAssertEqual(core.inputTarget(inWindow: 1), TmuxPaneID(1),
                       "closed active pane must re-route to the surviving pane")

        // Reaping closed-pane buffers drops %2's parser, keeps %1's.
        let reaped = core.reapClosedPanes()
        XCTAssertEqual(reaped, [TmuxPaneID(2)])
        XCTAssertNil(core.screen(forPane: TmuxPaneID(2)))
        XCTAssertNotNil(core.screen(forPane: TmuxPaneID(1)))
    }

    func test_paneAdd_viaLayout_extendsRoutableSet() {
        var core = TmuxControllerCore()
        core.ingest([
            .windowAdd(1),
            .layoutChange(window: 1, layout: "abcd,80x24,0,0,1"),   // single pane %1
        ])
        XCTAssertEqual(core.session.paneIDs(inWindow: 1), [TmuxPaneID(1)])

        // A split adds %2; both panes are now routable.
        core.ingest([.layoutChange(window: 1, layout: "abcd,80x24,0,0{40x24,0,0,1,39x24,41,0,2}")])
        XCTAssertEqual(core.session.paneIDs(inWindow: 1), [TmuxPaneID(1), TmuxPaneID(2)])
        // Active pane unchanged (still %1) → routes there; if it had been
        // killed, keyRoutingTarget would fall back to the first pane.
        XCTAssertEqual(core.inputTarget(inWindow: 1), TmuxPaneID(1))
    }

    // MARK: - Command FIFO correlation

    func test_fifo_assignsMonotonicNumbers_resolvesInOrder() {
        var q = TmuxCommandQueue<String>()
        XCTAssertEqual(q.enqueue("list-windows"), 0)
        XCTAssertEqual(q.enqueue("list-panes"), 1)
        XCTAssertEqual(q.enqueue("display-message"), 2)
        XCTAssertEqual(q.inFlightCount, 3)

        XCTAssertEqual(q.resolve(0), "list-windows")
        XCTAssertEqual(q.resolve(1), "list-panes")
        XCTAssertEqual(q.resolve(2), "display-message")
        XCTAssertEqual(q.inFlightCount, 0)
    }

    func test_fifo_resolveDropsSkippedEarlierEntries() {
        var q = TmuxCommandQueue<String>()
        q.enqueue("a"); q.enqueue("b"); q.enqueue("c")
        XCTAssertEqual(q.resolve(2), "c")
        XCTAssertEqual(q.inFlightCount, 0)
    }

    func test_fifo_unknownNumber_returnsNil_leavesQueueIntact() {
        var q = TmuxCommandQueue<String>()
        q.enqueue("a")
        XCTAssertNil(q.resolve(42))
        XCTAssertEqual(q.inFlightCount, 1)
    }

    func test_fifo_drain_returnsAllInFlight() {
        var q = TmuxCommandQueue<String>()
        q.enqueue("a"); q.enqueue("b")
        XCTAssertEqual(q.drain(), ["a", "b"])
        XCTAssertEqual(q.inFlightCount, 0)
    }

    // MARK: - Reply-frame assembly + correlation through the core

    func test_replyFrame_assemblesLines_andCorrelatesToCommand() {
        var core = TmuxControllerCore()
        // Enqueue a command (returns the wire bytes incl. newline).
        let data = core.encodeCommand("list-windows")
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "list-windows\n")

        // Command number 0 was assigned; the reply frame for #0 resolves to it.
        let fx = core.ingest([
            .beginReply(cmdNum: 0),
            .replyLine("@1 main"),
            .replyLine("@2 logs"),
            .endReply(cmdNum: 0),
        ])
        XCTAssertEqual(fx.replies.count, 1)
        XCTAssertEqual(fx.replies.first?.command, "list-windows")
        XCTAssertEqual(fx.replies.first?.lines, ["@1 main", "@2 logs"])
        XCTAssertTrue(fx.replies.first?.succeeded ?? false)
        XCTAssertEqual(core.commandQueue.inFlightCount, 0)
    }

    func test_replyFrame_errorClose_marksFailed() {
        var core = TmuxControllerCore()
        core.encodeCommand("bogus-command")
        let fx = core.ingest([
            .beginReply(cmdNum: 0),
            .replyLine("unknown command: bogus-command"),
            .errorReply(cmdNum: 0),
        ])
        XCTAssertEqual(fx.replies.count, 1)
        XCTAssertEqual(fx.replies.first?.command, "bogus-command")
        XCTAssertFalse(fx.replies.first?.succeeded ?? true)
    }

    func test_replyFrame_spuriousNumber_droppedNotCrashed() {
        var core = TmuxControllerCore()
        // A reply for a command we never sent: dropped, no reply emitted.
        let fx = core.ingest([
            .beginReply(cmdNum: 99),
            .replyLine("noise"),
            .endReply(cmdNum: 99),
        ])
        XCTAssertTrue(fx.replies.isEmpty)
    }

    func test_drainCommands_failsInFlight() {
        var core = TmuxControllerCore()
        core.encodeCommand("a")
        core.encodeCommand("b")
        XCTAssertEqual(core.drainCommands(), ["a", "b"])
        XCTAssertEqual(core.commandQueue.inFlightCount, 0)
    }

    // MARK: - Exit

    func test_exitEvent_setsDidExit() {
        var core = TmuxControllerCore()
        let fx = core.ingest([.exit(reason: nil)])
        XCTAssertTrue(fx.didExit)
    }

    // MARK: - tmux discovery + argv (pure seams)

    func test_locate_overrideWins_whenExecutable() {
        let found = TmuxControllerCore.locateTmux(
            override: "/custom/tmux",
            environment: ["PATH": "/usr/bin"],
            fileExists: { $0 == "/custom/tmux" }
        )
        XCTAssertEqual(found, "/custom/tmux")
    }

    func test_locate_ignoresOverride_whenNotExecutable_fallsToPath() {
        let found = TmuxControllerCore.locateTmux(
            override: "/custom/tmux",
            environment: ["PATH": "/opt/bin:/usr/bin"],
            fileExists: { $0 == "/usr/bin/tmux" }
        )
        XCTAssertEqual(found, "/usr/bin/tmux")
    }

    func test_locate_scansPathInOrder() {
        let found = TmuxControllerCore.locateTmux(
            override: nil,
            environment: ["PATH": "/a:/b:/c"],
            fileExists: { $0 == "/b/tmux" || $0 == "/c/tmux" }
        )
        XCTAssertEqual(found, "/b/tmux")
    }

    func test_locate_fixedHomebrewLocation_whenNotOnPath() {
        let found = TmuxControllerCore.locateTmux(
            override: nil,
            environment: ["PATH": "/nowhere"],
            fileExists: { $0 == "/opt/homebrew/bin/tmux" }
        )
        XCTAssertEqual(found, "/opt/homebrew/bin/tmux")
    }

    func test_locate_returnsNil_whenAbsent_drivesGracefulFallback() {
        let found = TmuxControllerCore.locateTmux(
            override: nil,
            environment: ["PATH": "/nowhere"],
            fileExists: { _ in false }
        )
        XCTAssertNil(found)
    }

    func test_controlModeArgv_default_andNamedSession() {
        XCTAssertEqual(
            TmuxControllerCore.controlModeArgv(tmuxPath: "/opt/homebrew/bin/tmux"),
            ["/opt/homebrew/bin/tmux", "-CC", "new-session", "-A"]
        )
        XCTAssertEqual(
            TmuxControllerCore.controlModeArgv(tmuxPath: "/usr/bin/tmux", sessionName: "work"),
            ["/usr/bin/tmux", "-CC", "new-session", "-A", "-s", "work"]
        )
        // An empty name is ignored (no stray -s).
        XCTAssertEqual(
            TmuxControllerCore.controlModeArgv(tmuxPath: "/usr/bin/tmux", sessionName: ""),
            ["/usr/bin/tmux", "-CC", "new-session", "-A"]
        )
    }

    // MARK: - End-to-end: raw control-mode bytes → parser → core

    func test_endToEnd_rawControlStream_seedsTabsAndDemuxesPaneOutput() {
        var parser = TmuxControlParser()
        var core = TmuxControllerCore(rows: 24, cols: 80)

        let wire =
            "%session-changed $1 main\n" +
            "%window-add @1\n" +
            "%window-renamed @1 editor\n" +
            "%layout-change @1 abcd,80x24,0,0,10\n" +
            "%window-pane-changed @1 %10\n" +
            "%output %10 \\033[1mhi\\033[0m\n"

        let events = parser.feed(Array(wire.utf8))
        let fx = core.ingest(events)

        XCTAssertTrue(fx.topologyChanged)
        XCTAssertEqual(core.session.sessionName, "main")
        XCTAssertEqual(core.session.window(id: 1)?.name, "editor")
        XCTAssertEqual(core.inputTarget(inWindow: 1), TmuxPaneID(10))
        XCTAssertEqual(fx.updatedPanes, [TmuxPaneID(10)])
        // The escaped output decoded + drew "hi" on pane %10.
        XCTAssertEqual(core.screen(forPane: TmuxPaneID(10))?.line(0).prefix(2), "hi")
    }
}
