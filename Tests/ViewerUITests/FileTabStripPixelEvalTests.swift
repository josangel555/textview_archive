import AppKit
import XCTest

/// Host-gate coverage for the PURE pixel-eval helpers the T5 file-tab-strip
/// suite (`FileTabStripVisualRegressionTests`) runs against VM captures.
/// Synthetic CGImages with known structure pin the detectors' behaviour —
/// the columns they must find, the noise they must reject — so a detector
/// regression goes red on the HOST even though the live captures are
/// VM-only (mandate point 6: headless tests pin the behaviour tier).
final class FileTabStripPixelEvalTests: HeadlessUITestCase {

    /// Light chrome background with optional dark vertical lines + glyph dots.
    private func makeImage(
        width: Int = 600, height: Int = 40, background: Int = 236,
        lines: [(x: Int, widthPx: Int, lum: Int)] = [],
        dots: [(x: Int, y: Int)] = []
    ) -> CGImage {
        let bpr = width * 4
        let ctx = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: bpr,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue
                | CGImageAlphaInfo.premultipliedLast.rawValue)!
        let g = CGFloat(background) / 255
        ctx.setFillColor(CGColor(red: g, green: g, blue: g, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        for line in lines {
            let v = CGFloat(line.lum) / 255
            ctx.setFillColor(CGColor(red: v, green: v, blue: v, alpha: 1))
            ctx.fill(CGRect(x: line.x, y: 0, width: line.widthPx, height: height))
        }
        ctx.setFillColor(CGColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 1))
        for dot in dots {
            ctx.fill(CGRect(x: dot.x, y: dot.y, width: 2, height: 2))
        }
        return ctx.makeImage()!
    }

    func test_separatorColumns_findsEachThinDarkLine() {
        let img = makeImage(lines: [(x: 180, widthPx: 1, lum: 200),
                                    (x: 361, widthPx: 1, lum: 200)])
        let cols = FileTabStripVisualRegressionTests.separatorColumns(
            in: img, xRange: 0 ..< 600, yRange: 0 ..< 40, scale: 1)
        XCTAssertEqual(cols.count, 2, "two 1-px lines → two columns, got \(cols)")
        XCTAssertEqual(cols.first.map { abs($0 - 180) <= 1 }, true)
        XCTAssertEqual(cols.last.map { abs($0 - 361) <= 1 }, true)
    }

    func test_separatorColumns_emptyOnFlatBackground() {
        let img = makeImage()
        let cols = FileTabStripVisualRegressionTests.separatorColumns(
            in: img, xRange: 0 ..< 600, yRange: 0 ..< 40, scale: 1)
        XCTAssertEqual(cols, [], "a flat strip must yield NO separator columns")
    }

    /// TEETH for the TSK-268 assert: the pre-fix strip (divider gated
    /// `index < count-1`) renders ONE line for two tabs — the detector must
    /// report exactly 1 so the `>= 2` assertion goes red.
    func test_separatorColumns_singleLine_isOne_notTwo() {
        let img = makeImage(lines: [(x: 180, widthPx: 1, lum: 200)])
        let cols = FileTabStripVisualRegressionTests.separatorColumns(
            in: img, xRange: 0 ..< 600, yRange: 0 ..< 40, scale: 1)
        XCTAssertEqual(cols.count, 1)
    }

    /// A 2-px-wide (retina / AA) line clusters into ONE detected column, not
    /// two — otherwise the count asserts double-fire on 2× captures.
    func test_separatorColumns_clusterRetinaWidthLine() {
        let img = makeImage(lines: [(x: 180, widthPx: 2, lum: 200)])
        let cols = FileTabStripVisualRegressionTests.separatorColumns(
            in: img, xRange: 0 ..< 600, yRange: 0 ..< 40, scale: 2)
        XCTAssertEqual(cols.count, 1, "one physical line must cluster to one column")
    }

