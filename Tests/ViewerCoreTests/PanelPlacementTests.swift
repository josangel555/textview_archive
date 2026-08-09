import XCTest
@testable import ViewerCore

/// Pure-logic tests for the unified tool-window PLACEMENT engine
/// (TSK-495): `SidebarPanelKind.isDockable`, `PanelPlacement.validate` /
/// `.move`, the GLOBAL default-edge + per-panel override resolution, and
/// that the toggle-button edge resolves from the assignment map.
///
/// Host-runnable (no UI). Together with `PanelEdgeTests` these pin the
/// model side of "assign ANY tool window to ANY shoulder, reject illegal
/// placements, persist, resolve the toggle-button location".
final class PanelPlacementTests: XCTestCase {

    // MARK: - isDockable: the single source of truth

    func test_onlyFiles_isNotDockable() {
        for kind in SidebarPanelKind.allCases {
            if kind == .files {
                XCTAssertFalse(kind.isDockable, "FILES is the accordion flex-fill panel — not dockable")
            } else {
                XCTAssertTrue(kind.isDockable, "\(kind) should be dockable by default")
            }
        }
    }

    // MARK: - validate: legality rules

    func test_validate_leftIsAlwaysLegal_evenForNonDockable() {
        // Every panel can live in the classic accordion — including FILES.
        for kind in SidebarPanelKind.allCases {
            XCTAssertEqual(PanelPlacement.validate(kind, to: .left), .ok,
                           "\(kind) must be allowed on .left (its home)")
        }
    }

    func test_validate_dockablePanel_anyEdgeLegal() {
        for edge in PanelEdge.allCases {
            XCTAssertEqual(PanelPlacement.validate(.git, to: edge), .ok)
            XCTAssertTrue(PanelPlacement.isLegal(.git, to: edge))
        }
    }

    func test_validate_nonDockablePanel_rejectedOnNonLeftEdge() {
        XCTAssertEqual(PanelPlacement.validate(.files, to: .right), .notDockable)
        XCTAssertEqual(PanelPlacement.validate(.files, to: .bottom), .notDockable)
        XCTAssertFalse(PanelPlacement.isLegal(.files, to: .right))
        XCTAssertFalse(PanelPlacement.isLegal(.files, to: .bottom))
        // …but its home edge stays legal.
        XCTAssertEqual(PanelPlacement.validate(.files, to: .left), .ok)
    }

    // MARK: - move: applies a legal move, rejects an illegal one

    func test_move_legal_reassignsPanel() {
        let a = PanelEdgeAssignment()
        let moved = PanelPlacement.move(.git, to: .right, in: a)
        XCTAssertEqual(moved.edge(.git), .right)
        // Original value is untouched (value semantics).
        XCTAssertEqual(a.edge(.git), .left)
    }

    func test_move_illegal_returnsAssignmentUnchanged() {
        let a = PanelEdgeAssignment()
        let moved = PanelPlacement.move(.files, to: .right, in: a)
        // Rejected ⇒ FILES stays on its default left edge, assignment equal.
        XCTAssertEqual(moved, a)
        XCTAssertEqual(moved.edge(.files), .left)
    }

    func test_move_isIdempotent_forSameEdge() {
        var a = PanelEdgeAssignment()
        a.setEdge(.git, .right)
        let moved = PanelPlacement.move(.git, to: .right, in: a)
        XCTAssertEqual(moved, a, "Moving to the edge it already holds is a no-op")
    }

    func test_move_canRedockBetweenEdges() {
        var a = PanelEdgeAssignment()
        a = PanelPlacement.move(.bookmarks, to: .right, in: a)
        a = PanelPlacement.move(.bookmarks, to: .bottom, in: a)
        XCTAssertEqual(a.edge(.bookmarks), .bottom)
        a = PanelPlacement.move(.bookmarks, to: .left, in: a)  // back home
        XCTAssertEqual(a.edge(.bookmarks), .left)
        XCTAssertEqual(a.encoded(), "", "Back to default ⇒ no stored override")
    }

    // MARK: - global default edge: setting + per-panel override resolution

    func test_defaultEdge_shipsAsLeft() {
        XCTAssertEqual(PanelEdgeAssignment().defaultEdge, .left)
    }

    func test_defaultEdge_resolvesAbsentPanels() {
        // With the global default flipped to .right, an untouched panel
        // resolves to .right WITHOUT a per-panel override.
        let a = PanelEdgeAssignment(defaultEdge: .right)
        XCTAssertEqual(a.edge(.git), .right)
        XCTAssertEqual(a.edge(.bookmarks), .right)
        // No override stored — purely the default.
        XCTAssertEqual(a.encoded(), "")
    }

    func test_perPanelOverride_winsOverGlobalDefault() {
        var a = PanelEdgeAssignment(defaultEdge: .right)
        a.setEdge(.git, .bottom)   // explicit override
        XCTAssertEqual(a.edge(.git), .bottom, "Override beats the global default")
        XCTAssertEqual(a.edge(.bookmarks), .right, "Untouched ⇒ the global default")
        // Setting a panel TO the current default removes its override.
        a.setEdge(.git, .right)
        XCTAssertEqual(a.edge(.git), .right)
        XCTAssertEqual(a.encoded(), "", "An entry equal to the default is normalized away")
    }

