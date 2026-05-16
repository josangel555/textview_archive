import XCTest
@testable import ViewerCore

final class DiffHighlighterTests: XCTestCase {

    private func kinds(_ text: String) -> [(NSRange, TokenKind)] {
        DiffHighlighter.highlight(text).map { ($0.range, $0.kind) }
    }

    func test_empty_input_yields_no_runs() {
        XCTAssertTrue(DiffHighlighter.highlight("").isEmpty)
    }

    func test_added_line_gets_string_kind() {
        let runs = DiffHighlighter.highlight("+hello\n")
        XCTAssertEqual(runs.count, 1)
        XCTAssertEqual(runs[0].kind, .string)
    }

    func test_removed_line_gets_number_kind() {
        let runs = DiffHighlighter.highlight("-goodbye\n")
        XCTAssertEqual(runs.count, 1)
        XCTAssertEqual(runs[0].kind, .number)
    }

    func test_context_line_has_no_run() {
        let runs = DiffHighlighter.highlight(" context line\n")
        XCTAssertTrue(runs.isEmpty)
    }

    func test_hunk_header_gets_comment_kind() {
        let runs = DiffHighlighter.highlight("@@ -1,3 +1,3 @@\n")
        XCTAssertEqual(runs.count, 1)
        XCTAssertEqual(runs[0].kind, .comment)
    }

    func test_triple_dash_is_heading_not_removed() {
        let runs = DiffHighlighter.highlight("--- a/foo.txt\n")
        XCTAssertEqual(runs.first?.kind, .heading)
    }

    func test_triple_plus_is_heading_not_added() {
        let runs = DiffHighlighter.highlight("+++ b/foo.txt\n")
        XCTAssertEqual(runs.first?.kind, .heading)
    }

    func test_diff_git_header_is_heading() {
        let runs = DiffHighlighter.highlight("diff --git a/foo b/foo\n")
        XCTAssertEqual(runs.first?.kind, .heading)
    }

    func test_index_header_is_heading() {
        let runs = DiffHighlighter.highlight("index abc..def 100644\n")
        XCTAssertEqual(runs.first?.kind, .heading)
    }

    func test_full_diff_classifies_each_line() {
        let diff = """
        diff --git a/foo b/foo
        --- a/foo
        +++ b/foo
        @@ -1,2 +1,2 @@
         context
        -old
        +new
        """
        let runs = DiffHighlighter.highlight(diff)
        // 3 headers (`diff`, `---`, `+++`) + 1 hunk + 1 removed
        // + 1 added = 6 runs; context line is intentionally
        // skipped (no kind).
        XCTAssertEqual(runs.count, 6)
        XCTAssertEqual(runs.filter { $0.kind == .heading }.count, 3)
        XCTAssertEqual(runs.filter { $0.kind == .comment }.count, 1)
        XCTAssertEqual(runs.filter { $0.kind == .number }.count, 1)
        XCTAssertEqual(runs.filter { $0.kind == .string }.count, 1)
    }

    func test_crlf_endings_classified_correctly() {
        let runs = DiffHighlighter.highlight("+added\r\n-removed\r\n")
        XCTAssertEqual(runs.count, 2)
        XCTAssertEqual(runs[0].kind, .string)
        XCTAssertEqual(runs[1].kind, .number)
    }
}
