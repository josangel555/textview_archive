import XCTest
import AppKit
@testable import ViewerUI
import ViewerCore

/// TSK-267 step 4 — the load-bearing invariant behind the hex view's
/// arithmetic frame: `HexGridGeometry`'s predicted document size must
/// EXACTLY equal what TextKit 2 lays out for real `HexDumpBuilder`
/// output. The live view sets its frame from the arithmetic and never
/// lets TK2 full-layout the document; if an OS update changes metrics
/// semantics (line stride, trailing-paragraph handling, monospace
/// advance), this goes red on the host gate BEFORE the user sees a
/// clipped or over-tall grid. Headless: NSTextLayoutManager needs no
/// window.
@MainActor
final class HexGridGeometryTK2Tests: XCTestCase {

    private func tk2Usage(of text: String, fontSize: CGFloat) -> CGSize {
        let font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        let content = NSTextContentStorage()
        let layout = NSTextLayoutManager()
        content.addTextLayoutManager(layout)
        let container = NSTextContainer(size: CGSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        layout.textContainer = container
        content.attributedString = NSAttributedString(
            string: text, attributes: [.font: font])
        layout.ensureLayout(for: layout.documentRange)
        let b = layout.usageBoundsForTextContainer
        return CGSize(width: b.width, height: b.height)
    }

    private func dump(byteCount: Int, width: Int, truncated: Bool = false) -> (text: String, plan: HexDumpBuilder.Plan) {
        let data = Data((0..<byteCount).map { UInt8(truncating: NSNumber(value: $0 % 251)) })
        let file = BinaryFile(url: URL(fileURLWithPath: "/tmp/grid.bin"),
                              data: data,
                              totalByteCount: truncated ? byteCount * 2 : byteCount,
                              isTruncated: truncated)
        let text = HexDumpBuilder.buildAll(file: file, width: width)
        let plan = HexDumpBuilder.plan(byteCount: file.byteCount,
                                       totalByteCount: file.totalByteCount,
                                       isTruncated: file.isTruncated,
                                       width: width)
        return (text, plan)
    }

    /// Predicted height == TK2 usage height for a matrix of row counts,
    /// widths and font sizes — including partial final rows and the
    /// truncation header.
    func test_predictedHeight_matchesTK2_exactly() {
        for fontSize: CGFloat in [11, 13, 16] {
            let m = HexGridMetrics.measure(fontSize: fontSize)
            for (bytes, width, truncated) in [
                (1, 16, false),          // single partial row
                (16, 16, false),         // exactly one row
                (40, 16, false),         // partial final row
                (64 * 16, 16, false),    // 64 rows
                (200, 32, false),        // wide rows
                (100, 16, true),         // truncation header (2 newlines)
            ] {
                let (text, plan) = dump(byteCount: bytes, width: width, truncated: truncated)
                let usage = tk2Usage(of: text, fontSize: fontSize)
                let lines = HexGridGeometry.lineCount(
                    newlineCount: HexGridGeometry.newlineCount(
                        rowCount: plan.rowCount,
                        hasHeader: plan.headerCharCount > 0))
                let predicted = HexGridGeometry.textHeight(
                    lineCount: lines, lineHeight: m.lineHeight)
                XCTAssertEqual(predicted, Double(usage.height), accuracy: 0.01,
                    "height mismatch: bytes=\(bytes) width=\(width) trunc=\(truncated) font=\(fontSize)")
            }
        }
    }

    /// Predicted width == TK2 usage width (the widest line is a data row;
    /// monospace advance × visible columns).
    func test_predictedWidth_matchesTK2_exactly() {
        for fontSize: CGFloat in [11, 13] {
            let m = HexGridMetrics.measure(fontSize: fontSize)
            for width in [16, 32, 64] {
                let (text, plan) = dump(byteCount: width * 3, width: width)
                let usage = tk2Usage(of: text, fontSize: fontSize)
                let predicted = HexGridGeometry.textWidth(
                    perRowChars: plan.perRowChars, charAdvance: m.charAdvance)
                XCTAssertEqual(predicted, Double(usage.width), accuracy: 0.01,
                    "width mismatch: width=\(width) font=\(fontSize)")
            }
        }
    }

    /// The empty-file shape (no rows, no header) still predicts a sane
    /// single-line height — the controller pins the frame on this path too.
    func test_emptyDump_predictsOneLine() {
        let m = HexGridMetrics.measure(fontSize: 13)
        let lines = HexGridGeometry.lineCount(
            newlineCount: HexGridGeometry.newlineCount(rowCount: 0, hasHeader: false))
        XCTAssertEqual(lines, 1)
        XCTAssertEqual(
            HexGridGeometry.textHeight(lineCount: lines, lineHeight: m.lineHeight),
            m.lineHeight, accuracy: 0.001)
    }
}
