import XCTest
import ViewerCore
@testable import ViewerUI

/// TSK-1463 — teeth for the file-tree operations' MODEL layer: Delete → Trash
/// (recoverable, tabs survive), New Folder, Move, and the open-tab retarget
/// that rename/move share (tab URL + loaded state + editor buffer follow,
/// unsaved edits preserved). Real temp dirs only — never the owner's files.
@MainActor
final class FileOperationsTests: HeadlessUITestCase {

    private var tmp: URL!

    override func setUp() async throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("FileOpsTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: tmp) }

    // MARK: - Rename → open tabs follow (the previously-deferred gap)

    func test_rename_retargetsOpenTab_preservingUnsavedEdits() throws {
        let model = DocumentModel()
        model.sidebar.setRoot(tmp)
        let src = tmp.appendingPathComponent("before.md")
        try Data("# original\n".utf8).write(to: src)

        model.open(url: src)
        let tab = try XCTUnwrap(model.tabs.tabs.first)
        model.updateEditorText("# edited, unsaved\n", forTabID: tab.id)

        let dst = try XCTUnwrap(model.renameFile(at: src, to: "after.md"))

        let renamed = try XCTUnwrap(model.tabs.tabs.first)
        XCTAssertEqual(renamed.url?.standardizedFileURL.path, dst.standardizedFileURL.path,
                       "the open tab must FOLLOW the rename")
        XCTAssertEqual(renamed.diskState, .fresh,
                       "no spurious 'deleted on disk' dot after a rename")
        let buf = try XCTUnwrap(model.editorBuffer(forTabID: renamed.id))
        XCTAssertEqual(buf.url.standardizedFileURL.path, dst.standardizedFileURL.path,
                       "the editor buffer saves to the NEW path")
        XCTAssertEqual(buf.text, "# edited, unsaved\n", "unsaved edits survive the rename")
        XCTAssertTrue(buf.isDirty, "dirty state survives the rename")
    }

    func test_renameFolder_retargetsDescendantTab() throws {
        let model = DocumentModel()
        model.sidebar.setRoot(tmp)
        let folder = tmp.appendingPathComponent("docs")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("deep.md")
        try Data("x\n".utf8).write(to: file)

        model.open(url: file)
        _ = try XCTUnwrap(model.renameFile(at: folder, to: "notes"))

        let tab = try XCTUnwrap(model.tabs.tabs.first)
        XCTAssertEqual(tab.url?.lastPathComponent, "deep.md")
        XCTAssertTrue(tab.url?.standardizedFileURL.path.contains("/notes/") == true,
                      "a tab under a renamed FOLDER is rebased onto the new folder path; got \(tab.url?.path ?? "nil")")
    }

    // MARK: - Delete → Trash

    func test_delete_movesToTrash_tabSurvivesMarkedDeleted() throws {
        let model = DocumentModel()
        model.sidebar.setRoot(tmp)
        let file = tmp.appendingPathComponent("doomed.md")
        try Data("# content\n".utf8).write(to: file)
        model.open(url: file)

        XCTAssertTrue(model.deleteFileToTrash(at: file))

        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path),
                       "the file left its folder (recoverable from the Trash)")
        let tab = try XCTUnwrap(model.tabs.tabs.first, "the open tab is NOT closed")
        XCTAssertEqual(tab.diskState, .deleted,
                       "the tab is flagged deleted-on-disk immediately")
    }

    func test_delete_missingFile_failsWithoutCrash() {
        let model = DocumentModel()
        XCTAssertFalse(model.deleteFileToTrash(at: tmp.appendingPathComponent("ghost.md")))
    }

    // MARK: - New Folder

    func test_createNewFolder_nonColliding() throws {
        let model = DocumentModel()
        model.sidebar.setRoot(tmp)
        let first = try XCTUnwrap(model.createNewFolder(in: tmp))
        XCTAssertEqual(first.lastPathComponent, "untitled folder")
        let second = try XCTUnwrap(model.createNewFolder(in: tmp))
        XCTAssertEqual(second.lastPathComponent, "untitled folder 2")
        XCTAssertEqual(model.sidebar.selectedURL?.path, second.path,
                       "the new folder is selected in the tree")
    }

    // MARK: - Move

    func test_moveFile_movesAndRetargetsOpenTab() throws {
        let model = DocumentModel()
        model.sidebar.setRoot(tmp)
        let src = tmp.appendingPathComponent("a.md")
        try Data("# a\n".utf8).write(to: src)
        let sub = tmp.appendingPathComponent("sub")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        model.open(url: src)

        let dst = try XCTUnwrap(model.moveFile(at: src, to: sub))
        XCTAssertEqual(dst.standardizedFileURL.path,
                       sub.appendingPathComponent("a.md").standardizedFileURL.path)
        let tab = try XCTUnwrap(model.tabs.tabs.first)
        XCTAssertEqual(tab.url?.standardizedFileURL.path, dst.standardizedFileURL.path,
                       "the open tab follows the move")
    }

    func test_moveFile_refusesClobber_returnsNil() throws {
        let model = DocumentModel()
        let src = tmp.appendingPathComponent("a.md")
        try Data("new\n".utf8).write(to: src)
        let sub = tmp.appendingPathComponent("sub")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        let occupant = sub.appendingPathComponent("a.md")
        try Data("precious\n".utf8).write(to: occupant)

        XCTAssertNil(model.moveFile(at: src, to: sub))
        XCTAssertEqual(try String(contentsOf: occupant, encoding: .utf8), "precious\n",
                       "the occupant survives byte-identical")
        XCTAssertTrue(FileManager.default.fileExists(atPath: src.path),
                      "the source is untouched after the refused move")
    }

    // MARK: - Entry-point wiring pins (dead-channel idiom, cf. RenameFileActionTests)

    func test_entryPoints_areWired() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let sidebar = try String(
            contentsOf: root.appendingPathComponent("Sources/ViewerUI/SidebarView.swift"),
            encoding: .utf8)
        XCTAssertTrue(sidebar.contains("presentDeleteConfirm(for: node.url, model: model)"),
                      "the right-click menu must offer Move to Trash behind a confirm")
        XCTAssertTrue(sidebar.contains("model.deleteFileToTrash(at: url)"),
                      "the confirm must call the model trash action")
        XCTAssertTrue(sidebar.contains("model.createNewFolder(in: node.url)"),
                      "the right-click menu must offer New Folder on directories")
        XCTAssertTrue(sidebar.contains("presentMovePanel(for: node.url, model: model)"),
                      "the right-click menu must offer Move to Folder…")
        XCTAssertTrue(sidebar.contains("model.moveFile(at: url, to: dest)"),
                      "the move panel must call the model move action")
        XCTAssertFalse(sidebar.contains("removeItem(at: node.url"),
                       "the sidebar must never hard-delete (trash only)")
    }
}
