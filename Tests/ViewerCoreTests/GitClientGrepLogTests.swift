import XCTest
@testable import ViewerCore

/// TSK-596 — `GitClient.grepLog`: full-message search (subject + body)
/// backing the Git Log tab's search field. Fixture-repo pattern from
/// `GitClientPanelTests`.
final class GitClientGrepLogTests: XCTestCase {

    private func makeRepo() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("GitClientGrepLogTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try run(["init", "-q", "-b", "main"], in: dir)
        try run(["config", "user.email", "t@example.com"], in: dir)
        try run(["config", "user.name", "Tester"], in: dir)
        try run(["config", "commit.gpgsign", "false"], in: dir)
        return dir
    }

    @discardableResult
    private func run(_ args: [String], in dir: URL) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.currentDirectoryURL = dir
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        try p.run()
        p.waitUntilExit()
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }

    private func commit(_ subject: String, body: String? = nil, file: String, in dir: URL) throws {
        try "x\n".write(to: dir.appendingPathComponent(file), atomically: true, encoding: .utf8)
        try run(["add", "."], in: dir)
        var args = ["commit", "-q", "-m", subject]
        if let body { args += ["-m", body] }
        try run(args, in: dir)
    }

    /// One repo, three commits: subject-only hit, body-only hit, no hit.
    private func makeFixture() throws -> URL {
        let repo = try makeRepo()
        try commit("add waveform reducer", file: "a.txt", in: repo)
        try commit("fix sidebar layout",
                   body: "The accordion mis-measured under Heartbeat polling.",
                   file: "b.txt", in: repo)
        try commit("docs: readme", file: "c.txt", in: repo)
        return repo
    }

    func test_matchesSubject() throws {
        let repo = try makeFixture()
        let hits = GitClient(repoRoot: repo).grepLog(query: "waveform")
        XCTAssertEqual(hits.map(\.subject), ["add waveform reducer"])
    }

    func test_matchesBody_notJustSubject() throws {
        let repo = try makeFixture()
        // "Heartbeat" appears ONLY in the second commit's BODY — the
        // whole point of going git-backed instead of filtering the
        // loaded (subject-only) list.
        let hits = GitClient(repoRoot: repo).grepLog(query: "Heartbeat")
        XCTAssertEqual(hits.map(\.subject), ["fix sidebar layout"])
    }

    func test_caseInsensitive() throws {
        let repo = try makeFixture()
        let hits = GitClient(repoRoot: repo).grepLog(query: "WAVEFORM")
        XCTAssertEqual(hits.count, 1)
    }

    func test_fixedStrings_regexMetacharactersAreLiteral() throws {
        let repo = try makeRepo()
        try commit("fix(csv): cap parse [TSK-557]", file: "a.txt", in: repo)
        // "fix(" and "[TSK-557]" are invalid/loaded regex syntax — with
        // --fixed-strings they match literally instead of erroring or
        // matching everything.
        XCTAssertEqual(GitClient(repoRoot: repo).grepLog(query: "fix(csv): cap").count, 1)
        XCTAssertEqual(GitClient(repoRoot: repo).grepLog(query: "[TSK-557]").count, 1)
    }

    func test_emptyAndWhitespaceQuery_returnEmpty() throws {
        let repo = try makeFixture()
        XCTAssertTrue(GitClient(repoRoot: repo).grepLog(query: "").isEmpty)
        XCTAssertTrue(GitClient(repoRoot: repo).grepLog(query: "   ").isEmpty)
    }

    func test_noMatch_returnsEmpty() throws {
        let repo = try makeFixture()
        XCTAssertTrue(GitClient(repoRoot: repo).grepLog(query: "zebra-quux").isEmpty)
    }
}
