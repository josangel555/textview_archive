import XCTest
@testable import ViewerCore

/// Teeth for the standalone HTML export wrapper (TSK-675). The load-bearing
/// distinction from `HTMLRenderer.renderPage` is the ABSENCE of the strict CSP
/// (so the exported file renders in a browser) — pinned here so a regression
/// that routes export through the in-app page is caught.
final class HtmlExportTests: XCTestCase {

    func test_standaloneDocument_embedsBodyAndStylesheet() {
        let doc = HtmlExport.standaloneDocument(
            body: "<h1>Hi</h1>", stylesheet: "body{color:red}", title: "Notes")
        XCTAssertTrue(doc.hasPrefix("<!DOCTYPE html>"))
        XCTAssertTrue(doc.contains("<h1>Hi</h1>"))
        XCTAssertTrue(doc.contains("body{color:red}"))
        XCTAssertTrue(doc.contains("<title>Notes</title>"))
        XCTAssertTrue(doc.contains("<meta charset=\"utf-8\">"))
    }

    func test_standaloneDocument_hasNoCSP() {
        // The export must NOT carry the in-app no-network CSP (would block
        // external images/fonts in a browser).
        let doc = HtmlExport.standaloneDocument(body: "x", stylesheet: "y", title: "t")
        XCTAssertFalse(doc.contains("Content-Security-Policy"))
    }

    func test_standaloneDocument_escapesTitle() {
        let doc = HtmlExport.standaloneDocument(
            body: "", stylesheet: "", title: "A < B & C > D")
        XCTAssertTrue(doc.contains("<title>A &lt; B &amp; C &gt; D</title>"))
    }

    func test_htmlFilename_swapsExtension() {
        XCTAssertEqual(HtmlExport.htmlFilename(for: URL(fileURLWithPath: "/x/notes.md")), "notes.html")
        XCTAssertEqual(HtmlExport.htmlFilename(for: URL(fileURLWithPath: "/x/a.markdown")), "a.html")
        XCTAssertEqual(HtmlExport.htmlFilename(for: URL(fileURLWithPath: "/x/README")), "README.html")
    }

    // MARK: inlineLocalImages (self-contained export)

    func test_inline_replacesLocalImageWithDataURI() {
        let html = "<img src=\"pic.png\" alt=\"x\">"
        let out = HtmlExport.inlineLocalImages(html) { src in
            src == "pic.png" ? Data([0xDE, 0xAD]) : nil
        }
        XCTAssertEqual(out, "<img src=\"data:image/png;base64,\(Data([0xDE,0xAD]).base64EncodedString())\" alt=\"x\">")
    }

    func test_inline_leavesExternalAndDataAndMissing() {
        let html = """
        <img src="https://x.com/a.png"> <img src="data:image/png;base64,zz"> \
        <img src="gone.png"> <img src="//cdn/x.png">
        """
        // readData returns nil for everything (incl. the missing local one)
        let out = HtmlExport.inlineLocalImages(html) { _ in nil }
        XCTAssertEqual(out, html, "external/data/protocol-relative + missing-local all untouched")
    }

    func test_inline_multipleLocalImages() {
        let html = "<img src=\"a.png\"><img src=\"b.gif\">"
        let out = HtmlExport.inlineLocalImages(html) { _ in Data([1]) }
        XCTAssertTrue(out.contains("data:image/png;base64,"))
        XCTAssertTrue(out.contains("data:image/gif;base64,"))
        XCTAssertFalse(out.contains("\"a.png\"") || out.contains("\"b.gif\""))
    }

    func test_isLocalImageRef() {
        XCTAssertTrue(HtmlExport.isLocalImageRef("img/p.png"))
        XCTAssertTrue(HtmlExport.isLocalImageRef("../up.png"))
        XCTAssertFalse(HtmlExport.isLocalImageRef("https://x/p.png"))
        XCTAssertFalse(HtmlExport.isLocalImageRef("data:image/png;base64,z"))
        XCTAssertFalse(HtmlExport.isLocalImageRef("//cdn/p.png"))
        XCTAssertFalse(HtmlExport.isLocalImageRef("#anchor"))
    }

    func test_mimeType() {
        XCTAssertEqual(HtmlExport.mimeType(forPathExtension: "PNG"), "image/png")
        XCTAssertEqual(HtmlExport.mimeType(forPathExtension: "jpeg"), "image/jpeg")
        XCTAssertEqual(HtmlExport.mimeType(forPathExtension: "svg"), "image/svg+xml")
        XCTAssertNil(HtmlExport.mimeType(forPathExtension: "txt"))
    }
}
