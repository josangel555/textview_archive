import XCTest
import ViewerCore
@testable import ViewerUI

/// TSK-266 — closing a tab must leave the auto-selected NEIGHBOR in a
/// loading/loaded state, never a dormant `.empty` lazy placeholder.
///
/// `selectTab` runs `materializeIfNeeded` for the incoming tab, but the
/// three close paths (`closeTab`, `closeOtherTabs`, `closeTabsToRight`)
/// historically did not — so when the coordinator's close auto-selected
/// a lazy tab (multi-open / workspace-restore tabs are `.empty` with a
/// url), the content pane sat blank until the user re-clicked the tab.
/// The owner felt this as "closing a tab takes a second".
///
/// Host-safe pure-model tests: `materializeIfNeeded` flips the tab to
/// `.loading` SYNCHRONOUSLY before the detached read, so the assertions
/// don't await the file I/O — "not .empty anymore" is the contract.
@MainActor
final class CloseTabMaterializeTests: XCTestCase {

    private var tmpDir: URL!

    override func setUp() async throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CloseTabMaterialize-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tmpDir)
    }

    private func makeFile(_ name: String) throws -> URL {
        let url = tmpDir.appendingPathComponent(name)
        try "content of \(name)\n".write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func isEmptyState(_ tab: Tab) -> Bool {
        if case .empty = tab.state { return true }
        return false
    }

    /// openMultiple leaves every non-last tab lazy; closing the eager
    /// selected tab auto-selects a lazy neighbor — it must start
    /// materializing as part of the close, not on a later re-click.
    func test_closeTab_materializesLazyNeighbor() throws {
        let a = try makeFile("a.md")
        let b = try makeFile("b.md")
        let model = DocumentModel()
        model.openMultiple([a, b])   // a lazy, b eager + selected

        let lazyIdx = try XCTUnwrap(model.tabs.tabs.firstIndex { $0.url == a })
        XCTAssertTrue(isEmptyState(model.tabs.tabs[lazyIdx]),
                      "precondition: the non-last multi-open tab is a lazy placeholder")
        let selected = try XCTUnwrap(model.tabs.selectedIndex)
        XCTAssertEqual(model.tabs.tabs[selected].url, b)

        model.closeTab(at: selected)

        let survivorIdx = try XCTUnwrap(model.tabs.selectedIndex,
                                        "a neighbor must be selected after close")
        XCTAssertEqual(model.tabs.tabs[survivorIdx].url, a)
        XCTAssertFalse(isEmptyState(model.tabs.tabs[survivorIdx]),
            "the auto-selected lazy neighbor must start materializing on close (TSK-266)")
    }

    /// closeOtherTabs keeping a lazy tab: the kept tab becomes the
    /// selection and must materialize.
    func test_closeOtherTabs_materializesKeptLazyTab() throws {
        let a = try makeFile("a.md")
        let b = try makeFile("b.md")
        let c = try makeFile("c.md")
        let model = DocumentModel()
        model.openMultiple([a, b, c])   // a+b lazy, c eager + selected

        let keepIdx = try XCTUnwrap(model.tabs.tabs.firstIndex { $0.url == a })
        XCTAssertTrue(isEmptyState(model.tabs.tabs[keepIdx]))

        model.closeOtherTabs(keeping: keepIdx)

        XCTAssertEqual(model.tabs.tabs.count, 1)
        XCTAssertFalse(isEmptyState(model.tabs.tabs[0]),
            "the kept lazy tab must start materializing when it becomes the selection")
    }

    /// closeTabsToRight where the selection was among the doomed tabs:
    /// selection falls back to the boundary tab — if lazy, materialize.
    func test_closeTabsToRight_materializesLazyBoundaryTab() throws {
        let a = try makeFile("a.md")
        let b = try makeFile("b.md")
        let c = try makeFile("c.md")
        let model = DocumentModel()
        model.openMultiple([a, b, c])   // a+b lazy, c eager + selected (index 2)

        let boundaryIdx = try XCTUnwrap(model.tabs.tabs.firstIndex { $0.url == a })
        XCTAssertEqual(boundaryIdx, 0)
        XCTAssertTrue(isEmptyState(model.tabs.tabs[boundaryIdx]))

        model.closeTabsToRight(of: boundaryIdx)

        XCTAssertEqual(model.tabs.tabs.count, 1)
        let selected = try XCTUnwrap(model.tabs.selectedIndex)
        XCTAssertFalse(isEmptyState(model.tabs.tabs[selected]),
            "the boundary tab the selection falls back to must materialize")
    }
}
