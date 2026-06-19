import XCTest
@testable import ViewerCore

/// Headless (Tier 1) coverage for the pure tmux control-mode topology model
/// (`TmuxSession` / `TmuxWindow`, slice c). Drives typed `ControlModeEvent`s
/// (slice a) carrying real tmux layout strings (slice b) and asserts the
/// resulting windows↔tabs, active window+pane selection, and that a window's
/// flattened pane-id set matches its layout tree. NO PTY, NO AppKit.
///
/// See `docs/TMUX_CC_DESIGN_2026-06-18.md` §2-§3.
final class TmuxSessionTests: XCTestCase {

    // MARK: - Layout-string fixtures (valid tmux layouts, see §1.4)

    /// Single pane (the layout tmux sends for a brand-new window).
    private func singlePane(_ id: Int) -> String { "1a2b,80x24,0,0,\(id)" }

    /// Horizontal split: pane `l` on the left, pane `r` on the right.
    private func hSplit(_ l: Int, _ r: Int) -> String {
        "bf3a,178x40,0,0{88x40,0,0,\(l),89x40,89,0,\(r)}"
    }

    /// Three panes: top-level horizontal split — pane `a` on the left, and on
    /// the right a vertical split of `b` over `c`. (The §1.4 worked example.)
    private func threePane(_ a: Int, _ b: Int, _ c: Int) -> String {
        "bf3a,178x40,0,0{88x40,0,0,\(a),89x40,89,0[89x20,89,0,\(b),89x19,89,21,\(c)]}"
    }

    // MARK: - The realistic end-to-end sequence (the task's mandated drive)

    /// Add 2 windows, layout-change each, rename one, pane-changed, close one;
    /// assert windows/tabs, active window+pane, and flattened pane-id sets.
    func testRealisticEventSequence() {
        var s = TmuxSession()

        // Session identity arrives first.
        s.apply(.sessionChanged(7, "work"))
        XCTAssertEqual(s.sessionId, 7)
        XCTAssertEqual(s.sessionName, "work")

        // Two windows appear → two tabs. First becomes active.
        s.apply(.windowAdd(1))
        s.apply(.windowAdd(2))
        XCTAssertEqual(s.windows.map(\.id), [1, 2])
        XCTAssertEqual(s.activeWindowId, 1, "first window added is active")

        // Layout for window 1: a 3-pane tree (panes 10,11,12).
        s.apply(.layoutChange(window: 1, layout: threePane(10, 11, 12)))
        // Layout for window 2: a 2-pane horizontal split (panes 20,21).
        s.apply(.layoutChange(window: 2, layout: hSplit(20, 21)))

        // Flattened pane ids match the trees, in document order.
        XCTAssertEqual(s.paneIds(inWindow: 1), [10, 11, 12])
        XCTAssertEqual(s.paneIds(inWindow: 2), [20, 21])
        // Active pane defaulted to the first pane of each new layout.
        XCTAssertEqual(s.activePaneId(inWindow: 1), 10)
        XCTAssertEqual(s.activePaneId(inWindow: 2), 20)
        // Union across windows, window-then-document order.
        XCTAssertEqual(s.allPaneIds, [10, 11, 12, 20, 21])

        // Rename window 2 → tab title updates.
        s.apply(.windowRenamed(2, "logs"))
        XCTAssertEqual(s.window(id: 2)?.name, "logs")
        XCTAssertEqual(s.window(id: 1)?.name, "", "untouched window keeps its name")

        // Active pane within window 1 moves 10 → 12.
        s.apply(.windowPaneChanged(window: 1, pane: 12))
        XCTAssertEqual(s.activePaneId(inWindow: 1), 12)

        // Close the active window (1) → window 2 survives and becomes active.
        s.apply(.windowClose(1))
        XCTAssertEqual(s.windows.map(\.id), [2])
        XCTAssertEqual(s.activeWindowId, 2, "neighbor reselected after closing active window")
        XCTAssertNil(s.window(id: 1))
        // Window 2's state is intact.
        XCTAssertEqual(s.window(id: 2)?.name, "logs")
        XCTAssertEqual(s.paneIds(inWindow: 2), [20, 21])
        XCTAssertEqual(s.activePaneId(inWindow: 2), 20)
    }

