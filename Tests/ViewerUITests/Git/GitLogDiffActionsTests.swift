import XCTest
import ViewerCore
import TestSupport
@testable import ViewerUI

/// TSK-522/523/620 — the Git Log row/toolbar EXACT action closures
/// (`GitLogDiffActions`, the functions GitLogTab's buttons call) and
/// their script-verb bridge. Host-pins, against a real fixture repo:
/// plain click → selection + commit-diff tab; cmd-click → multi-select;
/// cumulative-diff → net base..tip diff tab. The VM lane re-runs the
/// same closures cross-process via the verbs and asserts the dump's
/// `gitLog` projection (selection bar rendering = the residual).
@MainActor
final class GitLogDiffActionsTests: XCTestCase {

    private var repo: URL!

    override func setUp() async throws {
        try await super.setUp()
        repo = try GitTestRepo.makeRepo(prefix: "GitLogActions", email: "t@t", name: "t")
        for (i, body) in ["one\n", "one\ntwo\n", "one\ntwo\nthree\n"].enumerated() {
            try body.write(to: repo.appendingPathComponent("f.txt"),
                           atomically: true, encoding: .utf8)
            try git("add", "f.txt")
            try git("commit", "-q", "-m", "c\(i + 1)")
        }
    }

    override func tearDown() async throws {
        if let repo { try? FileManager.default.removeItem(at: repo) }
        try await super.tearDown()
    }

