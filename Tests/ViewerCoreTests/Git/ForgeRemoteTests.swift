import XCTest
@testable import ViewerCore

/// Host tests for the `ForgeRemote` parser + web-URL derivation — the
/// foundation slice of the GitHub integration (TSK-346). Pure logic, no
/// AppKit/SwiftUI, runs on the headless host gate.
final class ForgeRemoteTests: XCTestCase {

    // MARK: - Parsing the three remote shapes

    func test_parse_https() {
        let r = ForgeRemote.parse("https://github.com/foo/bar.git")
        XCTAssertEqual(r?.host, "github.com")
        XCTAssertEqual(r?.owner, "foo")
        XCTAssertEqual(r?.repo, "bar")
        XCTAssertEqual(r?.provider, .gitHub)
    }

    func test_parse_https_without_dot_git() {
        let r = ForgeRemote.parse("https://github.com/foo/bar")
        XCTAssertEqual(r?.repo, "bar")
        XCTAssertEqual(r?.fullName, "foo/bar")
    }

    func test_parse_scp_style_git_at() {
        let r = ForgeRemote.parse("git@github.com:foo/bar.git")
        XCTAssertEqual(r?.host, "github.com")
        XCTAssertEqual(r?.owner, "foo")
        XCTAssertEqual(r?.repo, "bar")
        XCTAssertEqual(r?.provider, .gitHub)
    }

    func test_parse_scp_style_no_dot_git_enterprise_host() {
        let r = ForgeRemote.parse("git@git.example-forge.com:textview/staging")
        XCTAssertEqual(r?.host, "git.example-forge.com")
        XCTAssertEqual(r?.owner, "textview")
        XCTAssertEqual(r?.repo, "staging")
        // unknown host → generic, but still a valid repo identity
        XCTAssertEqual(r?.provider, .generic)
    }

    func test_parse_ssh_scheme() {
        let r = ForgeRemote.parse("ssh://git@gitlab.com/foo/bar.git")
        XCTAssertEqual(r?.host, "gitlab.com")
        XCTAssertEqual(r?.owner, "foo")
        XCTAssertEqual(r?.repo, "bar")
        XCTAssertEqual(r?.provider, .gitLab)
    }

    func test_parse_ssh_scheme_with_port() {
        let r = ForgeRemote.parse("ssh://git@github.com:22/foo/bar.git")
        XCTAssertEqual(r?.host, "github.com", "port must be stripped from host")
        XCTAssertEqual(r?.fullName, "foo/bar")
    }

    func test_parse_https_with_port() {
        let r = ForgeRemote.parse("https://example.com:8443/foo/bar.git")
        XCTAssertEqual(r?.host, "example.com")
        XCTAssertEqual(r?.fullName, "foo/bar")
    }

    func test_parse_nested_namespace_gitlab_subgroup() {
        let r = ForgeRemote.parse("https://gitlab.com/group/sub/repo.git")
        XCTAssertEqual(r?.owner, "group/sub")
        XCTAssertEqual(r?.repo, "repo")
        XCTAssertEqual(r?.fullName, "group/sub/repo")
    }

    func test_parse_trailing_slash_tolerated() {
        let r = ForgeRemote.parse("https://github.com/foo/bar/")
        XCTAssertEqual(r?.fullName, "foo/bar")
    }

    func test_parse_whitespace_trimmed() {
        let r = ForgeRemote.parse("  git@github.com:foo/bar.git\n")
        XCTAssertEqual(r?.fullName, "foo/bar")
    }

    // MARK: - Rejections

    func test_parse_file_scheme_returns_nil() {
        XCTAssertNil(ForgeRemote.parse("file:///local/repo"))
    }

    func test_parse_empty_returns_nil() {
        XCTAssertNil(ForgeRemote.parse(""))
        XCTAssertNil(ForgeRemote.parse("   "))
    }

    func test_parse_no_owner_repo_pair_returns_nil() {
        // single path segment is not a repo identity
        XCTAssertNil(ForgeRemote.parse("https://github.com/onlyone"))
        XCTAssertNil(ForgeRemote.parse("git@github.com:onlyone"))
    }

    // MARK: - Provider classification

    func test_provider_classification() {
        XCTAssertEqual(ForgeRemote.provider(forHost: "github.com"), .gitHub)
        XCTAssertEqual(ForgeRemote.provider(forHost: "GitHub.com"), .gitHub) // case-insensitive
        XCTAssertEqual(ForgeRemote.provider(forHost: "github.mycorp.net"), .gitHub) // github.* enterprise
        XCTAssertEqual(ForgeRemote.provider(forHost: "gitlab.com"), .gitLab)
        XCTAssertEqual(ForgeRemote.provider(forHost: "bitbucket.org"), .bitbucket)
        XCTAssertEqual(ForgeRemote.provider(forHost: "git.example-forge.com"), .generic)
    }

