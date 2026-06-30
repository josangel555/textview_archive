import XCTest
import AppKit
import ViewerCore
@testable import ViewerUI

/// TSK-1163 / TSK-958 — the Universal Paste live action (DocumentModel.universalPaste). The
/// prior pass left this at review assuming "AppKit live behavior = VM-only", but the action is
/// fully HOST-testable: `universalPaste(from:)` takes an injectable NSPasteboard and routes via
/// PasteDispatch → UniversalPastePlan → materialize-temp → openInNewTab — no window/render. These
/// pin the end-to-end dispatch: the pasteboard KIND opens the right viewer (by file extension).
@MainActor
final class UniversalPasteActionTests: XCTestCase {

    private var tmpDir: URL!
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("UniversalPasteTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        suiteName = "UniversalPasteTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDownWithError() throws {
        if let tmpDir { try? FileManager.default.removeItem(at: tmpDir) }
        if let suiteName, let defaults { defaults.removePersistentDomain(forName: suiteName) }
    }

    private func makeModel() -> DocumentModel {
        DocumentModel(
            controller: DocumentController(),
            history: HistoryStore(storeURL: tmpDir.appendingPathComponent("history.json")),
            sidebar: SidebarModel(),
            preferences: PreferencesStore(defaults: defaults))
    }

    private func freshPasteboard() -> NSPasteboard {
        let pb = NSPasteboard(name: NSPasteboard.Name("UniversalPasteTest-\(UUID().uuidString)"))
        pb.clearContents()
        return pb
    }

    func test_plainText_opensANewTab() {
        let model = makeModel()
        let pb = freshPasteboard()
        pb.setString("hello from the clipboard", forType: .string)
        XCTAssertTrue(model.universalPaste(from: pb), "plain text should dispatch + open a tab")
        XCTAssertNotNil(model.tabs.selected?.url, "a new document tab opened")
    }

    func test_image_opensAPngTab() {
        let model = makeModel()
        let pb = freshPasteboard()
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let png = rep.representation(using: .png, properties: [:])!
        pb.setData(png, forType: .png)
        XCTAssertTrue(model.universalPaste(from: pb), "image should dispatch + open a tab")
        XCTAssertEqual(model.tabs.selected?.url?.pathExtension, "png",
                       "image paste routes to the image viewer (a .png temp)")
    }

    /// TSK-1327: a rich-text paste carrying HTML opens as STRUCTURED Markdown
    /// (headings → "# ", list items → "- "), not a raw .rtf dump.
    func test_richTextHTML_opensStructuredMarkdownTab() throws {
        let model = makeModel()
        let pb = freshPasteboard()
        let html = "<h1>Title</h1><ul><li>one</li><li>two</li></ul>"
        pb.setData(Data(html.utf8), forType: .html)
        XCTAssertTrue(model.universalPaste(from: pb), "HTML rich text should dispatch + open a tab")
        let url = try XCTUnwrap(model.tabs.selected?.url)
        XCTAssertEqual(url.pathExtension, "md",
                       "rich HTML paste opens as Markdown, not raw .rtf")
        let content = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(content.contains("# Title"), "heading → '# ' (got: \(content))")
        XCTAssertTrue(content.contains("- one") && content.contains("- two"),
                      "list items → '- ' (got: \(content))")
    }

    func test_emptyClipboard_returnsFalse() {
        let model = makeModel()
        let pb = freshPasteboard()   // nothing set
        XCTAssertFalse(model.universalPaste(from: pb),
                       "nothing recognized on the clipboard → no-op (false)")
    }
}