    private func git(_ args: String...) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = args
        p.currentDirectoryURL = repo
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0, "git \(args.joined(separator: " "))")
    }

    /// (panel with the fixture log loaded, doc model) — panel loads via
    /// the same GitClient the app uses.
    private func makePanelAndDoc() -> (GitPanelModel, DocumentModel, [GitClient.GraphCommit]) {
        let panel = GitPanelModel()
        panel.repoRoot = repo
        let log = GitClient(repoRoot: repo).graphLog(maxEntries: 10)
        XCTAssertEqual(log.count, 3, "fixture must have 3 commits")
        // The cumulative-range math resolves topo order from the loaded
        // log — populate it as the panel's refresh would.
        panel.logEntries = log
        return (panel, DocumentModel(), log)
    }

    func test_plainClick_selectsAndOpensCommitDiffTab() {
        let (panel, doc, log) = makePanelAndDoc()
        let tip = log[0]

        GitLogDiffActions.rowClicked(
            sha: tip.sha, command: false, shift: false, panel: panel, doc: doc)

        XCTAssertEqual(panel.selectedLogSHA, tip.sha)
        let tab = doc.tabs.tabs.last
        XCTAssertEqual(tab?.url?.lastPathComponent, "\(tip.sha).diff",
            "plain click must open the commit's diff tab")
        if let url = tab?.url, let body = try? String(contentsOf: url, encoding: .utf8) {
            XCTAssertTrue(body.contains("+three"),
                "the diff tab must hold the commit's actual patch")
        } else {
            XCTFail("diff tab file unreadable")
        }
    }

    func test_plainClick_sameCommitTwice_doesNotDuplicateTab() {
        // TSK-907: re-clicking the same commit must FOCUS its existing diff
        // tab, not stack a duplicate (the <sha>.diff path is deterministic).
        let (panel, doc, log) = makePanelAndDoc()
        let tip = log[0]

        GitLogDiffActions.rowClicked(
            sha: tip.sha, command: false, shift: false, panel: panel, doc: doc)
        let afterFirst = doc.tabs.tabs.count
        let firstTabID = doc.tabs.selected?.id

        GitLogDiffActions.rowClicked(
            sha: tip.sha, command: false, shift: false, panel: panel, doc: doc)

        XCTAssertEqual(doc.tabs.tabs.count, afterFirst,
            "re-clicking the same commit must not open a second tab")
        XCTAssertEqual(doc.tabs.selected?.url?.lastPathComponent, "\(tip.sha).diff",
            "the commit's diff tab must be the focused tab")
        XCTAssertEqual(doc.tabs.selected?.id, firstTabID,
            "the SAME tab must be re-focused, not a fresh one")
        XCTAssertEqual(
            doc.tabs.tabs.filter { $0.url?.lastPathComponent == "\(tip.sha).diff" }.count, 1,
            "exactly one tab for the commit's diff")
    }

    func test_twoDifferentCommits_reuseOneEphemeralPreviewSlot() {
        // TSK-1594: single-clicking commits is EPHEMERAL (VSCode-style, like the
        // file browser) — browsing from one commit to another REUSES the one
        // preview slot instead of stacking a tab per commit. The slot ends up
        // showing the most recently clicked commit's diff.
        let (panel, doc, log) = makePanelAndDoc()
        GitLogDiffActions.rowClicked(
            sha: log[0].sha, command: false, shift: false, panel: panel, doc: doc)
        let afterFirst = doc.tabs.tabs.count
        GitLogDiffActions.rowClicked(
            sha: log[1].sha, command: false, shift: false, panel: panel, doc: doc)
        XCTAssertEqual(doc.tabs.tabs.count, afterFirst,
            "browsing to a different commit reuses the one ephemeral preview slot (no stacking)")
        XCTAssertEqual(doc.tabs.selected?.url?.lastPathComponent, "\(log[1].sha).diff",
            "the reused slot now shows the latest commit's diff")
        XCTAssertEqual(doc.tabs.tabs.filter { $0.isPreview }.count, 1,
            "exactly one ephemeral preview tab")
    }

    func test_pinnedCommit_thenBrowse_keepsPinAndPreviewsTheNext() {
        // TSK-1594: double-clicking (two clicks on the same commit) PROMOTES its
        // diff to a permanent tab; a subsequent single-click on a DIFFERENT commit
        // opens its own fresh preview alongside the pinned one — so distinct
        // commits DO coexist once the earlier one is pinned.
        let (panel, doc, log) = makePanelAndDoc()
        // Double-click commit 0 → promote to permanent.
        GitLogDiffActions.rowClicked(
            sha: log[0].sha, command: false, shift: false, panel: panel, doc: doc)
        GitLogDiffActions.rowClicked(
            sha: log[0].sha, command: false, shift: false, panel: panel, doc: doc)
        XCTAssertEqual(doc.tabs.tabs.filter { $0.isPreview }.count, 0, "commit 0 is now pinned")
        let afterPin = doc.tabs.tabs.count

        // Single-click commit 1 → a NEW preview tab beside the pinned one.
        GitLogDiffActions.rowClicked(
            sha: log[1].sha, command: false, shift: false, panel: panel, doc: doc)
        XCTAssertEqual(doc.tabs.tabs.count, afterPin + 1,
            "with commit 0 pinned, a different commit opens its own preview tab")
        XCTAssertEqual(doc.tabs.tabs.filter { $0.isPreview }.count, 1)
        XCTAssertEqual(
            doc.tabs.tabs.filter { $0.url?.lastPathComponent == "\(log[0].sha).diff" }.count, 1,
            "the pinned commit-0 diff tab survives")
    }

    func test_cmdClick_buildsMultiSelection_withoutOpeningDiff() {
        let (panel, doc, log) = makePanelAndDoc()
        let before = doc.tabs.tabs.count

        GitLogDiffActions.rowClicked(
            sha: log[0].sha, command: true, shift: false, panel: panel, doc: doc)
        GitLogDiffActions.rowClicked(
            sha: log[2].sha, command: true, shift: false, panel: panel, doc: doc)

        XCTAssertEqual(panel.selectedLogSHAs, [log[0].sha, log[2].sha],
            "cmd-click must toggle SHAs into the multi-selection")
        XCTAssertEqual(doc.tabs.tabs.count, before,
            "cmd-click must NOT open a diff tab")
    }

    func test_cumulativeDiff_opensNetBaseTipDiffTab() throws {
        let (panel, doc, log) = makePanelAndDoc()
        // Select tip + oldest → range covers c2..c3 (base = parent of oldest selected).
        GitLogDiffActions.rowClicked(
            sha: log[0].sha, command: true, shift: false, panel: panel, doc: doc)
        GitLogDiffActions.rowClicked(
            sha: log[1].sha, command: true, shift: false, panel: panel, doc: doc)
        let range = try XCTUnwrap(panel.cumulativeLogSelectionRange,
            "two selected commits must yield a cumulative range")

        GitLogDiffActions.showCumulativeDiff(panel: panel, doc: doc)

        let tab = doc.tabs.tabs.last
        XCTAssertEqual(tab?.url?.lastPathComponent,
                       "\(range.baseRef)..\(range.tipRef).diff",
            "cumulative diff must open the base..tip net-diff tab")
        if let url = tab?.url, let body = try? String(contentsOf: url, encoding: .utf8) {
            XCTAssertTrue(body.contains("+two") && body.contains("+three"),
                "net diff c1→c3 must contain both added lines; got: \(body.prefix(300))")
        } else {
            XCTFail("diff tab file unreadable")
        }
    }

    /// I-02 (owner 2026-08-01): a renderer-choking commit body is BOUNDED
    /// before it reaches the .diff file — whole-line cut + explicit notice.
    /// Driven through the REAL click closure with the byte-cap seam shrunk.
    func test_hugeCommitDiff_isTruncatedWithNotice() throws {
        let (panel, doc, log) = makePanelAndDoc()
        let old = GitLogDiffActions.maxDiffBytes
        GitLogDiffActions.maxDiffBytes = 64
        defer { GitLogDiffActions.maxDiffBytes = old }

        // CI-flake hardening (2026-08-01, CI 3e54d32d): under the parallel
        // sweep a transient git SPAWN failure makes commitDiff return "" (the
        // `try? run` contract), which writes an EMPTY diff — that's load, not
        // a truncation regression. Retry the click (idempotent — same sha
        // rewrites the same cache file) until git actually produced output;
        // a REAL truncation break still fails after the retries.
        var body = ""
        for _ in 0..<3 {
            GitLogDiffActions.rowClicked(
                sha: log[0].sha, command: false, shift: false, panel: panel, doc: doc)
            if let url = doc.tabs.tabs.last?.url,
               let b = try? String(contentsOf: url, encoding: .utf8), !b.isEmpty {
                body = b
                break
            }
            // No inter-attempt sleep (the sleep ratchet stays at baseline):
            // each retry re-spawns git, whose own 10–100ms runtime is the
            // natural spacing for a transient spawn failure.
        }
        XCTAssertFalse(body.isEmpty, "git produced no diff output after 3 attempts")
        XCTAssertTrue(body.hasPrefix("⚠ DIFF TRUNCATED"),
            "an over-cap diff must carry the explicit truncation notice")
        XCTAssertTrue(body.contains("git show \(log[0].sha)"),
            "the notice names the full-output escape hatch")
        XCTAssertLessThan(body.utf8.count, 1024,
            "the written diff must be bounded, not the full body")
    }

    /// The script-verb bridge: `git-log-cmd-click <sha>` resolves the
    /// LIVE panel (weak registry) and drives the identical closure.
    func test_scriptVerbs_resolveLivePanel_andDriveClosures() {
        let (panel, doc, log) = makePanelAndDoc()
        XCTAssertTrue(GitPanelModel.live === panel,
            "the newest panel must be the live registry instance")

        XCTAssertTrue(ScriptVerb.apply(
            verb: "git-log-cmd-click \(log[0].sha)",
            to: doc, sessions: makeSessions(doc)))
        XCTAssertTrue(ScriptVerb.apply(
            verb: "git-log-cmd-click \(log[1].sha)",
            to: doc, sessions: makeSessions(doc)))
        XCTAssertEqual(panel.selectedLogSHAs, [log[0].sha, log[1].sha])

        XCTAssertTrue(ScriptVerb.apply(
            verb: "git-log-cumulative-diff", to: doc, sessions: makeSessions(doc)))
        XCTAssertTrue(doc.tabs.tabs.last?.url?.lastPathComponent.hasSuffix(".diff") == true,
            "the verb must open the cumulative diff tab")
    }

    private func makeSessions(_ doc: DocumentModel) -> SessionsAppCoordinator {
        let dir = repo.appendingPathComponent("store-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return SessionsAppCoordinator(
            model: doc, store: SessionStore(directory: dir),
            initialRoot: nil, autosaveDebounce: 0)
    }
}
