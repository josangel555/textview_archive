import XCTest
@testable import ViewerCore

/// Coverage for the unified-diff → per-line marks parser used by the
/// source-view gutter (Phase 7 follow-up, task #122). Tests use fixture
/// strings to avoid depending on a live repo.
final class DiffHunkParserTests: XCTestCase {

    func test_empty_diff_yields_no_marks() {
        XCTAssertEqual(DiffHunkParser.parse(""), [:])
    }

    func test_clean_metadata_only_diff_yields_no_marks() {
        // git emits header lines even when the patch body is empty
        // for binary / similarity reports.
        let diff = """
        diff --git a/a.txt b/a.txt
        index abc..def 100644
        Binary files a/a.txt and b/a.txt differ
        """
        XCTAssertEqual(DiffHunkParser.parse(diff), [:])
    }

    func test_hostile_header_clamps_instead_of_trapping() {
        // TSK-576: an Int.min new-side start used to TRAP on `n - 1`
        // (process crash on attacker-controlled diff text). PARITY-LOCKED
        // with the Rust hunk_marks_hostile_header_clamps_not_panics test.
        let diff = "@@ -1 +-9223372036854775808,0 @@\n-gone\n"
        XCTAssertEqual(DiffHunkParser.parse(diff)[1], .deleted)
        let diffMax = "@@ -1 +9223372036854775807,0 @@\n-gone\n"
        let marks = DiffHunkParser.parse(diffMax)
        XCTAssertTrue(marks.keys.allSatisfy { $0 >= 1 && $0 <= 1_000_000_001 })
    }

    func test_top_of_file_deletion_marks_line_one() {
        // TSK-565: "@@ -1,2 +0,0 @@" (delete the first two lines, add nothing)
        // used to put the tick on line 0 — invisible in the 1-based gutter.
        // PARITY-LOCKED with the Rust hunk_marks_top_of_file_deletion test.
        let diff = "@@ -1,2 +0,0 @@\n-a\n-b\n"
        let marks = DiffHunkParser.parse(diff)
        XCTAssertEqual(marks[1], .deleted)
        XCTAssertNil(marks[0])
    }

    func test_pure_addition() {
        let diff = """
        @@ -0,0 +1,3 @@
        +alpha
        +beta
        +gamma
        """
        XCTAssertEqual(DiffHunkParser.parse(diff), [
            1: .added, 2: .added, 3: .added,
        ])
    }

    func test_pure_modification_pairs_remove_and_add() {
        // git represents a single-line change as `-old` then `+new`;
        // the parser collapses to `.modified` on the new-side line.
        let diff = """
        @@ -1,3 +1,3 @@
         alpha
        -beta
        +bravo
         gamma
        """
        let marks = DiffHunkParser.parse(diff)
        XCTAssertEqual(marks[2], .modified)
        XCTAssertNil(marks[1], "unchanged context lines must not be marked")
        XCTAssertNil(marks[3])
    }

    func test_deletion_marks_the_following_line() {
        // After a `-` with no following `+`, the next existing line
        // in the new file gets `.deleted` so the gutter has somewhere
        // to surface the change.
        let diff = """
        @@ -1,3 +1,2 @@
         alpha
        -beta
         gamma
        """
        let marks = DiffHunkParser.parse(diff)
        XCTAssertEqual(marks[2], .deleted)
    }

    func test_addition_at_end_after_context() {
        let diff = """
        @@ -1,2 +1,3 @@
         alpha
         beta
        +gamma
        """
        let marks = DiffHunkParser.parse(diff)
        XCTAssertEqual(marks[3], .added)
        XCTAssertNil(marks[1])
        XCTAssertNil(marks[2])
    }

    func test_multiple_hunks_in_one_diff() {
        let diff = """
        @@ -1,2 +1,2 @@
         a
        -b
        +B
        @@ -10,2 +10,2 @@
         x
        -y
        +Y
        """
        let marks = DiffHunkParser.parse(diff)
        XCTAssertEqual(marks[2], .modified)
        XCTAssertEqual(marks[11], .modified)
    }

    func test_handles_no_newline_at_end_marker() {
        // `\\ No newline at end of file` should be skipped, not
        // misinterpreted as a content line.
        let diff = """
        @@ -1,1 +1,1 @@
        -old
        +new
        \\ No newline at end of file
        """
        let marks = DiffHunkParser.parse(diff)
        XCTAssertEqual(marks[1], .modified)
    }

    func test_malformed_hunk_header_does_not_crash() {
        // Tolerate weird headers — return whatever was parsed before
        // the broken bit.
        let diff = """
        @@ broken header @@
        +line
        """
        _ = DiffHunkParser.parse(diff)  // just shouldn't throw / loop
    }

    func test_handles_consecutive_modifications() {
        // Two adjacent `-`/`+` pairs.
        let diff = """
        @@ -1,3 +1,3 @@
        -one
        +1
        -two
        +2
        -three
        +3
        """
        let marks = DiffHunkParser.parse(diff)
        XCTAssertEqual(marks[1], .modified)
        XCTAssertEqual(marks[2], .modified)
        XCTAssertEqual(marks[3], .modified)
    }
}
