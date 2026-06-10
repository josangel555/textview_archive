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
        // 210 empty commits via ONE git process (stdin batch through
        // `git fast-import` would be overkill; a single `sh -c` loop keeps
        // the fixture ~1s instead of 210 process spawns).
        try shell(in: repoA, """
            git init -q -b main && git config user.email t@t && \
            git config user.name t && git config commit.gpgsign false && \
            for i in $(seq 1 210); do \
              git commit -q --allow-empty -m "a-commit-$i"; done
            """)
        try shell(in: repoB, """
            git init -q -b main && git config user.email t@t && \
            git config user.name t && git config commit.gpgsign false && \
            git commit -q --allow-empty -m "b-only-commit"
            """)
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
