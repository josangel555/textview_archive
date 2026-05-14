import XCTest
import ViewerKit
@testable import ViewerCore

final class TabsStateTests: XCTestCase {

    private func makeTab(_ name: String) -> Tab {
        Tab(url: URL(fileURLWithPath: "/\(name)"))
    }

    // MARK: Initial state

    func test_emptyState() {
        let s = TabsState()
        XCTAssertTrue(s.isEmpty)
        XCTAssertNil(s.selectedIndex)
        XCTAssertNil(s.selected)
    }

    func test_initWithTabsSelectsFirst() {
        let s = TabsState(tabs: [makeTab("a"), makeTab("b")])
        XCTAssertEqual(s.selectedIndex, 0)
    }

    func test_initWithOutOfBoundsSelectionClamps() {
        let s = TabsState(tabs: [makeTab("a")], selectedIndex: 99)
        XCTAssertEqual(s.selectedIndex, 0)
    }

    // MARK: Append

    func test_append_selectsNewTab() {
        var s = TabsState()
        s.append(makeTab("a"))
        XCTAssertEqual(s.tabs.count, 1)
        XCTAssertEqual(s.selectedIndex, 0)
        XCTAssertEqual(s.selected?.url?.lastPathComponent, "a")
    }

    func test_appendMultipleSelectsLast() {
        var s = TabsState()
        s.append(makeTab("a"))
        s.append(makeTab("b"))
        s.append(makeTab("c"))
        XCTAssertEqual(s.selectedIndex, 2)
        XCTAssertEqual(s.selected?.url?.lastPathComponent, "c")
    }

    // MARK: Close

    func test_close_atSelected_movesToRightNeighbor() {
        var s = TabsState(tabs: [makeTab("a"), makeTab("b"), makeTab("c")])
        s.select(at: 1)  // b
        s.close(at: 1)
        XCTAssertEqual(s.tabs.count, 2)
        XCTAssertEqual(s.selectedIndex, 1)  // /c shifted to index 1
        XCTAssertEqual(s.selected?.url?.lastPathComponent, "c")
    }

    func test_close_lastSelectedTab_movesToNewLast() {
        var s = TabsState(tabs: [makeTab("a"), makeTab("b"), makeTab("c")])
        s.select(at: 2)  // c (last)
        s.close(at: 2)
        XCTAssertEqual(s.selectedIndex, 1)
        XCTAssertEqual(s.selected?.url?.lastPathComponent, "b")
    }

    func test_close_beforeSelected_shiftsIndex() {
        var s = TabsState(tabs: [makeTab("a"), makeTab("b"), makeTab("c")])
        s.select(at: 2)
        s.close(at: 0)
        XCTAssertEqual(s.selectedIndex, 1)
        XCTAssertEqual(s.selected?.url?.lastPathComponent, "c")
    }

    func test_close_afterSelected_keepsIndex() {
        var s = TabsState(tabs: [makeTab("a"), makeTab("b"), makeTab("c")])
        s.select(at: 1)
        s.close(at: 2)
        XCTAssertEqual(s.selectedIndex, 1)
        XCTAssertEqual(s.selected?.url?.lastPathComponent, "b")
    }

    func test_close_onlyTab_clearsSelection() {
        var s = TabsState()
        s.append(Tab())
        s.close(at: 0)
        XCTAssertTrue(s.isEmpty)
        XCTAssertNil(s.selectedIndex)
    }

    func test_close_outOfBounds_isNoOp() {
        var s = TabsState()
        s.append(makeTab("a"))
        s.close(at: 5)
        XCTAssertEqual(s.tabs.count, 1)
    }

    // MARK: Select

    func test_select_outOfBounds_isNoOp() {
        var s = TabsState(tabs: [makeTab("a")])
        s.select(at: 99)
        XCTAssertEqual(s.selectedIndex, 0)
    }

    // MARK: Move

    func test_move_rearrangesTabs() {
        var s = TabsState(tabs: [makeTab("a"), makeTab("b"), makeTab("c")])
        s.move(from: 0, to: 3)  // a → end
        XCTAssertEqual(s.tabs.map { $0.url?.lastPathComponent },
                       ["b", "c", "a"])
    }

    func test_move_carriesSelection() {
        var s = TabsState(tabs: [makeTab("a"), makeTab("b"), makeTab("c")])
        s.select(at: 0)  // a
        s.move(from: 0, to: 3)
        XCTAssertEqual(s.selectedIndex, 2)
        XCTAssertEqual(s.selected?.url?.lastPathComponent, "a")
    }

    func test_move_invalidArgs_isNoOp() {
        var s = TabsState(tabs: [makeTab("a"), makeTab("b")])
        let before = s
        s.move(from: 5, to: 0)
        XCTAssertEqual(s, before)
    }

    // MARK: openOrReveal

    func test_openOrReveal_existingURL_switchesToIt() {
        var s = TabsState(tabs: [makeTab("a"), makeTab("b")])
        s.select(at: 1)
        let i = s.openOrReveal(
            url: URL(fileURLWithPath: "/a"),
            state: .empty,
            viewMode: .rendered
        )
        XCTAssertEqual(i, 0)
        XCTAssertEqual(s.selectedIndex, 0)
        XCTAssertEqual(s.tabs.count, 2, "should not create a new tab")
    }

    func test_openOrReveal_newURL_appendsTab() {
        var s = TabsState(tabs: [makeTab("a")])
        let i = s.openOrReveal(
            url: URL(fileURLWithPath: "/b"),
            state: .empty,
            viewMode: .rendered
        )
        XCTAssertEqual(i, 1)
        XCTAssertEqual(s.tabs.count, 2)
        XCTAssertEqual(s.selectedIndex, 1)
    }

    func test_openOrReveal_reusesBlankTab() {
        var s = TabsState()
        s.append(Tab())  // blank
        let i = s.openOrReveal(
            url: URL(fileURLWithPath: "/a"),
            state: .empty,
            viewMode: .rendered
        )
        XCTAssertEqual(s.tabs.count, 1, "blank tab should be reused, not appended")
        XCTAssertEqual(i, 0)
        XCTAssertEqual(s.tabs[0].url?.lastPathComponent, "a")
    }

    // MARK: Replace

    func test_replace_updatesTabAtIndex() {
        var s = TabsState(tabs: [makeTab("a"), makeTab("b")])
        s.replace(at: 1, with: makeTab("c"))
        XCTAssertEqual(s.tabs[1].url?.lastPathComponent, "c")
    }
}
