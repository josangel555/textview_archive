import XCTest
import ViewerKit
@testable import ViewerCore

/// Pure model coverage for the ephemeral preview-tab core (TSK-306 /
/// TSK-272 — `docs/PREVIEW_TAB_DESIGN.md`, Phase 1). The sidebar triggers
/// + italic affordance are Phase 2/3 (live); this pins the state machine.
final class TabsStatePreviewTests: XCTestCase {

    private func url(_ name: String) -> URL { URL(fileURLWithPath: "/tmp/\(name)") }

    private func openPreview(_ s: inout TabsState, _ name: String) {
        s.openPreview(url: url(name), state: .empty, viewMode: .rendered)
    }

    func test_openPreview_intoEmpty_createsOneFlaggedSelectedTab() {
        var s = TabsState()
        openPreview(&s, "a.txt")
        XCTAssertEqual(s.tabs.count, 1)
        XCTAssertTrue(s.tabs[0].isPreview)
        XCTAssertEqual(s.selectedIndex, 0)
        XCTAssertEqual(s.previewTabID, s.tabs[0].id)
    }

    func test_openPreview_reusesTheSingleSlot_noTabExplosion() {
        var s = TabsState()
        openPreview(&s, "a.txt")
        let firstID = s.tabs[0].id
        openPreview(&s, "b.txt")
        openPreview(&s, "c.txt")
        XCTAssertEqual(s.tabs.count, 1, "navigating files reuses the one preview slot")
        XCTAssertEqual(s.tabs[0].id, firstID, "same tab id — content replaced in place")
        XCTAssertEqual(s.tabs[0].url, url("c.txt"))
        XCTAssertTrue(s.tabs[0].isPreview)
    }

    func test_openPreview_fileAlreadyOpenPermanently_revealsAndDoesNotPreview() {
        var s = TabsState()
        // A permanent tab for a.txt.
        s.openOrReveal(url: url("a.txt"), state: .empty, viewMode: .rendered)
        XCTAssertFalse(s.tabs[0].isPreview)
        // Previewing the same file must reveal the existing permanent tab,
        // never spawn a preview.
        openPreview(&s, "a.txt")
        XCTAssertEqual(s.tabs.count, 1)
        XCTAssertFalse(s.tabs[0].isPreview)
        XCTAssertNil(s.previewTabID)
    }

    func test_openPreview_reusesBlankSelectedTab() {
        var s = TabsState(tabs: [Tab()]) // one blank tab, selected
        XCTAssertTrue(s.tabs[0].isBlank)
        openPreview(&s, "a.txt")
        XCTAssertEqual(s.tabs.count, 1, "blank tab is reused, not appended-past")
        XCTAssertEqual(s.tabs[0].url, url("a.txt"))
        XCTAssertTrue(s.tabs[0].isPreview)
    }

    func test_promoteTab_clearsPreview() {
        var s = TabsState()
        openPreview(&s, "a.txt")
        let id = s.tabs[0].id
        s.promoteTab(id: id)
        XCTAssertFalse(s.tabs[0].isPreview)
        XCTAssertNil(s.previewTabID)
    }

    func test_promoteTab_unknownOrNonPreview_isNoOp() {
        var s = TabsState()
        s.openOrReveal(url: url("a.txt"), state: .empty, viewMode: .rendered)
        s.promoteTab(id: s.tabs[0].id)        // already permanent
        s.promoteTab(id: UUID())              // unknown
        XCTAssertFalse(s.tabs[0].isPreview)
        XCTAssertEqual(s.tabs.count, 1)
    }

    func test_neverTwoPreviewTabs_afterPromoteThenNewPreview() {
        var s = TabsState()
        openPreview(&s, "a.txt")
        s.promoteTab(id: s.tabs[0].id)        // a.txt is now permanent
        openPreview(&s, "b.txt")              // new preview in a fresh slot
        XCTAssertEqual(s.tabs.count, 2)
        let previews = s.tabs.filter { $0.isPreview }
        XCTAssertEqual(previews.count, 1, "invariant: at most one preview tab")
        XCTAssertEqual(previews.first?.url, url("b.txt"))
    }

    func test_openOrReveal_producesPermanentTab_notPreview() {
        var s = TabsState()
        s.openOrReveal(url: url("a.txt"), state: .empty, viewMode: .rendered)
        XCTAssertFalse(s.tabs[0].isPreview,
            "the eager open path must never flag a tab as preview")
    }
}
