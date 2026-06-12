import XCTest
import ViewerKit
@testable import ViewerUI

/// TSK-638 phase 1 — the model layer of Print/Export-as-PDF: the printable
/// gate, the nonce-request flow the rendered view answers, and result
/// recording. The AppKit print panel + createPDF pixels are the VM/live
/// lane; this pins every behavior the menu and view wiring depend on.
@MainActor
final class PrintExportModelTests: HeadlessUITestCase {

    private var harness: HeadlessHarness!

    override func setUp() async throws {
        try await super.setUp()
        harness = HeadlessHarness(label: "PrintExportModelTests")
    }

    override func tearDown() async throws {
        harness?.cleanup()
        harness = nil
        try await super.tearDown()
    }

    func test_gate_marketdownRendered_yes_sourceMode_no() throws {
        let model = harness.model
        let url = try harness.writeFile("doc.md", "# Hello\n")
        model.open(url: url)
        XCTAssertEqual(model.currentViewMode, .rendered)
        XCTAssertTrue(model.canPrintRenderedPage, "rendered markdown is printable")

        model.toggleViewMode()
        XCTAssertNotEqual(model.currentViewMode, .rendered)
        XCTAssertFalse(model.canPrintRenderedPage, "source mode is phase 2 — not printable")
        XCTAssertFalse(model.printRenderedPage(), "print request must refuse")
        XCTAssertFalse(model.exportRenderedPDF(to: URL(fileURLWithPath: "/tmp/x.pdf")))
    }

    func test_gate_plainText_never() throws {
        let model = harness.model
        let url = try harness.writeFile("notes.txt", "plain\n")
        model.open(url: url)
        XCTAssertFalse(model.canPrintRenderedPage, "plain text has no rendered page")
        XCTAssertFalse(model.printRenderedPage())
    }

    func test_printRequest_bumpsNonce_onlyWhenPrintable() throws {
        let model = harness.model
        let url = try harness.writeFile("doc.md", "# H\n")
        model.open(url: url)
        let before = model.renderedPrintRequest
        XCTAssertTrue(model.printRenderedPage())
        XCTAssertEqual(model.renderedPrintRequest, before + 1,
                       "the nonce is the view's trigger — it must bump exactly once")
    }

    func test_exportRequest_carriesDestination_andNonceIncrements() throws {
        let model = harness.model
        let url = try harness.writeFile("doc.md", "# H\n")
        model.open(url: url)
        let dest1 = URL(fileURLWithPath: "/tmp/one.pdf")
        let dest2 = URL(fileURLWithPath: "/tmp/two.pdf")
        XCTAssertTrue(model.exportRenderedPDF(to: dest1))
        XCTAssertEqual(model.renderedPDFExportRequest?.url, dest1)
        let n1 = model.renderedPDFExportRequest!.nonce
        XCTAssertTrue(model.exportRenderedPDF(to: dest2))
        XCTAssertEqual(model.renderedPDFExportRequest?.url, dest2)
        XCTAssertEqual(model.renderedPDFExportRequest!.nonce, n1 + 1,
                       "each export is a fresh nonce — re-exporting to the same path must re-fire")
    }

    func test_resultRecording_roundTrips() throws {
        let model = harness.model
        model.recordPDFExportResult(nonce: 7, ok: true, message: "/tmp/out.pdf")
        XCTAssertEqual(model.renderedPDFExportResult,
                       DocumentModel.PDFExportResult(nonce: 7, ok: true, message: "/tmp/out.pdf"))
        model.recordPDFExportResult(nonce: 8, ok: false, message: "disk full")
        XCTAssertEqual(model.renderedPDFExportResult?.ok, false)
    }
}
