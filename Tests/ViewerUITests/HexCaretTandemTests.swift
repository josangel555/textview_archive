import XCTest
import AppKit
@testable import ViewerUI
import ViewerCore

/// Owner 2026-08-09 — two hex-view gaps:
///   1. the EDIT caret was invisible (a zero-length selection draws no
///      insertion beam in a non-editable NSTextView) — it is now a painted
///      cell: strong tint on the active side, lighter twin on the other;
///   2. VIEW-mode selections in the hex columns now mirror onto the ascii
///      chars (and vice versa) via a painted tandem highlight.
/// Headless: attribute assertions on the text storage, no window.
@MainActor
final class HexCaretTandemTests: XCTestCase {

    private func makeApplied(byteCount: Int = 64, editable: Bool,
                             width: Int = 16) -> HexTextController {
        let c = HexTextController()
        let data = Data((0..<byteCount).map { UInt8(truncating: NSNumber(value: $0 % 251)) })
        let file = BinaryFile(url: URL(fileURLWithPath: "/tmp/caret-tandem.bin"),
                              data: data, totalByteCount: byteCount,
                              isTruncated: false)
        c.apply(file: file, fontSize: 13, width: width, editable: editable,
                matches: [], matchPatternLength: 0, currentMatch: nil,
                clickOffsets: [], clickPatternLength: 0)
        return c
    }

    /// First-row start = everything through the header line's newline.
    private func headerCharCount(_ c: HexTextController) -> Int {
        let s = c.textView.string as NSString
        let nl = s.range(of: "\n")
        XCTAssertNotEqual(nl.location, NSNotFound, "dump must carry a header line")
        return nl.location + 1
    }

    private func background(_ c: HexTextController, at index: Int) -> NSColor? {
        guard let storage = c.textView.textStorage, index < storage.length else { return nil }
        return storage.attribute(.backgroundColor, at: index, effectiveRange: nil) as? NSColor
    }

    func test_placeEditCaret_paintsTheCell_andItsTwin() {
        let c = makeApplied(editable: true)
        let header = headerCharCount(c)
        let width = 16
        // Byte 5's hex cell char index (row 0, column 5).
        let hexIdx = header + HexLayout.hexCharOffset(inRowColumn: 5)
        let asciiIdx = header + HexLayout.asciiCharOffset(inRowColumn: 5, width: width)
        XCTAssertTrue(c.placeEditCaret(fromCharIndex: hexIdx),
                      "a hex-cell click must place the caret")
        XCTAssertNotNil(background(c, at: hexIdx),
                        "the caret CELL must be visibly painted (it was invisible)")
        XCTAssertNotNil(background(c, at: asciiIdx),
                        "the twin ascii cell must carry the lighter tandem tint")
    }

    func test_movingTheCaret_clearsThePreviousCell() {
        let c = makeApplied(editable: true)
        let header = headerCharCount(c)
        let width = 16
        let firstHex = header + HexLayout.hexCharOffset(inRowColumn: 2)
        let secondHex = header + HexLayout.hexCharOffset(inRowColumn: 9)
        _ = c.placeEditCaret(fromCharIndex: firstHex)
        _ = c.placeEditCaret(fromCharIndex: secondHex)
        XCTAssertNil(background(c, at: firstHex),
                     "the previous caret cell must be un-painted on move")
        XCTAssertNotNil(background(c, at: secondHex))
        XCTAssertNotNil(background(
            c, at: header + HexLayout.asciiCharOffset(inRowColumn: 9, width: width)))
    }

    func test_hexSideSelection_mirrorsOntoAsciiChars() {
        let c = makeApplied(editable: false)
        let header = headerCharCount(c)
        let width = 16
        // Select bytes 2...5 in the HEX columns (start of cell 2 through the
        // end of cell 5).
        let start = header + HexLayout.hexCharOffset(inRowColumn: 2)
        let end = header + HexLayout.hexCharOffset(inRowColumn: 5) + 2
        c.textView.setSelectedRange(NSRange(location: start, length: end - start))
        c.mirrorSelectionChanged()
        for col in 2...5 {
            XCTAssertNotNil(
                background(c, at: header + HexLayout.asciiCharOffset(
                    inRowColumn: col, width: width)),
                "ascii char for byte \(col) must carry the tandem tint")
        }
        XCTAssertNil(
            background(c, at: header + HexLayout.asciiCharOffset(inRowColumn: 0, width: width)),
            "bytes outside the selection stay unpainted")
    }

    func test_collapsingTheSelection_clearsTheMirror() {
        let c = makeApplied(editable: false)
        let header = headerCharCount(c)
        let width = 16
        let start = header + HexLayout.hexCharOffset(inRowColumn: 2)
        c.textView.setSelectedRange(NSRange(location: start, length: 8))
        c.mirrorSelectionChanged()
        c.textView.setSelectedRange(NSRange(location: start, length: 0))
        c.mirrorSelectionChanged()
        for col in 2...5 {
            XCTAssertNil(
                background(c, at: header + HexLayout.asciiCharOffset(
                    inRowColumn: col, width: width)),
                "the mirror tint must clear when the selection collapses")
        }
    }
}
