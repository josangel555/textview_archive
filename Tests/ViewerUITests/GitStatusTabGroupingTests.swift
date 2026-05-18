import XCTest
@testable import ViewerUI
@testable import ViewerCore

/// Pure unit tests for `GitStatusTab.group(_:)` — the staged / unstaged /
/// untracked bucketing rules. Doesn't render any view.
@MainActor
final class GitStatusTabGroupingTests: XCTestCase {

    private func entry(_ x: Character, _ y: Character, _ path: String) -> GitClient.StatusEntry {
        GitClient.StatusEntry(path: path, indexStatus: x, workingStatus: y)
    }

    func test_untracked_lands_in_untracked() {
        let g = GitStatusTab.group([entry("?", "?", "new.txt")])
        XCTAssertEqual(g.untracked.count, 1)
        XCTAssertTrue(g.staged.isEmpty)
        XCTAssertTrue(g.unstaged.isEmpty)
    }

    func test_index_modified_only_lands_in_staged() {
        let g = GitStatusTab.group([entry("M", " ", "a.txt")])
        XCTAssertEqual(g.staged.count, 1)
        XCTAssertTrue(g.unstaged.isEmpty)
    }

    func test_worktree_modified_only_lands_in_unstaged() {
        let g = GitStatusTab.group([entry(" ", "M", "a.txt")])
        XCTAssertEqual(g.unstaged.count, 1)
        XCTAssertTrue(g.staged.isEmpty)
    }

    func test_both_modified_lands_in_both_sections() {
        let g = GitStatusTab.group([entry("M", "M", "a.txt")])
        XCTAssertEqual(g.staged.count, 1)
        XCTAssertEqual(g.unstaged.count, 1)
    }

    func test_added_in_index_unmodified_in_worktree() {
        let g = GitStatusTab.group([entry("A", " ", "new.txt")])
        XCTAssertEqual(g.staged.count, 1)
        XCTAssertTrue(g.unstaged.isEmpty)
    }

    func test_mixed_bucket() {
        let entries = [
            entry("M", " ", "staged.txt"),
            entry(" ", "M", "unstaged.txt"),
            entry("?", "?", "new.txt"),
            entry("A", " ", "added.txt"),
        ]
        let g = GitStatusTab.group(entries)
        XCTAssertEqual(g.staged.count, 2)
        XCTAssertEqual(g.unstaged.count, 1)
        XCTAssertEqual(g.untracked.count, 1)
    }
}

/// Coverage for the ssh → https URL transformation used by Remotes tab.
@MainActor
final class GitRemotesURLTests: XCTestCase {

    func test_https_passthrough() {
        XCTAssertEqual(
            GitRemotesTab.webURL(from: "https://github.com/foo/bar.git")?.absoluteString,
            "https://github.com/foo/bar"
        )
    }

    func test_https_without_dot_git() {
        XCTAssertEqual(
            GitRemotesTab.webURL(from: "https://github.com/foo/bar")?.absoluteString,
            "https://github.com/foo/bar"
        )
    }

    func test_ssh_at_format() {
        XCTAssertEqual(
            GitRemotesTab.webURL(from: "git@github.com:foo/bar.git")?.absoluteString,
            "https://github.com/foo/bar"
        )
    }

    func test_ssh_at_format_no_dot_git() {
        XCTAssertEqual(
            GitRemotesTab.webURL(from: "git@git.example-forge.com:textview/staging")?.absoluteString,
            "https://git.example-forge.com/textview/staging"
        )
    }

    func test_ssh_url_scheme() {
        XCTAssertEqual(
            GitRemotesTab.webURL(from: "ssh://git@gitlab.com/foo/bar.git")?.absoluteString,
            "https://gitlab.com/foo/bar"
        )
    }

    func test_unsupported_scheme_returns_nil() {
        XCTAssertNil(GitRemotesTab.webURL(from: "file:///local/repo"))
    }
}
