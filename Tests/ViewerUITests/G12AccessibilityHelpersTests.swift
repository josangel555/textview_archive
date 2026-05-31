import XCTest
import SwiftUI
@testable import ViewerUI

/// Pure-logic, NO-window tests for the host-testable helpers introduced
/// by audit group G12 (accessibility + UI-liveliness). The visual parts
/// of G12 (hover backgrounds, pointing-hand cursor, VoiceOver
/// announcements) can only be verified on the VM / by eyeball; what's
/// captured here is the small amount of branch logic that backs them:
///
///   * `CSVTableView.columnName` / `.cellLabel` — the per-cell VoiceOver
///     label math (A11Y-01).
///   * `MotionGate.animation` — the Reduce-Motion gate (A11Y-06).
///
/// Safe on the host — no NSApp activation, no window. Filter with:
///   `swift test --filter ViewerUITests.G12AccessibilityHelpersTests`
final class G12AccessibilityHelpersTests: XCTestCase {

    // MARK: - A11Y-01: CSV cell/column labels

    func test_columnName_usesHeaderWhenPresent() {
        XCTAssertEqual(CSVTableView.columnName("Email", index: 0), "Email")
        XCTAssertEqual(CSVTableView.columnName("First Name", index: 3), "First Name")
    }

    func test_columnName_fallsBackToPositionalForBlankHeader() {
        // Blank header cells get a 1-based positional name, matching the
        // visible scope-picker label ("Column 1", "Column 2", …).
        XCTAssertEqual(CSVTableView.columnName("", index: 0), "Column 1")
        XCTAssertEqual(CSVTableView.columnName("", index: 7), "Column 8")
    }

    func test_cellLabel_combinesColumnAndValue() {
        let header = ["Name", "Age", "City"]
        XCTAssertEqual(
            CSVTableView.cellLabel(column: 0, header: header, value: "Ada"),
            "Name: Ada")
        XCTAssertEqual(
            CSVTableView.cellLabel(column: 2, header: header, value: "London"),
            "City: London")
    }

    func test_cellLabel_blankHeaderColumnFallsBackToPositional() {
        let header = ["", "Age"]
        XCTAssertEqual(
            CSVTableView.cellLabel(column: 0, header: header, value: "x"),
            "Column 1: x")
    }

    func test_cellLabel_raggedRow_outOfBoundsColumnUsesPositionalName() {
        // A row wider than the header (ragged CSV) must not crash; the
        // extra cell gets a positional "Column N" label.
        let header = ["A", "B"]
        XCTAssertEqual(
            CSVTableView.cellLabel(column: 2, header: header, value: "extra"),
            "Column 3: extra")
        XCTAssertEqual(
            CSVTableView.cellLabel(column: 5, header: header, value: "z"),
            "Column 6: z")
    }

    func test_cellLabel_emptyValue_stillLabelsColumn() {
        // An empty cell should still announce its column so VoiceOver
        // users can tell which column the empty value belongs to.
        XCTAssertEqual(
            CSVTableView.cellLabel(column: 0, header: ["Status"], value: ""),
            "Status: ")
    }

    // MARK: - A11Y-06: Reduce Motion gate

    func test_motionGate_passesAnimationThroughWhenMotionAllowed() {
        // reduceMotion == false → the supplied animation survives.
        XCTAssertNotNil(MotionGate.animation(.linear(duration: 0.05),
                                             reduceMotion: false))
    }

    func test_motionGate_suppressesAnimationWhenReduceMotionSet() {
        // reduceMotion == true → nil, which makes withAnimation(nil)
        // apply the change instantly (no interpolation).
        XCTAssertNil(MotionGate.animation(.linear(duration: 0.05),
                                          reduceMotion: true))
    }
}
