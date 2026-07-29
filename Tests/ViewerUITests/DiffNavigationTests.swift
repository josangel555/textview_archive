import XCTest
import TestSupport
import ViewerCore
@testable import ViewerUI

/// TSK-1599 — the web diff's per-file Old | New | Current buttons: host pins
/// for the model actions the `mdvDiff` bridge invokes (exact-closure rule),
/// against a REAL fixture repo. The button DOM + bridge post is the page's
/// VM-lane suite (`DiffWebPageTests`); the NSMenu-free model behavior here
/// keeps a routing regression on the host gate.
@MainActor
final class DiffNavigationTests: XCTestCase {

    private var repo: URL!
    private var tmpDir: URL!
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var panel: GitPanelModel!

    override func setUp() async throws {
        repo = try GitTestRepo.makeRepo(prefix: "DiffNavigationTests")
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DiffNavigationTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        suiteName = "DiffNavigationTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        // The live-panel registry is the diff tab's repo-context source.
        panel = GitPanelModel()
        panel.repoRoot = repo
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

    func test_blobContents_readsBothSidesOfACommit() throws {
        _ = commitFile("f.txt", "version one\n")
        let sha2 = commitFile("f.txt", "version two\n")
        let diffText = GitClient(repoRoot: repo).commitDiff(sha: sha2)
        let pairs = DiffWebPayload.blobPairs(diffText)
        XCTAssertEqual(pairs.count, 1)
        let old = try XCTUnwrap(pairs[0].old)
        let new = try XCTUnwrap(pairs[0].new)
        XCTAssertEqual(GitClient(repoRoot: repo).blobContents(sha: old), "version one\n")
        XCTAssertEqual(GitClient(repoRoot: repo).blobContents(sha: new), "version two\n")
        XCTAssertNil(GitClient(repoRoot: repo).blobContents(sha: "deadbeef"),
                     "unknown sha degrades to nil, not a throw")
    }

    func test_diffOpenBlob_opensEphemeralPreviewWithBlobContents() throws {
        _ = commitFile("f.txt", "old body\n")
        let sha2 = commitFile("f.txt", "new body\n")
        let pairs = DiffWebPayload.blobPairs(GitClient(repoRoot: repo).commitDiff(sha: sha2))
        let oldSha = try XCTUnwrap(pairs[0].old)

        let doc = makeDoc()
        doc.diffOpenBlob(sha: oldSha, path: "f.txt", versionLabel: "old")
        XCTAssertEqual(doc.tabs.tabs.count, 1)
        let tab = doc.tabs.tabs[0]
        XCTAssertTrue(tab.isPreview, "version views are throwaway → ephemeral slot")
        XCTAssertTrue(tab.url?.lastPathComponent.hasPrefix("old-") == true,
                      "scratch file is version-labelled: \(tab.url?.lastPathComponent ?? "nil")")
        XCTAssertTrue(tab.url?.lastPathComponent.hasSuffix("f.txt") == true)
        if case .loaded(let f) = tab.state {
            XCTAssertEqual(f.contents, "old body\n")
        } else {
            XCTFail("blob tab must be .loaded")
        }
    }

    func test_diffOpenCurrentFile_opensWorkingTreeFile() {
        _ = commitFile("seed.txt", "seed\n")   // ensure repo has a commit
        try? FileManager.default.createDirectory(
            at: repo.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try? "working copy\n".write(
            to: repo.appendingPathComponent("sub/cur.txt"), atomically: true, encoding: .utf8)

        let doc = makeDoc()
        doc.diffOpenCurrentFile(path: "sub/cur.txt")
        XCTAssertEqual(doc.tabs.tabs.count, 1)
        XCTAssertEqual(doc.tabs.tabs[0].url?.lastPathComponent, "cur.txt")

        // A path that is NOT in the working tree degrades to a toast, no tab.
        doc.diffOpenCurrentFile(path: "sub/ghost.txt")
        XCTAssertEqual(doc.tabs.tabs.count, 1, "missing working-tree file opens nothing")
    }
}
