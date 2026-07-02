import XCTest
@testable import ViewerCore

/// A `[text](url)` inside an inline code span is CODE, not a link — it must not be
/// extracted (and must not be flagged as a broken link). Same "code mistaken for
/// structure" class as the outline indented-code fix.
final class LinksCodeSpanTests: XCTestCase {
    func test_linkInsideCodeSpan_notExtracted() {
        let links = MarkdownLinks.extract("Use `[text](missing.md)` for a link, and a [real](ok.md) one.")
        XCTAssertEqual(links.map(\.target), ["ok.md"], "code-span link must be skipped")
    }

    func test_linkWithCodeInLabel_stillExtracted() {
        // The `[` comes before the backtick, so this is a real link whose label has code.
        let links = MarkdownLinks.extract("[`code`](real.md)")
        XCTAssertEqual(links.map(\.target), ["real.md"])
    }

    func test_multiBacktickSpan_skipped() {
        let links = MarkdownLinks.extract("``a `[x](y.md)` b`` then [t](z.md)")
        XCTAssertEqual(links.map(\.target), ["z.md"], "double-backtick span skipped as a unit")
    }

    func test_brokenLinkCheck_ignoresCodeSpan() {
        let broken = MarkdownLinks.brokenLocalLinks(in: "`[x](nope.md)` and [y](gone.md)") { _ in false }
        XCTAssertEqual(broken.map(\.target), ["gone.md"], "only the real link is broken")
    }

    func test_unclosedBacktick_isLiteral_linkAfterStillFound() {
        let links = MarkdownLinks.extract("a ` b [t](u.md)")
        XCTAssertEqual(links.map(\.target), ["u.md"], "lone backtick doesn't swallow the rest")
    }
}
