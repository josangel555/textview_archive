import XCTest
@testable import ViewerCore

/// Coverage for `CommandCategory` — the palette / keybindings section
/// grouping. Two pure surfaces, both untested: the `title` header labels
/// and the custom `Comparable` that orders by **declaration order in
/// `allCases`**, NOT alphabetically. The latter is load-bearing: it fixes
/// the palette's section order, so a refactor that derived `Comparable`
/// from the `String` rawValue (alphabetical) would silently reshuffle
/// every section. These tests pin both.
final class CommandCategoryTests: XCTestCase {

    func test_title_everyCaseHasNonEmptyLabel() {
        for c in CommandCategory.allCases {
            XCTAssertFalse(c.title.isEmpty, "\(c) must have a header label")
        }
    }

    func test_title_nonObviousMappings() {
        // The labels that don't trivially match the rawValue.
        XCTAssertEqual(CommandCategory.lsp.title, "Language")
        XCTAssertEqual(CommandCategory.navigation.title, "Navigation")
        XCTAssertEqual(CommandCategory.find.title, "Find")
        XCTAssertEqual(CommandCategory.file.title, "File")
    }

    func test_comparable_followsDeclarationOrder() {
        XCTAssertTrue(CommandCategory.file < CommandCategory.view)
        XCTAssertTrue(CommandCategory.view < CommandCategory.edit)
        XCTAssertTrue(CommandCategory.git < CommandCategory.find)
        XCTAssertTrue(CommandCategory.find < CommandCategory.window)
        XCTAssertTrue(CommandCategory.window < CommandCategory.debug)
    }

    /// The discriminating cases: pairs where declaration order and
    /// alphabetical order DISAGREE. If `Comparable` were ever rederived
    /// from the rawValue these flip and the test fails.
    func test_comparable_isDeclarationOrder_notAlphabetical() {
        // declaration: file(0) < view(1) < edit(2) → view < edit;
        // alphabetical: "edit" < "view" → would be the opposite.
        XCTAssertTrue(CommandCategory.view < CommandCategory.edit,
                      "must be declaration order (view before edit), not alphabetical")
        // declaration: git(6) < find(8); alphabetical: "find" < "git".
        XCTAssertTrue(CommandCategory.git < CommandCategory.find,
                      "must be declaration order (git before find), not alphabetical")
        // declaration: tabs(4) < sessions(5); alphabetical: "sessions" < "tabs".
        XCTAssertTrue(CommandCategory.tabs < CommandCategory.sessions,
                      "must be declaration order (tabs before sessions), not alphabetical")
    }

    func test_sorted_isStableDeclarationOrder() {
        XCTAssertEqual(CommandCategory.allCases.sorted(), CommandCategory.allCases,
                       "sorting allCases must reproduce declaration order")
        // Shuffled-by-reverse input still sorts back to declaration order.
        XCTAssertEqual(CommandCategory.allCases.reversed().sorted(),
                       CommandCategory.allCases)
    }

    func test_comparable_isIrreflexive() {
        for c in CommandCategory.allCases {
            XCTAssertFalse(c < c, "\(c) must not be < itself")
        }
    }
}
