import XCTest
@testable import ViewerCore

/// Coverage for `TreeSitterEngine.atxHeadingLevel(forLine:in:)` — computes
/// the `#`-count heading level for the heading on a 1-based line (used by
/// markdown folding). Was untested. Pins: levels 1–6, the cap at 6, leading
/// whitespace skip, multi-line addressing, and the default-1 fallbacks
/// (non-heading line, out-of-range line).
final class ATXHeadingLevelTests: XCTestCase {

    private func level(_ line: Int, _ text: String) -> Int {
        TreeSitterEngine.atxHeadingLevel(forLine: line, in: text)
    }

    func test_levelsOneThroughSix() {
        XCTAssertEqual(level(1, "# a"), 1)
        XCTAssertEqual(level(1, "## a"), 2)
        XCTAssertEqual(level(1, "### a"), 3)
        XCTAssertEqual(level(1, "#### a"), 4)
        XCTAssertEqual(level(1, "##### a"), 5)
        XCTAssertEqual(level(1, "###### a"), 6)
    }

    func test_cappedAtSix() {
        XCTAssertEqual(level(1, "####### too deep"), 6)
        XCTAssertEqual(level(1, String(repeating: "#", count: 20) + " x"), 6)
    }

    func test_leadingWhitespaceSkipped() {
        XCTAssertEqual(level(1, "   ### indented"), 3, "up to 3 leading spaces are allowed")
        XCTAssertEqual(level(1, "\t#### tab"), 4)
    }

    func test_multiLineAddressing() {
        let doc = "intro line\n## Section\nbody\n#### Deep\n"
        XCTAssertEqual(level(2, doc), 2)
        XCTAssertEqual(level(4, doc), 4)
    }

    func test_noSpaceAfterHashesStillCounts() {
        // The impl counts '#' runs regardless of a following space.
        XCTAssertEqual(level(1, "##x"), 2)
    }

    func test_nonHeadingLine_defaultsToOne() {
        XCTAssertEqual(level(1, "plain paragraph"), 1)
        XCTAssertEqual(level(1, ""), 1)
    }

    func test_outOfRangeLine_defaultsToOne() {
        XCTAssertEqual(level(99, "# only one line"), 1)
        XCTAssertEqual(level(3, "## a\n### b"), 1, "line beyond EOF → default")
    }
}
