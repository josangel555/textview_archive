import XCTest
import Foundation

/// T1m coverage for "Open in New Session" — exercised both via the
/// SidebarView file-row context menu and the BookmarksSection row menu in
/// the live app. Both paths funnel through
/// `DocumentModel.openFolderInNewSession`, which the AppDelegate wires
/// to `SessionsAppCoordinator.openFolder(_, forceNew: true)`.
///
/// SwiftUI context menus are not introspectable from a JSON dump
/// (`OpenInNewSessionTests` documents this constraint), so we drive
/// the model callback through two script verbs that share the same
/// coordinator entry point as the live menu items:
///
///   - `session-open-new <path>` — invokes the coordinator directly
///     (same call AppDelegate.openFolderInNewSession(_:) makes).
///   - `goto-commit-new-session <path>` — exercises the alternate
///     entry point: ⇧⏎ in the GoToPath prompt for a folder path.
///
/// Together they cover both the right-click and keyboard-path
/// open-in-new-session entry points listed under §1 of
/// docs/UI_TEST_GAPS_2026-05-22.md.
///
/// (History: this spawned `dist/TextView.app`. Every assertion reads
/// `dump.model.sessions` / `activeSessionID`, the goToPath flags, or the
/// window title — all pure coordinator/model state — so the migration
/// (§3.2, same class as `SessionTabBarUITests` / `SessionsKeyboardUITests`)
/// demoted it to in-process T1m. Keeping it at T4 would have falsified the
/// §3.4 "real-screen-only set is exactly {SourceViewVisualRegression,
/// launch-smoke, resize, relaunch-persistence}" claim.)
@MainActor
final class OpenInNewSessionUITests: HeadlessMultiScenarioTestCase {

    override class var harnessLabel: String { "OpenInNewSessionUI" }

    private func makeFolder(_ name: String) throws -> URL {
        let dir = try harness.makeDir(name)
        try "# \(name)\n".write(
            to: dir.appendingPathComponent("doc.md"),
            atomically: true, encoding: .utf8)
        return dir
    }

    // MARK: - Tests

    func test_treeContextMenuOpensInNewSession() throws {
        let folderA = try makeFolder("First")
        let folderB = try makeFolder("Second")
        let argFile = folderA.appendingPathComponent("doc.md")

        try runScenarios([
            // The right-click → "Open in New Session" path. Calling
            // `session-open-new` on a folder NOT yet in the session
            // list appends a fresh session AND activates it.
            Scenario(
                name: "fresh-folder-appends-and-activates",
                argFile: argFile,
                script: """
                    session-open-folder \(folderA.path)
                    session-open-new \(folderB.path)
                    """
            ) { dumps, file, line in
                XCTAssertEqual(dumps.count, 2, file: file, line: line)
                let pre = Pages(dump: dumps[0]).sessionTabBar
                let post = Pages(dump: dumps[1]).sessionTabBar
                pre.assertSessionCount(1, file: file, line: line)
                post.assertSessionCount(2, file: file, line: line)
                post.assertActiveSessionName("Second", file: file, line: line)
                post.assertActiveSessionRoot(endsWith: "Second",
                                             file: file, line: line)
            },

            // forceNew bypass: when the same folder is already an
            // existing session, the right-click menu still opens a
            // distinct second pill (worktrees / symlink chains use
            // this path).
            Scenario(
                name: "duplicate-folder-still-creates-second-pill",
                argFile: argFile,
                script: """
                    session-open-folder \(folderA.path)
                    session-open-new \(folderA.path)
                    """
            ) { dumps, file, line in
                XCTAssertEqual(dumps.count, 2, file: file, line: line)
                let post = Pages(dump: dumps[1]).sessionTabBar
                post.assertSessionCount(2, file: file, line: line)
                post.assertActiveSessionName("First", file: file, line: line)
            },
        ])
    }

    func test_goToPathShiftEnterOpensInNewSession() throws {
        let folderA = try makeFolder("Origin")
        let folderB = try makeFolder("Pasted")
        let argFile = folderA.appendingPathComponent("doc.md")

        try runScenarios([
            // ⇧⏎ in the GoToPath prompt for a folder path is the
            // keyboard equivalent of the right-click "Open in New
            // Session" menu item. Same observable effect.
            Scenario(
                name: "shift-enter-folder-creates-session",
                argFile: argFile,
                script: """
                    session-open-folder \(folderA.path)
                    show-goto
                    goto-commit-new-session \(folderB.path)
                    """
            ) { dumps, file, line in
                XCTAssertEqual(dumps.count, 3, file: file, line: line)
                let pre = Pages(dump: dumps[0]).sessionTabBar
                let post = Pages(dump: dumps[2])
                pre.assertSessionCount(1, file: file, line: line)
                post.sessionTabBar.assertSessionCount(2, file: file, line: line)
                post.sessionTabBar.assertActiveSessionName("Pasted",
                                                           file: file, line: line)
                post.goToPath.assertDismissed(file: file, line: line)
                post.goToPath.assertNoError(file: file, line: line)
            },

            // For a FILE (not directory) ⇧⏎ falls back to regular
            // open (same tab), per `commitGoToPath`'s contract. The
            // session list must NOT grow.
            Scenario(
                name: "shift-enter-file-falls-back-to-open-in-place",
                argFile: argFile,
                script: """
                    session-open-folder \(folderA.path)
                    show-goto
                    goto-commit-new-session \(folderB.appendingPathComponent("doc.md").path)
                    """
            ) { dumps, file, line in
                XCTAssertEqual(dumps.count, 3, file: file, line: line)
                let post = Pages(dump: dumps[2])
                post.sessionTabBar.assertSessionCount(1, file: file, line: line)
                post.goToPath.assertDismissed(file: file, line: line)
                post.tabBar.assertActiveTab(named: "doc.md",
                                            file: file, line: line)
            },
        ])
    }
}
