import XCTest
import Foundation
import ViewerKit
import ViewerCore
@testable import ViewerUI

/// Wiring coverage for two more commands that gained script verbs for
/// Omni-invokability (they shipped `scriptVerb: nil` — menu/keyboard-only):
/// git.showPanel → show-git-panel, view.toggleLineBookmark →
/// toggle-line-bookmark. Both wire to existing @MainActor model methods.
/// The harness injects a throwaway bookmarks store, so the line-bookmark
/// test never touches the real user bookmarks file.
@MainActor
final class GitPanelAndLineBookmarkVerbTests: HeadlessUITestCase {

    private var harness: HeadlessHarness!

    override func setUp() async throws {
        try await super.setUp()
        harness = HeadlessHarness(label: "GitPanelAndLineBookmarkVerbTests")
    }

    override func tearDown() async throws {
        harness?.cleanup()
        harness = nil
        try await super.tearDown()
    }

    func test_showGitPanelVerb_bumpsFocusRequest() {
        let model = harness.model
        let before = model.gitPanelFocusRequest
        XCTAssertTrue(ScriptVerb.apply(verb: "show-git-panel", to: model, sessions: harness.sessions))
        XCTAssertEqual(model.gitPanelFocusRequest, before + 1,
                       "show-git-panel must request focus of the Git panel")
    }

    func test_toggleLineBookmarkVerb_addsThenRemovesCurrentLineBookmark() throws {
        let url = try harness.writeFile("lb.txt", "one\ntwo\nthree\nfour\n")
        let model = harness.model
        model.open(url: url)
        // Seed a caret on line 3 (the toggle guards on line > 0).
        model.sourceSelection = SourceSelection(line: 3, column: 1, length: 0)

        XCTAssertTrue(ScriptVerb.apply(verb: "toggle-line-bookmark", to: model, sessions: harness.sessions))
        XCTAssertTrue(model.bookmarks.contains { $0.url == url && $0.line == 3 },
                      "toggle-line-bookmark must add a bookmark for the current line")

        // Toggling again on the same line removes it.
        XCTAssertTrue(ScriptVerb.apply(verb: "toggle-line-bookmark", to: model, sessions: harness.sessions))
        XCTAssertFalse(model.bookmarks.contains { $0.url == url && $0.line == 3 },
                       "a second toggle must remove the line bookmark")
    }

    func test_toggleLineBookmark_noSelection_isNoOp() throws {
        let url = try harness.writeFile("lb2.txt", "x\n")
        let model = harness.model
        model.open(url: url)
        model.sourceSelection = SourceSelection(line: 0, column: 0, length: 0)
        let countBefore = model.bookmarks.count
        XCTAssertTrue(ScriptVerb.apply(verb: "toggle-line-bookmark", to: model, sessions: harness.sessions))
        XCTAssertEqual(model.bookmarks.count, countBefore,
                       "line 0 (no caret) must not create a bookmark")
    }

    func test_bothCommands_arePaletteInvokable() {
        for id in ["git.showPanel", "view.toggleLineBookmark"] {
            XCTAssertNotNil(CommandRegistry.builtIn.command(id: id)?.scriptVerb)
            XCTAssertTrue(CommandRegistry.builtIn.paletteInvokable.contains { $0.id == id },
                          "\(id) must be palette-invokable")
        }
    }
}
