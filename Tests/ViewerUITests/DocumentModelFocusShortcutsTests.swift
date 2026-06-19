import XCTest
@testable import ViewerUI
@testable import ViewerCore
@testable import ViewerKit

/// Tests for the focus-shortcut family (TSK-937): "Focus Terminal",
/// "Focus File Navigator", "Focus Git Panel", "Focus Active File".
///
/// Each command moves keyboard focus to a specific surface by bumping a
/// per-target focus-request nonce (the same idiom as `editorFocusRequest`
/// / `gitPanelFocusRequest`), and each is enablement-gated on its target
/// surface's availability so a hidden target's menu item / palette entry
/// greys out. Model-only — the actual first-responder move is the VM tail;
/// here we pin the nonce + visibility contract a logic regression must trip.
@MainActor
final class DocumentModelFocusShortcutsTests: XCTestCase {

    private var tmpRoot: URL!

    override func setUp() async throws {
        // No super.setUp — @MainActor strict-concurrency.
        tmpRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("DocumentModelFocusShortcutsTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpRoot, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let tmpRoot { try? FileManager.default.removeItem(at: tmpRoot) }
    }

    /// A `DocumentModel` whose terminal-pane / layout persistence rides a
    /// throwaway `UserDefaults` suite, NOT `.standard`. The terminal pane
    /// restores its open-flag from defaults in `init`, so a model over
    /// `.standard` would (a) inherit whatever the real app last persisted —
    /// making "starts closed" unreliable under the parallel gate — and (b)
    /// write through to the owner's real terminal preference. The isolated
    /// suite makes the terminal-state tests hermetic + side-effect-free.
    private func isolatedModel() -> DocumentModel {
        let suite = UserDefaults(suiteName: "FocusShortcutsTests-\(UUID().uuidString)")!
        return DocumentModel(preferences: PreferencesStore(defaults: suite))
    }

    // MARK: - Nonce bumps

    func test_focusTerminal_bumpsNonceAndOpensPane() {
        // Isolated defaults ⇒ a reliably-closed pane (no persisted state).
        let m = isolatedModel()
        XCTAssertFalse(m.terminalPane.isOpen)
        let before = m.terminalFocusRequest
        m.focusTerminal()
        XCTAssertEqual(m.terminalFocusRequest, before &+ 1)
        // Focusing a closed terminal opens it so the surface can take focus.
        XCTAssertTrue(m.terminalPane.isOpen)
    }

    func test_focusTerminal_repeated_stillBumpsNonce() {
        // SwiftUI dedupes identical value publishes — the nonce must change
        // on EVERY ask so a second "Focus Terminal" isn't swallowed.
        let m = isolatedModel()
        m.focusTerminal()
        let after1 = m.terminalFocusRequest
        m.focusTerminal()
        XCTAssertEqual(m.terminalFocusRequest, after1 &+ 1)
    }

    func test_focusFileNav_bumpsNonce() {
        let m = DocumentModel()
        let before = m.fileNavFocusRequest
        m.focusFileNav()
        XCTAssertEqual(m.fileNavFocusRequest, before &+ 1)
    }

    func test_focusFileNav_withRoot_revealsSidebar() {
        let m = DocumentModel()
        m.sidebar.setRoot(tmpRoot)
        m.sidebar.isVisible = false
        m.focusFileNav()
        XCTAssertTrue(m.sidebar.isVisible,
                      "Focusing the file nav must reveal the sidebar that hosts it")
    }

    func test_focusGitPanel_bumpsGitFocusRequestAndSelectsStatus() {
        // Focus Git is a thin alias over showGitPanel(.status); it must
        // reuse the existing git-focus plumbing.
        let m = DocumentModel()
        let before = m.gitPanelFocusRequest
        m.focusGitPanel()
        XCTAssertEqual(m.gitPanelFocusRequest, before &+ 1)
        XCTAssertEqual(m.gitPanelDesiredTab, .status)
    }

    func test_focusActiveDocument_bumpsNonce() {
        let m = DocumentModel()
        let before = m.documentFocusRequest
        m.focusActiveDocument()
        XCTAssertEqual(m.documentFocusRequest, before &+ 1)
        m.focusActiveDocument()
        XCTAssertEqual(m.documentFocusRequest, before &+ 2)
    }

    // MARK: - Enablement gates (keyed on target visibility)

    func test_canFocusTerminal_tracksPaneOpen() {
        let m = isolatedModel()
        XCTAssertFalse(m.canFocusTerminal, "closed pane ⇒ disabled")
        m.terminalPane.setOpen(true)
        XCTAssertTrue(m.canFocusTerminal, "open pane ⇒ enabled")
        m.terminalPane.setOpen(false)
        XCTAssertFalse(m.canFocusTerminal, "re-closed pane ⇒ disabled again")
    }

    func test_canFocusFileNav_tracksRootPresence() {
        let m = DocumentModel()
        XCTAssertFalse(m.canFocusFileNav, "no folder root ⇒ disabled")
        m.sidebar.setRoot(tmpRoot)
        XCTAssertTrue(m.canFocusFileNav, "folder root open ⇒ enabled")
    }

    func test_canFocusGitPanel_requiresRepo() {
        let m = DocumentModel()
        // A bare temp dir is NOT a git repo: gate stays disabled even with a
        // root open (mirrors SidebarDataPresence `.git` = hasRoot && hasRepo).
        m.sidebar.setRoot(tmpRoot)
        XCTAssertFalse(m.canFocusGitPanel,
                       "root with no .git repo ⇒ Focus Git disabled")
    }

    func test_canFocusGitPanel_enabledInRepo() throws {
        let m = DocumentModel()
        // Make the temp dir a git repo by planting a `.git` marker dir, then
        // re-root so SidebarModel re-discovers `gitRepoRoot`.
        try FileManager.default.createDirectory(
            at: tmpRoot.appendingPathComponent(".git"),
            withIntermediateDirectories: true)
        m.sidebar.setRoot(tmpRoot)
        XCTAssertNotNil(m.sidebar.gitRepoRoot,
                        "planting .git should make the root a repo")
        XCTAssertTrue(m.canFocusGitPanel, "repo present ⇒ Focus Git enabled")
    }

    func test_canFocusActiveDocument_tracksSelectedTab() {
        let m = DocumentModel()
        // A fresh model has no selected tab ⇒ nothing to focus.
        XCTAssertEqual(m.canFocusActiveDocument, m.tabs.selected != nil,
                       "enablement must mirror tab selection")
    }

    // MARK: - Command-registry wiring (palette parity)

    func test_focusCommands_areRegistered_withScriptVerbs() {
        // The four focus actions must be palette-invokable (a scriptVerb) so
        // the command palette + automation reach them, not just the menu.
        let reg = CommandRegistry.builtIn
        let expected: [(id: String, verb: String)] = [
            ("view.focusTerminal", "focus-terminal"),
            ("view.focusFileNav", "focus-file-nav"),
            ("view.focusGit", "focus-git"),
            ("view.focusDocument", "focus-document"),
        ]
        for e in expected {
            let cmd = reg.command(id: e.id)
            XCTAssertNotNil(cmd, "missing command \(e.id)")
            XCTAssertEqual(cmd?.scriptVerb, e.verb,
                           "\(e.id) must dispatch via \(e.verb)")
        }
    }

    func test_focusCommands_haveNoDefaultShortcut() {
        // TSK-936 concern: the obvious focus keys overlap existing bindings,
        // so these ship WITHOUT a default key-equivalent (discoverable via
        // menu + palette; key choice is a deliberate follow-up). Guard that
        // we don't accidentally introduce a conflicting default.
        let reg = CommandRegistry.builtIn
        for id in ["view.focusTerminal", "view.focusFileNav",
                   "view.focusGit", "view.focusDocument"] {
            XCTAssertNil(reg.command(id: id)?.defaultShortcut,
                         "\(id) must not ship a default shortcut (TSK-936)")
        }
    }
}
