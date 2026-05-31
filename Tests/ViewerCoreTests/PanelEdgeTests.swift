import XCTest
@testable import ViewerCore

/// Pure-logic tests for `PanelEdge` + `PanelEdgeAssignment`.
///
/// Mirrors `SidebarPanelKindTests` — host-runnable (no UI), pins the
/// storage key + the comma-joined wire format, and covers the
/// default-everything-to-`.left` v1 product state.
final class PanelEdgeTests: XCTestCase {

    // MARK: - PanelEdge enum

    func test_default_isLeft() {
        XCTAssertEqual(PanelEdge.default, .left)
    }

    func test_allCases_areLeftRightBottom_noTop() {
        XCTAssertEqual(Set(PanelEdge.allCases), [.left, .right, .bottom])
        // No `.top` — product direction is three rails only.
        XCTAssertNil(PanelEdge(rawValue: "top"))
    }

    // MARK: - Default-all-left (the v1 product state)

    func test_emptyAssignment_everyPanelOnLeft() {
        let a = PanelEdgeAssignment()
        for kind in SidebarPanelKind.allCases {
            XCTAssertEqual(a.edge(kind), .left,
                           "\(kind) should default to .left")
        }
    }

    func test_emptyAssignment_panelsOnLeft_isFullDefaultOrder() {
        let a = PanelEdgeAssignment()
        XCTAssertEqual(a.panels(on: .left), SidebarPanelRegistry.defaultOrder)
        XCTAssertEqual(a.panels(on: .right), [])
        XCTAssertEqual(a.panels(on: .bottom), [])
    }

    // MARK: - set/get edge assignment

    func test_setEdge_assignsAndReads() {
        var a = PanelEdgeAssignment()
        a.setEdge(.git, .right)
        a.setEdge(.bookmarks, .bottom)
        XCTAssertEqual(a.edge(.git), .right)
        XCTAssertEqual(a.edge(.bookmarks), .bottom)
        XCTAssertEqual(a.edge(.files), .left)   // untouched ⇒ default
    }

    func test_setEdge_backToLeft_removesOverride() {
        var a = PanelEdgeAssignment()
        a.setEdge(.git, .right)
        XCTAssertEqual(a.edge(.git), .right)
        a.setEdge(.git, .left)
        XCTAssertEqual(a.edge(.git), .left)
        // .left override must not be stored ⇒ encodes to nothing.
        XCTAssertEqual(a.encoded(), "")
    }

    func test_init_dropsLeftEntries() {
        // Constructing with an explicit `.left` entry must normalize it
        // away — otherwise two equal assignments could differ.
        let a = PanelEdgeAssignment(overrides: [.git: .left, .bookmarks: .right])
        XCTAssertEqual(a, PanelEdgeAssignment(overrides: [.bookmarks: .right]))
        XCTAssertEqual(a.encoded(), "bookmarks:right")
    }

    // MARK: - panels(on:) filtering + order preservation

    func test_panelsOn_filtersAndPreservesOrder() {
        var a = PanelEdgeAssignment()
        // Move .files (first in defaultOrder) and .lspProblems (8th) to
        // .right — the returned list must keep defaultOrder sequencing.
        a.setEdge(.files, .right)
        a.setEdge(.lspProblems, .right)
        XCTAssertEqual(a.panels(on: .right), [.files, .lspProblems])
        // .left now excludes the two moved panels but keeps the rest in
        // order.
        let expectedLeft = SidebarPanelRegistry.defaultOrder.filter {
            $0 != .files && $0 != .lspProblems
        }
        XCTAssertEqual(a.panels(on: .left), expectedLeft)
    }

    func test_panelsOn_customOrder() {
        var a = PanelEdgeAssignment()
        a.setEdge(.git, .right)
        let order: [SidebarPanelKind] = [.git, .files, .bookmarks]
        XCTAssertEqual(a.panels(on: .right, order: order), [.git])
        XCTAssertEqual(a.panels(on: .left, order: order), [.files, .bookmarks])
    }

    // MARK: - encode / decode round-trip

