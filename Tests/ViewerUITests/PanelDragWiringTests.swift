import XCTest
import UniformTypeIdentifiers
import ViewerCore
@testable import ViewerUI

/// TSK-327 — the owner's report "Tool windows and Tool window icons are
/// still not draggable" had THREE roots, each pinned here:
///
///   1. The custom drag UTI (`UTType(exportedAs:)`) was never declared in
///      the app's Info.plist `UTExportedTypeDeclarations` — an undeclared
///      exported UTI is the silently-dead drag (payload writes, no
///      `dropDestination` accepts).
///   2. The only drag SOURCE was the header of an already right/bottom-
///      docked tool window — a panel in its default left-accordion home
///      had no drag handle at all.
///   3. The rail ICONS had no drag source either.
///
/// The drag/drop SESSION itself can't run headlessly (NSItemProvider +
/// WindowServer); the strategy follows the testing mandate: pin the data
/// layer (payload codec), the configuration (Info.plist), the wiring
/// (source audit of the drag-source chokepoints), and the interaction
/// BEHAVIOR (the exact action the drop closure performs, against the real
/// store). Visual drag validation stays in the VM lane.
@MainActor
final class PanelDragWiringTests: HeadlessUITestCase {

    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // ViewerUITests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // repo root

    private func source(_ rel: String) throws -> String {
        try String(contentsOf: Self.repoRoot.appendingPathComponent(rel),
                   encoding: .utf8)
    }

    // MARK: 1. Payload codec (the data layer of every drag)

    func test_panelDragPayload_roundTripsEveryKind_andRejectsGarbage() throws {
        for kind in SidebarPanelKind.allCases {
            XCTAssertEqual(PanelDragPayload(kind).kind, kind,
                           "payload must round-trip \(kind)")
            // Through the Codable layer — what CodableRepresentation
            // actually moves across the drag session.
            let wire = try JSONEncoder().encode(PanelDragPayload(kind))
            let back = try JSONDecoder().decode(PanelDragPayload.self, from: wire)
            XCTAssertEqual(back.kind, kind)
        }
        let garbage = try JSONDecoder().decode(
            PanelDragPayload.self,
            from: Data(#"{"rawKind":"no-such-panel"}"#.utf8))
        XCTAssertNil(garbage.kind,
                     "unknown rawKind must decode to nil, not crash a drop")
    }

    func test_dragUTI_identifierMatchesTheInfoPlistDeclaration() {
        XCTAssertEqual(UTType.mdvPanelDrag.identifier,
                       "com.markdownviewer.panel-drag")
    }

    // MARK: 2. Info.plist declares the exported UTI

    func test_infoPlist_declaresThePanelDragUTI() throws {
        // Parse structurally (a substring check is fooled by e.g. a
        // "...-suffixed" identifier that still CONTAINS the needle).
        let data = try Data(contentsOf:
            Self.repoRoot.appendingPathComponent("scripts/Info.plist"))
        let plist = try XCTUnwrap(
            try PropertyListSerialization.propertyList(from: data, format: nil)
                as? [String: Any])
        let declared = try XCTUnwrap(
            plist["UTExportedTypeDeclarations"] as? [[String: Any]],
            "Info.plist lost UTExportedTypeDeclarations — UTType(exportedAs:) "
            + "types MUST be declared or panel drag/drop dies silently (TSK-327)")
        let identifiers = declared.compactMap { $0["UTTypeIdentifier"] as? String }
        XCTAssertTrue(identifiers.contains(UTType.mdvPanelDrag.identifier),
                      "Info.plist no longer declares \(UTType.mdvPanelDrag.identifier) "
                      + "— the drag payload would write but no drop zone would "
                      + "accept it (TSK-327). Declared: \(identifiers)")
    }

    // MARK: 3. Drag sources exist at all three chokepoints (source audit)

    func test_dragSources_railIcon_sectionHeader_dockedHeader() throws {
        // Rail icons (the owner's "tool window icons").
        let rail = try source("Sources/ViewerUI/ShoulderRailView.swift")
        XCTAssertTrue(rail.contains(".draggable(PanelDragPayload("),
                      "PanelRailButton lost its drag source (TSK-327)")
        // The shared accordion section-header label.
        let header = try source("Sources/ViewerUI/SidebarConstants.swift")
        XCTAssertTrue(header.contains(".draggable(PanelDragPayload("),
                      "SidebarSectionHeaderLabel lost its drag source (TSK-327)")
        // The docked tool-window header (the original UX-E source).
        let docked = try source("Sources/ViewerUI/DockedToolWindow.swift")
        XCTAssertTrue(docked.contains(".draggable(PanelDragPayload("),
                      "DockedToolWindow header lost its drag source (UX-E/#227)")
    }

    func test_everyDockableSectionHeader_passesItsDragKind() throws {
        // Each dockable panel's accordion header must hand its kind to the
        // shared label — a missing dragKind silently reverts that section
        // to "not draggable" (exactly the owner's report).
        let expected: [(file: String, needle: String)] = [
            ("Sources/ViewerUI/BookmarksSection.swift",       "dragKind: .bookmarks"),
            ("Sources/ViewerUI/SearchAnywhereSection.swift",  "dragKind: .searchAnywhere"),
            ("Sources/ViewerUI/ClaudeTimelineSection.swift",  "dragKind: .claudeTimeline"),
            ("Sources/ViewerUI/RecentlyOpenedSection.swift",  "dragKind: .recentlyOpened"),
            ("Sources/ViewerUI/Git/GitPanelSection.swift",    "dragKind: .git"),
            ("Sources/ViewerUI/LSP/LSPOutlineSection.swift",  "dragKind: .lspOutline"),
            ("Sources/ViewerUI/LSP/LSPProblemsPanel.swift",   "dragKind: .lspProblems"),
            ("Sources/ViewerUI/LSP/LSPNavigationPanel.swift", "dragKind: .lspNavigation"),
        ]
        for (file, needle) in expected {
            let text = try source(file)
            XCTAssertTrue(text.contains(needle),
                          "\(file) no longer passes \(needle) — its header "
                          + "is not a drag handle (TSK-327)")
        }
    }

    // MARK: 4. The drop behavior (the exact action the drop closure runs)

    func test_dropAction_payloadKind_drivesStoreMove_toEveryEdge() {
        let suite = "PanelDragWiringTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = PanelLayoutStore(defaults: defaults)

        for edge in PanelEdge.allCases {
            // What PanelDropZone's closure does with a received payload:
            // decode the kind, then `panelLayout.move(kind, to: edge)`.
            let payload = PanelDragPayload(.git)
            guard let kind = payload.kind else {
                return XCTFail("payload must decode")
            }
            store.move(kind, to: edge)
            XCTAssertEqual(store.edge(of: .git), edge,
                           "drop on \(edge) must redock the panel there")
        }
    }
}
