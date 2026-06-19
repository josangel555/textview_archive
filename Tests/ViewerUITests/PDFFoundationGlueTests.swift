import XCTest
import CoreGraphics
@testable import ViewerUI
@testable import ViewerKit

/// PDF reader FOUNDATION (TSK-670) — the `ViewerUI`-layer half of the PDF
/// viewer contract that can't live in `ViewerKit`: the on-disk magic-byte
/// sniff (`DocumentModel.sniffCategory`) and the PDF metadata extraction
/// (`MetadataPanel.pdfMetadata`), both reading real files from the per-user
/// tmpdir.
///
/// HOST-SAFE: pure model/helper calls — no NSApplication, no window, no
/// `.app` launch. The on-screen `PDFView` render (crisp pixels, scroll, zoom)
/// stays VM-only (T5 `PreviewsUATTests.PV-03`); this file pins the byte-sniff
/// and metadata glue that feeds it.
///
/// The extension + view-mode routing contract is pinned host-side in
/// `PDFRoutingContractTests` (ViewerKit).
@MainActor
final class PDFFoundationGlueTests: XCTestCase {

    private var tmp: URL!

    override func setUp() async throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("PDFFoundationGlue-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: tmp, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let tmp { try? FileManager.default.removeItem(at: tmp) }
    }

    // MARK: - Magic-byte sniff: extension-less file whose bytes start with %PDF

    /// A file with NO extension at all, whose bytes lead with `%PDF`, must
    /// sniff to `.pdf` so the "Open As…" hint floats the PDF viewer to the
    /// front. The existing sniff test (`OpenAsSniffAndHostedViewTests`) uses
    /// `doc.blob` (an extension that just isn't a known type); this pins the
    /// genuinely extension-less case the hint calls out.
    func test_sniff_extensionlessFile_withPDFMagic_classifiesAsPDF() throws {
        let url = tmp.appendingPathComponent("scanned-document")  // no extension
        XCTAssertTrue(url.pathExtension.isEmpty, "fixture must be extension-less")
        try Data(Array("%PDF-1.4\n%âãÏÓ".utf8)).write(to: url)
        XCTAssertEqual(DocumentModel.sniffCategory(url: url), .pdf,
                       "extension-less %PDF bytes must sniff as PDF")
    }

    /// Defensive: only the leading `%PDF` magic counts — a `%PDF` appearing
    /// later in the header (not at offset 0) must NOT false-positive.
    func test_sniff_pdfMagic_notAtStart_doesNotClassifyAsPDF() throws {
        let url = tmp.appendingPathComponent("decoy")
        try Data(Array("not a pdf %PDF".utf8)).write(to: url)
        XCTAssertNotEqual(DocumentModel.sniffCategory(url: url), .pdf,
                          "%PDF must be at offset 0 to classify as PDF")
    }

    // MARK: - pdfMetadata: real multi-page fixture yields non-nil page count

    /// Build a real 3-page PDF via CoreGraphics, write it to the tmpdir, and
    /// assert `pdfMetadata` reads back the page count + page size from disk.
    /// This is the end-to-end PDFKit read path the metadata panel uses for
    /// `.pdf` files — distinct from the `pdfRows` pure-mapping tests.
    func test_pdfMetadata_realThreePageFixture_yieldsPageCountAndSize() throws {
        let url = tmp.appendingPathComponent("multipage.pdf")
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)  // US Letter
        let ctx = try XCTUnwrap(
            CGContext(url as CFURL, mediaBox: &box, nil),
            "failed to create a PDF CGContext")
        for _ in 0..<3 {
            ctx.beginPDFPage(nil)
            ctx.endPDFPage()
        }
        ctx.closePDF()

        let rows = MetadataPanel.pdfMetadata(url: url)
        XCTAssertFalse(rows.isEmpty, "a real PDF must yield metadata rows")
        let pages = rows.first(where: { $0.label == "Pages" })?.value
        XCTAssertEqual(pages, "3", "page count must be read from the real PDF")
        XCTAssertEqual(rows.first(where: { $0.label == "Page Size" })?.value,
                       "612 × 792 pt", "page size must be read from the media box")
    }

    /// A missing / unreadable PDF must degrade to an empty row set, never a
    /// crash or a bogus "Pages: 0" — `PDFDocument(url:)` returns nil.
    func test_pdfMetadata_missingFile_yieldsEmptyRows() {
        let url = tmp.appendingPathComponent("nonexistent.pdf")
        XCTAssertTrue(MetadataPanel.pdfMetadata(url: url).isEmpty,
                      "an unreadable PDF must yield no metadata rows")
    }

    // MARK: - Routing parity: sniff result agrees with the .pdf lens

    /// End-to-end glue: a sniffed-PDF file resolves to the same first-class
    /// preview lens an extension-routed `.pdf` does — proving the sniff hint
    /// and the extension path converge on the PDF viewer, not divergent lenses.
    func test_sniffedPDF_resolvesToPreviewLens_sameAsExtensionRouted() throws {
        let url = tmp.appendingPathComponent("hinted-pdf")
        try Data(Array("%PDF-1.5".utf8)).write(to: url)
        let sniffed = try XCTUnwrap(DocumentModel.sniffCategory(url: url))
        XCTAssertEqual(sniffed, .pdf)
        // The sniffed category, used as a forced "Open As…" hint, must default
        // to the same Preview lens the extension path gives.
        XCTAssertEqual(
            ViewModeOptions.defaultMode(for: url, forcedCategory: sniffed),
            .preview,
            "sniffed PDF must open into the Preview lens, matching .pdf routing")
    }
}
