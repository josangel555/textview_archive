import XCTest
@testable import ViewerCore

/// TSK-1427: a rich-paste of a NESTED list must keep the nesting (indented
/// sub-items), not merge the inner item's text into its parent ("aa1").
final class RichTextNestedListPasteTests: XCTestCase {
    func test_nestedList_indentsSubItems_noMerge() {
        let html = "<ul><li>a<ul><li>a1</li></ul></li><li>b</li></ul>"
        let md = RichTextHTMLParser.markdown(fromHTML: html)
        XCTAssertEqual(md, "- a\n  - a1\n- b", "nested item indented, not merged; got [\(md)]")
    }
    func test_twoLevelNesting() {
        let html = "<ul><li>a<ul><li>a1<ul><li>a1x</li></ul></li></ul></li></ul>"
        let md = RichTextHTMLParser.markdown(fromHTML: html)
        XCTAssertEqual(md, "- a\n  - a1\n    - a1x", "got [\(md)]")
    }
    func test_orderedNestedInBullet() {
        let html = "<ul><li>a<ol><li>one</li><li>two</li></ol></li></ul>"
        let md = RichTextHTMLParser.markdown(fromHTML: html)
        XCTAssertEqual(md, "- a\n  1. one\n  2. two", "got [\(md)]")
    }
    func test_flatListStillWorks() {
        let md = RichTextHTMLParser.markdown(fromHTML: "<ul><li>x</li><li>y</li></ul>")
        XCTAssertEqual(md, "- x\n- y")
    }
}
