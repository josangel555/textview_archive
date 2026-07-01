import XCTest
import PDFKit
import CoreText
import AppKit
@testable import ViewerUI

/// TSK-1140 slice 5 — validates the PDF-find CONSUMER (the actual `updateNSView`
/// logic, extracted to `PDFFindDriver`) against a real `PDFView`: a query selects
/// the match, next steps it, a no-match clears it. `PDFView.currentSelection` is
/// the on-screen truth — PDFView natively renders its current selection as the
/// highlight — and the selection STATE is testable without a window (no T5 grant),
/// so this graduates the PDF-find behavior to validated host-side.
@MainActor
final class PDFFindDriverTests: XCTestCase {

    private func makePDFView(_ text: String) throws -> PDFView {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let consumer = try XCTUnwrap(CGDataConsumer(data: data as CFMutableData))
        let ctx = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &box, nil))
        ctx.beginPDFPage(nil)
        let attr = NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 18)])
        let line = CTLineCreateWithAttributedString(attr)
        ctx.textPosition = CGPoint(x: 40, y: 700)
        CTLineDraw(line, ctx)
        ctx.endPDFPage(); ctx.closePDF()
        let v = PDFView()
        v.document = try XCTUnwrap(PDFDocument(data: data as Data))
        return v
    }

    func test_sync_query_selectsFirstMatchInPDFView() throws {
        let v = try makePDFView("foo bar foo baz foo")
        let d = PDFFindDriver()
        let st = d.sync(query: "foo", caseSensitive: false, nextNonce: 0, prevNonce: 0, in: v)
        XCTAssertEqual(st?.total, 3, "all matches found")
        XCTAssertEqual(v.currentSelection?.string?.lowercased(), "foo",
                       "the PDFView's current selection (the on-screen highlight) is the first match")
    }

    func test_sync_nextNonce_advancesTheSelection() throws {
        let v = try makePDFView("foo bar foo baz foo")
        let d = PDFFindDriver()
        d.sync(query: "foo", caseSensitive: false, nextNonce: 0, prevNonce: 0, in: v)
        d.sync(query: "foo", caseSensitive: false, nextNonce: 1, prevNonce: 0, in: v)  // ⌘G
        XCTAssertEqual(d.searcher.state.currentIndex, 1, "the next nonce stepped the cursor")
        XCTAssertNotNil(v.currentSelection, "the PDFView still has a selection after stepping")
    }

    func test_sync_noMatch_clearsThePDFViewSelection() throws {
        let v = try makePDFView("alpha beta gamma")
        let d = PDFFindDriver()
        d.sync(query: "alpha", caseSensitive: false, nextNonce: 0, prevNonce: 0, in: v)
        XCTAssertNotNil(v.currentSelection, "precondition: a match is selected")
        d.sync(query: "zzz", caseSensitive: false, nextNonce: 0, prevNonce: 0, in: v)
        XCTAssertNil(v.currentSelection, "a no-match query clears the PDFView selection")
    }

    func test_sync_identicalInputs_doesNotReSearch() throws {
        // updateNSView fires repeatedly; identical inputs must be a no-op so we
        // don't reset the cursor on every SwiftUI re-render.
        let v = try makePDFView("foo foo")
        let d = PDFFindDriver()
        XCTAssertNotNil(d.sync(query: "foo", caseSensitive: false, nextNonce: 0, prevNonce: 0, in: v),
                        "first sync runs the search")
        XCTAssertNil(d.sync(query: "foo", caseSensitive: false, nextNonce: 0, prevNonce: 0, in: v),
                     "identical inputs → nil (no re-search, cursor untouched)")
    }
}
