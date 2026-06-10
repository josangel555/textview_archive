import XCTest
import AppKit
@testable import ViewerUI
import ViewerCore

/// TSK-267 — the fixed-grid configuration contract on the live controller.
/// `HexGridGeometryTK2Tests` proves the SIZE formula matches the engine;
/// this suite proves the controller actually APPLIES it: self-sizing off,
/// frame pinned to the arithmetic size, and the `textContainerOrigin`
/// override armed. Reverting any of these silently re-introduces the
/// measured 1MB full-document-layout stall — these assertions are the
/// host-gate regression guard for that perf fix. Headless: no window.
@MainActor
final class HexFixedGridFrameTests: XCTestCase {

    private func makeApplied(byteCount: Int, width: Int = 16,
                             fontSize: CGFloat = 13) -> HexTextController {
        let c = HexTextController()
        let data = Data((0..<byteCount).map { UInt8(truncating: NSNumber(value: $0 % 251)) })
        let file = BinaryFile(url: URL(fileURLWithPath: "/tmp/fixedgrid.bin"),
                              data: data, totalByteCount: byteCount,
                              isTruncated: false)
        c.apply(file: file, fontSize: fontSize, width: width, editable: false,
                matches: [], matchPatternLength: 0, currentMatch: nil,
                clickOffsets: [], clickPatternLength: 0)
        return c
    }

    func test_apply_disablesSelfSizing_andArmsFixedOrigin() {
        let c = makeApplied(byteCount: 256)
        XCTAssertFalse(c.textView.isVerticallyResizable,
            "self-sizing forces TK2 full-document layout (the 1MB stall)")
        XCTAssertFalse(c.textView.isHorizontallyResizable)
        XCTAssertTrue(c.textView.autoresizingMask.isEmpty)
        XCTAssertTrue(c.textView.usesFixedGridOrigin,
            "the textContainerOrigin override must be armed")
    }

    func test_apply_pinsFrameToArithmeticGridSize() {
        let width = 16
        let fontSize: CGFloat = 13
        let c = makeApplied(byteCount: 64 * width, width: width, fontSize: fontSize)
        let m = HexGridMetrics.measure(fontSize: fontSize)
        let plan = HexDumpBuilder.plan(byteCount: 64 * width,
                                       totalByteCount: 64 * width,
                                       isTruncated: false, width: width)
        let lines = HexGridGeometry.lineCount(
            newlineCount: HexGridGeometry.newlineCount(
                rowCount: plan.rowCount, hasHeader: false))
        let inset = c.textView.textContainerInset
        let pad = c.textView.textContainer?.lineFragmentPadding ?? 0
        let expectedH = ceil(HexGridGeometry.textHeight(
            lineCount: lines, lineHeight: m.lineHeight) + Double(inset.height) * 2)
        let expectedW = ceil(HexGridGeometry.textWidth(
            perRowChars: plan.perRowChars, charAdvance: m.charAdvance)
            + Double(pad) * 2 + Double(inset.width) * 2)
        XCTAssertEqual(Double(c.textView.frame.height), expectedH, accuracy: 0.5)
        XCTAssertEqual(Double(c.textView.frame.width), expectedW, accuracy: 0.5)
    }

    /// The armed override answers from the inset — no layout pass needed —
    /// and the container itself stays unbounded (bounding it defeats TK2's
    /// lazy layout; tried and reverted in 30fdc32).
    func test_fixedOrigin_isInset_andContainerStaysInfinite() {
        let c = makeApplied(byteCount: 64)
        XCTAssertEqual(c.textView.textContainerOrigin.x,
                       c.textView.textContainerInset.width)
        XCTAssertEqual(c.textView.textContainerOrigin.y,
                       c.textView.textContainerInset.height)
        let size = c.textView.textContainer?.containerSize ?? .zero
        XCTAssertGreaterThan(size.height, 1_000_000,
            "container must stay effectively unbounded (lazy layout)")
    }
}
