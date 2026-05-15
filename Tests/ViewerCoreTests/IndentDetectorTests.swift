import XCTest
@testable import ViewerCore

final class IndentDetectorTests: XCTestCase {

    func testTabsOnly() {
        let src = "\tfoo\n\tbar\n\tbaz\n"
        XCTAssertEqual(IndentDetector.detect(in: src), "Tabs")
    }

    func testFourSpaceIndent() {
        let src = "def foo():\n    pass\n    return 1\n"
        XCTAssertEqual(IndentDetector.detect(in: src), "Spaces (4)")
    }

    func testTwoSpaceIndent() {
        let src = "function f() {\n  a()\n  b()\n}\n"
        XCTAssertEqual(IndentDetector.detect(in: src), "Spaces (2)")
    }

    func testMixedTabsAndSpaces() {
        let src = "\ttab line\n    space line\n"
        XCTAssertEqual(IndentDetector.detect(in: src), "Mixed")
    }

    func testNoIndent() {
        let src = "line one\nline two\nline three\n"
        XCTAssertEqual(IndentDetector.detect(in: src), "—")
    }

    func testEmptyString() {
        XCTAssertEqual(IndentDetector.detect(in: ""), "—")
    }

    func testSampleWindowCapsScan() {
        // 200 tab-indented lines but we sample only 50 by default;
        // still should report Tabs.
        let src = String(repeating: "\tfoo\n", count: 200)
        XCTAssertEqual(IndentDetector.detect(in: src), "Tabs")
    }

    func testSpaceOnlyLinesIgnored() {
        // Pure-whitespace lines shouldn't count as "indented content".
        let src = "    \n    \nfoo\n"
        XCTAssertEqual(IndentDetector.detect(in: src), "—")
    }
}
