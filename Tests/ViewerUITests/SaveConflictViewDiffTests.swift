import XCTest
@testable import ViewerUI
import ViewerCore

/// The save-conflict prompt's "View Diff…" (2026-08-01 — previously a
/// DEAD BUTTON: `onViewSaveConflictDiff` was a no-op seam). The wired
/// behavior: generate a unified disk-vs-buffer diff and open it in the
/// ephemeral preview slot (the git-diff-tab shape), leaving the buffer
/// and the file untouched so the user can ⌘S again and re-decide.
@MainActor
final class SaveConflictViewDiffTests: HeadlessUITestCase {

    private var tmp: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("SaveConflictViewDiffTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
        try super.tearDownWithError()
    }

    func test_viewDiff_opensUnifiedBufferVsDiskDiff_asPreview() throws {
        let model = DocumentModel()
        let file = tmp.appendingPathComponent("doc.md")
        try "shared line\ndisk-only line\n".write(to: file, atomically: true, encoding: .utf8)
        model.openPath(file)
        let id = try XCTUnwrap(model.tabs.selected?.id)
        _ = model.editor.editorBuffer(forTabID: id)
        model.updateEditorText("shared line\nbuffer-only line\n", forTabID: id)

        model.editor.onViewSaveConflictDiff?(id, file)

        XCTAssertNotNil(model.tabs.previewTabID,
            "View Diff must open the ephemeral preview slot")
        let previewURL = try XCTUnwrap(model.tabs.selected?.url)
        XCTAssertEqual(previewURL.pathExtension, "diff",
            "the preview is a .diff scratch file: \(previewURL.lastPathComponent)")
        let body = try String(contentsOf: previewURL, encoding: .utf8)
        XCTAssertTrue(body.contains("-disk-only line"),
            "the disk side reads as removed relative to the buffer: \(body)")
        XCTAssertTrue(body.contains("+buffer-only line"),
            "the buffer side reads as added: \(body)")
        // Non-destructive: the file and the dirty buffer are untouched.
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8),
                       "shared line\ndisk-only line\n")
    }

    /// Same text, different metadata (mtime-only conflicts happen): the
    /// preview must SAY the text is identical, not show a blank tab the
    /// user reads as a broken button.
    func test_viewDiff_identicalText_saysSoInsteadOfBlank() throws {
        let model = DocumentModel()
        let file = tmp.appendingPathComponent("same.md")
        try "alpha\n".write(to: file, atomically: true, encoding: .utf8)
        model.openPath(file)
        let id = try XCTUnwrap(model.tabs.selected?.id)
        _ = model.editor.editorBuffer(forTabID: id)
        model.updateEditorText("alpha\n", forTabID: id)

        model.editor.onViewSaveConflictDiff?(id, file)

        let previewURL = try XCTUnwrap(model.tabs.selected?.url)
        let body = try String(contentsOf: previewURL, encoding: .utf8)
        XCTAssertTrue(body.contains("identical"),
            "an mtime-only conflict must explain itself: \(body)")
    }
}
