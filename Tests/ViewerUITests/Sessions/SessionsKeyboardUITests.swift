import XCTest
import Foundation

/// L4 coverage for session keyboard dispatch (⌃Tab / ⌃1-9 / ⇧⌘W).
/// The AppLauncher harness can't synthesise keyboard events through
/// the macOS event loop (the .app is started headless via Process,
/// no XCUIApplication), so we drive the same SessionsAppCoordinator
/// methods the key bindings call: `session-next` / `session-prev` /
/// `session-activate <index>` / `session-close-active`.
///
/// What this gives us:
///   - The coordinator-level routing through the actions is correct
///     (active id flips, LRU re-activation on close, no off-by-one
///     on the index-based activate).
///   - Each dump still goes through the same dump → Pages → asserter
///     pipeline as a keyboard-driven test would, so when the VM gains
///     real key dispatch later, only the verb lines change.
///
/// What this does NOT cover (intentional):
///   - The macOS key binding dispatch chain itself (`NSEvent`
///     monitor → menu action selector). That's a separate concern
///     verified manually until the harness grows real key support.
@MainActor
final class SessionsKeyboardUITests: MultiScenarioTestCase {

    override class var harnessLabel: String { "SessionsKeyboardUI" }
    override class var defaultScenarioTimeout: TimeInterval { 25 }

    private func makeFolder(_ name: String) throws -> URL {
        let dir = try harness.makeDir(name)
        try "# \(name)\n".write(
            to: dir.appendingPathComponent("doc.md"),
            atomically: true, encoding: .utf8)
        return dir
    }

    // MARK: - Tests

    func test_activateByIndexSwitchesSessions() throws {
        let folderA = try makeFolder("Alpha")
        let folderB = try makeFolder("Bravo")
        let folderC = try makeFolder("Charlie")
        let argFile = folderA.appendingPathComponent("doc.md")

        try runScenarios([
            // ⌃2 equivalent: open three sessions, then activate index 1
            // (the second pill, "Bravo"). The active id and active
            // display name flip without changing the session count.
            Scenario(
                name: "activate-index-2",
                argFile: argFile,
                script: """
                    session-open-folder \(folderA.path)
                    session-open-folder \(folderB.path)
                    session-open-folder \(folderC.path)
                    session-activate 2
                    """
            ) { dumps, file, line in
                XCTAssertEqual(dumps.count, 4, file: file, line: line)
                let pre = Pages(dump: dumps[2]).sessionTabBar
                let post = Pages(dump: dumps[3]).sessionTabBar
                pre.assertSessionCount(3, file: file, line: line)
                pre.assertActiveSessionName("Charlie", file: file, line: line)
                post.assertSessionCount(3, file: file, line: line)
                post.assertActiveSessionName("Bravo", file: file, line: line)
            },

            // ⌃1 equivalent: re-target the first pill.
            Scenario(
                name: "activate-index-1",
                argFile: argFile,
                script: """
                    session-open-folder \(folderA.path)
                    session-open-folder \(folderB.path)
                    session-activate 1
                    """
            ) { dumps, file, line in
                XCTAssertEqual(dumps.count, 3, file: file, line: line)
                let post = Pages(dump: dumps[2]).sessionTabBar
                post.assertActiveSessionName("Alpha", file: file, line: line)
            },
        ])
    }

    func test_nextAndPrevWrapAround() throws {
        let folderA = try makeFolder("S1")
        let folderB = try makeFolder("S2")
        let folderC = try makeFolder("S3")
        let argFile = folderA.appendingPathComponent("doc.md")

        try runScenarios([
            // ⌃Tab equivalent: next walks forward; from the last
            // session it wraps to the first.
            Scenario(
                name: "next-walks-forward-with-wraparound",
                argFile: argFile,
                script: """
                    session-open-folder \(folderA.path)
                    session-open-folder \(folderB.path)
                    session-open-folder \(folderC.path)
                    session-activate 1
                    session-next
                    session-next
                    session-next
                    """
            ) { dumps, file, line in
                XCTAssertEqual(dumps.count, 7, file: file, line: line)
                // After session-activate 1 → S1 active.
                XCTAssertEqual(
                    Pages(dump: dumps[3]).sessionTabBar.activeSessionName,
                    "S1", file: file, line: line)
                // Three nexts cycle S1 → S2 → S3 → S1.
                XCTAssertEqual(
                    Pages(dump: dumps[4]).sessionTabBar.activeSessionName,
                    "S2", file: file, line: line)
                XCTAssertEqual(
                    Pages(dump: dumps[5]).sessionTabBar.activeSessionName,
                    "S3", file: file, line: line)
                XCTAssertEqual(
                    Pages(dump: dumps[6]).sessionTabBar.activeSessionName,
                    "S1", file: file, line: line)
            },

            // ⇧⌃Tab equivalent: prev walks backward; from the first
            // session it wraps to the last.
            Scenario(
                name: "prev-walks-backward-with-wraparound",
                argFile: argFile,
                script: """
                    session-open-folder \(folderA.path)
                    session-open-folder \(folderB.path)
                    session-open-folder \(folderC.path)
                    session-activate 1
                    session-prev
                    """
            ) { dumps, file, line in
                XCTAssertEqual(dumps.count, 5, file: file, line: line)
                // S1 active → prev wraps to S3.
                XCTAssertEqual(
                    Pages(dump: dumps[4]).sessionTabBar.activeSessionName,
                    "S3", file: file, line: line)
            },
        ])
    }

    func test_closeActiveDropsAndReactivates() throws {
        let folderA = try makeFolder("ToKeep")
        let folderB = try makeFolder("ToClose")
        let argFile = folderA.appendingPathComponent("doc.md")

        try runScenarios([
            // ⇧⌘W equivalent: closing the active session removes its
            // pill and the LRU machinery re-activates the surviving
            // session.
            Scenario(
                name: "close-active-leaves-other-session-active",
                argFile: argFile,
                script: """
                    session-open-folder \(folderA.path)
                    session-open-folder \(folderB.path)
                    session-close-active
                    """
            ) { dumps, file, line in
                XCTAssertEqual(dumps.count, 3, file: file, line: line)
                let pre = Pages(dump: dumps[1]).sessionTabBar
                let post = Pages(dump: dumps[2]).sessionTabBar
                pre.assertSessionCount(2, file: file, line: line)
                pre.assertActiveSessionName("ToClose", file: file, line: line)
                post.assertSessionCount(1, file: file, line: line)
                post.assertActiveSessionName("ToKeep", file: file, line: line)
            },

            // Closing the last session leaves the strip empty
            // (activeSessionID = ""); the model still exists, but no
            // pill is rendered.
            Scenario(
                name: "close-last-clears-active",
                argFile: argFile,
                script: """
                    session-open-folder \(folderA.path)
                    session-close-active
                    """
            ) { dumps, file, line in
                XCTAssertEqual(dumps.count, 2, file: file, line: line)
                let post = Pages(dump: dumps[1]).sessionTabBar
                post.assertSessionCount(0, file: file, line: line)
                XCTAssertEqual(post.activeSessionID, "",
                    "Expected activeSessionID to clear after closing the last session, got '\(post.activeSessionID)'",
                    file: file, line: line)
            },
        ])
    }
}