    // MARK: - windowAdd / active selection

    func testFirstWindowAddedBecomesActive() {
        var s = TmuxSession()
        XCTAssertNil(s.activeWindowId)
        XCTAssertTrue(s.apply(.windowAdd(5)))
        XCTAssertEqual(s.activeWindowId, 5)
    }

    func testSubsequentWindowAddDoesNotStealActive() {
        var s = TmuxSession()
        s.apply(.windowAdd(1))
        s.apply(.windowAdd(2))
        s.apply(.windowAdd(3))
        XCTAssertEqual(s.windows.map(\.id), [1, 2, 3])
        XCTAssertEqual(s.activeWindowId, 1, "active stays on the first window")
    }

    func testReAddingExistingWindowIsNoOp() {
        var s = TmuxSession()
        s.apply(.windowAdd(1))
        s.apply(.windowRenamed(1, "named"))
        XCTAssertFalse(s.apply(.windowAdd(1)), "re-add is inert")
        XCTAssertEqual(s.windows.count, 1)
        XCTAssertEqual(s.window(id: 1)?.name, "named", "re-add does not reset state")
    }

    // MARK: - windowClose / neighbor reselection

    func testCloseActiveWindowSelectsLeftNeighbor() {
        var s = TmuxSession()
        s.apply(.windowAdd(1))
        s.apply(.windowAdd(2))
        s.apply(.windowAdd(3))
        s.selectWindow(id: 2)               // active is the middle window
        XCTAssertEqual(s.activeWindowId, 2)

        s.apply(.windowClose(2))            // closing the active middle one
        XCTAssertEqual(s.windows.map(\.id), [1, 3])
        XCTAssertEqual(s.activeWindowId, 1, "reselects the LEFT neighbor")
    }

    func testCloseFirstActiveWindowSelectsNewFirst() {
        var s = TmuxSession()
        s.apply(.windowAdd(1))
        s.apply(.windowAdd(2))
        XCTAssertEqual(s.activeWindowId, 1)

        s.apply(.windowClose(1))           // closing index 0
        XCTAssertEqual(s.windows.map(\.id), [2])
        XCTAssertEqual(s.activeWindowId, 2, "clamps to the new first window")
    }

    func testCloseInactiveWindowKeepsActive() {
        var s = TmuxSession()
        s.apply(.windowAdd(1))
        s.apply(.windowAdd(2))
        s.apply(.windowAdd(3))
        // active is 1; close a non-active window.
        s.apply(.windowClose(3))
        XCTAssertEqual(s.windows.map(\.id), [1, 2])
        XCTAssertEqual(s.activeWindowId, 1, "active is unaffected by closing another window")
    }

    func testCloseLastWindowClearsActive() {
        var s = TmuxSession()
        s.apply(.windowAdd(1))
        s.apply(.windowClose(1))
        XCTAssertTrue(s.windows.isEmpty)
        XCTAssertNil(s.activeWindowId)
    }

    func testCloseUnknownWindowIsNoOp() {
        var s = TmuxSession()
        s.apply(.windowAdd(1))
        XCTAssertFalse(s.apply(.windowClose(99)))
        XCTAssertEqual(s.windows.map(\.id), [1])
        XCTAssertEqual(s.activeWindowId, 1)
    }

    // MARK: - rename

    func testRenameUnknownWindowIsNoOp() {
        var s = TmuxSession()
        XCTAssertFalse(s.apply(.windowRenamed(42, "ghost")))
        XCTAssertTrue(s.windows.isEmpty)
    }

    func testRenameToSameNameIsNoOp() {
        var s = TmuxSession()
        s.apply(.windowAdd(1))
        s.apply(.windowRenamed(1, "shell"))
        XCTAssertFalse(s.apply(.windowRenamed(1, "shell")), "idempotent rename")
    }

    // MARK: - layout-change → PaneNode tree + flatten

