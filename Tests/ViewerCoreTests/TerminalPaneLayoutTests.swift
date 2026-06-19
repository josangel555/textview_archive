import XCTest
@testable import ViewerCore

/// Headless coverage for the terminal pane's persisted layout value type
/// (open/closed + clamped height + UserDefaults round-trip).
final class TerminalPaneLayoutTests: XCTestCase {

    private func freshDefaults() -> UserDefaults {
        let suite = "TerminalPaneLayoutTests.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        return d
    }

    func test_defaults_closed_andDefaultHeight() {
        let l = TerminalPaneLayout()
        XCTAssertFalse(l.isOpen)
        XCTAssertEqual(l.height, TerminalPaneLayout.defaultHeight)
    }

    func test_heightClamp_belowMin_andAboveMax() {
        XCTAssertEqual(TerminalPaneLayout(height: 10).height, TerminalPaneLayout.minHeight)
        XCTAssertEqual(TerminalPaneLayout(height: 99999).height, TerminalPaneLayout.maxHeight)
    }

    func test_heightClamp_nonFinite_fallsBackToDefault() {
        XCTAssertEqual(TerminalPaneLayout.clampHeight(.nan), TerminalPaneLayout.defaultHeight)
        XCTAssertEqual(TerminalPaneLayout.clampHeight(.infinity), TerminalPaneLayout.maxHeight)
    }

    func test_setHeight_clamps() {
        var l = TerminalPaneLayout()
        l.setHeight(300)
        XCTAssertEqual(l.height, 300)
        l.setHeight(5)
        XCTAssertEqual(l.height, TerminalPaneLayout.minHeight)
    }

    func test_persistence_roundTrip() {
        let d = freshDefaults()
        var l = TerminalPaneLayout(isOpen: true, height: 333)
        l.save(to: d)

        let loaded = TerminalPaneLayout.load(from: d)
        XCTAssertTrue(loaded.isOpen)
        XCTAssertEqual(loaded.height, 333)
    }

    func test_tabSet_persistence_roundTrip() {
        // TSK-368: the tab set (names/cwds/active id) survives a save/load.
        let d = freshDefaults()
        var set = TerminalTabSet()
        _ = set.addTab(cwd: URL(fileURLWithPath: "/a/one"))
        let b = set.addTab()
        _ = set.rename(b, to: "build")
        _ = set.select(b)
        var l = TerminalPaneLayout(isOpen: true, tabSet: set)
        l.save(to: d)

        let loaded = TerminalPaneLayout.load(from: d)
        XCTAssertEqual(loaded.tabSet.tabs.map(\.id), set.tabs.map(\.id))
        XCTAssertEqual(loaded.tabSet.activeID, b)
        XCTAssertEqual(loaded.tabSet.tab(b)?.customName, "build")
        XCTAssertEqual(loaded.tabSet.tabs.first?.cwd, URL(fileURLWithPath: "/a/one"))
    }

    func test_load_missingTabSet_isEmpty() {
        // A fresh install (no persisted tab set) loads an empty set; the pane
        // seeds one tab when it opens.
        let d = freshDefaults()
        let loaded = TerminalPaneLayout.load(from: d)
        XCTAssertTrue(loaded.tabSet.isEmpty)
    }

    func test_load_corruptTabSet_degradesToEmpty() {
        let d = freshDefaults()
        d.set(Data("not json".utf8), forKey: TerminalPaneLayout.tabSetKey)
        let loaded = TerminalPaneLayout.load(from: d)
        XCTAssertTrue(loaded.tabSet.isEmpty)
    }

    func test_load_unsetHeight_usesDefault_notZero() {
        let d = freshDefaults()
        // Only the open flag was ever written.
        d.set(true, forKey: TerminalPaneLayout.openKey)
        let loaded = TerminalPaneLayout.load(from: d)
        XCTAssertTrue(loaded.isOpen)
        XCTAssertEqual(loaded.height, TerminalPaneLayout.defaultHeight)
    }

    func test_load_storedZeroHeight_clampsToMin() {
        let d = freshDefaults()
        d.set(true, forKey: TerminalPaneLayout.openKey)
        d.set(Double(0), forKey: TerminalPaneLayout.heightKey)
        let loaded = TerminalPaneLayout.load(from: d)
        XCTAssertEqual(loaded.height, TerminalPaneLayout.minHeight)
    }

