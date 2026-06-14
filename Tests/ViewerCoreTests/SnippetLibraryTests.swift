import XCTest
@testable import ViewerCore

/// TSK-705 (slice 2) — the built-in snippet set. Pins that the shipped snippets
/// are well-formed (unique ids, parse to non-empty text) so a bad body can't
/// ship a broken menu entry.
final class SnippetLibraryTests: XCTestCase {

    func test_builtIns_nonEmpty_uniqueIds_uniqueNames() {
        let b = SnippetLibrary.builtIns
        XCTAssertFalse(b.isEmpty)
        XCTAssertEqual(Set(b.map(\.id)).count, b.count, "ids are unique")
        XCTAssertEqual(Set(b.map(\.name)).count, b.count, "names are unique (menu labels)")
    }

    func test_builtIns_allParseToNonEmptyText() {
        for s in SnippetLibrary.builtIns {
            XCTAssertFalse(s.parsed.plainText.isEmpty, "\(s.id) must expand to non-empty text")
        }
    }

    func test_markdownLink_expandsAsExpected() {
        let link = SnippetLibrary.builtIns.first { $0.id == "md.link" }!
        XCTAssertEqual(link.parsed.plainText, "[text](https://)")
        XCTAssertEqual(link.parsed.tabStopOrder, [1, 2])
    }

    func test_codeFence_hasFinalStop() {
        let fence = SnippetLibrary.builtIns.first { $0.id == "md.codeFence" }!
        XCTAssertTrue(fence.parsed.tabStopOrder.contains(0), "fence has a final ($0) caret")
        XCTAssertTrue(fence.parsed.plainText.hasPrefix("```swift"))
    }
}
