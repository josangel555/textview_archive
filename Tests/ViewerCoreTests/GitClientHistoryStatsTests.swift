import XCTest
@testable import ViewerCore

/// Tests for the File-History + Folder-Stats GitClient surfaces:
/// `fileHistory(path:)` (full + short SHA, rename-following),
/// `diff(from:to:path:)` (vs-current + two-commit + option-injection
/// guard), `repoStats(scope:)` aggregation, the pure parsers
/// (`parseShortlog`, `parseExtensionHistogram`), and the
/// `RepoStatsCache` HEAD-invalidation. Each test owns a temp repo,
/// drives real git, and asserts the parsed output.
final class GitClientHistoryStatsTests: XCTestCase {

    // MARK: - Setup helpers (mirrors GitClientPanelTests)

    private func makeRepo() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("GitClientHistoryStatsTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try run(["init", "-q", "-b", "main"], in: dir)
        try run(["config", "user.email", "t@example.com"], in: dir)
        try run(["config", "user.name",  "Tester"], in: dir)
        try run(["config", "commit.gpgsign", "false"], in: dir)
        return dir
    }

    @discardableResult
    private func run(_ args: [String], in dir: URL, env: [String: String]? = nil) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.currentDirectoryURL = dir
        p.arguments = args
        if let env {
            var merged = ProcessInfo.processInfo.environment
            for (k, v) in env { merged[k] = v }
            p.environment = merged
        }
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        try p.run()
        p.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }

    private func writeFile(_ name: String, _ contents: String, in dir: URL) throws {
        let url = dir.appendingPathComponent(name)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: - fileHistory

    func test_fileHistory_empty_for_nonrepo() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("not-a-repo-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertEqual(GitClient(repoRoot: dir).fileHistory(path: "x.txt"), [])
    }

    func test_fileHistory_returns_full_and_short_sha_newest_first() throws {
        let repo = try makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        try writeFile("a.txt", "one\n", in: repo)
        try run(["add", "."], in: repo)
        try run(["commit", "-q", "-m", "add a"], in: repo)
        try writeFile("a.txt", "one\ntwo\n", in: repo)
        try run(["commit", "-q", "-am", "extend a"], in: repo)
        // A commit touching a DIFFERENT file must not appear in a.txt's history.
        try writeFile("b.txt", "b\n", in: repo)
        try run(["add", "."], in: repo)
        try run(["commit", "-q", "-m", "add b"], in: repo)

        let history = GitClient(repoRoot: repo).fileHistory(path: "a.txt")
        XCTAssertEqual(history.count, 2, "only commits touching a.txt")
        XCTAssertEqual(history[0].subject, "extend a")  // newest first
        XCTAssertEqual(history[1].subject, "add a")
        // Full SHA is 40-hex; short SHA is its prefix.
        for e in history {
            XCTAssertEqual(e.fullSHA.count, 40, "full SHA should be 40 hex chars")
            XCTAssertFalse(e.sha.isEmpty)
            XCTAssertTrue(e.fullSHA.hasPrefix(e.sha),
                          "short SHA should be a prefix of full SHA")
            XCTAssertEqual(e.author, "Tester")
            XCTAssertFalse(e.date.isEmpty)
        }
    }

    func test_fileHistory_follows_rename() throws {
        let repo = try makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        try writeFile("old.txt", "content line one\ncontent line two\n", in: repo)
        try run(["add", "."], in: repo)
        try run(["commit", "-q", "-m", "create old.txt"], in: repo)
        try run(["mv", "old.txt", "new.txt"], in: repo)
        try run(["commit", "-q", "-m", "rename to new.txt"], in: repo)

        let history = GitClient(repoRoot: repo).fileHistory(path: "new.txt")
        // --follow should reach back across the rename to the create commit.
        XCTAssertEqual(history.count, 2)
        XCTAssertTrue(history.contains { $0.subject == "create old.txt" },
                      "--follow should surface the pre-rename create commit")
    }

    // MARK: - diff(from:to:path:)

    func test_diff_commit_vs_current_working_tree() throws {
        let repo = try makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        try writeFile("a.txt", "v1\n", in: repo)
        try run(["add", "."], in: repo)
        try run(["commit", "-q", "-m", "v1"], in: repo)
        let history = GitClient(repoRoot: repo).fileHistory(path: "a.txt")
        let firstSHA = history[0].fullSHA
        // Dirty the working tree (uncommitted).
        try writeFile("a.txt", "v1-changed\n", in: repo)

        // to == nil → diff against working tree.
        let d = GitClient(repoRoot: repo).diff(from: firstSHA, to: nil, path: "a.txt")
        XCTAssertTrue(d.contains("v1-changed"), "should show working-tree change")
        let files = DiffParser.parse(d)
        XCTAssertEqual(files.count, 1)
    }

    func test_diff_commit_vs_commit_range() throws {
        let repo = try makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        try writeFile("a.txt", "alpha\n", in: repo)
        try run(["add", "."], in: repo)
        try run(["commit", "-q", "-m", "c1"], in: repo)
        try writeFile("a.txt", "alpha\nbeta\n", in: repo)
        try run(["commit", "-q", "-am", "c2"], in: repo)

        let history = GitClient(repoRoot: repo).fileHistory(path: "a.txt")
        XCTAssertEqual(history.count, 2)
        let newer = history[0].fullSHA  // c2
        let older = history[1].fullSHA  // c1

        let d = GitClient(repoRoot: repo).diff(from: older, to: newer, path: "a.txt")
        let files = DiffParser.parse(d)
        XCTAssertEqual(files.count, 1)
        // Going older→newer, "beta" is an addition.
        let added = files[0].hunks.flatMap { $0.lines }.filter { $0.kind == .added }
        XCTAssertTrue(added.contains { $0.content.contains("beta") })
    }

    func test_diff_rejects_option_injection_revisions() throws {
        let repo = try makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        try writeFile("a.txt", "x\n", in: repo)
        try run(["add", "."], in: repo)
        try run(["commit", "-q", "-m", "c1"], in: repo)
        let client = GitClient(repoRoot: repo)
        // A leading-dash revision must be rejected (returns "") rather
        // than reaching git as an option.
        XCTAssertEqual(client.diff(from: "--output=/tmp/pwn", path: "a.txt"), "")
        XCTAssertEqual(client.diff(from: "", path: "a.txt"), "")
        let validSHA = client.fileHistory(path: "a.txt")[0].fullSHA
        XCTAssertEqual(client.diff(from: validSHA, to: "-x", path: "a.txt"), "")
    }

    // MARK: - repoStats

    func test_repoStats_counts_commits_and_authors() throws {
        let repo = try makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        // Two commits by Tester, one by a second author.
        try writeFile("a.swift", "let x = 1\n", in: repo)
        try run(["add", "."], in: repo)
        try run(["commit", "-q", "-m", "c1"], in: repo)
        try writeFile("b.swift", "let y = 2\n", in: repo)
        try run(["add", "."], in: repo)
        try run(["commit", "-q", "-m", "c2"], in: repo)
        try writeFile("c.md", "# hi\n", in: repo)
        try run(["add", "."], in: repo)
        try run(["commit", "-q", "-m", "c3"], in: repo,
                env: ["GIT_AUTHOR_NAME": "Other Person",
                      "GIT_AUTHOR_EMAIL": "other@example.com",
                      "GIT_COMMITTER_NAME": "Other Person",
                      "GIT_COMMITTER_EMAIL": "other@example.com"])

        let stats = GitClient(repoRoot: repo).repoStats(scope: .repo)
        XCTAssertEqual(stats.totalCommits, 3)
        XCTAssertNotNil(stats.firstCommitDate)
        XCTAssertNotNil(stats.lastCommitDate)
        XCTAssertGreaterThanOrEqual(stats.lastCommitDate!, stats.firstCommitDate!)
        // Author leaderboard: Tester (2) before Other Person (1).
        XCTAssertEqual(stats.authors.count, 2)
        XCTAssertEqual(stats.authors[0].name, "Tester")
        XCTAssertEqual(stats.authors[0].commitCount, 2)
        XCTAssertEqual(stats.authors[0].email, "t@example.com")
        XCTAssertEqual(stats.authors[1].commitCount, 1)
        // Extension histogram: 2x swift, 1x md, total 3 tracked files.
        XCTAssertEqual(stats.trackedFileCount, 3)
        let swift = stats.extensions.first { $0.ext == "swift" }
        XCTAssertEqual(swift?.fileCount, 2)
        XCTAssertEqual(stats.extensions.first?.ext, "swift", "histogram sorted desc")
    }

    func test_repoStats_folder_scope_limits_aggregation() throws {
        let repo = try makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        // Root-level commit.
        try writeFile("root.txt", "r\n", in: repo)
        try run(["add", "."], in: repo)
        try run(["commit", "-q", "-m", "root commit"], in: repo)
        // Subdir commits.
        try writeFile("sub/x.txt", "x\n", in: repo)
        try run(["add", "."], in: repo)
        try run(["commit", "-q", "-m", "sub one"], in: repo)
        try writeFile("sub/y.txt", "y\n", in: repo)
        try run(["add", "."], in: repo)
        try run(["commit", "-q", "-m", "sub two"], in: repo)

        let client = GitClient(repoRoot: repo)
        let whole = client.repoStats(scope: .repo)
        XCTAssertEqual(whole.totalCommits, 3)
        XCTAssertEqual(whole.trackedFileCount, 3)

        let folder = client.repoStats(scope: .folder(relativePath: "sub"))
        XCTAssertEqual(folder.totalCommits, 2, "only commits touching sub/")
        XCTAssertEqual(folder.trackedFileCount, 2, "only files under sub/")
    }

    func test_repoStats_unsafe_folder_path_degrades_to_repo() throws {
        let repo = try makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        try writeFile("a.txt", "a\n", in: repo)
        try run(["add", "."], in: repo)
        try run(["commit", "-q", "-m", "c1"], in: repo)
        let client = GitClient(repoRoot: repo)
        // A leading-dash relative path must not reach git as an option;
        // the pathspec degrades to whole-repo.
        let stats = client.repoStats(scope: .folder(relativePath: "--all"))
        XCTAssertEqual(stats.totalCommits, 1)
        XCTAssertEqual(stats.trackedFileCount, 1)
    }

    func test_repoStats_empty_repo() throws {
        let repo = try makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        let stats = GitClient(repoRoot: repo).repoStats(scope: .repo)
        XCTAssertEqual(stats.totalCommits, 0)
        XCTAssertNil(stats.firstCommitDate)
        XCTAssertEqual(stats.authors, [])
        XCTAssertEqual(stats.trackedFileCount, 0)
    }

    // MARK: - pure parsers

    func test_parseShortlog_handles_names_with_spaces_and_email() {
        let out = "    12\tJane Q. Doe <jane@example.com>\n     3\tbob <bob@x.io>\n"
        let stats = GitClient.parseShortlog(out)
        XCTAssertEqual(stats.count, 2)
        XCTAssertEqual(stats[0].name, "Jane Q. Doe")
        XCTAssertEqual(stats[0].email, "jane@example.com")
        XCTAssertEqual(stats[0].commitCount, 12)
        XCTAssertEqual(stats[1].name, "bob")
        XCTAssertEqual(stats[1].commitCount, 3)
    }

    func test_parseShortlog_sorts_descending() {
        let out = "  1\tA <a@x>\n  9\tB <b@x>\n  4\tC <c@x>\n"
        let stats = GitClient.parseShortlog(out)
        XCTAssertEqual(stats.map(\.commitCount), [9, 4, 1])
    }

    func test_parseShortlog_skips_malformed_lines() {
        let out = "garbage no tab\n  5\tValid <v@x>\n"
        let stats = GitClient.parseShortlog(out)
        XCTAssertEqual(stats.count, 1)
        XCTAssertEqual(stats[0].name, "Valid")
    }

    func test_parseExtensionHistogram_buckets_and_dotfiles() {
        let out = """
        src/a.swift
        src/b.swift
        README.md
        .gitignore
        Makefile
        nested/dir/c.swift
        """
        let (hist, total) = GitClient.parseExtensionHistogram(out)
        XCTAssertEqual(total, 6)
        let dict = Dictionary(uniqueKeysWithValues: hist.map { ($0.ext, $0.fileCount) })
        XCTAssertEqual(dict["swift"], 3)
        XCTAssertEqual(dict["md"], 1)
        // .gitignore and Makefile have no extension → "" bucket.
        XCTAssertEqual(dict[""], 2)
        // Sorted descending by count → swift first.
        XCTAssertEqual(hist.first?.ext, "swift")
    }

    func test_parseExtensionHistogram_lowercases_extension() {
        let (hist, _) = GitClient.parseExtensionHistogram("Photo.JPG\nother.jpg\n")
        let dict = Dictionary(uniqueKeysWithValues: hist.map { ($0.ext, $0.fileCount) })
        XCTAssertEqual(dict["jpg"], 2, "extensions should be case-folded")
    }

    // MARK: - RepoStatsCache

    func test_repoStatsCache_returns_cached_until_head_changes() async throws {
        let repo = try makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        try writeFile("a.txt", "a\n", in: repo)
        try run(["add", "."], in: repo)
        try run(["commit", "-q", "-m", "c1"], in: repo)

        let cache = RepoStatsCache()
        let first = await cache.stats(repoRoot: repo, scope: .repo)
        XCTAssertEqual(first.totalCommits, 1)

        // Same HEAD → cached (still 1 even though we add an UNCOMMITTED
        // file; rev-list count only counts commits, and the cache is
        // keyed on HEAD which hasn't moved).
        try writeFile("uncommitted.txt", "u\n", in: repo)
        let second = await cache.stats(repoRoot: repo, scope: .repo)
        XCTAssertEqual(second.totalCommits, 1)
        XCTAssertEqual(second.trackedFileCount, first.trackedFileCount,
                       "cached value, untracked file not counted")

        // New commit moves HEAD → cache recomputes.
        try run(["add", "."], in: repo)
        try run(["commit", "-q", "-m", "c2"], in: repo)
        let third = await cache.stats(repoRoot: repo, scope: .repo)
        XCTAssertEqual(third.totalCommits, 2, "HEAD moved → recomputed")
    }

    func test_repoStatsCache_invalidate_forces_recompute() async throws {
        let repo = try makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        try writeFile("a.txt", "a\n", in: repo)
        try run(["add", "."], in: repo)
        try run(["commit", "-q", "-m", "c1"], in: repo)

        let cache = RepoStatsCache()
        _ = await cache.stats(repoRoot: repo, scope: .repo)
        await cache.invalidate(repoRoot: repo)
        // After invalidation a fresh compute happens; result is identical
        // here, but the call must succeed (smoke that invalidation path).
        let after = await cache.stats(repoRoot: repo, scope: .repo)
        XCTAssertEqual(after.totalCommits, 1)
    }
}
