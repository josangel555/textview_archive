import XCTest
import ViewerCore

/// TSK-1127 — the zero-server fallback completion ranking. Teeth on the order
/// (frequency → length → alpha), the identifier rules, and the empty/no-match edges.
final class InFileCompletionTests: XCTestCase {
    func test_ranks_frequency_then_length_then_alpha() {
        // foo:2, foobar:1 ; "fab" doesn't share the "fo" prefix
        let text = "foo foobar foo fab"
        XCTAssertEqual(InFileCompletion.completions(in: text, prefix: "fo"), ["foo", "foobar"])
    }

    func test_excludes_the_prefix_itself() {
        let text = "count count counter countdown"
        // prefix "count": "count" itself excluded; counter:1, countdown:1 -> equal freq,
        // equal length(7,9? counter=7 countdown=9) -> shorter first
        XCTAssertEqual(InFileCompletion.completions(in: text, prefix: "count"), ["counter", "countdown"])
    }

    func test_identifiers_not_digit_leading_and_case_sensitive() {
        // "123abc" is digit-leading -> ignored; "Foo" != prefix "fo" (case-sensitive)
        let text = "123abc Foo food"
        XCTAssertEqual(InFileCompletion.completions(in: text, prefix: "fo"), ["food"])
    }

    func test_empty_prefix_and_no_match() {
        XCTAssertEqual(InFileCompletion.completions(in: "alpha beta", prefix: ""), [])
        XCTAssertEqual(InFileCompletion.completions(in: "alpha beta", prefix: "zzz"), [])
    }

    func test_limit_caps_results() {
        let text = "aa1 aa2 aa3 aa4 aa5" // underscores/digits make 5 distinct aaN identifiers
        let result = InFileCompletion.completions(in: text, prefix: "aa", limit: 3)
        XCTAssertEqual(result.count, 3)
    }

    func test_cursor_extracts_prefix_at_position() {
        // line 1 is "pri" (cursor at col 3); print:2, printf:1 from line 0
        let text = "print printf print\npri"
        XCTAssertEqual(InFileCompletion.completions(in: text, line: 1, column: 3), ["print", "printf"])
    }

    func test_cursor_no_prefix_after_nonidentifier_or_out_of_range() {
        let text = "alpha beta\n"
        // column 0 → empty prefix → none
        XCTAssertEqual(InFileCompletion.completions(in: text, line: 0, column: 0), [])
        // column right after a space (col 6, the 'b' not yet typed → prefix empty) → none
        XCTAssertEqual(InFileCompletion.completions(in: text, line: 0, column: 6), [])
        // out-of-range line → none
        XCTAssertEqual(InFileCompletion.completions(in: text, line: 9, column: 0), [])
    }
}
