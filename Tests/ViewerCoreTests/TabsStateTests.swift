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

    func test_move_negativeOrOversizedTo_isNoOp() {
        var s = TabsState(tabs: [makeTab("a"), makeTab("b"), makeTab("c")])
        let before = s
        s.move(from: 0, to: -1)
        XCTAssertEqual(s, before)
        s.move(from: 0, to: 99)
        XCTAssertEqual(s, before)
    }

    func test_move_toEqualsFrom_isStableNoOp() {
        var s = TabsState(tabs: [makeTab("a"), makeTab("b"), makeTab("c")])
        let before = s
        s.move(from: 1, to: 1)
        XCTAssertEqual(s.tabs.map { $0.id }, before.tabs.map { $0.id })
    }

    // T5: round-trip — move a tab somewhere then move it back; original order returns.
    func test_move_isReversible_acrossManyPairs() {
        let names = ["a", "b", "c", "d"]
        for from in 0..<names.count {
            for to in 0...names.count {
                if from == to || to == from + 1 { continue }
                var s = TabsState(tabs: names.map(makeTab))
                let originalIDs = s.tabs.map { $0.id }
                s.move(from: from, to: to)
                // Inverse move: where did the moved tab end up?
                let movedID = originalIDs[from]
                let newPos = s.tabs.firstIndex { $0.id == movedID }!
                // Move it back to its original position.
                let targetTo = from < newPos ? from : from + 1
                s.move(from: newPos, to: targetTo)
                XCTAssertEqual(s.tabs.map { $0.id }, originalIDs,
                               "round-trip failed for from=\(from) to=\(to)")
            }
        }
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

    func test_openOrReveal_lazyExistingTab_adoptsNewViewMode() {
        // Workspace restore scenario: lazy tab carries .source from
        // the previous session. Opening the file (e.g. from sidebar)
        // should adopt the new file's default viewMode rather than
        // keep the stale source mode.
        let lazyTab = Tab(
            url: URL(fileURLWithPath: "/a.md"),
            state: .empty,
            viewMode: .source
        )
        var s = TabsState(tabs: [lazyTab])
        let i = s.openOrReveal(
            url: URL(fileURLWithPath: "/a.md"),
            state: .empty,
            viewMode: .rendered
        )
        XCTAssertEqual(i, 0)
        XCTAssertEqual(s.tabs[0].viewMode, .rendered,
                       "lazy tab should pick up the new computed viewMode")
    }

    func test_openOrReveal_errorTab_preservesViewMode() {
        // Even an existing error-state tab counts as "materialized" —
        // the user has seen the error and may have explicitly switched
        // to source view to inspect the raw bytes. Reopen should keep
        // their pick, not overwrite with the caller's default.
        let failure = DocumentState.LoadFailure(
            url: URL(fileURLWithPath: "/a.md"),
            message: "x"
        )
        let errorTab = Tab(
            url: URL(fileURLWithPath: "/a.md"),
            state: .error(failure),
            viewMode: .source
        )
        var s = TabsState(tabs: [errorTab])
        _ = s.openOrReveal(
            url: URL(fileURLWithPath: "/a.md"),
            state: .error(failure),
            viewMode: .rendered
        )
        XCTAssertEqual(s.tabs[0].viewMode, .source,
                       "error tab is materialized — keep its viewMode")
    }

    func test_openOrReveal_previewTab_preservesViewMode() {
        let url = URL(fileURLWithPath: "/a.png")
        let previewTab = Tab(
            url: url,
            state: .preview(url, .image),
            viewMode: .hex
        )
        var s = TabsState(tabs: [previewTab])
        _ = s.openOrReveal(
            url: url,
            state: .preview(url, .image),
            viewMode: .source
        )
        XCTAssertEqual(s.tabs[0].viewMode, .hex,
                       "preview tab is materialized — keep its viewMode")
    }

    func test_openOrReveal_loadedExistingTab_preservesViewMode() {
        // Already-materialized tab: user may have deliberately
        // switched to .source. Reopening should not overwrite that.
        let loadedTab = Tab(
            url: URL(fileURLWithPath: "/a.md"),
            state: .preview(URL(fileURLWithPath: "/a.md"), .markdown),
            viewMode: .source
        )
        var s = TabsState(tabs: [loadedTab])
        let i = s.openOrReveal(
            url: URL(fileURLWithPath: "/a.md"),
            state: .preview(URL(fileURLWithPath: "/a.md"), .markdown),
            viewMode: .rendered
        )
        XCTAssertEqual(i, 0)
        XCTAssertEqual(s.tabs[0].viewMode, .source,
                       "materialized tab should keep its current viewMode")
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

    // CORR-1: revealing an already-open URL must NOT discard the tab's
    // dirty flag. Dropping it made a tab with unsaved edits look clean,
    // so a later close skipped the save prompt → silent data loss.
    func test_openOrReveal_existingDirtyTab_preservesIsDirty() {
        let url = URL(fileURLWithPath: "/a.md")
        let dirtyTab = Tab(
            url: url,
            state: .preview(url, .markdown),
            viewMode: .source,
            isDirty: true
        )
        var s = TabsState(tabs: [dirtyTab, makeTab("b")])
        s.select(at: 1)
        let i = s.openOrReveal(url: url, state: .preview(url, .markdown), viewMode: .rendered)
        XCTAssertEqual(i, 0)
        XCTAssertTrue(s.tabs[0].isDirty,
                      "revealing a dirty tab must keep isDirty — else close skips the save prompt (CORR-1)")
        // The materialized tab also keeps its chosen viewMode.
        XCTAssertEqual(s.tabs[0].viewMode, .source)
    }

    // CORR-1: a lazy (unmaterialized) dirty tab — unusual but possible
    // if a buffer was hydrated dirty — must likewise keep the flag when
    // revealed/materialized.
    func test_openOrReveal_lazyDirtyTab_preservesIsDirty() {
        let url = URL(fileURLWithPath: "/a.md")
        let lazyDirty = Tab(url: url, state: .empty, viewMode: .source, isDirty: true)
        var s = TabsState(tabs: [lazyDirty])
        let i = s.openOrReveal(url: url, state: .empty, viewMode: .rendered)
        XCTAssertEqual(i, 0)
        XCTAssertTrue(s.tabs[0].isDirty,
                      "lazy dirty tab must keep isDirty across reveal (CORR-1)")
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

    // MARK: closeAll / closeAllToRight (context menu helpers)

    func test_closeAll_exceptIndex_keepsOnlyOne() {
        var s = TabsState(tabs: [makeTab("a"), makeTab("b"), makeTab("c")])
        s.closeAll(except: 1)
        XCTAssertEqual(s.tabs.map { $0.url?.lastPathComponent }, ["b"])
        XCTAssertEqual(s.selectedIndex, 0)
    }

    func test_closeAll_exceptOutOfBounds_isNoOp() {
        var s = TabsState(tabs: [makeTab("a")])
        let before = s
        s.closeAll(except: 5)
        XCTAssertEqual(s, before)
    }

    func test_closeAllToRight_trims() {
        var s = TabsState(tabs: [makeTab("a"), makeTab("b"), makeTab("c"), makeTab("d")])
        s.select(at: 1)
        s.closeAllToRight(of: 1)
        XCTAssertEqual(s.tabs.map { $0.url?.lastPathComponent }, ["a", "b"])
        XCTAssertEqual(s.selectedIndex, 1)
    }

    func test_closeAllToRight_clampsSelection() {
        var s = TabsState(tabs: [makeTab("a"), makeTab("b"), makeTab("c")])
        s.select(at: 2)  // selected = c
        s.closeAllToRight(of: 0)
        XCTAssertEqual(s.tabs.count, 1)
        XCTAssertEqual(s.selectedIndex, 0)
    }

    func test_closeAllToRight_atLastIndex_isNoOp() {
        var s = TabsState(tabs: [makeTab("a"), makeTab("b")])
        let before = s
        s.closeAllToRight(of: 1)
        XCTAssertEqual(s, before)
    }
}
