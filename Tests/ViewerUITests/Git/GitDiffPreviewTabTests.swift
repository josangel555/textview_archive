import XCTest
import TestSupport
@testable import ViewerCore
@testable import ViewerUI

/// TSK-1594 — git diff tabs open in the ONE ephemeral PREVIEW slot (VSCode-style,
/// matching the sidebar file browser): a single click previews (reused slot), a
/// second click on the SAME commit promotes it to permanent, and browsing
/// commits never stacks tabs. Pins `GitLogDiffActions.showCommit` routing through
/// `DocumentModel.openPreview` (the live SwiftUI click + italic affordance are the
/// VM lane; this catches a revert of the open→openPreview routing on the host gate).
///
/// Tier: window-free (drives DocumentModel + GitPanelModel directly against a real
/// temp repo, no NSWindow) — host-safe, same harness as GitLogMultiSelectTests.
@MainActor
final class GitDiffPreviewTabTests: XCTestCase {
    private var repo: URL!
    private var tmpDir: URL!
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        repo = try GitTestRepo.makeRepo(prefix: "GitDiffPreviewTabTests")
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("GitDiffPreviewTabTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        suiteName = "GitDiffPreviewTabTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: repo)
        try? FileManager.default.removeItem(at: tmpDir)
        defaults.removePersistentDomain(forName: suiteName)
    }

    @discardableResult
    private func git(_ args: String) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.currentDirectoryURL = repo
        p.arguments = ["-c", "git \(args)"]
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
        try? p.run(); p.waitUntilExit()
        return p.terminationStatus
    }

    /// Commit a file and return the new HEAD sha.
    private func commitFile(_ name: String, _ body: String) -> String {
        try? body.write(to: repo.appendingPathComponent(name), atomically: true, encoding: .utf8)
        _ = git("add -A")
        _ = git("commit -q -m 'c \(name)'")
        return GitClient(repoRoot: repo).revParse("HEAD") ?? ""
    }

    private func makeDoc() -> DocumentModel {
        DocumentModel(
            controller: DocumentController(),
            history: HistoryStore(storeURL: tmpDir.appendingPathComponent("history.json")),
            sidebar: SidebarModel(),
            preferences: PreferencesStore(defaults: defaults))
    }

    private func makePanel() -> GitPanelModel {
        let p = GitPanelModel()
        p.repoRoot = repo
        return p
    }

    private func previewCount(_ doc: DocumentModel) -> Int {
        doc.tabs.tabs.filter { $0.isPreview }.count
    }

    func test_singleClick_opensEphemeralPreviewDiff() {
        let sha = commitFile("a.txt", "hello\n")
        XCTAssertFalse(sha.isEmpty, "fixture must produce a real commit")
        let doc = makeDoc()
        GitLogDiffActions.showCommit(sha: sha, panel: makePanel(), doc: doc)
        XCTAssertEqual(previewCount(doc), 1, "the commit diff opens in the single ephemeral preview slot")
        XCTAssertEqual(doc.tabs.tabs.first?.url?.lastPathComponent, "\(sha).diff")
    }

    func test_secondClickSameCommit_promotesToPermanent() {
        let sha = commitFile("a.txt", "hello\n")
        let doc = makeDoc(); let panel = makePanel()
        GitLogDiffActions.showCommit(sha: sha, panel: panel, doc: doc)
        XCTAssertEqual(previewCount(doc), 1)
        GitLogDiffActions.showCommit(sha: sha, panel: panel, doc: doc)   // the "double-click"
        XCTAssertEqual(previewCount(doc), 0,
                       "clicking the same commit again promotes its diff to a permanent tab")
        XCTAssertEqual(doc.tabs.tabs.count, 1, "no duplicate tab is stacked")
    }

    func test_browsingCommits_reusesOneSlot_neverStacks() {
        let sha1 = commitFile("a.txt", "one\n")
        let sha2 = commitFile("b.txt", "two\n")
        let doc = makeDoc(); let panel = makePanel()
        GitLogDiffActions.showCommit(sha: sha1, panel: panel, doc: doc)
        GitLogDiffActions.showCommit(sha: sha2, panel: panel, doc: doc)
        XCTAssertEqual(doc.tabs.tabs.count, 1, "browsing commits reuses the one preview slot (no stacking)")
        XCTAssertEqual(previewCount(doc), 1)
        XCTAssertEqual(doc.tabs.tabs.first?.url?.lastPathComponent, "\(sha2).diff",
                       "the slot now shows the most recently clicked commit's diff")
    }

    func test_cumulativeDiff_alsoEphemeral() {
        let sha1 = commitFile("a.txt", "one\n")
        let sha2 = commitFile("b.txt", "two\n")
        let doc = makeDoc(); let panel = makePanel()
        // Select a 2-commit range, then open the cumulative diff.
        panel.logEntries = [
            GitClient.GraphCommit(sha: sha2, parents: [sha1], author: "t", timestamp: 0,
                                  subject: "s2", refs: [], filesChanged: 1, insertions: 1, deletions: 0),
            GitClient.GraphCommit(sha: sha1, parents: [], author: "t", timestamp: 0,
                                  subject: "s1", refs: [], filesChanged: 1, insertions: 1, deletions: 0),
        ]
        panel.logRowClicked(sha: sha1, command: true)
        panel.logRowClicked(sha: sha2, command: true)
        GitLogDiffActions.showCumulativeDiff(panel: panel, doc: doc)
        XCTAssertEqual(previewCount(doc), 1, "a cumulative diff is ephemeral too")
    }
}
