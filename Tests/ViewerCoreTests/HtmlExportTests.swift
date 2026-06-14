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
}
