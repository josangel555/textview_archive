import XCTest
import Foundation
import ViewerCore
@testable import ViewerUI

/// TSK-459 — backgrounded terminal tabs must stop bumping `version` (the
/// UI re-render trigger) while still feeding the parser, and foreground
/// re-entry must force exactly one refresh bump.
///
/// The audited waste: a deselected tab's chatty shell kept scheduling
/// main-actor `version &+= 1` hops ~60x/s with NO mounted observer
/// (`.id(selectedTabID)` tears the representable down). The fix gates the
/// bump on a thread-safe foreground flag read in the PTY output callback
/// BEFORE the Task hop. These tests drive the REAL output path (a live
/// `forkpty` shell — host-safe, no window/GUI/TCC; same floor as the
/// PTYProcess lifecycle tests) so the exact production closure is what's
/// exercised, not a reimplementation.
@MainActor
final class TerminalForegroundBumpTests: HeadlessUITestCase {

    /// Spin until `predicate()` holds or `timeout` elapses, draining the
    /// main run loop so `Task { @MainActor }` bumps can land.
    private func waitUntil(
        timeout: TimeInterval = 10.0,
        _ predicate: () -> Bool
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        return predicate()
    }

    func test_backgroundOutput_feedsParser_withoutVersionBump() throws {
        let model = TerminalModel(rows: 24, cols: 80)
        defer { model.stop() }

        // Background BEFORE any output exists — every byte the shell emits
        // from here on (prompt included) is unobserved.
        model.setForeground(false)
        XCTAssertFalse(model.isForeground)
        XCTAssertEqual(model.version, 0)

        model.start()
        model.sendString("printf 'BG-MARKER-459\\n'\n")

        // The parser must keep eating output while backgrounded (scrollback
        // stays current for the eventual tab switch)…
        XCTAssertTrue(
            waitUntil { model.screenSnapshot.plainText().contains("BG-MARKER-459") },
            "backgrounded shell output never reached the parser — feed must not be gated"
        )
        // …but the UI version must never have bumped: no mounted observer,
        // so any bump is the exact waste TSK-459 removed.
        XCTAssertEqual(model.version, 0,
            "backgrounded output bumped version — the foreground gate is broken (TSK-459)")

        // Foreground re-entry: exactly one synchronous refresh bump so the
        // freshly-shown view picks up everything that accumulated.
        model.setForeground(true)
        XCTAssertEqual(model.version, 1,
            "foreground re-entry must force exactly one refresh bump")

        // And live output resumes bumping once foregrounded.
        model.sendString("printf 'FG-MARKER-459\\n'\n")
        XCTAssertTrue(waitUntil { model.version > 1 },
            "foreground output must resume scheduling UI bumps")
    }

    func test_setForeground_sameValue_doesNotBump() {
        let model = TerminalModel(rows: 24, cols: 80)
        XCTAssertTrue(model.isForeground, "a fresh model defaults to foreground")
        let v = model.version
        model.setForeground(true)
        XCTAssertEqual(model.version, v,
            "re-asserting the current foreground state must not churn a bump")
    }
}