    func testLayoutChangeStoresTreeAndFlattensPaneIds() {
        var s = TmuxSession()
        s.apply(.windowAdd(1))
        s.apply(.layoutChange(window: 1, layout: threePane(2, 3, 4)))

        // The stored tree is exactly what TmuxLayoutParser produces.
        let expected = TmuxLayoutParser.parse(threePane(2, 3, 4))
        XCTAssertNotNil(expected)
        XCTAssertEqual(s.window(id: 1)?.layout, expected)

        // The flattened pane-id set matches the layout tree, in order.
        XCTAssertEqual(s.window(id: 1)?.paneIds, [2, 3, 4])
        XCTAssertEqual(s.paneIds(inWindow: 1), [2, 3, 4])
    }

    func testLayoutChangeSeedsActivePaneWhenUnset() {
        var s = TmuxSession()
        s.apply(.windowAdd(1))
        XCTAssertNil(s.activePaneId(inWindow: 1))
        s.apply(.layoutChange(window: 1, layout: hSplit(7, 8)))
        XCTAssertEqual(s.activePaneId(inWindow: 1), 7, "defaults to the first pane")
    }

    func testLayoutChangeKeepsExistingActivePaneIfStillPresent() {
        var s = TmuxSession()
        s.apply(.windowAdd(1))
        s.apply(.layoutChange(window: 1, layout: threePane(10, 11, 12)))
        s.apply(.windowPaneChanged(window: 1, pane: 11))
        XCTAssertEqual(s.activePaneId(inWindow: 1), 11)

        // A re-layout that still contains pane 11 must NOT reset the focus.
        s.apply(.layoutChange(window: 1, layout: hSplit(11, 12)))
        XCTAssertEqual(s.paneIds(inWindow: 1), [11, 12])
        XCTAssertEqual(s.activePaneId(inWindow: 1), 11, "active pane preserved across re-layout")
    }

    func testLayoutChangeReseedsActiveWhenPaneVanishes() {
        var s = TmuxSession()
        s.apply(.windowAdd(1))
        s.apply(.layoutChange(window: 1, layout: threePane(10, 11, 12)))
        s.apply(.windowPaneChanged(window: 1, pane: 12))
        XCTAssertEqual(s.activePaneId(inWindow: 1), 12)

        // Pane 12 was killed → new layout lacks it → reseed to the new first.
        s.apply(.layoutChange(window: 1, layout: hSplit(10, 11)))
        XCTAssertEqual(s.paneIds(inWindow: 1), [10, 11])
        XCTAssertEqual(s.activePaneId(inWindow: 1), 10, "reseeded after active pane vanished")
    }

    func testMalformedLayoutIsIgnored() {
        var s = TmuxSession()
        s.apply(.windowAdd(1))
        s.apply(.layoutChange(window: 1, layout: hSplit(5, 6)))
        let before = s.window(id: 1)?.layout

        XCTAssertFalse(s.apply(.layoutChange(window: 1, layout: "garbage,not,a,layout{")))
        XCTAssertEqual(s.window(id: 1)?.layout, before, "bad layout never corrupts topology")
        XCTAssertEqual(s.paneIds(inWindow: 1), [5, 6])
    }

    func testLayoutChangeForUnknownWindowIsNoOp() {
        var s = TmuxSession()
        XCTAssertFalse(s.apply(.layoutChange(window: 1, layout: singlePane(1))))
        XCTAssertTrue(s.windows.isEmpty)
    }

    // MARK: - window-pane-changed

    func testWindowPaneChangedUpdatesActivePane() {
        var s = TmuxSession()
        s.apply(.windowAdd(1))
        s.apply(.layoutChange(window: 1, layout: threePane(10, 11, 12)))
        XCTAssertTrue(s.apply(.windowPaneChanged(window: 1, pane: 11)))
        XCTAssertEqual(s.activePaneId(inWindow: 1), 11)
    }

    func testWindowPaneChangedSameValueIsNoOp() {
        var s = TmuxSession()
        s.apply(.windowAdd(1))
        s.apply(.layoutChange(window: 1, layout: hSplit(1, 2)))   // active → 1
        XCTAssertFalse(s.apply(.windowPaneChanged(window: 1, pane: 1)))
    }

