import XCTest
@testable import ViewerCore

/// Headless coverage for the terminal tool window's pure tab-collection model
/// (TSK-368): open N tabs, close (active-id adjustment when closing the
/// active/last tab), select, cycle, reorder, rename (sanitize), the
/// cwd-derived default title, and the Codable persistence round-trip.
final class TerminalTabSetTests: XCTestCase {

    // MARK: - Add / number

    func test_empty_initial() {
        let s = TerminalTabSet()
        XCTAssertTrue(s.isEmpty)
        XCTAssertEqual(s.count, 0)
        XCTAssertNil(s.activeID)
        XCTAssertNil(s.active)
        XCTAssertNil(s.activeIndex)
    }

    func test_addTab_appendsAndActivates_withMonotonicNumbers() {
        var s = TerminalTabSet()
        let a = s.addTab()
        let b = s.addTab()
        let c = s.addTab()
        XCTAssertEqual(s.count, 3)
        XCTAssertEqual(s.activeID, c)               // newest is active
        XCTAssertEqual(s.tabs.map(\.number), [1, 2, 3])
        XCTAssertEqual(s.tab(a)?.number, 1)
        XCTAssertEqual(s.tab(b)?.number, 2)
    }

    // MARK: - Select

    func test_select_changesActive_andIsNoOpForUnknownOrCurrent() {
        var s = TerminalTabSet()
        let a = s.addTab()
        let b = s.addTab()
        XCTAssertEqual(s.activeID, b)
        XCTAssertTrue(s.select(a))
        XCTAssertEqual(s.activeID, a)
        XCTAssertFalse(s.select(a))                 // already active
        XCTAssertFalse(s.select(UUID()))            // unknown id
        XCTAssertEqual(s.activeID, a)
    }

    // MARK: - Cycle

    func test_cycle_wrapsBothDirections() {
        var s = TerminalTabSet()
        let a = s.addTab(); let b = s.addTab(); let c = s.addTab()
        _ = s.select(a)
        XCTAssertEqual(s.cycle(forward: true), b)
        XCTAssertEqual(s.cycle(forward: true), c)
        XCTAssertEqual(s.cycle(forward: true), a)   // wrap forward
        XCTAssertEqual(s.cycle(forward: false), c)  // wrap backward
    }

    func test_cycle_singleTab_isNoOp() {
        var s = TerminalTabSet()
        let a = s.addTab()
        XCTAssertEqual(s.cycle(forward: true), a)
        XCTAssertEqual(s.activeID, a)
    }

    // MARK: - Close: active-id adjustment

    func test_close_nonActive_leavesActiveUntouched() {
        var s = TerminalTabSet()
        let a = s.addTab(); let b = s.addTab(); _ = s.addTab()
        _ = s.select(b)
        XCTAssertTrue(s.close(a))                   // close a non-active tab
        XCTAssertEqual(s.activeID, b)               // active unchanged
        XCTAssertEqual(s.count, 2)
    }

    func test_close_activeMiddle_selectsRightNeighbor() {
        var s = TerminalTabSet()
        _ = s.addTab(); let b = s.addTab(); let c = s.addTab()
        _ = s.select(b)                             // active is the middle tab
        XCTAssertTrue(s.close(b))
        XCTAssertEqual(s.activeID, c)               // the tab that slid into b's slot
    }

    func test_close_activeLast_selectsNewLast() {
        var s = TerminalTabSet()
        _ = s.addTab(); let b = s.addTab(); let c = s.addTab()
        _ = s.select(c)                             // active is the last tab
        XCTAssertTrue(s.close(c))
        XCTAssertEqual(s.activeID, b)               // falls back to the new last
    }

    func test_close_lastRemaining_clearsActive_andResetsNumbering() {
        var s = TerminalTabSet()
        let a = s.addTab()
        _ = s.addTab()
        XCTAssertTrue(s.close(a))
        // close the remaining one
        XCTAssertTrue(s.close(s.activeID!))
        XCTAssertTrue(s.isEmpty)
        XCTAssertNil(s.activeID)                    // store reads nil → close pane
        // numbering restarts after the pane fully closes
        let fresh = s.addTab()
        XCTAssertEqual(s.tab(fresh)?.number, 1)
    }

    func test_close_unknownID_isNoOp() {
        var s = TerminalTabSet()
        _ = s.addTab()
        XCTAssertFalse(s.close(UUID()))
        XCTAssertEqual(s.count, 1)
    }

    // MARK: - Reorder

    func test_move_reorders_andKeepsActiveTabActive() {
        var s = TerminalTabSet()
        let a = s.addTab(); let b = s.addTab(); let c = s.addTab()
        _ = s.select(a)                             // active is the first tab
        s.move(from: 0, to: 3)                      // a → end
        XCTAssertEqual(s.tabs.map(\.id), [b, c, a])
        XCTAssertEqual(s.activeID, a)               // active follows the tab, not the index
    }

