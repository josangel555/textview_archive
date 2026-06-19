import XCTest
@testable import ViewerUI
import ViewerCore

/// Host tests for the History list's pure per-row presentation model
/// (TSK-703). The view itself (SwiftUI rendering) is VM-validated; this pins
/// the model layer: label passthrough, category→glyph mapping, coalesced
/// badge, and timestamp formatting — so a logic regression fails the host gate.
final class ActionHistoryRowModelTests: XCTestCase {

    private func entry(
        label: String = "Edit cell B3",
        category: ActionCategory = .cell,
        timestamp: Date = Date(timeIntervalSince1970: 0),
        coalescedCount: Int = 1
    ) -> ActionHistoryLogEntry {
        ActionHistoryLogEntry(
            id: 0, label: label, category: category,
            timestamp: timestamp, coalescedCount: coalescedCount
        )
    }

    func testLabelPassesThrough() {
        let model = ActionHistoryRowModel(entry: entry(label: "Close tab README.md"))
        XCTAssertEqual(model.label, "Close tab README.md")
    }

    func testCategoryGlyphMapping() {
        let pairs: [(ActionCategory, String)] = [
            (.edit, "pencil"),
            (.cell, "tablecells"),
            (.tab, "rectangle.stack"),
            (.file, "doc"),
            (.marker, "bookmark"),
            (.other, "circle"),
        ]
        for (cat, expected) in pairs {
            XCTAssertEqual(ActionHistoryRowModel.systemImage(for: cat), expected,
                           "glyph for \(cat)")
            XCTAssertEqual(ActionHistoryRowModel(entry: entry(category: cat)).systemImage, expected)
        }
        // Every category must map (no missing case).
        for cat in ActionCategory.allCases {
            XCTAssertFalse(ActionHistoryRowModel.systemImage(for: cat).isEmpty)
        }
    }

    func testCoalescedBadgeOnlyWhenMerged() {
        XCTAssertNil(ActionHistoryRowModel(entry: entry(coalescedCount: 1)).coalescedBadge)
        XCTAssertEqual(ActionHistoryRowModel(entry: entry(coalescedCount: 4)).coalescedBadge, "×4")
    }

    func testTimeStringFormat() {
        // 1970-01-01 00:00:00 UTC. Pin a UTC calendar so the assertion is
        // host-timezone-independent.
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let model = ActionHistoryRowModel(
            entry: entry(timestamp: Date(timeIntervalSince1970: 3661)), // 01:01:01
            calendar: cal
        )
        XCTAssertEqual(model.timeString, "01:01:01")
    }
}
