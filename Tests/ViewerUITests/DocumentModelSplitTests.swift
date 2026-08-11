import XCTest
import Foundation
import ViewerKit
import ViewerCore
@testable import ViewerUI

/// Contract tests for the split-pane API family extracted into
/// `DocumentModel+Split.swift` (TSK-308, first clean SRP-split slice).
///
/// These pin the BEHAVIOUR of the moved forwarders so the extraction is
/// provably byte-identical in effect, and so any future regression of the
/// open/close/toggle/swap state machine or the `splitPaneText` dirty-buffer
/// rule fails on the host headless gate (the methods touch only the public
/// surface — no render path, so they are fully host-testable).
@MainActor
final class DocumentModelSplitTests: HeadlessUITestCase {

    private var harness: HeadlessHarness!

    override func setUp() async throws {
        try await super.setUp()
        harness = HeadlessHarness(label: "DocumentModelSplitTests")
    }

    override func tearDown() async throws {
        harness?.cleanup()
        harness = nil
        try await super.tearDown()
    }

    /// `openInSplit` populates `splitURL` (symlink-resolved) and flips
    /// `isSplitOpen`; `closeSplit` clears both.
    func test_openInSplit_then_closeSplit() throws {
        let url = try harness.writeFile("a.md", "# A\n")
        let model = harness.model
        XCTAssertFalse(model.isSplitOpen, "precondition: no split open")
        XCTAssertNil(model.splitURL)

        model.openInSplit(url)
        XCTAssertTrue(model.isSplitOpen, "openInSplit should open the pane")
        XCTAssertEqual(model.splitURL,
                       url.standardizedFileURL.resolvingSymlinksInPath(),
                       "splitURL is the symlink-resolved input")

        model.closeSplit()
        XCTAssertFalse(model.isSplitOpen, "closeSplit should close the pane")
        XCTAssertNil(model.splitURL, "closeSplit clears splitURL")
    }

    /// The menu/keyboard "Toggle Split" contract — I-19 (2026-08-11):
    /// markdown routes to the PER-TAB split-editing layout; files without
    /// a rendered preview keep the classic same-file pane.
    func test_toggleSplit_markdown_drivesPerTabLayout_thenExits() throws {
        let url = try harness.writeFile("t.md", "# T\n")
        let model = harness.model
        model.open(url: url)
        XCTAssertFalse(model.isSplitOpen, "precondition: no split open")

        model.toggleSplit()
        XCTAssertTrue(model.isSplitEditingActive, "first toggle enters the per-tab layout")
        XCTAssertNil(model.splitURL, "markdown same-file split does not claim the pane")

        model.toggleSplit()
        XCTAssertFalse(model.isSplitEditingActive, "second toggle exits the layout")
    }

    func test_toggleSplit_nonMarkdown_opensThePane_thenCloses() throws {
        let url = try harness.writeFile("t.txt", "text\n")
        let model = harness.model
        model.open(url: url)

        model.toggleSplit()
        XCTAssertTrue(model.isSplitOpen, "no rendered preview ⇒ the classic pane")
        XCTAssertEqual(model.splitURL, model.currentURL)

        model.toggleSplit()
        XCTAssertFalse(model.isSplitOpen, "second toggle closes the pane")
    }

    /// `toggleSplit` is a no-op when there's nothing to show (no current
    /// file and no open split).
    func test_toggleSplit_noOp_whenNoCurrentFile() {
        let model = harness.model
        XCTAssertNil(model.currentURL, "precondition: no file open")
        model.toggleSplit()
        XCTAssertFalse(model.isSplitOpen, "no current file ⇒ toggle is a no-op")
    }

    /// `swapSplit` flips the primary (current tab) and secondary (split
    /// pane) files; it's a no-op when either pane is empty.
    func test_swapSplit_swapsPrimaryAndSecondary() throws {
        let a = try harness.writeFile("swap_a.md", "# A\n")
        let b = try harness.writeFile("swap_b.md", "# B\n")
        let model = harness.model
        let resolvedA = a.standardizedFileURL.resolvingSymlinksInPath()
        let resolvedB = b.standardizedFileURL.resolvingSymlinksInPath()

        model.open(url: a)                // primary = A
        model.openInSplit(b)              // secondary = B
        XCTAssertEqual(model.currentURL, resolvedA)
        XCTAssertEqual(model.splitURL, resolvedB)

        model.swapSplit()
        XCTAssertEqual(model.splitURL, resolvedA,
                       "after swap the split pane holds the old primary")
        XCTAssertEqual(model.currentURL, resolvedB,
                       "after swap the primary tab holds the old secondary")
    }

    func test_swapSplit_noOp_whenSplitClosed() throws {
        let a = try harness.writeFile("noswap.md", "# A\n")
        let model = harness.model
        model.open(url: a)
        XCTAssertNil(model.splitURL, "precondition: no split")
        model.swapSplit()                 // nothing to swap
        XCTAssertNil(model.splitURL, "swap with no split is a no-op")
        XCTAssertEqual(model.currentURL,
                       a.standardizedFileURL.resolvingSymlinksInPath(),
                       "primary file is unchanged by a no-op swap")
    }

    /// `splitPaneText` returns the live DIRTY buffer text for a file that's
    /// open in a tab with unsaved edits, keyed on the file's OWN tab — not
    /// `tabs.selected` (TSK-806 contract).
    func test_splitPaneText_returnsDirtyBufferText_forItsOwnTab() throws {
        let url = try harness.writeFile("dirty.md", "v1")
        let model = harness.model
        model.open(url: url)
        let id = model.tabs.selected!.id
        _ = model.editorBuffer(forTabID: id)         // materialize the buffer
        model.updateEditorText("v2-unsaved", forTabID: id)
        XCTAssertTrue(model.tabs.tabs[0].isDirty,
                      "precondition: tab is dirty after the edit")

        let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
        XCTAssertEqual(
            model.splitPaneText(for: resolved, fallback: "ON-DISK"),
            "v2-unsaved",
            "a dirty buffer wins over the on-disk fallback")
    }

    /// `splitPaneText` falls back to the on-disk argument when the file
    /// isn't open / has no dirty buffer.
    func test_splitPaneText_fallsBackToDisk_whenNotDirty() throws {
        let url = try harness.writeFile("clean.md", "# C\n")
        let model = harness.model
        let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
        // No tab open for this URL at all ⇒ fallback.
        XCTAssertEqual(
            model.splitPaneText(for: resolved, fallback: "ON-DISK"),
            "ON-DISK",
            "no open tab ⇒ on-disk fallback")
    }
}
