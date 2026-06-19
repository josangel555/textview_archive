import XCTest
import ViewerCore
@testable import ViewerUI

/// TSK-150 — the loadMoreLog stale-page guard, pinned headless.
///
/// CONTRACT: a log page fetched in flight must NEVER land once the list's
/// identity changes underneath it (repo switch / wholesale refresh). The
/// protection is layered (Task cancellation in `setRepoRoot`, then the
/// `repoRoot`/`logGen`/`logLoadedCount` guard after the suspension); this
/// test pins the OBSERVABLE contract, so it fails if the layers are
/// stripped — the drain pass found no test did (dropping the guard +
/// cancel stayed green everywhere).
///
/// Fixture: repo A gets 210 commits so the initial page (`logPageSize`,
/// 100) leaves a real, non-empty page 2 — with fewer commits the stale
/// append would be zero rows and invisible to assertions.
@MainActor
final class GitLogStalePageGuardTests: XCTestCase {

    private var tmpDir: URL!
    private var repoA: URL!
    private var repoB: URL!

    override func setUp() async throws {
        try await super.setUp()
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("GitLogStalePage-\(UUID().uuidString)")
        repoA = tmpDir.appendingPathComponent("a")
        repoB = tmpDir.appendingPathComponent("b")
        try FileManager.default.createDirectory(at: repoA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: repoB, withIntermediateDirectories: true)
        // 210 empty commits, but via `git fast-import` (ONE process, one
        // stream) instead of a 210-iteration `git commit` loop (210 process
        // spawns — the run-floor offender this class was, TSK-849). The
        // import-built history is byte-equivalent for our purposes: 210 empty
        // commits, subjects a-commit-1…a-commit-210, strictly increasing
        // committer timestamps so `git log`'s newest-first ordering is stable
        // (page 2 = the oldest commits, a-commit-1…). ~70x faster than the
        // loop (~0.05s vs ~3.7s isolated; far more under parallel host load).
        try fastImport(in: repoA, commits: 210, subjectPrefix: "a-commit-")
        try shell(in: repoB, """
            git init -q -b main && git config user.email t@t && \
            git config user.name t && git config commit.gpgsign false && \
            git commit -q --allow-empty -m "b-only-commit"
            """)
    }

    /// Build a repo of `commits` empty commits in ONE `git fast-import` run.
    /// Subjects are `<subjectPrefix><1…commits>`; committer timestamps strictly
    /// increase so newest-first `git log` order is deterministic. Replaces a
    /// per-commit `git commit` loop (one process spawn per commit) — the cost
    /// that made this the slowest class in the headless sweep.
    private func fastImport(in dir: URL, commits: Int,
                            subjectPrefix: String) throws {
        var stream = ""
        for i in 1...commits {
            let ts = 1_700_000_000 + i  // strictly increasing → stable log order
            let subject = "\(subjectPrefix)\(i)"
            let byteLen = subject.utf8.count
            stream += "commit refs/heads/main\n"
            stream += "mark :\(i)\n"
            stream += "committer Tester <t@example.com> \(ts) +0000\n"
            stream += "data \(byteLen)\n"
            stream += subject + "\n"
            if i > 1 { stream += "from :\(i - 1)\n" }
            stream += "\n"
        }

        // `git init` first (fast-import needs an existing repo), config to
        // match the prior fixture, then pipe the import stream on stdin, then
        // reset the working tree to the imported branch tip.
        try shell(in: dir, """
            git init -q -b main && git config user.email t@example.com && \
            git config user.name Tester && git config commit.gpgsign false
            """)

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = ["fast-import", "--quiet"]
        p.currentDirectoryURL = dir
        let stdin = Pipe()
        p.standardInput = stdin
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        try p.run()
        // Feed stdin on a background thread so a large stream can't deadlock
        // against git's stdout (pipe-buffer back-pressure) — we read stdout to
        // EOF on this thread concurrently. Safe at any `commits` count.
        let payload = Data(stream.utf8)
        let writer = Thread {
            stdin.fileHandleForWriting.write(payload)
            try? stdin.fileHandleForWriting.close()
        }
        writer.start()
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0,
            "git fast-import failed: " + String(decoding: outData, as: UTF8.self))

        // Point HEAD/index at the imported tip (fast-import only moves the ref).
        try shell(in: dir, "git reset -q --hard main")
    }

    override func tearDown() async throws {
        if let tmpDir { try? FileManager.default.removeItem(at: tmpDir) }
        try await super.tearDown()
    }

    private func shell(in dir: URL, _ script: String) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", script]
        p.currentDirectoryURL = dir
        try p.run()
        p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0, "fixture shell failed")
    }

    /// Poll until `cond` or fail after `timeout`.
    private func settle(_ what: String, timeout: TimeInterval = 15,
                        _ cond: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !cond() {
            if Date() > deadline { XCTFail("timed out settling: \(what)"); return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    func test_inFlightPage_droppedWhenRepoSwitchesUnderneath() async throws {
        let m = GitPanelModel()
        m.setRepoRoot(repoA)
        m.selectTab(.log)
        // Initial page: exactly logIncrementSize (200) of the 210.
        try await settle("repo A initial page") { m.logLoadedCount == m.logPageSize }

        // Kick page 2 (the remaining 10 commits) and capture the in-flight
        // task BEFORE invalidating the list identity — setRepoRoot nils
        // the property.
        m.loadMoreLog()
        let inFlightPage = m.loadMoreTask
        XCTAssertNotNil(inFlightPage, "page-2 fetch should be in flight")

        // Wholesale identity change while the page is in flight.
        m.setRepoRoot(repoB)

        // Drain the captured stale page task and assert IMMEDIATELY —
        // before repo B's refresh can wholesale-replace the list and
        // mask a leaked append. Page 2 of repo A is the OLDEST 110
        // commits (a-commit-1...a-commit-110, newest-first paging), so
        // their subjects are the stale-page fingerprint: present at this
        // instant ⇔ the protection is broken, regardless of whether B's
        // initial page has applied yet.
        await inFlightPage?.value
        XCTAssertFalse(
            m.logEntries.contains { $0.subject == "a-commit-110" || $0.subject == "a-commit-1" },
            "repo A's in-flight page 2 landed after the repo switch "
            + "(count \(m.logEntries.count)) — stale-page protection broken")

        try await settle("repo B initial page") { m.logLoadedCount == 1 }

        // THE CONTRACT: repo A's page 2 must have been dropped — the list
        // is exactly repo B's single commit, no a-commit-* rows appended.
        XCTAssertEqual(m.logEntries.count, 1,
            "stale repo-A page leaked into repo B's log "
            + "(count \(m.logEntries.count))")
        XCTAssertEqual(m.logEntries.first?.subject, "b-only-commit")
        XCTAssertFalse(m.logEntries.contains { $0.subject.hasPrefix("a-commit-") },
            "cross-repo commits appended — the stale-page protection is broken")
    }

    /// Control: with NO identity change, page 2 lands normally — proves
    /// the fixture actually produces a non-empty second page (so the
    /// guard test above can't pass vacuously).
    func test_control_page2AppendsWithoutInterference() async throws {
        let m = GitPanelModel()
        m.setRepoRoot(repoA)
        m.selectTab(.log)
        try await settle("repo A initial page") { m.logLoadedCount == m.logPageSize }

        m.loadMoreLog()
        await m.loadMoreTask?.value
        XCTAssertEqual(m.logLoadedCount, 210,
            "page 2 should append the remaining 10 commits")
        XCTAssertTrue(m.logEntries.contains { $0.subject == "a-commit-1" },
            "oldest commit must arrive with page 2")
    }
}
