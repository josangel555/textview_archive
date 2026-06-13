import XCTest
import AppKit
@testable import ViewerUI
import ViewerCore

/// TSK-741 — `TerminalNSView.update` installs a new screen only when the model's
/// monotonic `version` changed, replacing a per-frame deep value-compare of the
/// whole screen (`cells` + up to ~1256 scrollback rows) that ran on the MAIN
/// thread once per coalesced frame. With a full scrollback that `==` was the
/// residual large-paste ANR (e.g. big JSON echoed by vim). `version` is the
/// authoritative change signal, so an unchanged version means identical content
/// and nothing to reinstall.
///
/// These pin the gate's BEHAVIOUR host-side via `diagnosticGridInfo()`. TEETH:
/// revert `update` to `if self.screen != screen { … }` and
/// `test_sameVersion_doesNotReinstall_evenWhenContentDiffers` goes red (the deep
/// compare would install the differing screen). The felt no-beachball is the VM
/// confirm; this guards that the per-frame deep compare is gone.
@MainActor
final class TerminalUpdateVersionGateTests: HeadlessUITestCase {

    private func screen(_ text: String) -> TerminalScreen {
        var s = TerminalScreen(rows: 24, cols: 80)
        for ch in text { s.write(ch) }
        return s
    }

    func test_firstUpdate_installsRegardlessOfVersionValue() {
        // lastScreenVersion starts nil, so the initial snapshot always lands.
        let view = TerminalNSView(initialScreen: TerminalScreen(rows: 24, cols: 80), fontSize: 13)
        view.update(screen: screen("hello"), version: 0, fontSize: 13)
        XCTAssertEqual(view.diagnosticGridInfo()["nonBlankRowCount"] as? Int, 1,
                       "the first update installs the screen even at version 0")
    }

    func test_sameVersion_doesNotReinstall_evenWhenContentDiffers() {
        let view = TerminalNSView(initialScreen: TerminalScreen(rows: 24, cols: 80), fontSize: 13)
        view.update(screen: screen("user@host %"), version: 7, fontSize: 13)
        XCTAssertEqual(view.diagnosticGridInfo()["firstNonBlankRow"] as? Int, 0,
                       "precondition: the content screen is installed")

        // Same version, DIFFERENT content (a blank screen). The version gate
        // must skip the install — version is the authority, not the content.
        view.update(screen: TerminalScreen(rows: 24, cols: 80), version: 7, fontSize: 13)
        XCTAssertEqual(view.diagnosticGridInfo()["nonBlankRowCount"] as? Int, 1,
                       "an unchanged version is a no-op — the prior content stays (no deep compare)")
    }

    func test_versionBump_installsTheNewScreen() {
        let view = TerminalNSView(initialScreen: TerminalScreen(rows: 24, cols: 80), fontSize: 13)
        view.update(screen: screen("first"), version: 1, fontSize: 13)
        XCTAssertEqual(view.diagnosticGridInfo()["nonBlankRowCount"] as? Int, 1)

        // A higher version DOES install — here a blank screen clears the grid.
        view.update(screen: TerminalScreen(rows: 24, cols: 80), version: 2, fontSize: 13)
        XCTAssertEqual(view.diagnosticGridInfo()["nonBlankRowCount"] as? Int, 0,
                       "a version bump installs the new screen")
    }

    func test_fontSizeChange_appliesEvenWhenVersionUnchanged() {
        // Zoom changes the font without a screen-version bump; that path must
        // still take effect (it sets `changed` independently of the gate).
        let view = TerminalNSView(initialScreen: screen("x"), fontSize: 13)
        view.update(screen: screen("x"), version: 5, fontSize: 13)
        // Same version again but a new font size — must not be swallowed.
        view.update(screen: screen("x"), version: 5, fontSize: 20)
        // No crash / no stale grid; the content is intact.
        XCTAssertEqual(view.diagnosticGridInfo()["nonBlankRowCount"] as? Int, 1)
    }
}
