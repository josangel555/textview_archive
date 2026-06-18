import XCTest
@testable import ViewerCore

/// `GitClient.statusEntries()` parsing tests — successor to the retired
/// `GitServiceTests`. The pure-logic cases (parseStatusEntries) pin
/// the same edge cases (B6 " -> " gating, unicode paths, B7 quotePath
/// disabled) that the original GitService surface enforced; the live-
/// repo cases use `GitClient(repoRoot:)` directly.
final class GitClientStatusTests: XCTestCase {
    private var tmpDir: URL!

    override func setUpWithError() throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("GitClientStatusTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmpDir)
    }

    private func runGit(_ args: [String], in dir: URL? = nil) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["git"] + args
        p.currentDirectoryURL = dir ?? tmpDir
        try p.run()
        p.waitUntilExit()
        if p.terminationStatus != 0 {
            throw NSError(domain: "git", code: Int(p.terminationStatus))
        }
    }

    // TSK-850: shared batched fixture at the pre-created tmpDir (one shell vs 3
    // git Processes). `-b main` ≡ the prior `init.defaultBranch=main`; the
    // added gpgsign-false just hardens against an env `commit.gpgsign=true`.
    private func initRepo() throws {
        _ = try GitTestRepo.makeRepo(prefix: "GitClientStatusTests", at: tmpDir,
                                     email: "test@example.com", name: "Test")
    }

    private func touch(_ name: String, contents: String = "x") throws {
        let url = tmpDir.appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: discoverRoot

    func test_discoverRoot_nil_whenNoDotGit() {
        XCTAssertNil(GitClient.discoverRoot(from: tmpDir))
    }

    func test_discoverRoot_walksUpFromSubdirectory() throws {
        try initRepo()
        let nested = tmpDir.appendingPathComponent("a/b/c")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let root = GitClient.discoverRoot(from: nested)
        // discoverRoot does not resolve symlinks, but tmpDir's /var → /private/var
        // resolution would make a naive path-eq comparison flaky. Compare via the
        // shared standardization path.
        XCTAssertEqual(root?.standardizedFileURL.resolvingSymlinksInPath().path,
                       tmpDir.standardizedFileURL.resolvingSymlinksInPath().path)
    }

    // MARK: parseStatusEntries (pure)

    func test_parseStatusEntries_untracked() {
        let entries = GitClient.parseStatusEntries("?? foo.md\n?? bar/baz.txt\n")
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0], GitStatusEntry(path: "foo.md", status: .untracked))
        XCTAssertEqual(entries[1], GitStatusEntry(path: "bar/baz.txt", status: .untracked))
    }

    func test_parseStatusEntries_modified() {
        let entries = GitClient.parseStatusEntries(" M foo.md\n")
        XCTAssertEqual(entries[0].status, .modified)
    }

    func test_parseStatusEntries_added() {
        let entries = GitClient.parseStatusEntries("A  new.md\n")
        XCTAssertEqual(entries[0].status, .added)
    }

    func test_parseStatusEntries_deleted() {
        let entries = GitClient.parseStatusEntries(" D gone.md\n")
        XCTAssertEqual(entries[0].status, .deleted)
    }

    func test_parseStatusEntries_renamed_keepsDestination() {
        let entries = GitClient.parseStatusEntries("R  old.md -> new.md\n")
        XCTAssertEqual(entries[0], GitStatusEntry(path: "new.md", status: .renamed))
    }

    // B6: a literal " -> " in a filename must NOT be parsed as a rename
    // unless the status itself is R or C.
    func test_parseStatusEntries_modifiedFilenameWithArrowSubstring_keepsFullPath() {
        let entries = GitClient.parseStatusEntries(" M foo -> bar.txt\n")
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].status, .modified)
        XCTAssertEqual(entries[0].path, "foo -> bar.txt",
                       "non-rename status must preserve the literal path")
    }

    func test_parseStatusEntries_untrackedFilenameWithArrowSubstring_keepsFullPath() {
        let entries = GitClient.parseStatusEntries("?? foo -> bar.txt\n")
        XCTAssertEqual(entries[0].status, .untracked)
        XCTAssertEqual(entries[0].path, "foo -> bar.txt")
    }

    // B7: with core.quotePath=false (which we pass), git emits raw UTF-8
    // in paths. The parser just keeps the bytes as-is.
    func test_parseStatusEntries_pathWithSpaces() {
        let entries = GitClient.parseStatusEntries(" M my docs/notes.md\n")
        XCTAssertEqual(entries[0].path, "my docs/notes.md")
    }

    func test_parseStatusEntries_pathWithUnicode() {
        let entries = GitClient.parseStatusEntries("?? résumé.md\n")
        XCTAssertEqual(entries[0].path, "résumé.md")
    }

    func test_parseStatusEntries_conflict() {
        let entries = GitClient.parseStatusEntries("UU conflicted.md\n")
        XCTAssertEqual(entries[0].status, .conflicted)
    }

    func test_parseStatusEntries_emptyInput() {
        XCTAssertEqual(GitClient.parseStatusEntries(""), [])
    }

    // MARK: statusEntries (live; needs /usr/bin/git on the host)

    func test_statusEntries_listsUntrackedFile() throws {
        try initRepo()
        try touch("a.md")
        let entries = GitClient(repoRoot: tmpDir).statusEntries()
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].path, "a.md")
        XCTAssertEqual(entries[0].status, .untracked)
    }

    func test_statusEntries_listsModifiedFile() throws {
        try initRepo()
        try touch("a.md", contents: "v1")
        try runGit(["add", "a.md"])
        try runGit(["commit", "-m", "init"])
        try touch("a.md", contents: "v2")
        let entries = GitClient(repoRoot: tmpDir).statusEntries()
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].status, .modified)
    }

    func test_statusEntries_emptyArray_outsideRepo() {
        // Not a repo: the old throwing API became "return []" in
        // GitClient. Behavior shift documented in the migration.
        let entries = GitClient(repoRoot: tmpDir).statusEntries()
        XCTAssertEqual(entries, [])
    }
}
