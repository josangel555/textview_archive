import XCTest
import ViewerCore
import TestSupport
@testable import ViewerUI

/// TSK-596 — GitPanelModel's log-search state machine, pinned headless:
/// a search replaces the displayed list with the git-backed match set,
/// clearing restores the paged log, pagination is disabled while a
/// search is active, and a repo switch drops the search. The search
/// field UI calls exactly `runLogSearch` / `clearLogSearch`.
@MainActor
final class GitLogSearchModelTests: XCTestCase {

    private var repo: URL!

    override func setUp() async throws {
        try await super.setUp()
        repo = try GitTestRepo.makeRepo(prefix: "GitLogSearchModelTests")
        try commit("add waveform reducer", file: "a.txt")
        try commit("fix sidebar layout", body: "Heartbeat polling drift.", file: "b.txt")
        try commit("docs: readme", file: "c.txt")
    }

    override func tearDown() async throws {
        if let repo { try? FileManager.default.removeItem(at: repo) }
        try await super.tearDown()
    }

    @discardableResult
    private func git(_ args: [String]) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.currentDirectoryURL = repo
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        try p.run()
        p.waitUntilExit()
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }

    private func commit(_ subject: String, body: String? = nil, file: String) throws {
        try "x\n".write(to: repo.appendingPathComponent(file), atomically: true, encoding: .utf8)
        try git(["add", "."])
        var args = ["commit", "-q", "-m", subject]
        if let body { args += ["-m", body] }
        try git(args)
    }

    private func makeModel() -> GitPanelModel {
        let m = GitPanelModel()
        m.logSearchDebounceNanos = 0  // tests don't wait out the keystroke debounce
        m.setRepoRoot(repo)
        return m
    }

    /// Spin until the async search lands (detached git shell-out).
    ///
    /// TSK-1600: search is now TWO-PHASE — instant local hits (sha/ref/
    /// worktree prefix + subject over loaded rows) can publish before the
    /// `--grep` body pass merges in — so "landed" means `logSearchIsSettled`,
    /// not merely "results is non-nil".
    private func waitForSearch(_ m: GitPanelModel, timeout: TimeInterval = 5) async {
        let deadline = Date().addingTimeInterval(timeout)
        while (m.logSearchResults == nil || !m.logSearchIsSettled) && Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    func test_search_replacesDisplayedList_clearRestores() async {
        let m = makeModel()
        m.runLogSearch("Heartbeat")  // body-only match
        await waitForSearch(m)

        XCTAssertTrue(m.isLogSearchActive)
        XCTAssertEqual(m.displayedLogEntries.map(\.subject), ["fix sidebar layout"])

        m.clearLogSearch()
        XCTAssertFalse(m.isLogSearchActive)
        XCTAssertNil(m.logSearchResults)
        XCTAssertEqual(m.displayedLogEntries, m.logEntries,
                       "clearing must restore the normal paged log")
        XCTAssertTrue(m.logSearchQuery.isEmpty, "clear also resets the field text")
    }

    func test_emptyQuery_clearsInsteadOfSearching() async {
        let m = makeModel()
        m.runLogSearch("waveform")
        await waitForSearch(m)
        XCTAssertTrue(m.isLogSearchActive)

        m.runLogSearch("   ")
        XCTAssertFalse(m.isLogSearchActive, "whitespace query = clear")
    }

    func test_repoSwitch_dropsActiveSearch() async {
        let m = makeModel()
        m.runLogSearch("waveform")
        await waitForSearch(m)
        XCTAssertTrue(m.isLogSearchActive)

        m.setRepoRoot(nil)
        XCTAssertFalse(m.isLogSearchActive,
                       "a stale match set must never survive into another repo")
    }

    func test_modifiedClicks_areNoOpsWhileSearchActive() async {
        // TSK-522: the grep match set is a filtered view — row adjacency
        // is not commit adjacency, so multi-select range/contiguity math
        // over it would lie. Cmd/Shift clicks must be inert during search.
        let m = makeModel()
        m.runLogSearch("waveform")
        await waitForSearch(m)
        XCTAssertTrue(m.isLogSearchActive)

        m.logRowClicked(sha: "abc1234", command: true)
        m.logRowClicked(sha: "abc1234", shift: true)
        XCTAssertTrue(m.selectedLogSHAs.isEmpty,
                      "multi-select is disabled while a search is active")
    }

    /// TSK-1600 — a sha/ref/worktree/subject hit over ALREADY-LOADED rows
    /// publishes INSTANTLY (no subprocess, no debounce wait), so the list
    /// narrows as the user types; the body pass then merges in and settles.
    func test_localHits_publishBeforeTheGrepSettles() async throws {
        let m = makeModel()
        // Real rows, loaded the way the Log tab loads them.
        m.logEntries = GitClient(repoRoot: repo).graphLog(maxEntries: 20)
        let target = try XCTUnwrap(
            m.logEntries.first { $0.subject == "add waveform reducer" })

        m.runLogSearch(String(target.sha.prefix(3)))   // commit-id PREFIX
        XCTAssertEqual(m.logSearchResults?.map(\.sha), [target.sha],
                       "a local sha-prefix hit is published synchronously")
        XCTAssertFalse(m.logSearchIsSettled, "the body pass is still in flight")
        await waitForSearch(m)
        XCTAssertTrue(m.logSearchIsSettled)
        XCTAssertTrue(m.displayedLogEntries.contains { $0.sha == target.sha },
                      "the early hit survives the merge")

        m.runLogSearch("waveform")                    // SUBJECT substring
        XCTAssertEqual(m.logSearchResults?.map(\.sha), [target.sha],
                       "a subject hit also resolves locally, before the grep")
        m.clearLogSearch()
        XCTAssertTrue(m.logSearchIsSettled, "clearing settles the search")
    }

    func test_loadMoreLog_isNoOpWhileSearchActive() async {
        let m = makeModel()
        m.runLogSearch("waveform")
        await waitForSearch(m)
        let displayed = m.displayedLogEntries

        m.loadMoreLog()
        // Give a would-be page a beat to (incorrectly) land.
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(m.displayedLogEntries, displayed,
                       "pagination must not mutate the displayed match set")
    }
}
