import XCTest
@testable import ViewerCore

/// TSK-672 (blame slice) — `GitClient.parseBlamePorcelain` is the
/// correctness-critical core of git blame: it maps `git blame --line-porcelain`
/// output to per-line authorship. Host-tested against a captured fixture (no
/// real repo). The gutter surfacing that consumes this is a follow-up.
final class GitBlameParseTests: XCTestCase {

    /// Representative `--line-porcelain` output: two final lines from two
    /// commits. Under --line-porcelain the full commit header repeats per line.
    private let fixture = """
    1111111111111111111111111111111111111111 1 1 1
    author Alice Hacker
    author-mail <alice@example.com>
    author-time 1700000000
    author-tz +0000
    committer Alice Hacker
    committer-time 1700000000
    committer-tz +0000
    summary Initial import of the parser
    filename parser.swift
    \tlet x = 1
    2222222222222222222222222222222222222222 5 2 1
    author Bob Coder
    author-mail <bob@example.com>
    author-time 1710000000
    author-tz +0000
    committer Bob Coder
    committer-time 1710000000
    committer-tz +0000
    summary Fix the off-by-one
    filename parser.swift
    \tlet y = 2
    """

    func test_parseBlamePorcelain_perLineAuthorship() {
        let lines = GitClient.parseBlamePorcelain(fixture)
        XCTAssertEqual(lines.count, 2, "one BlameLine per final line")

        XCTAssertEqual(lines[0], GitClient.BlameLine(
            line: 1, sha: "11111111", author: "Alice Hacker",
            timestamp: 1700000000, summary: "Initial import of the parser"))
        XCTAssertEqual(lines[1], GitClient.BlameLine(
            line: 2, sha: "22222222", author: "Bob Coder",
            timestamp: 1710000000, summary: "Fix the off-by-one"))
    }

    func test_parseBlamePorcelain_emptyAndGarbage_areEmptyNotCrash() {
        XCTAssertTrue(GitClient.parseBlamePorcelain("").isEmpty)
        // Header with no terminating content line ⇒ no emitted record (a record
        // is only committed when its \t content line is seen).
        XCTAssertTrue(GitClient.parseBlamePorcelain(
            "3333333333333333333333333333333333333333 1 1 1\nauthor X").isEmpty)
    }
}
