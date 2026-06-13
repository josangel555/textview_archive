import XCTest
import ViewerCore
@testable import ViewerUI

/// TSK-283 — wire "rename from the file nav" (FileRenamer) into the UI.
/// The model action + tree/bookmark follow-through are host-tested here;
/// the F2 keypress + right-click prompt are the live glance. Real temp
/// dirs only — never the owner's filesystem.
@MainActor
final class RenameFileActionTests: HeadlessUITestCase {

    private var tmp: URL!

    override func setUp() async throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("RenameFileActionTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: tmp) }

    func test_renameFile_movesOnDisk_reselects_andShowsNewNameInTree() throws {
        let model = DocumentModel()
        model.sidebar.setRoot(tmp)
        let src = tmp.appendingPathComponent("before.txt")
        try Data("hi".utf8).write(to: src)
        model.sidebar.reloadChildren(of: tmp)

        let dst = try XCTUnwrap(model.renameFile(at: src, to: "after.txt"),
                                "rename must succeed in a real writable dir")
        XCTAssertEqual(dst.lastPathComponent, "after.txt")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dst.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: src.path))
        XCTAssertEqual(model.sidebar.selectedURL?.path, dst.path,
                       "the renamed item is reselected")
        XCTAssertTrue(
            model.sidebar.flatVisibleRows().contains { $0.node.url.path == dst.path },
            "the new name appears in the tree immediately (reloadChildren)")
        XCTAssertFalse(
            model.sidebar.flatVisibleRows().contains { $0.node.url.path == src.path },
            "the old name is gone from the tree")
    }

    func test_renameFile_relocatesBookmark() throws {
        let model = DocumentModel()
        model.sidebar.setRoot(tmp)
        let src = tmp.appendingPathComponent("doc.md")
        try Data("x".utf8).write(to: src)
        model.bookmarksStore.add(url: src)
        XCTAssertTrue(model.bookmarksStore.contains(src))

        let dst = try XCTUnwrap(model.renameFile(at: src, to: "renamed.md"))
        XCTAssertFalse(model.bookmarksStore.contains(src),
                       "the stale bookmark URL is gone")
        XCTAssertTrue(model.bookmarksStore.contains(dst),
                      "the bookmark followed the rename")
    }

    func test_renameFile_invalidOrColliding_returnsNil_withoutCrash() throws {
        let model = DocumentModel()
        model.sidebar.setRoot(tmp)
        let src = tmp.appendingPathComponent("a.txt")
        try Data("a".utf8).write(to: src)
        try Data("b".utf8).write(to: tmp.appendingPathComponent("taken.txt"))

        XCTAssertNil(model.renameFile(at: src, to: "../escape.txt"),
                     "a traversal name is rejected, not crashed on")
        XCTAssertNil(model.renameFile(at: src, to: "taken.txt"),
                     "a collision returns nil (no overwrite)")
        XCTAssertEqual(try String(contentsOf: src, encoding: .utf8), "a",
                       "the source is intact after rejected renames")
    }

    /// Wiring pins (dead-channel idiom): the F2 key + the right-click menu
    /// both route to the model action via the shared prompt. A core with no
    /// UI trigger is the exact gap TSK-283 reported ("no rename anywhere").
    func test_entryPoints_areWired() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        func src(_ rel: String) throws -> String {
            try String(contentsOf: root.appendingPathComponent(rel), encoding: .utf8)
        }
        let monitor = try src("Sources/ViewerUI/SidebarKeyMonitor.swift")
        XCTAssertTrue(monitor.contains("return .f2"),
                      "the key monitor must map F2's keyCode to the .f2 case")
        XCTAssertTrue(monitor.contains("static let f2:"),
                      "F2's hardware keyCode must be defined")

        let sidebar = try src("Sources/ViewerUI/SidebarView.swift")
        XCTAssertTrue(sidebar.contains("case .f2:"),
                      "the sidebar key switch must handle F2")
        XCTAssertTrue(sidebar.contains("presentRenamePrompt(for: url, model: model)"),
                      "F2 must invoke the rename prompt for the selected row")
        XCTAssertTrue(sidebar.contains(
            "Button(\"Rename…\") { SidebarView.presentRenamePrompt(for: node.url, model: model) }"),
            "the right-click menu must offer Rename for files and folders")
        XCTAssertTrue(sidebar.contains("model.renameFile(at: url, to: field.stringValue)"),
                      "the prompt must call the model rename action")
    }
}