    /// The VM-capture regression that drove the asymmetric contrast rule
    /// (2026-06-11): a separator flanked by the SELECTED tab's accent tint
    /// is only ~7/255 darker than the tint side, so a darker-than-BOTH-by-8
    /// rule misses it. Pin: line lum 217 between tint 227 (left) and clear
    /// background 236 (right) MUST be detected.
    func test_separatorColumns_findsLineBesideSelectedTabTint() {
        let bpr = 600 * 4
        let ctx = CGContext(
            data: nil, width: 600, height: 40,
            bitsPerComponent: 8, bytesPerRow: bpr,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue
                | CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 236/255.0, green: 236/255.0, blue: 236/255.0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 600, height: 40))
        ctx.setFillColor(CGColor(red: 227/255.0, green: 227/255.0, blue: 227/255.0, alpha: 1))
        ctx.fill(CGRect(x: 100, y: 0, width: 200, height: 40))     // tinted tab
        ctx.setFillColor(CGColor(red: 217/255.0, green: 217/255.0, blue: 217/255.0, alpha: 1))
        ctx.fill(CGRect(x: 300, y: 0, width: 1, height: 40))       // separator
        let img = ctx.makeImage()!
        let cols = FileTabStripVisualRegressionTests.separatorColumns(
            in: img, xRange: 250 ..< 400, yRange: 0 ..< 40, scale: 1)
        XCTAssertEqual(
            cols.count, 1,
            "the separator beside a selected-tab tint must be detected (got \(cols))")
        XCTAssertEqual(cols.first.map { abs($0 - 300) <= 3 }, true, "found at \(cols)")
    }

    /// A partial-height edge must NOT register — the detector requires ≥85%
    /// of the band rows. The ~70% case is the live false-positive that drove
    /// the threshold (a tab's file-icon chip is ~15 pt of the 22-pt band:
    /// its vertical edges over-counted 2 tabs as 6 columns at a 60% bar).
    func test_separatorColumns_rejectsPartialHeightEdges() {
        let bpr = 600 * 4
        let ctx = CGContext(
            data: nil, width: 600, height: 40,
            bitsPerComponent: 8, bytesPerRow: bpr,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue
                | CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.925, green: 0.925, blue: 0.925, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 600, height: 40))
        ctx.setFillColor(CGColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1))
        ctx.fill(CGRect(x: 200, y: 12, width: 1, height: 14))   // 35% of band
        ctx.fill(CGRect(x: 400, y: 6, width: 1, height: 28))    // 70% — icon chip
        let img = ctx.makeImage()!
        let cols = FileTabStripVisualRegressionTests.separatorColumns(
            in: img, xRange: 0 ..< 600, yRange: 0 ..< 40, scale: 1)
        XCTAssertEqual(cols, [], "partial-height edges (icon chips) must not count")
    }

    func test_inkPixelCount_countsGlyphInk_zeroOnFlat() {
        let withGlyph = makeImage(dots: [(x: 400, y: 18), (x: 404, y: 18),
                                         (x: 402, y: 14), (x: 402, y: 22)])
        let ink = FileTabStripVisualRegressionTests.inkPixelCount(
            in: withGlyph, xRange: 390 ..< 420, yRange: 0 ..< 40)
        XCTAssertGreaterThanOrEqual(ink, 16, "4 dots × 4 px of ink expected, got \(ink)")

        let flat = makeImage()
        XCTAssertEqual(
            FileTabStripVisualRegressionTests.inkPixelCount(
                in: flat, xRange: 390 ..< 420, yRange: 0 ..< 40),
            0, "a flat region has no ink — the TSK-261 far-right assert relies on this")
    }

    /// Dark-mode safety: ink is |Δ| from the region median, so LIGHT glyphs
    /// on a dark strip count too.
    func test_inkPixelCount_lightOnDark() {
        let bpr = 100 * 4
        let ctx = CGContext(
            data: nil, width: 100, height: 40,
            bitsPerComponent: 8, bytesPerRow: bpr,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue
                | CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.12, green: 0.12, blue: 0.12, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 100, height: 40))
        ctx.setFillColor(CGColor(red: 0.9, green: 0.9, blue: 0.9, alpha: 1))
        ctx.fill(CGRect(x: 48, y: 16, width: 4, height: 4))
        let img = ctx.makeImage()!
        XCTAssertGreaterThanOrEqual(
            FileTabStripVisualRegressionTests.inkPixelCount(
                in: img, xRange: 0 ..< 100, yRange: 0 ..< 40),
            16)
    }
}
