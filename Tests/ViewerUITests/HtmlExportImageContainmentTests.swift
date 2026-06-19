import XCTest
import ViewerKit
import ViewerCore
@testable import ViewerUI

/// L-sec1 (TSK-997) — teeth for the export `<img src>` inlining containment
/// fence. `htmlExportForActiveMarkdown(inlineImages: true)` makes a saved
/// `.html` portable by base64-embedding LOCAL images as `data:` URIs. The
/// resolver collapses `..` (`standardizedFileURL`), so without a containment
/// check `![](../../../../etc/passwd)` — or ANY readable file given an image
/// extension — would be inlined into the export, an exfiltration of arbitrary
/// readable host files into a document the user then shares.
///
/// The in-app `.html` subresource path already fences with
/// `HTMLDocumentPolicy.isWithinDocumentTree` (`decideSubresource`); the export
/// inlining path did not — a genuine asymmetry these tests pin shut. An
/// in-tree control image MUST still inline (the fence is precise, not a blanket
/// "never inline `..`"); a path that escapes the document directory MUST be
/// left as its original relative reference, never embedded.
///
/// Pure model/string layer (no view, no WKWebView) — host-headless, merge gate.
@MainActor
final class HtmlExportImageContainmentTests: HeadlessUITestCase {

    private var tmpDir: URL!
    private var docDir: URL!
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var historyStoreURL: URL!
    private var bookmarksStoreURL: URL!

    override func setUp() async throws {
        try await super.setUp()
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("HtmlExportImageContainment-\(UUID().uuidString)")
        docDir = tmpDir.appendingPathComponent("docDir")
        try FileManager.default.createDirectory(at: docDir, withIntermediateDirectories: true)
        suiteName = "HtmlExportImageContainment-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        historyStoreURL = tmpDir.appendingPathComponent("history.json")
        bookmarksStoreURL = tmpDir.appendingPathComponent("bookmarks.json")
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
            history: HistoryStore(storeURL: historyStoreURL),
            bookmarks: BookmarksStore(storeURL: bookmarksStoreURL),
            sidebar: SidebarModel(),
            preferences: PreferencesStore(defaults: defaults)
        )
    }

    /// PNG bytes only need a recognisable, distinct payload for base64
    /// detection — not a valid image (the inliner reads raw bytes).
    private let inTreeBytes = Data([0x49, 0x4E, 0x54, 0x52, 0x45, 0x45])      // "INTREE"
    private let secretBytes = Data([0x53, 0x45, 0x43, 0x52, 0x45, 0x54])      // "SECRET"

    /// Opens a markdown doc in `docDir` that references BOTH an in-tree control
    /// image (`pic.png`, sibling of the doc) and a traversal target
    /// (`../secret.png`, OUTSIDE the doc directory). Returns the exported HTML
    /// with images inlined.
    private func exportWithBothImages() throws -> String {
        // Control: in-tree image, sibling of the doc.
        let inTree = docDir.appendingPathComponent("pic.png")
        try inTreeBytes.write(to: inTree)
        // Traversal target: a readable file OUTSIDE the doc tree, given an
        // image extension. `../secret.png` from docDir resolves to tmpDir.
        let secret = tmpDir.appendingPathComponent("secret.png")
        try secretBytes.write(to: secret)

        let md = "![ok](pic.png)\n\n![bad](../secret.png)\n"
        let docURL = docDir.appendingPathComponent("note.md")
        try md.write(to: docURL, atomically: true, encoding: .utf8)

        let m = makeModel()
        m.open(url: docURL)
        guard case .loaded = m.currentState else {
            throw XCTSkip("open did not load — environment problem, not the unit under test")
        }
        return try XCTUnwrap(m.htmlExportForActiveMarkdown(inlineImages: true),
                             "export must produce HTML for an active markdown doc")
    }

    func test_traversalTarget_isNotInlined() throws {
        let html = try exportWithBothImages()
        let secretB64 = secretBytes.base64EncodedString()
        XCTAssertFalse(html.contains(secretB64),
            "a `../secret.png` escaping the document tree must NOT be base64-inlined")
        XCTAssertFalse(html.contains("data:image/png;base64,\(secretB64)"),
            "the escaping file must never appear as a data: URI")
        // The escaping ref is left as its original relative src instead.
        XCTAssertTrue(html.contains("src=\"../secret.png\""),
            "the fenced image must fall back to its original relative reference")
    }

    func test_inTreeControlImage_isStillInlined() throws {
        let html = try exportWithBothImages()
        let inTreeB64 = inTreeBytes.base64EncodedString()
        XCTAssertTrue(html.contains("data:image/png;base64,\(inTreeB64)"),
            "the in-tree control image MUST still inline — the fence is precise, "
            + "not a blanket refusal to inline")
        XCTAssertFalse(html.contains("src=\"pic.png\""),
            "the in-tree image's relative src must have been replaced by the data: URI")
    }

    /// An absolute path to a readable host file (here, the secret outside the
    /// tree) must also be refused — the markdown `![](/abs/path)` form.
    func test_absolutePathOutsideTree_isNotInlined() throws {
        let secret = tmpDir.appendingPathComponent("abs-secret.png")
        try secretBytes.write(to: secret)
        // Absolute path reference.
        let md = "![abs](\(secret.path))\n"
        let docURL = docDir.appendingPathComponent("abs-note.md")
        try md.write(to: docURL, atomically: true, encoding: .utf8)

        let m = makeModel()
        m.open(url: docURL)
        guard case .loaded = m.currentState else {
            throw XCTSkip("open did not load — environment problem, not the unit under test")
        }
        let html = try XCTUnwrap(m.htmlExportForActiveMarkdown(inlineImages: true))
        XCTAssertFalse(html.contains(secretBytes.base64EncodedString()),
            "an absolute path to a file outside the doc tree must NOT be inlined")
    }
}
