import XCTest
@testable import ViewerCore

/// Teeth for the Markdown linter (docs hygiene). Each rule is a pure consumer of
/// MarkdownLinks / MarkdownOutline.
final class MarkdownLintTests: XCTestCase {

    func test_imageAlt_flagsEmptyAltOnly() {
        let text = """
        ![](no-alt.png)
        ![has alt](ok.png)
        [link not image]()
        """
        let issues = MarkdownLint.lint(text)
        XCTAssertEqual(issues.count, 1)
        XCTAssertEqual(issues.first?.rule, "image-alt")
        XCTAssertEqual(issues.first?.line, 1)
        XCTAssertTrue(issues.first?.message.contains("no-alt.png") == true)
    }

    func test_headingSkip_flagsJumpDeeperByMoreThanOne() {
        let text = """
        # A
        ### C
        ## B
        #### D
        """
        let issues = MarkdownLint.lint(text).filter { $0.rule == "heading-skip" }
        // H1→H3 (skip H2) flagged at line 2; H2→H4 (skip H3) flagged at line 4;
        // H3→H2 (going back) is NOT a skip.
        XCTAssertEqual(issues.map(\.line), [2, 4])
    }

    func test_dupAnchor_flagsSecondOccurrence() {
        let text = """
        # Setup
        # Setup
        # Other
        """
        let issues = MarkdownLint.lint(text).filter { $0.rule == "dup-anchor" }
        XCTAssertEqual(issues.count, 1)
        XCTAssertEqual(issues.first?.line, 2, "the 2nd identical-slug heading is flagged")
    }

    func test_cleanDocument_noIssues() {
        let text = """
        # Title
        ![logo](logo.png)
        ## Section
        ### Sub
        ## Another
        """
        XCTAssertTrue(MarkdownLint.lint(text).isEmpty)
    }

    func test_issuesSortedByLine() {
        let text = """
        # A
        ### skip
        ![](x.png)
        """
        let lines = MarkdownLint.lint(text).map(\.line)
        XCTAssertEqual(lines, lines.sorted())
    }

    func test_extract_capturesLabelText() {
        // The MarkdownLink.text addition (used by the image-alt rule).
        let links = MarkdownLinks.extract("[the label](url) ![the alt](img.png)")
        XCTAssertEqual(links.map(\.text), ["the label", "the alt"])
    }
}
