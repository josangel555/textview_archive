import XCTest
import ViewerKit
import ViewerCore
@testable import ViewerUI

/// TSK-948 — the Fold / Unfold menu actions wired to Source-view code folding.
///
/// The View → Fold All / Unfold All menu items used to dispatch directly to
/// the CM6 editor and were greyed unless the active tab was in `.editor` mode,
/// so they did NOTHING in the read-only `.source` lens (which IS foldable —
/// its gutter draws the same TreeSitter fold chevrons). This pins:
///
///  1. The enablement gate `DocumentModel.canFoldActiveDocument` — true in the
///     foldable Source/Editor lens, false in Render / HEX / non-foldable.
///  2. That invoking `foldAllActiveDocument()` / `unfoldAllActiveDocument()`
///     (the exact methods the menu action closures call — see
///     `MarkdownViewer/main.swift`'s `cmFoldAll` / `cmUnfoldAll`) records the
///     correct command + dispatch target, and is an inert no-op outside a
///     foldable lens.
///
/// The actual on-screen collapse is the VM render tail; this is the host-tested
/// model/dispatch layer.
@MainActor
final class FoldMenuActionTests: XCTestCase {

    private var tmpDir: URL!
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        try await super.setUp()
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FoldMenuActionTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        suiteName = "FoldMenuActionTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        if let tmpDir { try? FileManager.default.removeItem(at: tmpDir) }
        if let suiteName, let defaults {
            defaults.removePersistentDomain(forName: suiteName)
        }
        try await super.tearDown()
    }

    private func makeModel() -> DocumentModel {
        DocumentModel(
            controller: DocumentController(),
            history: HistoryStore(storeURL: tmpDir.appendingPathComponent("history.json")),
            bookmarks: BookmarksStore(storeURL: tmpDir.appendingPathComponent("bookmarks.json")),
            sidebar: SidebarModel(),
            preferences: PreferencesStore(defaults: defaults)
        )
    }

    @discardableResult
    private func writeFile(_ name: String, _ contents: String) throws -> URL {
        let url = tmpDir.appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: - Enablement gate (canFoldActiveDocument)

    func test_gate_disabled_whenNoTabOpen() {
        let m = makeModel()
        XCTAssertFalse(m.canFoldActiveDocument,
                       "no tab → Fold menu items greyed")
    }

    func test_gate_enabled_inSourceLens() throws {
        let url = try writeFile("code.swift", "func f() {\n  let x = 1\n}\n")
        let m = makeModel()
        m.open(url: url)
        m.setCurrentViewMode(.source)
        XCTAssertEqual(m.currentViewMode, .source)
        XCTAssertTrue(m.canFoldActiveDocument,
                      "Source view is foldable → Fold menu items enabled (the bug: "
                      + "they were greyed here)")
    }

    func test_gate_enabled_inEditorLens() throws {
        let url = try writeFile("code.swift", "func f() {\n  let x = 1\n}\n")
        let m = makeModel()
        m.open(url: url)
        m.setCurrentViewMode(.editor)
        XCTAssertEqual(m.currentViewMode, .editor)
        XCTAssertTrue(m.canFoldActiveDocument,
                      "Editor view is foldable → Fold menu items enabled")
    }

    func test_gate_disabled_inRenderedLens() throws {
        let url = try writeFile("doc.md", "# Title\n\nbody\n")
        let m = makeModel()
        m.open(url: url)
        // Markdown defaults to .rendered — the non-foldable WKWebView lens.
        XCTAssertEqual(m.currentViewMode, .rendered)
        XCTAssertFalse(m.canFoldActiveDocument,
                       "Rendered (WKWebView) has no fold model → Fold greyed")
    }

    func test_gate_disabled_inHexLens() throws {
        let url = try writeFile("code.swift", "func f() {}\n")
        let m = makeModel()
        m.open(url: url)
        m.setCurrentViewMode(.hex)
        XCTAssertEqual(m.currentViewMode, .hex)
        XCTAssertFalse(m.canFoldActiveDocument,
                       "HEX byte grid has no fold model → Fold greyed")
    }

    // MARK: - Dispatch (the exact methods the menu closures call)

    func test_foldAll_inSource_dispatchesToSourceTarget() throws {
        let url = try writeFile("code.swift", "func f() {\n  let x = 1\n}\n")
        let m = makeModel()
        m.open(url: url)
        m.setCurrentViewMode(.source)

        XCTAssertNil(m.lastFoldDispatch, "no dispatch before the action fires")
        let handled = m.foldAllActiveDocument()
        XCTAssertTrue(handled, "action handled in a foldable lens")
        XCTAssertEqual(m.lastFoldDispatch?.command, .foldAll)
        XCTAssertEqual(m.lastFoldDispatch?.target, .source,
                       "Source lens routes the fold to the Source-view surface")
    }

    func test_unfoldAll_inEditor_dispatchesToEditorTarget() throws {
        let url = try writeFile("code.swift", "func f() {\n  let x = 1\n}\n")
        let m = makeModel()
        m.open(url: url)
        m.setCurrentViewMode(.editor)

        let handled = m.unfoldAllActiveDocument()
        XCTAssertTrue(handled)
        XCTAssertEqual(m.lastFoldDispatch?.command, .unfoldAll)
        XCTAssertEqual(m.lastFoldDispatch?.target, .editor,
                       "Editor lens routes the fold to the CM6 editor surface")
    }

    func test_repeatedFoldAll_bumpsNonce_soReissueFires() throws {
        let url = try writeFile("code.swift", "func f() {\n  let x = 1\n}\n")
        let m = makeModel()
        m.open(url: url)
        m.setCurrentViewMode(.source)

        m.foldAllActiveDocument()
        let first = m.lastFoldDispatch
        m.foldAllActiveDocument()
        let second = m.lastFoldDispatch
        XCTAssertNotNil(first); XCTAssertNotNil(second)
        XCTAssertEqual(first?.command, second?.command)
        XCTAssertNotEqual(first?.nonce, second?.nonce,
                          "re-issuing the same command bumps the nonce so the "
                          + "view re-applies it (one-shot semantics)")
    }

    func test_foldActions_noOp_inNonFoldableLens() throws {
        let url = try writeFile("doc.md", "# Title\n\nbody\n")
        let m = makeModel()
        m.open(url: url)
        // .rendered — non-foldable.
        XCTAssertEqual(m.currentViewMode, .rendered)
        XCTAssertFalse(m.foldAllActiveDocument(),
                       "fold action is inert in a non-foldable lens (matches the "
                       + "greyed menu — a keyboard shortcut here does nothing)")
        XCTAssertFalse(m.unfoldAllActiveDocument())
        XCTAssertNil(m.lastFoldDispatch,
                     "no dispatch recorded for a non-foldable lens")
    }
}
