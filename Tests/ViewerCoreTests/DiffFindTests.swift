import XCTest
@testable import ViewerCore

/// TSK-597 — the find-in-diff engine. The DiffView find bar renders
/// exactly this output (match set, "N of M", wrap-around next/prev),
/// so matching semantics and navigation math are pinned here headless.
final class DiffFindTests: XCTestCase {

    /// Two files, second file has two hunks — enough shape to pin
    /// coordinate ordering across every tree level.
    private var files: [UnifiedDiff.File] {
        DiffParser.parse("""
        diff --git a/alpha.swift b/alpha.swift
        --- a/alpha.swift
        +++ b/alpha.swift
        @@ -1,3 +1,3 @@
         let keep = 1
        -let needle = 2
        +let needle = 3
        @@ -10,2 +10,2 @@
         func other() {}
        -let done = 4
        +let done = 5
        diff --git a/beta.swift b/beta.swift
        --- a/beta.swift
        +++ b/beta.swift
        @@ -1,2 +1,2 @@
         // NEEDLE in a comment
        -let x = 9
        +let x = 10
        """)
    }

    func test_matchesAcrossFilesAndHunks_inDocumentOrder() {
        let m = DiffFind.matches(in: files, query: "needle")
        // alpha hunk 0: removed + added line both contain "needle";
        // beta hunk 0: the context comment (case-insensitive).
        XCTAssertEqual(m, [
            DiffFind.Match(file: 0, hunk: 0, line: 1),
            DiffFind.Match(file: 0, hunk: 0, line: 2),
            DiffFind.Match(file: 1, hunk: 0, line: 0),
        ])
    }

    func test_caseInsensitive_bothDirections() {
        XCTAssertEqual(DiffFind.matches(in: files, query: "NEEDLE").count, 3)
        XCTAssertEqual(DiffFind.matches(in: files, query: "func OTHER").count, 1)
    }

    func test_contextAndRemovedLinesParticipate() {
        // "done" only appears on removed/added lines of alpha's hunk 1.
        let m = DiffFind.matches(in: files, query: "done")
        XCTAssertEqual(m.map(\.hunk), [1, 1])
    }

    func test_emptyAndWhitespaceQuery_matchNothing() {
        XCTAssertTrue(DiffFind.matches(in: files, query: "").isEmpty)
        XCTAssertTrue(DiffFind.matches(in: files, query: "  \n").isEmpty)
    }

    func test_next_wrapsAndSeedsFirst() {
        XCTAssertEqual(DiffFind.next(after: nil, count: 3), 0, "fresh search lands on first")
        XCTAssertEqual(DiffFind.next(after: 0, count: 3), 1)
        XCTAssertEqual(DiffFind.next(after: 2, count: 3), 0, "wraps")
        XCTAssertNil(DiffFind.next(after: nil, count: 0), "no matches, no index")
    }

    func test_previous_wrapsAndSeedsLast() {
        XCTAssertEqual(DiffFind.previous(before: nil, count: 3), 2, "fresh reverse lands on last")
        XCTAssertEqual(DiffFind.previous(before: 2, count: 3), 1)
        XCTAssertEqual(DiffFind.previous(before: 0, count: 3), 2, "wraps")
        XCTAssertNil(DiffFind.previous(before: nil, count: 0))
    }
}
