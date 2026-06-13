import XCTest
import ViewerCore
@testable import ViewerUI

/// TSK-330 — the undo AUDIT's finding made executable: the store's
/// removal-undo stack existed (BookmarkUndoTests) but had ZERO production
/// consumers — ⌘Z outside the editor did nothing. These pin the model
/// surface the Edit→Undo fallback now calls, and the wiring itself.
/// Store is injected at a temp path — the owner's real bookmarks.json is
/// never touched.
@MainActor
final class BookmarkUndoWiringTests: HeadlessUITestCase {

    private var tmpDir: URL!

    override func setUp() async throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("BookmarkUndoWiringTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tmpDir)
    }

    private func makeModel() -> DocumentModel {
        DocumentModel(
            bookmarks: BookmarksStore(storeURL: tmpDir.appendingPathComponent("b.json")))
    }

    func test_modelUndo_restoresTheRemovedBookmark_andRepublishes() throws {
        let model = makeModel()
        let url = URL(fileURLWithPath: "/tmp/BookmarkUndoWiringTests-target.md")
        model.bookmarksStore.add(url: url)
        model.publishBookmarksChange()
        XCTAssertTrue(model.bookmarks.contains { $0.url.path == url.path })

        model.removeBookmark(url)
        XCTAssertFalse(model.bookmarks.contains { $0.url.path == url.path })
        XCTAssertTrue(model.canUndoBookmarkRemoval, "removal must arm the undo")

        XCTAssertTrue(model.undoLastBookmarkRemoval())
        XCTAssertTrue(model.bookmarks.contains { $0.url.path == url.path },
                      "undo must restore the bookmark AND republish the array")
        XCTAssertFalse(model.canUndoBookmarkRemoval, "stack consumed")
    }

    func test_modelUndo_emptyStack_isFalse_andSafe() {
        let model = makeModel()
        XCTAssertFalse(model.canUndoBookmarkRemoval)
        XCTAssertFalse(model.undoLastBookmarkRemoval(),
                       "empty stack: report false, never throw/crash")
    }

    /// The wiring pins (the dead-channel idiom): the menu fallback calls
    /// the model surface, and the text-input guard is present so ⌘Z is
    /// never stolen from prompts/search fields.
    func test_menuFallback_isWired_withTheTextInputGuard() throws {
        let main = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/MarkdownViewer/main.swift"),
            encoding: .utf8)
        XCTAssertTrue(main.contains("model.undoLastBookmarkRemoval()"),
                      "editorUndo's non-editor path must consume the store's "
                      + "undo stack (TSK-330 — it had zero consumers)")
        XCTAssertTrue(main.contains("firstResponder is NSText"),
                      "the validateMenuItem guard must release ⌘Z to focused "
                      + "text inputs")
        XCTAssertTrue(main.contains("model.canUndoBookmarkRemoval"),
                      "menu enablement must track the store's undo stack")
    }
}
