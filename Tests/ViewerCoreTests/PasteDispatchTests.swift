import XCTest
@testable import ViewerCore

/// TSK-958 — Universal Paste: pasteboard type-precedence resolver. Pure model,
/// fully host-coverable. Feeds synthetic type lists for each precedence combo
/// and asserts the chosen `PasteTarget`.
final class PasteDispatchTests: XCTestCase {

    typealias Target = PasteDispatch.PasteTarget

    // MARK: - Single-representation baselines

    func test_onlyPlainText_isPlainText() {
        XCTAssertEqual(PasteDispatch.resolve(types: ["public.utf8-plain-text"]), .plainText)
    }

    func test_onlyImage_isImage() {
        XCTAssertEqual(PasteDispatch.resolve(types: ["public.png"]), .image)
        XCTAssertEqual(PasteDispatch.resolve(types: ["public.tiff"]), .image)
    }

    func test_onlyTSV_isTable() {
        XCTAssertEqual(PasteDispatch.resolve(types: ["public.tab-separated-values-text"]), .table)
    }

    func test_onlyRTF_isRichText() {
        XCTAssertEqual(PasteDispatch.resolve(types: ["public.rtf"]), .richText)
    }

    func test_onlyFileURL_isFileURL() {
        XCTAssertEqual(PasteDispatch.resolve(types: ["public.file-url"]), .fileURL)
    }

    // MARK: - Precedence: image > text (coexisting)

    func test_imagePlusText_isImage() {
        // A copied web image: PNG + a source-URL plain-text rep.
        let types = ["public.png", "public.utf8-plain-text"]
        XCTAssertEqual(PasteDispatch.resolve(types: types), .image)
    }

    func test_imagePlusRichTextPlusText_isImage() {
        let types = ["public.tiff", "public.rtf", "public.utf8-plain-text", "public.html"]
        XCTAssertEqual(PasteDispatch.resolve(types: types, htmlHasTable: true), .image,
                       "image wins even over a coexisting HTML table")
    }

    // MARK: - Precedence: fileURL is the top

    func test_fileURLPlusImagePlusText_isFileURL() {
        // A dragged image file from Finder: file-url + image preview + path text.
        let types = ["public.file-url", "public.png", "public.utf8-plain-text"]
        XCTAssertEqual(PasteDispatch.resolve(types: types), .fileURL)
    }

    func test_legacyFilenamesPboard_isFileURL() {
        XCTAssertEqual(PasteDispatch.resolve(types: ["NSFilenamesPboardType", "NSStringPboardType"]),
                       .fileURL)
    }

    // MARK: - Precedence: HTML-with-<table> + text → table

    func test_htmlTablePlusText_isTable() {
        // Copied spreadsheet range: HTML(<table>) + plain text fallback.
        let types = ["public.html", "public.utf8-plain-text"]
        XCTAssertEqual(PasteDispatch.resolve(types: types, htmlHasTable: true), .table)
    }

    func test_htmlTablePlusRTFPlusText_isTable() {
        let types = ["public.html", "public.rtf", "public.utf8-plain-text"]
        XCTAssertEqual(PasteDispatch.resolve(types: types, htmlHasTable: true), .table,
                       "table beats rich text")
    }

    func test_tsvPlusRTFPlusText_isTable() {
        let types = ["public.tab-separated-values-text", "public.rtf", "public.utf8-plain-text"]
        XCTAssertEqual(PasteDispatch.resolve(types: types), .table)
    }

    // MARK: - Precedence: HTML prose (no table) → richText, not table

    func test_htmlProsePlusText_isRichText() {
        // Copied paragraph from a web page: HTML(no <table>) + plain text.
        let types = ["public.html", "public.utf8-plain-text"]
        XCTAssertEqual(PasteDispatch.resolve(types: types, htmlHasTable: false), .richText)
    }

    func test_htmlWithoutTableSignal_defaultsToRichText() {
        // The no-peek overload treats HTML as rich text (never a phantom table).
        let types = ["public.html", "public.utf8-plain-text"]
        XCTAssertEqual(PasteDispatch.resolve(types: types), .richText)
    }

