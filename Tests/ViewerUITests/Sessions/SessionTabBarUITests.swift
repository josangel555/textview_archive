import XCTest
import Foundation

/// L4 live-app coverage for the Phase-1 SessionTabBar
/// (`Sources/ViewerUI/Sessions/SessionTabBar.swift`).
///
/// Phase-1 session model: the launcher boots with
/// `MDV_SKIP_WORKSPACE_RESTORE=1`, so the coordinator starts empty;
/// the script verb `session-open-folder` triggers the same coordinator
/// path the UI's `+` button hits.
///
/// We assert on `dump.model.sessions` + `model.activeSessionID` rather
/// than chasing SwiftUI a11y identifiers — those surface
/// inconsistently on the realised NSView (same caveat that
/// `TabBarPage` documents).
@MainActor
final class SessionTabBarUITests: MultiScenarioTestCase {

    override class var harnessLabel: String { "SessionTabBarUI" }
    override class var defaultScenarioTimeout: TimeInterval { 20 }

    private func makeFolder(_ name: String, fileBody: String = "# Hello\n") throws -> URL {
        let dir = try harness.makeDir(name)
        try fileBody.write(
            to: dir.appendingPathComponent("doc.md"),
            atomically: true, encoding: .utf8)
        return dir
    }

    // MARK: - Tests

    func test_basicSessionPillLifecycle() throws {
        let folderA = try makeFolder("ProjectA")
        let argFile = folderA.appendingPathComponent("doc.md")

        try runScenarios([
            // Opening a folder via the sessions coordinator (the same
            // call path as the `+` button) registers a session pill
            // and marks it active.
            Scenario(
                name: "renders-active-session-pill",
                argFile: argFile,
                script: """
                    session-open-folder \(folderA.path)
                    """
            ) { dumps, file, line in
                XCTAssertEqual(dumps.count, 1, file: file, line: line)
                let page = Pages(dump: dumps[0]).sessionTabBar
                page.assertSessionCount(1, file: file, line: line)
                page.assertActiveSessionName("ProjectA", file: file, line: line)
                page.assertActiveSessionRoot(endsWith: "ProjectA", file: file, line: line)
            },

            // (Deleted: the `shows-plus-button` scenario was a no-op —
            // it discarded `page.newSessionButton` (the a11y id never
            // propagates to the realised NSView, so the probe was always
            // best-effort/nil) and only re-asserted `assertSessionCount(1)`,
            // a duplicate of the load-bearing check above. Testing-pyramid
            // migration §3.2.)
        ])
    }

    func test_openInNewSession_addsPillAndActivates() throws {
        let folderA = try makeFolder("ProjA")
        let folderB = try makeFolder("ProjB")
        let argFile = folderA.appendingPathComponent("doc.md")

        try runScenarios([
            // Two distinct folders — the second openFolder call must
            // append a new pill (sessionCount goes 1 → 2) and the
            // active pill flips to the newer session.
            Scenario(
                name: "second-folder-creates-new-pill",
                argFile: argFile,
                script: """
                    session-open-folder \(folderA.path)
                    session-open-folder \(folderB.path)
                    """
            ) { dumps, file, line in
                XCTAssertEqual(dumps.count, 2, file: file, line: line)
                let afterA = Pages(dump: dumps[0]).sessionTabBar
                let afterB = Pages(dump: dumps[1]).sessionTabBar
                afterA.assertSessionCount(1, file: file, line: line)
                afterA.assertActiveSessionName("ProjA", file: file, line: line)
                afterB.assertSessionCount(2, file: file, line: line)
                afterB.assertActiveSessionName("ProjB", file: file, line: line)
            },

            // Re-opening the same folder must NOT create a duplicate
            // pill — the coordinator de-dupes on resolved sidebar
            // root path. forceNew (`session-open-new`) bypasses the
            // dedupe, which is what the "Open in New Session" context
            // menu does.
            Scenario(
                name: "force-new-session-bypasses-dedupe",
                argFile: argFile,
                script: """
                    session-open-folder \(folderA.path)
                    session-open-folder \(folderA.path)
                    session-open-new \(folderA.path)
                    """
            ) { dumps, file, line in
                XCTAssertEqual(dumps.count, 3, file: file, line: line)
                let s1 = Pages(dump: dumps[0]).sessionTabBar
                let s2 = Pages(dump: dumps[1]).sessionTabBar
                let s3 = Pages(dump: dumps[2]).sessionTabBar
                s1.assertSessionCount(1, file: file, line: line)
                s2.assertSessionCount(1, file: file, line: line)
                s3.assertSessionCount(2, file: file, line: line)
            },
        ])
    }

    func test_renameUpdatesPillLabel() throws {
        let folderA = try makeFolder("OrigName")
        let argFile = folderA.appendingPathComponent("doc.md")

        try runScenarios([
            Scenario(
                name: "rename-changes-displayName",
                argFile: argFile,
                script: """
                    session-open-folder \(folderA.path)
                    session-rename Renamed
                    """
            ) { dumps, file, line in
                XCTAssertEqual(dumps.count, 2, file: file, line: line)
                let before = Pages(dump: dumps[0]).sessionTabBar
                let after = Pages(dump: dumps[1]).sessionTabBar
                before.assertActiveSessionName("OrigName", file: file, line: line)
                after.assertActiveSessionName("Renamed", file: file, line: line)
                after.assertSessionCount(1, file: file, line: line)
            },

            // Empty/whitespace rename is a no-op per
            // SessionsAppCoordinator.rename. The dump must still show
            // the original name.
            Scenario(
                name: "empty-rename-is-no-op",
                argFile: argFile,
                script: """
                    session-open-folder \(folderA.path)
                    session-rename
                    """
            ) { dumps, file, line in
                XCTAssertEqual(dumps.count, 2, file: file, line: line)
                let after = Pages(dump: dumps[1]).sessionTabBar
                after.assertActiveSessionName("OrigName", file: file, line: line)
                after.assertSessionCount(1, file: file, line: line)
            },
        ])
    }
}
