import XCTest
import PDFKit
import CoreText
import AppKit
@testable import ViewerUI

/// TSK-1140 — host-safe coverage for the `PDFSearcher` find cursor (slice 1 of the
/// PDF reader find). Generates a real single-page PDF with extractable text via
/// Core Text, then drives search + next/prev/wraparound against PDFKit's
/// `findString` — no window/view. The render slice (FindCoordinator `pdf` bag +
/// `PDFView.setCurrentSelection` + a PDF find bar) is separate.
@MainActor
final class PDFSearcherTests: XCTestCase {

    /// Draw `text` into a one-page PDF and return the parsed document. Uses Core
    /// Text so the glyphs carry a ToUnicode map → PDFKit can extract + search them.
    private func makePDF(_ text: String) throws -> PDFDocument {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let consumer = try XCTUnwrap(CGDataConsumer(data: data as CFMutableData))
        let ctx = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &box, nil))
        ctx.beginPDFPage(nil)
        let attr = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 18),
            .foregroundColor: NSColor.black,
        ])
        let line = CTLineCreateWithAttributedString(attr)
        ctx.textPosition = CGPoint(x: 40, y: 700)
        CTLineDraw(line, ctx)
        ctx.endPDFPage()
        ctx.closePDF()
        return try XCTUnwrap(PDFDocument(data: data as Data), "PDFDocument from generated data")
    }

    /// Precondition: the generated PDF's text must be extractable, else the whole
    /// approach (host-searching a generated PDF) is invalid — fail loudly here.
    func test_generatedPDF_textIsExtractable_precondition() throws {
        let doc = try makePDF("alpha foo beta")
        let extracted = (doc.string ?? "").lowercased()
        XCTAssertTrue(extracted.contains("foo"),
                      "generated PDF text must be extractable (got: \(extracted))")
    }

    func test_search_findsAllMatches_cursorStartsAtFirst() throws {
        let doc = try makePDF("foo bar foo baz foo qux")   // three "foo"
        let s = PDFSearcher()
        let st = s.search("foo", in: doc)
        XCTAssertEqual(st.total, 3, "all three occurrences found")
        XCTAssertEqual(st.currentIndex, 0, "cursor starts at the first match")
        XCTAssertEqual(st.summary, "1/3")
        XCTAssertEqual(st.matched, true)
        XCTAssertEqual(s.current?.string?.lowercased(), "foo", "current selection is the match")
    }

    func test_next_advances_andWrapsAround() throws {
        let doc = try makePDF("foo bar foo baz foo")   // three "foo"
        let s = PDFSearcher()
        s.search("foo", in: doc)
        _ = s.next(); XCTAssertEqual(s.state.currentIndex, 1)
        _ = s.next(); XCTAssertEqual(s.state.currentIndex, 2)
        _ = s.next(); XCTAssertEqual(s.state.currentIndex, 0, "next past the end wraps to the first")
    }

    func test_prev_wrapsBackwards() throws {
        let doc = try makePDF("foo bar foo baz foo")
        let s = PDFSearcher()
        s.search("foo", in: doc)
        _ = s.prev(); XCTAssertEqual(s.state.currentIndex, 2, "prev before the start wraps to the last")
        _ = s.prev(); XCTAssertEqual(s.state.currentIndex, 1)
    }

    func test_caseInsensitiveByDefault_caseSensitiveOptIn() throws {
        let doc = try makePDF("Foo foo FOO")   // three, mixed case
        let s = PDFSearcher()
        XCTAssertEqual(s.search("foo", in: doc).total, 3, "case-insensitive by default matches all")
        XCTAssertEqual(s.search("foo", in: doc, caseSensitive: true).total, 1,
                       "case-sensitive matches only the exact-case occurrence")
    }

    func test_noMatch_hasEmptySummary_andNilCurrent() throws {
        let doc = try makePDF("alpha beta gamma")
        let s = PDFSearcher()
        let st = s.search("zzz", in: doc)
        XCTAssertEqual(st.total, 0)
        XCTAssertEqual(st.currentIndex, -1)
        XCTAssertEqual(st.summary, "")
        XCTAssertEqual(st.matched, false)
        XCTAssertNil(s.current)
        XCTAssertNil(s.next(), "next with no matches is a no-op")
    }

    func test_emptyQuery_clears() throws {
        let doc = try makePDF("foo foo")
        let s = PDFSearcher()
        s.search("foo", in: doc)
        XCTAssertEqual(s.state.total, 2)
        let st = s.search("", in: doc)
        XCTAssertEqual(st.total, 0)
        XCTAssertNil(st.matched, "empty query is 'no active search', not 'no match'")
        XCTAssertEqual(s.query, "")
    }
}
