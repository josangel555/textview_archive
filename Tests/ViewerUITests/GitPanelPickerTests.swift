import XCTest
import Combine
import ViewerCore
@testable import ViewerUI

/// Host-safe @MainActor tests for the Git-panel multi-repo follow/pick
/// behavior. Exercises `GitPanelModel.followFocus(_:tracked:)` +
/// `pickRepoRoot(_:)` as a pure state machine (no app launch), and the
/// end-to-end "focusedRoot follows the current tab's repo" path through a
/// real DocumentModel with two temp-dir git repos.
///
/// These never spin up an NSApplication / window — `GitPanelModel` is a
/// plain @MainActor ObservableObject and DocumentModel's focus tracking is
/// model-level, so they're safe on the host per CLAUDE.md.
@MainActor
final class GitPanelPickerTests: XCTestCase {

    private var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("mdv-gitpanel-picker-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    private func norm(_ u: URL) -> URL { TrackedReposReducer.normalize(u) }

    // MARK: - followFocus state machine (pure, no app)

    func test_followFocus_followsFocusedRoot_whenNoPin() {
        let panel = GitPanelModel()
        let a = norm(tmp.appendingPathComponent("A"))
        let b = norm(tmp.appendingPathComponent("B"))

        panel.followFocus(a, tracked: [a, b])
        XCTAssertEqual(panel.repoRoot, a, "panel follows the focused root")

        panel.followFocus(b, tracked: [a, b])
        XCTAssertEqual(panel.repoRoot, b, "panel re-follows when focus moves")
    }

    func test_pick_pinsPanel_survivesFocusOnSameRepo() {
        let panel = GitPanelModel()
        let a = norm(tmp.appendingPathComponent("A"))
        let b = norm(tmp.appendingPathComponent("B"))

        // User explicitly picks B while focus is on A.
        panel.followFocus(a, tracked: [a, b])
        panel.pickRepoRoot(b)
        XCTAssertEqual(panel.repoRoot, b)
        XCTAssertEqual(panel.userPinnedPanelRoot, b)

        // A focus event that stays on the SAME repo (B) must keep the pin.
        panel.followFocus(b, tracked: [a, b])
        XCTAssertEqual(panel.repoRoot, b, "pin holds when focus is on the picked repo")
        XCTAssertEqual(panel.userPinnedPanelRoot, b)

        // A nil focus (e.g. a non-repo tab) must NOT release the pin either
        // — only focus on a *different tracked repo* releases it.
        panel.followFocus(nil, tracked: [a, b])
        XCTAssertEqual(panel.repoRoot, b, "pin holds across a nil-focus event")
        XCTAssertEqual(panel.userPinnedPanelRoot, b)
    }

    func test_pick_releasedWhenFocusMovesToDifferentRepo() {
        let panel = GitPanelModel()
        let a = norm(tmp.appendingPathComponent("A"))
        let b = norm(tmp.appendingPathComponent("B"))
        let c = norm(tmp.appendingPathComponent("C"))

        panel.pickRepoRoot(b)
        XCTAssertEqual(panel.userPinnedPanelRoot, b)

        // Focus moves to a DIFFERENT tracked repo → pin released, follow
        // resumes on the new focused root.
        panel.followFocus(c, tracked: [a, b, c])
        XCTAssertNil(panel.userPinnedPanelRoot, "explicit pick released when focus moves to another repo")
        XCTAssertEqual(panel.repoRoot, c, "follow resumes on the new focused repo")
    }

    func test_pick_releasedWhenPinnedRootDropsFromTrackedSet() {
        let panel = GitPanelModel()
        let a = norm(tmp.appendingPathComponent("A"))
        let b = norm(tmp.appendingPathComponent("B"))

        panel.pickRepoRoot(b)
        // B is evicted from the tracked set (e.g. its last tab closed +
        // grace elapsed). The pin can't hold a dropped root → release +
        // follow whatever's focused now (A).
        panel.followFocus(a, tracked: [a])
        XCTAssertNil(panel.userPinnedPanelRoot, "pin released when its root drops from the tracked set")
        XCTAssertEqual(panel.repoRoot, a)
    }

    // MARK: - setRepoRoot dedup guard still holds

    func test_setRepoRoot_dedupGuard() {
        let panel = GitPanelModel()
        let a = norm(tmp.appendingPathComponent("A"))
        panel.setRepoRoot(a)

        // Re-setting the SAME root must hit the early-return guard
        // (GitPanelModel:97) — no @Published mutation, hence no
        // objectWillChange fires. Observing the publisher is type-free and
        // proves the guard short-circuits before clearing caches / refresh.
        var republishes = 0
        let sub = panel.objectWillChange.sink { _ in republishes += 1 }
        defer { sub.cancel() }
        panel.setRepoRoot(a)
        XCTAssertEqual(republishes, 0,
            "re-setting the same root is a no-op (dedup guard at GitPanelModel:97)")
    }

    // MARK: - Republish invariant for the panel's registry observation

    /// The panel is driven by `trackedRepos.version` (a sibling
    /// observable), and `followFocus` / `pickRepoRoot` republish the
    /// PANEL — never DocumentModel. A regression here (e.g. someone
    /// forwarding the panel's changes into the model) re-introduces the
    /// republish storm now amplified by FSEvents. Mirrors the core
    /// `TrackedReposRepublishInvariantTests` shape for the panel surface.
    func test_panelFollow_doesNotRepublishDocumentModel() async {
        let model = makeModel()
        await Task.yield()
        let panel = GitPanelModel()
        let a = norm(tmp.appendingPathComponent("A"))
        let b = norm(tmp.appendingPathComponent("B"))

        var docRepublishes = 0
        let sub = model.objectWillChange.sink { _ in docRepublishes += 1 }
        defer { sub.cancel() }

        // The consumer-phase drive path: followFocus + an explicit pick.
        panel.followFocus(a, tracked: [a, b])
        panel.pickRepoRoot(b)
        panel.followFocus(a, tracked: [a, b])  // releases pin → follow a
        await Task.yield()

        XCTAssertEqual(docRepublishes, 0,
            "panel follow/pick must not route through DocumentModel.objectWillChange")
    }

    // MARK: - Integration: focusedRoot follows the current tab's repo

    func test_focusedRoot_followsCurrentTab_acrossTwoRepos() async throws {
        try requireGit()
        let repoA = tmp.appendingPathComponent("repoA")
        let repoB = tmp.appendingPathComponent("repoB")
        try makeRepo(at: repoA)
        try makeRepo(at: repoB)
        let fileA = repoA.appendingPathComponent("a.md")
        let fileB = repoB.appendingPathComponent("b.md")
        try "A".write(to: fileA, atomically: true, encoding: .utf8)
        try "B".write(to: fileB, atomically: true, encoding: .utf8)

        let model = makeModel()
        model.open(url: fileA)
        try await settle()
        XCTAssertEqual(model.repoFocus.focusedRoot, norm(repoA),
            "focusedRoot follows the selected tab into repo A")

        // Open a file in the OTHER repo — focus follows the new tab.
        model.open(url: fileB)
        try await settle()
        XCTAssertEqual(model.repoFocus.focusedRoot, norm(repoB),
            "focusedRoot follows the selected tab into repo B")
    }

    // MARK: - helpers

    private func makeModel() -> DocumentModel {
        DocumentModel(
            controller: DocumentController(),
            history: HistoryStore(storeURL: tmp.appendingPathComponent("h.json")),
            sidebar: SidebarModel(),
            preferences: PreferencesStore(
                defaults: UserDefaults(suiteName: "GitPanelPicker-\(UUID().uuidString)")!
            )
        )
    }

    /// Give the async recompute + store retain/refresh chain time to land.
    private func settle() async throws {
        try? await Task.sleep(nanoseconds: 500_000_000)
        await Task.yield()
    }

    private func requireGit() throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/git") else {
            throw XCTSkip("git not available")
        }
    }

    @discardableResult
    private func runGit(_ args: [String], in dir: URL) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.currentDirectoryURL = dir
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe; p.standardError = pipe
        try p.run(); p.waitUntilExit()
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }

    private func makeRepo(at dir: URL) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        _ = try runGit(["init", "-q"], in: dir)
        _ = try runGit(["config", "user.email", "t@e.com"], in: dir)
        _ = try runGit(["config", "user.name", "T"], in: dir)
    }
}
