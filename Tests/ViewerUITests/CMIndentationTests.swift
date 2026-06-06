import XCTest
@testable import ViewerUI

/// Coverage for `CMIndentation` — the editor indentation setting
/// (`tabs(width:)` / `spaces(_:)`). Was untested. The load-bearing logic
/// is `size`, which **clamps to [1, 16]** on both arms so a malformed
/// preference (0, negative, or absurdly large) can never push a degenerate
/// indent width into the CodeMirror bridge. `useTabs` is the case
/// discriminator the bridge reads to pick tab-vs-space indent.
final class CMIndentationTests: XCTestCase {

    // MARK: - useTabs discriminator

    func test_useTabs_reflectsCase() {
        XCTAssertTrue(CMIndentation.tabs(width: 4).useTabs)
        XCTAssertFalse(CMIndentation.spaces(4).useTabs)
    }

    // MARK: - size clamp [1, 16]

    func test_size_inRange_passesThrough() {
        XCTAssertEqual(CMIndentation.tabs(width: 4).size, 4)
        XCTAssertEqual(CMIndentation.spaces(2).size, 2)
        XCTAssertEqual(CMIndentation.spaces(16).size, 16)   // upper boundary
        XCTAssertEqual(CMIndentation.tabs(width: 1).size, 1) // lower boundary
    }

    func test_size_belowOne_clampsToOne() {
        XCTAssertEqual(CMIndentation.spaces(0).size, 1)
        XCTAssertEqual(CMIndentation.tabs(width: 0).size, 1)
        XCTAssertEqual(CMIndentation.spaces(-5).size, 1, "negative width must clamp, not go degenerate")
    }

    func test_size_aboveSixteen_clampsToSixteen() {
        XCTAssertEqual(CMIndentation.spaces(17).size, 16)
        XCTAssertEqual(CMIndentation.tabs(width: 100).size, 16)
        XCTAssertEqual(CMIndentation.spaces(Int.max).size, 16)
    }

    // MARK: - Equatable / Hashable (drives @Published change detection)

    func test_equatable_byCaseAndAssociatedValue() {
        XCTAssertEqual(CMIndentation.spaces(4), .spaces(4))
        XCTAssertNotEqual(CMIndentation.spaces(4), .tabs(width: 4),
                          "same width but different kind must be distinct")
        XCTAssertNotEqual(CMIndentation.spaces(2), .spaces(4))
    }
}
