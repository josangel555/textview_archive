import XCTest
@testable import ViewerCore

/// TSK-911 — extract the commit-header preamble from `git show` output for the
/// diff-view summary banner. (The totals line reuses host-tested DiffStat.)
final class CommitDiffSummaryTests: XCTestCase {

    func test_extractsPreamble_beforeFirstDiffGit() {
        let text = """
        abc123
        Jos <jos@example.com>
        Mon Jun 14

        Fix the thing

        A longer body line.
        diff --git a/f.txt b/f.txt
        index e69de29..0cfbf08 100644
        --- a/f.txt
        +++ b/f.txt
        @@ -0,0 +1 @@
        +hi
        """
        let p = CommitDiffSummary.preamble(text)
        XCTAssertNotNil(p)
        XCTAssertTrue(p!.contains("Fix the thing"))
        XCTAssertTrue(p!.contains("Jos <jos@example.com>"))
        XCTAssertFalse(p!.contains("diff --git"), "preamble stops before the patch")
        XCTAssertFalse(p!.contains("@@"), "no hunk content in the preamble")
    }

    func test_plainPatch_startingAtDiffGit_hasNoPreamble() {
        let text = """
        diff --git a/f.txt b/f.txt
        --- a/f.txt
        +++ b/f.txt
        @@ -0,0 +1 @@
        +hi
        """
        XCTAssertNil(CommitDiffSummary.preamble(text))
    }

    func test_multiFile_preambleIsNotTheFirstFile() {
        // Bug guard: with no preamble, the FIRST file's diff must not be mistaken
        // for the header just because a later "\ndiff --git" exists.
        let text = """
        diff --git a/a.txt b/a.txt
        @@ -1 +1 @@
        -a
        +A
        diff --git a/b.txt b/b.txt
        @@ -1 +1 @@
        -b
        +B
        """
        XCTAssertNil(CommitDiffSummary.preamble(text))
    }

    func test_noDiffGit_returnsNil() {
        XCTAssertNil(CommitDiffSummary.preamble("just some text, not a diff"))
    }

    func test_empty_returnsNil() {
        XCTAssertNil(CommitDiffSummary.preamble(""))
    }
}