    func test_storageKeys_areStable() {
        // Pin the keys — changing them silently drops users' layout.
        XCTAssertEqual(TerminalPaneLayout.openKey, "MarkdownViewer.terminal.isOpen")
        XCTAssertEqual(TerminalPaneLayout.heightKey, "MarkdownViewer.terminal.height")
        XCTAssertEqual(TerminalPaneLayout.tabPositionKey, "MarkdownViewer.terminal.tabPosition")
        XCTAssertEqual(TerminalPaneLayout.paneEdgeKey, "MarkdownViewer.terminal.paneEdge")
        XCTAssertEqual(TerminalPaneLayout.sideWidthKey, "MarkdownViewer.terminal.sideWidth")
    }

    // MARK: - Tab-strip position (TSK-488)

    func test_tabPosition_defaultsToLeft() {
        XCTAssertEqual(TerminalPaneLayout().tabPosition, .left)
        XCTAssertEqual(TerminalPaneLayout.load(from: freshDefaults()).tabPosition, .left)
    }

    func test_tabPosition_roundTrips() {
        let d = freshDefaults()
        var l = TerminalPaneLayout()
        l.tabPosition = .right
        l.save(to: d)
        XCTAssertEqual(TerminalPaneLayout.load(from: d).tabPosition, .right)
    }

    func test_tabPosition_unknownStoredValue_degradesToLeft() {
        let d = freshDefaults()
        d.set("bogus", forKey: TerminalPaneLayout.tabPositionKey)
        XCTAssertEqual(TerminalPaneLayout.load(from: d).tabPosition, .left)
    }

    func test_tabPosition_isVertical() {
        XCTAssertTrue(TerminalTabPosition.left.isVertical)
        XCTAssertTrue(TerminalTabPosition.right.isVertical)
        XCTAssertFalse(TerminalTabPosition.top.isVertical)
    }

    // MARK: - Pane dock edge + side width (TSK-491)

    func test_paneEdge_defaultsToBottom() {
        XCTAssertEqual(TerminalPaneLayout().paneEdge, .bottom)
        XCTAssertEqual(TerminalPaneEdge.default, .bottom)
        XCTAssertEqual(TerminalPaneLayout.load(from: freshDefaults()).paneEdge, .bottom)
    }

    func test_paneEdge_roundTrips() {
        let d = freshDefaults()
        var l = TerminalPaneLayout()
        l.paneEdge = .right
        l.save(to: d)
        XCTAssertEqual(TerminalPaneLayout.load(from: d).paneEdge, .right)
    }

    func test_paneEdge_unknownStoredValue_degradesToBottom() {
        let d = freshDefaults()
        d.set("bogus", forKey: TerminalPaneLayout.paneEdgeKey)
        XCTAssertEqual(TerminalPaneLayout.load(from: d).paneEdge, .bottom)
    }

    func test_paneEdge_isSide() {
        XCTAssertTrue(TerminalPaneEdge.left.isSide)
        XCTAssertTrue(TerminalPaneEdge.right.isSide)
        XCTAssertFalse(TerminalPaneEdge.bottom.isSide)
    }

    func test_sideWidth_defaultAndClamp() {
        XCTAssertEqual(TerminalPaneLayout().sideWidth, TerminalPaneLayout.defaultWidth)
        XCTAssertEqual(TerminalPaneLayout(sideWidth: 10).sideWidth, TerminalPaneLayout.minWidth)
        XCTAssertEqual(TerminalPaneLayout(sideWidth: 99999).sideWidth, TerminalPaneLayout.maxWidth)
        XCTAssertEqual(TerminalPaneLayout.clampWidth(.nan), TerminalPaneLayout.defaultWidth)
    }

    func test_setWidth_clamps() {
        var l = TerminalPaneLayout()
        l.setWidth(420)
        XCTAssertEqual(l.sideWidth, 420)
        l.setWidth(5)
        XCTAssertEqual(l.sideWidth, TerminalPaneLayout.minWidth)
    }

    func test_sideWidth_roundTrips_andUnsetUsesDefault() {
        let d = freshDefaults()
        var l = TerminalPaneLayout()
        l.setWidth(411)
        l.save(to: d)
        XCTAssertEqual(TerminalPaneLayout.load(from: d).sideWidth, 411)
        // Unset → default, not zero.
        XCTAssertEqual(TerminalPaneLayout.load(from: freshDefaults()).sideWidth,
                       TerminalPaneLayout.defaultWidth)
    }
}