    func test_move_backward() {
        var s = TerminalTabSet()
        let a = s.addTab(); let b = s.addTab(); let c = s.addTab()
        s.move(from: 2, to: 0)                      // c → front
        XCTAssertEqual(s.tabs.map(\.id), [c, a, b])
    }

    func test_move_outOfRange_isNoOp() {
        var s = TerminalTabSet()
        let a = s.addTab(); let b = s.addTab()
        s.move(from: 5, to: 0)
        s.move(from: 0, to: 99)
        XCTAssertEqual(s.tabs.map(\.id), [a, b])
    }

    // MARK: - Rename (sanitize like SessionRename)

    func test_rename_storesTrimmed_andClearsOnBlank() {
        var s = TerminalTabSet()
        let a = s.addTab()
        XCTAssertTrue(s.rename(a, to: "  build  "))
        XCTAssertEqual(s.tab(a)?.customName, "build")
        // a no-op rename to the same value returns false (no republish)
        XCTAssertFalse(s.rename(a, to: "build"))
        // blank clears the custom name
        XCTAssertTrue(s.rename(a, to: "   "))
        XCTAssertNil(s.tab(a)?.customName)
        // blanking an already-default tab is a no-op
        XCTAssertFalse(s.rename(a, to: ""))
    }

    func test_rename_unknownID_isNoOp() {
        var s = TerminalTabSet()
        _ = s.addTab()
        XCTAssertFalse(s.rename(UUID(), to: "x"))
    }

    // MARK: - cwd-derived default title

    func test_title_default_isTerminalN_whenNoCwdOrName() {
        var s = TerminalTabSet()
        let a = s.addTab()
        let tab = s.tab(a)!
        XCTAssertEqual(s.title(for: tab), "Terminal 1")
        XCTAssertEqual(s.label(for: tab), "1")
    }

    func test_title_derivesFromCwdFolder() {
        var s = TerminalTabSet()
        let a = s.addTab(cwd: URL(fileURLWithPath: "/Users/me/projects/mdv"))
        let tab = s.tab(a)!
        XCTAssertEqual(s.title(for: tab), "Terminal 1 — mdv")
        XCTAssertEqual(s.label(for: tab), "mdv")
    }

    func test_customName_winsOverCwd() {
        var s = TerminalTabSet()
        let a = s.addTab(cwd: URL(fileURLWithPath: "/Users/me/projects/mdv"))
        _ = s.rename(a, to: "deploy")
        let tab = s.tab(a)!
        XCTAssertEqual(s.title(for: tab), "deploy")
        XCTAssertEqual(s.label(for: tab), "deploy")
    }

    func test_folderName_rootAndHomeSpecialCases() {
        XCTAssertEqual(TerminalTabTitle.folderName(for: URL(fileURLWithPath: "/")), "/")
        let home = FileManager.default.homeDirectoryForCurrentUser
        XCTAssertEqual(TerminalTabTitle.folderName(for: home), "~")
        XCTAssertNil(TerminalTabTitle.folderName(for: nil))
        // non-file URL → no folder name
        XCTAssertNil(TerminalTabTitle.folderName(for: URL(string: "https://example.com")!))
    }

    func test_setCwd_updatesDerivedTitle() {
        var s = TerminalTabSet()
        let a = s.addTab()
        XCTAssertEqual(s.title(for: s.tab(a)!), "Terminal 1")
        s.setCwd(a, to: URL(fileURLWithPath: "/tmp/work"))
        XCTAssertEqual(s.title(for: s.tab(a)!), "Terminal 1 — work")
    }

    // MARK: - Codable persistence round-trip

    func test_codable_roundTrip_preservesTabsActiveAndNumbering() throws {
        var s = TerminalTabSet()
        _ = s.addTab(cwd: URL(fileURLWithPath: "/a/one"))
        let b = s.addTab(cwd: URL(fileURLWithPath: "/a/two"))
        _ = s.addTab()
        _ = s.rename(b, to: "second")
        _ = s.select(b)

        let data = try JSONEncoder().encode(s)
        let decoded = try JSONDecoder().decode(TerminalTabSet.self, from: data)

        XCTAssertEqual(decoded.tabs.map(\.id), s.tabs.map(\.id))
        XCTAssertEqual(decoded.tabs.map(\.number), [1, 2, 3])
        XCTAssertEqual(decoded.activeID, b)
        XCTAssertEqual(decoded.tab(b)?.customName, "second")
        XCTAssertEqual(decoded.tabs.first?.cwd, URL(fileURLWithPath: "/a/one"))
        // numbering must continue past the restored max, not collide
        var resumed = decoded
        let next = resumed.addTab()
        XCTAssertEqual(resumed.tab(next)?.number, 4)
    }

    func test_init_repairsDanglingActiveID() {
        let live = TerminalTabSet.Tab(number: 1)
        // Construct with an activeID that doesn't reference any tab.
        let s = TerminalTabSet(tabs: [live], activeID: UUID())
        XCTAssertEqual(s.activeID, live.id)         // repaired to the first tab
    }
}