    func testWindowPaneChangedForUnknownWindowIsNoOp() {
        var s = TmuxSession()
        XCTAssertFalse(s.apply(.windowPaneChanged(window: 9, pane: 3)))
    }

    // MARK: - session-changed

    func testSessionChangedUpdatesIdentity() {
        var s = TmuxSession()
        XCTAssertTrue(s.apply(.sessionChanged(3, "alpha")))
        XCTAssertEqual(s.sessionId, 3)
        XCTAssertEqual(s.sessionName, "alpha")
        XCTAssertTrue(s.apply(.sessionChanged(4, "beta")))
        XCTAssertEqual(s.sessionId, 4)
        XCTAssertEqual(s.sessionName, "beta")
        XCTAssertFalse(s.apply(.sessionChanged(4, "beta")), "idempotent session set")
    }

    // MARK: - inert events never mutate topology

    func testInertEventsDoNotChangeTopology() {
        var s = TmuxSession()
        s.apply(.windowAdd(1))
        s.apply(.layoutChange(window: 1, layout: hSplit(1, 2)))
        let snapshot = s

        let inert: [ControlModeEvent] = [
            .output(paneId: 1, bytes: [0x68, 0x69]),
            .beginReply(cmdNum: 0),
            .replyLine("some output"),
            .endReply(cmdNum: 0),
            .errorReply(cmdNum: 1),
            .clientSessionChanged,
            .sessionsChanged,
            .paneModeChanged(1),
            .exit(reason: "detached"),
            .unknown(name: "subscription-changed", args: ["foo"]),
        ]
        for e in inert {
            XCTAssertFalse(s.apply(e), "\(e) must be inert")
        }
        XCTAssertEqual(s, snapshot, "no inert event changed topology")
    }

    // MARK: - batch apply

    func testBatchApplyReportsAnyChange() {
        var s = TmuxSession()
        let changed = s.apply([
            .sessionChanged(1, "s"),
            .windowAdd(1),
            .layoutChange(window: 1, layout: singlePane(100)),
            .output(paneId: 100, bytes: [0x41]),   // inert
        ])
        XCTAssertTrue(changed)
        XCTAssertEqual(s.windows.map(\.id), [1])
        XCTAssertEqual(s.paneIds(inWindow: 1), [100])
    }

    func testBatchOfOnlyInertEventsReportsNoChange() {
        var s = TmuxSession()
        let changed = s.apply([
            .output(paneId: 1, bytes: [0x41]),
            .sessionsChanged,
        ])
        XCTAssertFalse(changed)
    }

    // MARK: - selectWindow (UI-driven)

    func testSelectWindow() {
        var s = TmuxSession()
        s.apply(.windowAdd(1))
        s.apply(.windowAdd(2))
        XCTAssertTrue(s.selectWindow(id: 2))
        XCTAssertEqual(s.activeWindowId, 2)
        XCTAssertFalse(s.selectWindow(id: 2), "already active")
        XCTAssertFalse(s.selectWindow(id: 99), "unknown window")
        XCTAssertEqual(s.activeWindowId, 2)
    }

    // MARK: - flatten correctness (single-pane and deep trees)

    func testFlattenSinglePane() {
        var s = TmuxSession()
        s.apply(.windowAdd(1))
        s.apply(.layoutChange(window: 1, layout: singlePane(42)))
        XCTAssertEqual(s.paneIds(inWindow: 1), [42])
        XCTAssertEqual(s.activePaneId(inWindow: 1), 42)
    }

    func testPaneIdsForWindowWithoutLayoutIsEmpty() {
        var s = TmuxSession()
        s.apply(.windowAdd(1))
        XCTAssertEqual(s.paneIds(inWindow: 1), [])
        XCTAssertEqual(s.window(id: 1)?.paneIds, [])
    }

    func testPaneIdsForUnknownWindowIsEmpty() {
        let s = TmuxSession()
        XCTAssertEqual(s.paneIds(inWindow: 7), [])
    }
}
