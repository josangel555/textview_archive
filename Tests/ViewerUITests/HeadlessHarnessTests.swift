import XCTest
import Foundation
import ViewerKit
@testable import ViewerUI

/// Validates the §3.1 keystone end-to-end: `HeadlessHarness` applies the
/// SAME script verbs the VM `--script` path uses (via `ScriptVerb.apply`),
/// emits the SAME `model` dump dict (via `ScriptVerb.modelStateDump`), and
/// the EXISTING Page Objects (`Pages(dump:)`) consume it unchanged — no
/// process spawn, no JSON file, host-headless.
@MainActor
final class HeadlessHarnessTests: HeadlessUITestCase {

    private var harness: HeadlessHarness!

    override func setUp() async throws {
        try await super.setUp()
        harness = HeadlessHarness(label: "HeadlessHarnessTests")
    }

    override func tearDown() async throws {
        harness?.cleanup()
        harness = nil
        try await super.tearDown()
    }

    // MARK: - Dump shape feeds the existing Page Objects

    func test_dumpFeedsExistingPageObjects_modelScalars() throws {
        let url = try harness.writeFile("doc.md", "# Hello\n")
        let dumps = harness.runScript(
            """
            zoom-in
            toggle-view
            """,
            with: url
        )
        XCTAssertEqual(dumps.count, 2)

        // The existing GenericDumpPage reads model.zoom / currentViewMode.
        let afterZoom = Pages(dump: dumps[0]).generic
        let afterToggle = Pages(dump: dumps[1]).generic
        XCTAssertNotNil(afterZoom.zoom)
        XCTAssertGreaterThan(afterZoom.zoom ?? 0, 1.0, "zoom-in should raise zoom above default")
        // Markdown opens in rendered mode; toggle flips it to source.
        XCTAssertEqual(afterToggle.currentViewMode, "source")
    }

    // MARK: - Tab verbs (the InteractionScriptTests T4→T1m target class)

    func test_tabVerbs_reflectInModelDump() throws {
        let a = try harness.writeFile("a.md", "# A\n")
        let b = try harness.writeFile("b.md", "# B\n")
        let dumps = harness.runScript(
            """
            new-tab
            open \(b.path)
            """,
            with: a
        )
        XCTAssertEqual(dumps.count, 2)
        // model.tabCount is in the dump; assert via the raw projection.
        let last = dumps[1]["model"] as! [String: Any]
        XCTAssertGreaterThanOrEqual(last["tabCount"] as! Int, 1)
        XCTAssertEqual(last["currentURL"] as? String, b.path)
    }

    // MARK: - Sessions verbs feed SessionTabBarPage unchanged

    func test_sessionVerbs_feedSessionTabBarPage() throws {
        let folderA = try harness.makeDir("ProjectA")
        try "# Hello\n".write(
            to: folderA.appendingPathComponent("doc.md"),
            atomically: true, encoding: .utf8)

        let dumps = harness.runScript("session-open-folder \(folderA.path)")
        XCTAssertEqual(dumps.count, 1)

        let page = Pages(dump: dumps[0]).sessionTabBar
        page.assertSessionCount(1)
        page.assertActiveSessionName("ProjectA")
        page.assertActiveSessionRoot(endsWith: "ProjectA")
    }

    // MARK: - Find-bar verbs (FindBar / RenderedFindBar T1m target)

    func test_findBarVerbs_reflectInModelDump() throws {
        let url = try harness.writeFile("find.md", "# findme\n")
        let dumps = harness.runScript(
            """
            show-find
            dismiss-find
            """,
            with: url
        )
        XCTAssertEqual(dumps.count, 2)
        let afterShow = dumps[0]["model"] as! [String: Any]
        let afterDismiss = dumps[1]["model"] as! [String: Any]
        XCTAssertEqual(afterShow["isRenderedFindBarPresented"] as? Bool, true)
        XCTAssertEqual(afterDismiss["isRenderedFindBarPresented"] as? Bool, false)
    }

    // MARK: - Sidebar verbs feed SidebarPage unchanged

    func test_sidebarSetRoot_feedsSidebarPage() throws {
        let dir = try harness.makeDir("tree")
        let dumps = harness.runScript("sidebar-set-root \(dir.path)")
        XCTAssertEqual(dumps.count, 1)
        let page = Pages(dump: dumps[0]).sidebar
        // `absoluteString` preserves the trailing slash the live dump uses.
        page.assertRoot(endsWith: "tree/")
    }

    // MARK: - Residual window verbs are a no-op headless (false return)

    func test_windowCoupledVerb_isUnhandledHeadless() {
        // `resize` / `find` are window/NSApp-coupled — ScriptVerb.apply
        // returns false; the harness simply produces a dump with the
        // model state unchanged (no crash, no window).
        XCTAssertFalse(ScriptVerb.apply(
            verb: "resize 1200x800", to: harness.model, sessions: harness.sessions))
        XCTAssertFalse(ScriptVerb.apply(
            verb: "find", to: harness.model, sessions: harness.sessions))
        // Model verbs return true.
        XCTAssertTrue(ScriptVerb.apply(
            verb: "zoom-in", to: harness.model, sessions: harness.sessions))
    }

    // MARK: - confirm-dirty-close arms the close prompt (SC-CHROME-01 step 6)

    /// `confirm-dirty-close <choice>` must pre-arm the dirty-close prompt
    /// so a following `close-tab` on a dirty tab is automatable instead of
    /// blocking the main thread on `NSAlert.runModal()`. If the verb were
    /// not wired, this in-process test would deadlock on the modal — the
    /// very bug it guards.
    func test_confirmDirtyClose_discard_closesDirtyTabWithoutModal() throws {
        let url = try harness.writeFile("dirty.txt", "v1")
        let model = harness.model
        model.open(url: url)
        let id = model.tabs.tabs[0].id
        _ = model.editorBuffer(forTabID: id)
        model.updateEditorText("edited-content-marker", forTabID: id)
        XCTAssertTrue(model.tabs.tabs[0].isDirty, "precondition: tab is dirty")

        XCTAssertTrue(ScriptVerb.apply(
            verb: "confirm-dirty-close discard", to: model, sessions: harness.sessions),
            "the new verb must be recognised + handled in-process")
        XCTAssertNotNil(model.editor.dirtyClosePromptOverride,
            "verb must install the override seam so close() doesn't hit runModal()")

        ScriptVerb.apply(verb: "close-tab", to: model, sessions: harness.sessions)

        XCTAssertTrue(model.tabs.isEmpty, "discard must close the dirty tab")
        XCTAssertEqual(try? String(contentsOf: url, encoding: .utf8), "v1",
            "discard (Don't Save) must NOT write the buffer to disk")
        XCTAssertNil(model.editor.dirtyClosePromptOverride,
            "one-shot: override must clear itself after the close consumes it")
    }

    /// `cancel` aborts the close and leaves the dirty tab intact.
    func test_confirmDirtyClose_cancel_abortsClose() throws {
        let url = try harness.writeFile("cancel.txt", "v1")
        let model = harness.model
        model.open(url: url)
        let id = model.tabs.tabs[0].id
        _ = model.editorBuffer(forTabID: id)
        model.updateEditorText("edited", forTabID: id)

        ScriptVerb.apply(verb: "confirm-dirty-close cancel", to: model, sessions: harness.sessions)
        ScriptVerb.apply(verb: "close-tab", to: model, sessions: harness.sessions)

        XCTAssertEqual(model.tabs.tabs.count, 1, "cancel must keep the tab open")
        XCTAssertTrue(model.tabs.tabs[0].isDirty, "cancel must preserve the dirty edit")
    }
}
