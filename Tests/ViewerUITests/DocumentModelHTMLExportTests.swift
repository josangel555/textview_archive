import XCTest
import ViewerKit
import ViewerCore
@testable import ViewerUI

/// Host coverage for the Markdown HTML-export model wiring + its SECURITY fences
/// (TSK-1228, backing Export-as-HTML / Open-in-Browser). The HTMLRenderer /
/// HtmlExport engines are tested, but the DocumentModel wiring — the .md gate,
/// standalone-doc wrapping, and crucially the two security behaviors — had NO
/// host coverage:
///   - TSK-966: author-embedded HTML is rendered ESCAPED (authorHTML: .escape),
///     so no live author markup reaches the CSP-light file:// export.
///   - TSK-997 / L-sec1: `inlineImages` resolves local images through
///     HTMLDocumentPolicy.isWithinDocumentTree — an image path that escapes the
///     document's own directory must NOT be base64-inlined into the export.
/// These pin both fences with teeth so a regression (live <script> reaching the
/// export, or an out-of-tree file getting embedded) fails the host gate.
@MainActor
final class DocumentModelHTMLExportTests: XCTestCase {

    private var tmpDir: URL!
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DocumentModelHTMLExportTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        suiteName = "DocumentModelHTMLExportTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tmpDir)
        defaults.removePersistentDomain(forName: suiteName)
    }

    private func makeModel() -> DocumentModel {
        DocumentModel(
            controller: DocumentController(),
            history: HistoryStore(storeURL: tmpDir.appendingPathComponent("history.json")),
            sidebar: SidebarModel(),
            preferences: PreferencesStore(defaults: defaults)
        )
    }

    @discardableResult
    private func write(_ relPath: String, _ contents: String) throws -> URL {
        let url = tmpDir.appendingPathComponent(relPath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: - Basic export + standalone structure

    func test_htmlExport_producesStandaloneDocWithRenderedBody() throws {
        let model = makeModel()
        let url = try write("doc.md", "# Hello\n\nworld\n")
        model.open(url: url)
        let html = try XCTUnwrap(model.htmlExportForActiveMarkdown())
        XCTAssertTrue(html.contains("Hello") && html.contains("world"), "rendered body present")
        XCTAssertTrue(html.lowercased().contains("<html"), "standalone document has an <html> root")
        XCTAssertTrue(html.contains("<style"), "stylesheet embedded for a self-contained export")
    }

    // MARK: - Gates

    func test_htmlExport_isNil_forNonMarkdownFile() throws {
        let model = makeModel()
        let url = try write("notes.txt", "# not markdown by extension\n")
        model.open(url: url)
        XCTAssertNil(model.htmlExportForActiveMarkdown(), "export is gated to Markdown files")
    }

    func test_htmlExport_isNil_whenNoActiveFile() {
        let model = makeModel()
        XCTAssertNil(model.htmlExportForActiveMarkdown())
    }

    // MARK: - Security fence 1: author HTML is escaped, never live (TSK-966)

    func test_htmlExport_escapesAuthorHTML_noLiveScript() throws {
        let model = makeModel()
        let url = try write("doc.md", "# Title\n\n<script>alert(1)</script>\n")
        model.open(url: url)
        let html = try XCTUnwrap(model.htmlExportForActiveMarkdown())
        XCTAssertFalse(html.contains("<script>alert(1)</script>"),
            "author <script> must NOT reach the file:// export as live markup")
        XCTAssertTrue(html.contains("alert(1)"),
            "the author text survives — escaped, not stripped (proves .escape, not removal)")
    }

    // MARK: - Security fence 2: image inlining containment (TSK-997 / L-sec1)

    func test_htmlExport_inlineImages_blocksOutOfTreeImage_inlinesInTree() throws {
        let model = makeModel()
        let inBytes = "INSIDE_IMG_BYTES"
        let outBytes = "OUTSIDE_SECRET_BYTES"
        // Document lives in a SUBDIR so `../outside.png` escapes its own tree.
        try write("sub/in.png", inBytes)
        try write("outside.png", outBytes)
        let docURL = try write("sub/doc.md", "![inside](in.png)\n\n![outside](../outside.png)\n")
        model.open(url: docURL)

        let html = try XCTUnwrap(model.htmlExportForActiveMarkdown(inlineImages: true))
        let inB64 = Data(inBytes.utf8).base64EncodedString()
        let outB64 = Data(outBytes.utf8).base64EncodedString()
        XCTAssertTrue(html.contains(inB64),
            "an in-tree image IS base64-inlined into the portable export")
        XCTAssertFalse(html.contains(outB64),
            "an out-of-tree image (../outside.png) must NOT be embedded — the containment fence blocks it")
    }
}
