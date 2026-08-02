import XCTest
@testable import ViewerUI

/// I-07 (owner intake 2026-08-01) — pointer-cursor audit, batch 1: every
/// always-visible chrome control that keeps `.buttonStyle(.plain)` (it draws
/// its own visuals) must carry `.pointingCursor()` so the cursor stops lying
/// about clickability. Cursor behavior itself is live-only (NSCursor needs a
/// real window/mouse — VM tier); this pins the WIRING so a refactor can't
/// silently drop the affordance. The hover BUTTON STYLES push the cursor
/// themselves, so styled controls don't appear here.
final class PointerCursorAuditTests: XCTestCase {

    /// file → minimum `.pointingCursor()` occurrences (batch-1 surfaces).
    private static let expectations: [(String, Int)] = [
        ("TabBar.swift", 1),                // the tab item (I-16a)
        ("StatusBar.swift", 1),             // breadcrumb path segments
        ("ContentToolbar.swift", 1),        // view-mode segments
        ("ToastOverlayView.swift", 2),      // toast dismiss + operation cancel
        ("SecretWarningBanner.swift", 1),   // banner dismiss
        ("LSPStatusChipView.swift", 1),     // the LSP chip
    ]

    /// Owner bug report 2026-08-01 ("which pointer renders is very
    /// unpredictable"): the pointing-hand mechanism must be the
    /// system-managed `.pointerStyle(.link)`, NEVER the global NSCursor
    /// push/pop stack — that stack is order-sensitive across adjacent
    /// hovers and is clobbered by NSTextView/WKWebView cursor writes.
    /// Kills the class in the shared styles file; the resize-divider
    /// sites are tracked as Phase 2 (BACKLOG).
    func test_pointingHandMechanism_isPointerStyle_neverTheCursorStack() throws {
        let src = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/ViewerUI/RowHoverButtonStyle.swift"),
            encoding: .utf8)
        XCTAssertGreaterThanOrEqual(
            src.components(separatedBy: ".pointerStyle(.link)").count - 1, 3,
            "all three hover/cursor modifiers ride the system pointer style")
        XCTAssertFalse(src.contains("NSCursor.pointingHand.push"),
            "the global cursor stack must not come back for pointing-hand")
    }

    func test_batchOneChromeSurfaces_carryThePointerAffordance() throws {
        let uiRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // ViewerUITests/
            .deletingLastPathComponent()   // Tests/
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("Sources/ViewerUI")
        for (file, minCount) in Self.expectations {
            let src = try String(
                contentsOf: uiRoot.appendingPathComponent(file), encoding: .utf8)
            let count = src.components(separatedBy: ".pointingCursor()").count - 1
            XCTAssertGreaterThanOrEqual(count, minCount,
                "\(file): expected ≥\(minCount) .pointingCursor() affordances, found \(count)")
        }
    }
}
