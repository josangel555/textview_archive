import XCTest
@testable import ViewerCore

final class GitServiceTests: XCTestCase {
    private var tmpDir: URL!
    private let service = GitService()

    override func setUpWithError() throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("GitServiceTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmpDir)
    }

    private func runGit(_ args: [String], in dir: URL? = nil) throws {
        try service.run(args, in: dir ?? tmpDir)
    }

    private func initRepo() throws {
        try runGit(["-c", "init.defaultBranch=main", "init"])
        try runGit(["config", "user.email", "test@example.com"])
        try runGit(["config", "user.name", "Test"])
    }

    private func touch(_ name: String, contents: String = "x") throws {
        let url = tmpDir.appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: isGitRepo / repoRoot

    func test_isGitRepo_false_whenNoDotGit() {
        XCTAssertFalse(service.isGitRepo(at: tmpDir))
    }

    func test_isGitRepo_true_afterInit() throws {
        try initRepo()
        XCTAssertTrue(service.isGitRepo(at: tmpDir))
    }

    func test_repoRoot_walksUpFromSubdirectory() throws {
        try initRepo()
        let nested = tmpDir.appendingPathComponent("a/b/c")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let root = service.repoRoot(for: nested)
        XCTAssertEqual(root?.resolvingSymlinksInPath(),
                       tmpDir.resolvingSymlinksInPath())
    }

    func test_repoRoot_nilWhenNotInRepo() {
        XCTAssertNil(service.repoRoot(for: tmpDir))
    }

    // MARK: status parsing (pure)

    func test_parseStatus_untracked() {
        let entries = GitService.parseStatus("?? foo.md\n?? bar/baz.txt\n")
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0], GitStatusEntry(path: "foo.md", status: .untracked))
        XCTAssertEqual(entries[1], GitStatusEntry(path: "bar/baz.txt", status: .untracked))
    }

    func test_parseStatus_modified() {
        let entries = GitService.parseStatus(" M foo.md\n")
        XCTAssertEqual(entries[0].status, .modified)
    }

    func test_parseStatus_added() {
        let entries = GitService.parseStatus("A  new.md\n")
        XCTAssertEqual(entries[0].status, .added)
    }

    func test_parseStatus_deleted() {
        let entries = GitService.parseStatus(" D gone.md\n")
        XCTAssertEqual(entries[0].status, .deleted)
    }

    func test_parseStatus_renamed_keepsDestination() {
        let entries = GitService.parseStatus("R  old.md -> new.md\n")
        XCTAssertEqual(entries[0], GitStatusEntry(path: "new.md", status: .renamed))
    }

    // B6: a literal " -> " in a filename must NOT be parsed as a rename
    // unless the status itself is R or C.
    func test_parseStatus_modifiedFilenameWithArrowSubstring_keepsFullPath() {
        let entries = GitService.parseStatus(" M foo -> bar.txt\n")
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].status, .modified)
        XCTAssertEqual(entries[0].path, "foo -> bar.txt",
                       "non-rename status must preserve the literal path")
    }

    func test_parseStatus_untrackedFilenameWithArrowSubstring_keepsFullPath() {
        let entries = GitService.parseStatus("?? foo -> bar.txt\n")
        XCTAssertEqual(entries[0].status, .untracked)
        XCTAssertEqual(entries[0].path, "foo -> bar.txt")
    }

    // B7: with core.quotePath=false (which we now pass), git emits raw UTF-8
    // in paths. The parser just keeps the bytes as-is.
    func test_parseStatus_pathWithSpaces() {
        let entries = GitService.parseStatus(" M my docs/notes.md\n")
        XCTAssertEqual(entries[0].path, "my docs/notes.md")
    }

    func test_parseStatus_pathWithUnicode() {
        let entries = GitService.parseStatus("?? résumé.md\n")
        XCTAssertEqual(entries[0].path, "résumé.md")
    }

    func test_parseStatus_conflict() {
        let entries = GitService.parseStatus("UU conflicted.md\n")
        XCTAssertEqual(entries[0].status, .conflicted)
    }

    func test_parseStatus_emptyInput() {
        XCTAssertEqual(GitService.parseStatus(""), [])
    }

    // MARK: status (live; needs /usr/bin/git on the host)

    func test_status_listsUntrackedFile() throws {
        try initRepo()
        try touch("a.md")
        let entries = try service.status(at: tmpDir)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].path, "a.md")
        XCTAssertEqual(entries[0].status, .untracked)
    }

    func test_status_listsModifiedFile() throws {
        try initRepo()
        try touch("a.md", contents: "v1")
        try runGit(["add", "a.md"])
        try runGit(["commit", "-m", "init"])
        try touch("a.md", contents: "v2")
        let entries = try service.status(at: tmpDir)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].status, .modified)
    }

    func test_run_throwsOnFailingCommand() {
        XCTAssertThrowsError(try service.run(["status"], in: tmpDir)) { error in
            guard case .commandFailed = error as? GitError else {
                return XCTFail("expected GitError.commandFailed, got \(error)")
            }
        }
    }
}