    func test_encoded_isSortedStable() {
        var a = PanelEdgeAssignment()
        a.setEdge(.git, .right)
        a.setEdge(.bookmarks, .bottom)
        // Sorted by "kind:edge" token ⇒ bookmarks before git.
        XCTAssertEqual(a.encoded(), "bookmarks:bottom,git:right")
    }

    func test_roundTrip_throughEncodedString() {
        var a = PanelEdgeAssignment()
        a.setEdge(.git, .right)
        a.setEdge(.lspOutline, .bottom)
        let decoded = PanelEdgeAssignment.decoded(a.encoded())
        XCTAssertEqual(decoded, a)
        XCTAssertEqual(decoded.edge(.git), .right)
        XCTAssertEqual(decoded.edge(.lspOutline), .bottom)
        XCTAssertEqual(decoded.edge(.files), .left)
    }

    func test_decoded_emptyString_isAllLeft() {
        let a = PanelEdgeAssignment.decoded("")
        XCTAssertEqual(a, PanelEdgeAssignment())
        XCTAssertEqual(a.panels(on: .left), SidebarPanelRegistry.defaultOrder)
    }

    // MARK: - unknown-token drop

    func test_decoded_dropsUnknownKind() {
        let a = PanelEdgeAssignment.decoded("git:right,bogusPanel:left,bookmarks:bottom")
        XCTAssertEqual(a.edge(.git), .right)
        XCTAssertEqual(a.edge(.bookmarks), .bottom)
        // The bogus kind contributed nothing.
        XCTAssertEqual(a, PanelEdgeAssignment(overrides: [.git: .right, .bookmarks: .bottom]))
    }

    func test_decoded_dropsUnknownEdge() {
        let a = PanelEdgeAssignment.decoded("git:sideways,bookmarks:right")
        // Unknown edge token ⇒ that panel falls back to default (.left).
        XCTAssertEqual(a.edge(.git), .left)
        XCTAssertEqual(a.edge(.bookmarks), .right)
    }

    func test_decoded_skipsMalformedTokens() {
        let a = PanelEdgeAssignment.decoded("git,bookmarks:right,:bottom,extra:left:weird")
        XCTAssertEqual(a.edge(.bookmarks), .right)
        // `git` (no colon), `:bottom` (no kind), and the triple-part
        // token are all skipped.
        XCTAssertEqual(a, PanelEdgeAssignment(overrides: [.bookmarks: .right]))
    }

    // MARK: - UserDefaults load / save

    func test_savesAndLoadsFromUserDefaults() {
        let suite = "PanelEdgeTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        var a = PanelEdgeAssignment()
        a.setEdge(.claudeTimeline, .bottom)
        a.save(to: defaults)

        let loaded = PanelEdgeAssignment.load(from: defaults)
        XCTAssertEqual(loaded, a)
        XCTAssertEqual(loaded.edge(.claudeTimeline), .bottom)
    }

    func test_loadWithoutKey_isAllLeft() {
        let suite = "PanelEdgeTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let loaded = PanelEdgeAssignment.load(from: defaults)
        XCTAssertEqual(loaded, PanelEdgeAssignment())
        XCTAssertEqual(loaded.panels(on: .left), SidebarPanelRegistry.defaultOrder)
    }

    func test_save_survivesRelaunch() {
        // Same shape as SidebarPanelKindTests.test_persistedHeight_survivesRelaunch:
        // a brand-new defaults handle on the same suite must read back
        // the persisted assignment, not the default.
        let suite = "PanelEdgeRelaunch.\(UUID().uuidString)"
        let writeHandle = UserDefaults(suiteName: suite)!
        defer { writeHandle.removePersistentDomain(forName: suite) }

        var a = PanelEdgeAssignment()
        a.setEdge(.git, .right)
        a.save(to: writeHandle)

        let readHandle = UserDefaults(suiteName: suite)!
        let loaded = PanelEdgeAssignment.load(from: readHandle)
        XCTAssertEqual(loaded.edge(.git), .right)
    }

    // MARK: - storage-key stability (public contract)

    func test_storageKey_isStable() {
        XCTAssertEqual(PanelEdgeAssignment.storageKey,
                       "MarkdownViewer.sidebar.panelEdges")
    }
}