    // MARK: - Derived web URLs (GitHub shapes)

    func test_repo_web_url() {
        let r = ForgeRemote.parse("git@github.com:foo/bar.git")
        XCTAssertEqual(r?.webURL?.absoluteString, "https://github.com/foo/bar")
    }

    func test_commit_url_github() {
        let r = ForgeRemote.parse("https://github.com/foo/bar")
        XCTAssertEqual(
            r?.commitURL("abc123")?.absoluteString,
            "https://github.com/foo/bar/commit/abc123"
        )
    }

    func test_pull_request_url_github() {
        let r = ForgeRemote.parse("https://github.com/foo/bar")
        XCTAssertEqual(
            r?.pullRequestURL(42)?.absoluteString,
            "https://github.com/foo/bar/pull/42"
        )
    }

    func test_issue_url_github() {
        let r = ForgeRemote.parse("https://github.com/foo/bar")
        XCTAssertEqual(
            r?.issueURL(7)?.absoluteString,
            "https://github.com/foo/bar/issues/7"
        )
    }

    func test_branch_url_github() {
        let r = ForgeRemote.parse("https://github.com/foo/bar")
        XCTAssertEqual(
            r?.branchURL("main")?.absoluteString,
            "https://github.com/foo/bar/tree/main"
        )
    }

    func test_file_url_github_with_line() {
        let r = ForgeRemote.parse("https://github.com/foo/bar")
        XCTAssertEqual(
            r?.fileURL(ref: "main", path: "Sources/App.swift", line: 12)?.absoluteString,
            "https://github.com/foo/bar/blob/main/Sources/App.swift#L12"
        )
    }

    func test_file_url_github_without_line() {
        let r = ForgeRemote.parse("https://github.com/foo/bar")
        XCTAssertEqual(
            r?.fileURL(ref: "main", path: "README.md")?.absoluteString,
            "https://github.com/foo/bar/blob/main/README.md"
        )
    }

    // MARK: - Provider-specific URL schemes

    func test_gitlab_url_schemes() {
        let r = ForgeRemote.parse("https://gitlab.com/group/repo")
        XCTAssertEqual(r?.commitURL("abc")?.absoluteString,
                       "https://gitlab.com/group/repo/-/commit/abc")
        XCTAssertEqual(r?.pullRequestURL(5)?.absoluteString,
                       "https://gitlab.com/group/repo/-/merge_requests/5")
        XCTAssertEqual(r?.issueURL(9)?.absoluteString,
                       "https://gitlab.com/group/repo/-/issues/9")
        XCTAssertEqual(r?.fileURL(ref: "main", path: "a.txt", line: 3)?.absoluteString,
                       "https://gitlab.com/group/repo/-/blob/main/a.txt#L3")
    }

    func test_bitbucket_url_schemes() {
        let r = ForgeRemote.parse("https://bitbucket.org/team/repo")
        XCTAssertEqual(r?.commitURL("abc")?.absoluteString,
                       "https://bitbucket.org/team/repo/commits/abc")
        XCTAssertEqual(r?.pullRequestURL(5)?.absoluteString,
                       "https://bitbucket.org/team/repo/pull-requests/5")
        XCTAssertEqual(r?.fileURL(ref: "main", path: "a.txt", line: 3)?.absoluteString,
                       "https://bitbucket.org/team/repo/src/main/a.txt#lines-3")
    }

    func test_generic_host_falls_back_to_github_shape() {
        let r = ForgeRemote.parse("git@git.example-forge.com:textview/staging")
        XCTAssertEqual(r?.pullRequestURL(1)?.absoluteString,
                       "https://git.example-forge.com/textview/staging/pull/1")
    }

    // MARK: - URL encoding of refs/paths

    func test_file_url_encodes_spaces_in_path() {
        let r = ForgeRemote.parse("https://github.com/foo/bar")
        let url = r?.fileURL(ref: "main", path: "My Folder/file.swift", line: 1)
        XCTAssertEqual(
            url?.absoluteString,
            "https://github.com/foo/bar/blob/main/My%20Folder/file.swift#L1"
        )
    }

    func test_branch_url_keeps_slash_in_feature_ref() {
        let r = ForgeRemote.parse("https://github.com/foo/bar")
        XCTAssertEqual(
            r?.branchURL("feature/x")?.absoluteString,
            "https://github.com/foo/bar/tree/feature/x"
        )
    }
}