    func test_setDefaultEdge_renormalizesOverrides() {
        var a = PanelEdgeAssignment()           // default .left
        a.setEdge(.git, .right)                  // explicit override
        a.setEdge(.bookmarks, .right)            // explicit override
        XCTAssertEqual(a.encoded(), "bookmarks:right,git:right")
        // Flip the global default to .right: the two .right overrides are
        // now redundant (they equal the default) and must be dropped.
        a.setDefaultEdge(.right)
        XCTAssertEqual(a.defaultEdge, .right)
        XCTAssertEqual(a.edge(.git), .right)
        XCTAssertEqual(a.edge(.bookmarks), .right)
        XCTAssertEqual(a.encoded(), "", "Overrides equal to the new default are normalized away")
        // A panel that was on .left only by absence now resolves .right.
        XCTAssertEqual(a.edge(.lspOutline), .right)
    }

    func test_setDefaultEdge_leavesDistinctOverridesAlone() {
        var a = PanelEdgeAssignment()
        a.setEdge(.git, .bottom)
        a.setDefaultEdge(.right)
        XCTAssertEqual(a.edge(.git), .bottom, "A distinct override survives a default flip")
        XCTAssertEqual(a.encoded(), "git:bottom")
    }

    func test_panelsOn_withRightDefault_putsUntouchedPanelsRight() {
        let a = PanelEdgeAssignment(defaultEdge: .right)
        // The terminal's PER-PANEL preferred default (.bottom) beats the
        // global default (2026-08-09) — every other untouched panel follows
        // the global .right.
        XCTAssertEqual(a.panels(on: .right),
                       SidebarPanelRegistry.defaultOrder.filter { $0 != .terminal })
        XCTAssertEqual(a.panels(on: .bottom), [.terminal])
        XCTAssertEqual(a.panels(on: .left), [])
    }

    // MARK: - toggle-button location resolves FROM the assignment

    func test_toggleButtonEdge_resolvesFromAssignment() {
        // The rail toggle button "follows the panel": its shoulder is
        // exactly `assignment.edge(kind)`. Pin that resolution here so a
        // model regression fails the host gate even though the on-screen
        // button placement is VM-only.
        var a = PanelEdgeAssignment()
        XCTAssertEqual(a.edge(.git), .left, "Untouched ⇒ button on the left rail")
        a = PanelPlacement.move(.git, to: .bottom, in: a)
        XCTAssertEqual(a.edge(.git), .bottom, "After move ⇒ button on the bottom rail")
        // And the bottom rail's button set now includes git, the left set excludes it.
        XCTAssertTrue(a.panels(on: .bottom).contains(.git))
        XCTAssertFalse(a.panels(on: .left).contains(.git))
    }

    // MARK: - persistence round-trip incl. the global default

    func test_persistence_roundTripsDefaultEdge() {
        let suite = "PanelPlacementTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        var a = PanelEdgeAssignment(defaultEdge: .right)
        a.setEdge(.git, .bottom)
        a.save(to: defaults)

        let loaded = PanelEdgeAssignment.load(from: defaults)
        XCTAssertEqual(loaded.defaultEdge, .right, "Global default must persist")
        XCTAssertEqual(loaded.edge(.git), .bottom)
        XCTAssertEqual(loaded.edge(.bookmarks), .right, "Untouched ⇒ persisted global default")
        XCTAssertEqual(loaded, a)
    }

    func test_load_withoutDefaultEdgeKey_fallsBackToLeft() {
        // An older settings blob with no default-edge key must read as the
        // shipping .left default — never crash, never resolve to garbage.
        let suite = "PanelPlacementTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        // Only the legacy override-map key is present.
        defaults.set("git:right", forKey: PanelEdgeAssignment.storageKey)

        let loaded = PanelEdgeAssignment.load(from: defaults)
        XCTAssertEqual(loaded.defaultEdge, .left)
        XCTAssertEqual(loaded.edge(.git), .right)
        XCTAssertEqual(loaded.edge(.bookmarks), .left)
    }

    func test_load_unknownDefaultEdgeToken_fallsBackToLeft() {
        let suite = "PanelPlacementTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("sideways", forKey: PanelEdgeAssignment.defaultEdgeStorageKey)

        let loaded = PanelEdgeAssignment.load(from: defaults)
        XCTAssertEqual(loaded.defaultEdge, .left, "Unknown default token ⇒ .left fallback")
    }

    func test_defaultEdgeStorageKey_isStable() {
        XCTAssertEqual(PanelEdgeAssignment.defaultEdgeStorageKey,
                       "MarkdownViewer.sidebar.panelDefaultEdge")
    }

    // MARK: - decoded(_:defaultEdge:) re-anchors

    func test_decoded_withDefaultEdge_reAnchors() {
        // Decode an override-map string under a .right default: a token
        // equal to .right is normalized away; the rest survive.
        let a = PanelEdgeAssignment.decoded("git:right,bookmarks:bottom", defaultEdge: .right)
        XCTAssertEqual(a.defaultEdge, .right)
        XCTAssertEqual(a.edge(.git), .right, "git == default ⇒ resolves to default")
        XCTAssertEqual(a.edge(.bookmarks), .bottom)
        XCTAssertEqual(a.encoded(), "bookmarks:bottom", "git override dropped (== default)")
    }
}
