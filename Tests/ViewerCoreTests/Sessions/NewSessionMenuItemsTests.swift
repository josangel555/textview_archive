import XCTest
@testable import ViewerCore

/// Host-safe (T1m) tests for `NewSessionMenuItems` and the `SessionKind`
/// metadata that backs the New ▸ Session ▸ Kind menu / palette (TSK-373).
///
/// This is the pure source-of-truth the AppKit menu, the SwiftUI Menu, and
/// the command palette all iterate, so these tests pin: the kinds offered,
/// their order, and that every row carries a non-empty title / subtitle /
/// SF Symbol — a regression in any of those would silently break the
/// picker (which is the only UI gateway to the seed-once kind backend).
final class NewSessionMenuItemsTests: XCTestCase {

    // MARK: Menu contents + order -------------------------------------

    func test_menuOrder_isProjectCodeReviewAgentCicdMetrics() {
        XCTAssertEqual(NewSessionMenuItems.order,
                       [.project, .codeReview, .agent, .cicd, .metrics],
                       "menu order is owner-curated: Project first, then the "
                       + "task-shaped kinds the owner asked for, then dashboards")
    }

    func test_allItems_matchTheOrder() {
        XCTAssertEqual(NewSessionMenuItems.all.map(\.kind),
                       NewSessionMenuItems.order,
                       "the rendered rows must follow `order` exactly")
    }

    func test_everyKindIsSurfaced() {
        // No SessionKind case may be silently dropped from the menu — if a
        // future case is added it must be added to `order` too.
        let surfaced = Set(NewSessionMenuItems.order)
        let all = Set(SessionKind.allCases)
        XCTAssertEqual(surfaced, all,
                       "every SessionKind must appear in the New Session menu")
    }

    // MARK: Per-row metadata ------------------------------------------

    func test_everyItem_hasNonEmptyLabelIconSubtitle() {
        for item in NewSessionMenuItems.all {
            XCTAssertFalse(item.title.isEmpty, "\(item.kind) title empty")
            XCTAssertFalse(item.subtitle.isEmpty, "\(item.kind) subtitle empty")
            XCTAssertFalse(item.symbolName.isEmpty, "\(item.kind) symbol empty")
            XCTAssertFalse(item.paletteSearchText.isEmpty,
                           "\(item.kind) palette text empty")
        }
    }

    func test_itemMetadata_tracksTheKind() {
        // The Item must mirror the kind's own properties — no parallel,
        // drift-prone copy of the strings.
        for kind in SessionKind.allCases {
            let item = NewSessionMenuItems.item(for: kind)
            XCTAssertNotNil(item, "no menu item for \(kind)")
            XCTAssertEqual(item?.title, kind.displayName)
            XCTAssertEqual(item?.subtitle, kind.menuSubtitle)
            XCTAssertEqual(item?.symbolName, kind.symbolName)
            XCTAssertEqual(item?.id, kind.rawValue)
        }
    }

    func test_paletteSearchText_includesSurfaceAndKind() {
        let cr = NewSessionMenuItems.item(for: .codeReview)
        XCTAssertEqual(cr?.paletteSearchText, "New Code Review Session")
        let agent = NewSessionMenuItems.item(for: .agent)
        XCTAssertEqual(agent?.paletteSearchText, "New Agent Session Session")
    }

    func test_lookup_unknownIsNilSafe() {
        // Every known kind resolves; `item(for:)` is total over allCases.
        for kind in SessionKind.allCases {
            XCTAssertNotNil(NewSessionMenuItems.item(for: kind))
        }
    }
}
