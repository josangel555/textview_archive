import XCTest
@testable import ViewerUI

/// TSK-679 / owner-wishlist L861 — the vim mode chip colors NORMAL/INSERT/VISUAL
/// distinctly. This pins the host-testable CLASSIFIER half (raw CM6 mode string →
/// VimModeKind); the chip's on-screen Color is the render tail (review/VM).
final class VimModeKindTests: XCTestCase {

    func test_from_classifiesCoreModes() {
        XCTAssertEqual(VimModeKind.from("NORMAL"), .normal)
        XCTAssertEqual(VimModeKind.from("INSERT"), .insert)
        XCTAssertEqual(VimModeKind.from("VISUAL"), .visual)
        XCTAssertEqual(VimModeKind.from("REPLACE"), .replace)
    }

    func test_from_visualVariants_allMapToVisual() {
        XCTAssertEqual(VimModeKind.from("VISUAL LINE"), .visual)
        XCTAssertEqual(VimModeKind.from("VISUAL BLOCK"), .visual)
    }

    func test_from_isCaseAndWhitespaceInsensitive() {
        XCTAssertEqual(VimModeKind.from("  insert  "), .insert)
        XCTAssertEqual(VimModeKind.from("normal"), .normal)
    }

    func test_from_emptyOrUnknown_isOther() {
        XCTAssertEqual(VimModeKind.from(""), .other)
        XCTAssertEqual(VimModeKind.from("   "), .other)
        XCTAssertEqual(VimModeKind.from("PENDING"), .other)
    }
}
