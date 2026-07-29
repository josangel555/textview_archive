import XCTest
import ViewerCore
@testable import ViewerUI

/// TSK-329 — wire the (already tested) atomic NewFileCreator into the UI.
/// The model action + target resolution are host-tested here; the menu /
/// context-menu key+click is the live glance. Real temp dirs only — never
/// the owner's filesystem.
@MainActor
final class NewFileActionTests: HeadlessUITestCase {

    private var tmp: URL!

    override func setUp() async throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("NewFileActionTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: tmp) }

    func test_createNewFile_makesFile_opensTab_selectsIt() throws {
        let model = DocumentModel()
        model.sidebar.setRoot(tmp)
        let url = try XCTUnwrap(model.createNewFile(in: tmp),
                                "create must succeed in a real writable dir")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path),
                      "the file must be on disk")
        XCTAssertEqual(url.deletingLastPathComponent().path, tmp.path)
        XCTAssertEqual(model.sidebar.selectedURL?.path, url.path,
                       "the new file is selected in the tree")
        XCTAssertTrue(model.openTabURLs.contains(url),
                      "the new file opens in a tab for editing")
        // A second call collides → NewFileCreator suffixes, never overwrites.
        let url2 = try XCTUnwrap(model.createNewFile(in: tmp))
        XCTAssertNotEqual(url2.lastPathComponent, url.lastPathComponent,
                          "a colliding name must be suffixed, not clobbered")
    }

    func test_createNewFile_reloadsTreeSoTheFileIsVisibleNow() throws {
        let model = DocumentModel()
        model.sidebar.setRoot(tmp)
        let url = try XCTUnwrap(model.createNewFile(in: tmp))
        XCTAssertTrue(
            model.sidebar.flatVisibleRows().contains { $0.node.url.path == url.path },
            "the new file must appear in the tree immediately (reloadChildren), "
            + "not only after the FSEvents coalesce window")
    }

    func test_newFileTargetDirectory_resolution() {
        let model = DocumentModel()
        XCTAssertNil(model.newFileTargetDirectory, "no folder open → nil (menu disabled)")
        model.sidebar.setRoot(tmp)
        // No selection → root.
        XCTAssertEqual(model.newFileTargetDirectory?.path, tmp.path)
        // A selected SUBFOLDER → that folder.
        let sub = tmp.appendingPathComponent("sub")
        try? FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        model.sidebar.setSelected(sub)
        XCTAssertEqual(model.newFileTargetDirectory?.path, sub.path)
        // A selected FILE → its containing folder.
        let f = sub.appendingPathComponent("a.txt")
        try? Data("x".utf8).write(to: f)
        model.sidebar.setSelected(f)
        XCTAssertEqual(model.newFileTargetDirectory?.path, sub.path)
    }

    /// Wiring pins (dead-channel idiom): the menu + context-menu entries
    /// route to the model action. A core with no UI caller is the exact
    /// gap TSK-329 reported.
    func test_entryPoints_areWired() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        func src(_ rel: String) throws -> String {
            try String(contentsOf: root.appendingPathComponent(rel), encoding: .utf8)
        }
        let main = try src("Sources/MarkdownViewer/main.swift")
        XCTAssertTrue(main.contains("#selector(newFile(_:))"),
                      "File menu must have a New File item")
        // TSK-1605: every entry point now routes through the NAME-FIRST
        // prompt (`promptForNewFile`) instead of creating `Untitled.txt` and
        // leaving the user to rename it. Pinning the prompting call keeps a
        // regression back to silent-Untitled creation RED.
        XCTAssertTrue(main.contains("model.promptForNewFile(in: dir)"),
                      "newFile action must call the model's name-first prompt")
        XCTAssertTrue(main.contains("model.promptForNewFile(in: dir, type: type)"),
                      "the typed New File ▸ … items must prompt for the name too")
        XCTAssertTrue(main.contains("model.newFileTargetDirectory != nil"),
                      "the item must disable when no folder is open")
        let sidebar = try src("Sources/ViewerUI/SidebarView.swift")
        // TSK-747: the right-click "New File" is a typed submenu
        // (txt/md/csv/json); TSK-1605: it prompts for the name first.
        XCTAssertTrue(sidebar.contains("model.promptForNewFile(in: node.url, type: type)"),
                      "the folder context menu must offer New File (the "
                      + "right-click entry point TSK-329 named, TSK-747 typed) "
                      + "and prompt for the name (TSK-1605)")
        let content = try src("Sources/ViewerUI/ContentView.swift")
        XCTAssertTrue(content.contains("model.promptForNewFileForLanding()"),
                      "the empty-state landing button must prompt too — it was "
                      + "the other silent-Untitled path")
    }
}
