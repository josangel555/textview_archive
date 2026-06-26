import XCTest
import ViewerCore
@testable import ViewerUI

/// Slice (d) host coverage for `TmuxController` (TSK-1023): the observable PUMP
/// that drives the pure `TmuxControllerCore` from a tmux `-CC` byte stream.
/// Feeds canned control-mode bytes (no live PTY) and asserts the published
/// channels + per-pane screen. The live spawn + SwiftUI split render are the
/// VM-tail; this pins the protocol→model→publish seam on the host gate.
@MainActor
final class TmuxControllerTests: XCTestCase {

    func test_output_routesToPaneScreen_andBumpsOutputVersion() {
        let c = TmuxController(rows: 24, cols: 80)
        XCTAssertEqual(c.outputVersion, 0)
        XCTAssertNil(c.screen(forPane: TmuxPaneID(1)))

        c.ingest(Data("%output %1 hi\n".utf8))

        XCTAssertGreaterThan(c.outputVersion, 0, "a %output bumps the output channel")
        XCTAssertNotNil(c.screen(forPane: TmuxPaneID(1)),
                        "pane %1 gets an ANSI screen after %output")
        XCTAssertEqual(c.topologyVersion, 0, "pure output must NOT churn the topology channel")
    }

    func test_windowAdd_bumpsTopologyOnly() {
        let c = TmuxController()
        let topoBefore = c.topologyVersion
        let outBefore = c.outputVersion

        c.ingest(Data("%window-add @2\n".utf8))

        XCTAssertGreaterThan(c.topologyVersion, topoBefore, "a window add rebuilds the tab strip")
        XCTAssertEqual(c.outputVersion, outBefore, "topology change must NOT bump the output channel")
    }

    func test_exit_setsDidExit() {
        let c = TmuxController()
        XCTAssertFalse(c.didExit)
        c.ingest(Data("%exit\n".utf8))
        XCTAssertTrue(c.didExit)
    }

    func test_partialLine_buffersAcrossChunks() {
        let c = TmuxController()
        // Split one %output line across two ingest() calls — the parser must
        // buffer the partial line and only emit once the newline arrives.
        c.ingest(Data("%output %3 par".utf8))
        XCTAssertNil(c.screen(forPane: TmuxPaneID(3)), "no event until the line completes")
        c.ingest(Data("tial\n".utf8))
        XCTAssertNotNil(c.screen(forPane: TmuxPaneID(3)), "completed line routes to the pane")
    }
}
