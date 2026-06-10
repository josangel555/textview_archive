import XCTest
import ViewerCore
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
        repo = FileManager.default.temporaryDirectory
            .appendingPathComponent("GitLogActions-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try git("init", "-q", "-b", "main")
        try git("config", "user.email", "t@t")
        try git("config", "user.name", "t")
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