    func test_rtfPlusText_isRichText() {
        XCTAssertEqual(PasteDispatch.resolve(types: ["public.rtf", "public.utf8-plain-text"]),
                       .richText)
    }

    // MARK: - Plain text floor

    func test_textOnly_variousIdentifiers() {
        XCTAssertEqual(PasteDispatch.resolve(types: ["public.utf16-external-plain-text"]), .plainText)
        XCTAssertEqual(PasteDispatch.resolve(types: ["NSStringPboardType"]), .plainText)
        XCTAssertEqual(PasteDispatch.resolve(types: ["public.text"]), .plainText)
    }

    // MARK: - Nothing recognised

    func test_emptyTypes_isNil() {
        XCTAssertNil(PasteDispatch.resolve(types: []))
    }

    func test_unknownTypes_isNil() {
        XCTAssertNil(PasteDispatch.resolve(types: ["com.example.proprietary", "x-vendor/blob"]))
    }

    // MARK: - Order-independence + case-insensitivity

    func test_orderDoesNotMatter() {
        let a = ["public.utf8-plain-text", "public.png"]
        let b = ["public.png", "public.utf8-plain-text"]
        XCTAssertEqual(PasteDispatch.resolve(types: a), PasteDispatch.resolve(types: b))
        XCTAssertEqual(PasteDispatch.resolve(types: a), .image)
    }

    func test_caseInsensitiveMatch() {
        XCTAssertEqual(PasteDispatch.resolve(types: ["PUBLIC.PNG"]), .image)
        XCTAssertEqual(PasteDispatch.resolve(types: ["Public.File-URL"]), .fileURL)
    }

    // MARK: - htmlBody convenience overload + table detection

    func test_resolveWithHtmlBody_detectsTable() {
        let body = "<html><body><table><tr><td>1</td></tr></table></body></html>"
        XCTAssertEqual(
            PasteDispatch.resolve(types: ["public.html", "public.utf8-plain-text"], htmlBody: body),
            .table)
    }

    func test_resolveWithHtmlBody_proseIsRichText() {
        let body = "<html><body><p>Just a paragraph.</p></body></html>"
        XCTAssertEqual(
            PasteDispatch.resolve(types: ["public.html", "public.utf8-plain-text"], htmlBody: body),
            .richText)
    }

    func test_resolveWithNilHtmlBody_isRichText() {
        XCTAssertEqual(
            PasteDispatch.resolve(types: ["public.html"], htmlBody: nil),
            .richText)
    }

    func test_htmlContainsTable_variants() {
        XCTAssertTrue(PasteDispatch.htmlContainsTable("<table>"))
        XCTAssertTrue(PasteDispatch.htmlContainsTable("<TABLE>"))
        XCTAssertTrue(PasteDispatch.htmlContainsTable("<table class=\"data\">"))
        XCTAssertTrue(PasteDispatch.htmlContainsTable("<table\n  border=1>"))
        XCTAssertFalse(PasteDispatch.htmlContainsTable("<p>no table here</p>"))
        XCTAssertFalse(PasteDispatch.htmlContainsTable("the word table in prose"))
    }

    // MARK: - Full ladder sanity (each rung wins over all below it)

    func test_fullPrecedenceLadder() {
        // All five reps present at once → fileURL wins.
        let all = [
            "public.file-url", "public.png",
            "public.tab-separated-values-text", "public.rtf",
            "public.utf8-plain-text", "public.html",
        ]
        XCTAssertEqual(PasteDispatch.resolve(types: all, htmlHasTable: true), .fileURL)

        // Drop fileURL → image.
        XCTAssertEqual(PasteDispatch.resolve(types: Array(all.dropFirst()), htmlHasTable: true), .image)

        // Drop fileURL + image → table.
        XCTAssertEqual(PasteDispatch.resolve(types: Array(all.dropFirst(2)), htmlHasTable: true), .table)

        // Drop down to rtf + text + html(no table) → richText.
        XCTAssertEqual(PasteDispatch.resolve(types: ["public.rtf", "public.utf8-plain-text"],
                                             htmlHasTable: false), .richText)

        // Only plain text → plainText.
        XCTAssertEqual(PasteDispatch.resolve(types: ["public.utf8-plain-text"]), .plainText)
    }
}
