import CoreGraphics
import XCTest
@testable import ViewerCore

/// T1 headless tests for the raster paint engine (TSK-285): pure pixels-in →
/// pixels-out assertions on `RasterCanvas` (flood fill, brush dab/stroke, color
/// pick) plus the `CGImage` round-trip bridge. No window, no fixtures on disk —
/// every canvas is built in-memory and asserted byte-for-byte.
final class RasterCanvasTests: XCTestCase {

    // MARK: - construction

    func test_init_filledCanvas_hasUniformColor() {
        let c = RasterCanvas(width: 3, height: 2, fill: .red)
        XCTAssertEqual(c.width, 3)
        XCTAssertEqual(c.height, 2)
        XCTAssertEqual(c.pixels.count, 3 * 2 * 4)
        for y in 0..<2 {
            for x in 0..<3 {
                XCTAssertEqual(c.pixel(x: x, y: y), .red, "every pixel is the fill color")
            }
        }
    }

    func test_init_defaultFill_isTransparent() {
        let c = RasterCanvas(width: 2, height: 2)
        XCTAssertEqual(c.pixel(x: 0, y: 0), .clear)
        XCTAssertTrue(c.pixels.allSatisfy { $0 == 0 }, "default fill is all-zero (transparent black)")
    }

    func test_init_nonPositiveDims_collapseToEmpty() {
        let c = RasterCanvas(width: -5, height: 3)
        XCTAssertTrue(c.isEmpty)
        XCTAssertEqual(c.pixels.count, 0)
        XCTAssertNil(c.pixel(x: 0, y: 0))
    }

    func test_initWithPixels_rejectsLengthMismatch() {
        XCTAssertNil(RasterCanvas(width: 2, height: 2, pixels: [0, 0, 0]),
                     "a buffer that isn't width·height·4 bytes is rejected")
        XCTAssertNotNil(RasterCanvas(width: 1, height: 1, pixels: [1, 2, 3, 4]))
    }

    // MARK: - pixel access + bounds

    func test_setPixel_outOfBounds_isNoOp() {
        var c = RasterCanvas(width: 2, height: 2, fill: .white)
        c.setPixel(x: 5, y: 5, to: .red)        // off-canvas
        c.setPixel(x: -1, y: 0, to: .red)       // negative
        for y in 0..<2 { for x in 0..<2 {
            XCTAssertEqual(c.pixel(x: x, y: y), .white, "OOB writes don't touch valid pixels")
        }}
    }

    func test_pickColor_readsExactPixel() {
        var c = RasterCanvas(width: 3, height: 3, fill: .white)
        c.setPixel(x: 1, y: 2, to: RGBAColor(r: 10, g: 20, b: 30, a: 200))
        XCTAssertEqual(c.pickColor(x: 1, y: 2), RGBAColor(r: 10, g: 20, b: 30, a: 200))
        XCTAssertEqual(c.pickColor(x: 0, y: 0), .white)
        XCTAssertNil(c.pickColor(x: 9, y: 9), "off-canvas pick is nil")
    }

    // MARK: - flood fill

    func test_floodFill_replacesContiguousRegion() {
        // A 5x5 white canvas with a red border (a closed ring); fill the white
        // interior to green — the border must NOT change.
        var c = RasterCanvas(width: 5, height: 5, fill: .white)
        for i in 0..<5 {
            c.setPixel(x: i, y: 0, to: .red)
            c.setPixel(x: i, y: 4, to: .red)
            c.setPixel(x: 0, y: i, to: .red)
            c.setPixel(x: 4, y: i, to: .red)
        }
        let changed = c.floodFill(x: 2, y: 2, with: .green)
        XCTAssertEqual(changed, 9, "the 3x3 white interior is filled (9 pixels)")
        XCTAssertEqual(c.pixel(x: 2, y: 2), .green)
        XCTAssertEqual(c.pixel(x: 1, y: 1), .green, "corner of interior filled")
        XCTAssertEqual(c.pixel(x: 0, y: 0), .red, "border untouched")
        XCTAssertEqual(c.pixel(x: 2, y: 0), .red, "border untouched")
    }

    func test_floodFill_doesNotLeakAcrossDifferentColor() {
        // Left half blue, right half white, split by a vertical line; fill the
        // blue side — the white side stays white.
        var c = RasterCanvas(width: 4, height: 2, fill: .white)
        for y in 0..<2 { for x in 0..<2 { c.setPixel(x: x, y: y, to: .blue) } }
        let changed = c.floodFill(x: 0, y: 0, with: .red)
        XCTAssertEqual(changed, 4, "only the 2x2 blue region")
        XCTAssertEqual(c.pixel(x: 0, y: 0), .red)
        XCTAssertEqual(c.pixel(x: 1, y: 1), .red)
        XCTAssertEqual(c.pixel(x: 2, y: 0), .white, "white side never touched")
        XCTAssertEqual(c.pixel(x: 3, y: 1), .white)
    }

    func test_floodFill_seedEqualsReplacement_isNoOp() {
        var c = RasterCanvas(width: 3, height: 3, fill: .white)
        let changed = c.floodFill(x: 1, y: 1, with: .white)
        XCTAssertEqual(changed, 0, "filling white-with-white changes nothing (and must terminate)")
    }

    func test_floodFill_outOfBounds_isNoOp() {
        var c = RasterCanvas(width: 3, height: 3, fill: .white)
        XCTAssertEqual(c.floodFill(x: 10, y: 10, with: .red), 0)
    }

    func test_floodFill_tolerance_bridgesNearColors() {
        // Three near-white pixels (off by a few per channel) and one far black.
        var c = RasterCanvas(width: 4, height: 1, fill: .white)
        c.setPixel(x: 1, y: 0, to: RGBAColor(r: 250, g: 252, b: 255))   // near-white
        c.setPixel(x: 2, y: 0, to: RGBAColor(r: 245, g: 248, b: 250))   // near-white
        c.setPixel(x: 3, y: 0, to: .black)                              // far
        let changed = c.floodFill(x: 0, y: 0, with: .red, tolerance: 12)
        XCTAssertEqual(changed, 3, "tolerance bridges the three near-white pixels, not black")
        XCTAssertEqual(c.pixel(x: 0, y: 0), .red)
        XCTAssertEqual(c.pixel(x: 2, y: 0), .red)
        XCTAssertEqual(c.pixel(x: 3, y: 0), .black, "the far pixel is outside tolerance")
    }

    func test_floodFill_zeroTolerance_isExactMatchOnly() {
        var c = RasterCanvas(width: 3, height: 1, fill: .white)
        c.setPixel(x: 1, y: 0, to: RGBAColor(r: 254, g: 255, b: 255))   // off by 1
        let changed = c.floodFill(x: 0, y: 0, with: .red, tolerance: 0)
        XCTAssertEqual(changed, 1, "exact match stops at the off-by-one pixel")
        XCTAssertEqual(c.pixel(x: 1, y: 0), RGBAColor(r: 254, g: 255, b: 255), "off-by-one pixel untouched")
    }

    func test_floodFill_wholeUniformCanvas_terminates() {
        // A large uniform fill must not blow the stack or spin — bounds the work.
        var c = RasterCanvas(width: 64, height: 64, fill: .white)
        let changed = c.floodFill(x: 0, y: 0, with: .blue)
        XCTAssertEqual(changed, 64 * 64, "every pixel of a uniform canvas is reachable")
        XCTAssertTrue((0..<64).allSatisfy { c.pixel(x: $0, y: $0) == .blue })
    }

    // MARK: - brush dab

    func test_brushDab_radiusZero_paintsSinglePixel() {
        var c = RasterCanvas(width: 5, height: 5, fill: .white)
        let n = c.brushDab(cx: 2, cy: 2, radius: 0, color: .black)
        XCTAssertEqual(n, 1)
        XCTAssertEqual(c.pixel(x: 2, y: 2), .black)
        XCTAssertEqual(c.pixel(x: 1, y: 2), .white, "neighbor untouched at radius 0")
    }

    func test_brushDab_radiusOne_paintsDisc() {
        // radius 1 with the (r+0.5) test ⇒ the centre + 4 orthogonal neighbors +
        // 4 diagonals = a 3x3 block (dist² ≤ 2.25 admits the corners at dist²=2).
        var c = RasterCanvas(width: 5, height: 5, fill: .white)
        let n = c.brushDab(cx: 2, cy: 2, radius: 1, color: .red)
        XCTAssertEqual(n, 9, "radius 1 paints the 3x3 disc")
        XCTAssertEqual(c.pixel(x: 2, y: 2), .red)
        XCTAssertEqual(c.pixel(x: 1, y: 1), .red, "diagonal in disc")
        XCTAssertEqual(c.pixel(x: 0, y: 2), .white, "two pixels away is outside the disc")
    }

    func test_brushDab_square_fillsFullBlockIncludingCorners() {
        var round = RasterCanvas(width: 9, height: 9, fill: .white)
        let roundN = round.brushDab(cx: 4, cy: 4, radius: 2, color: .red, square: false)
        var square = RasterCanvas(width: 9, height: 9, fill: .white)
        let squareN = square.brushDab(cx: 4, cy: 4, radius: 2, color: .red, square: true)
        XCTAssertEqual(squareN, 25, "square paints the full (2r+1)² block")
        XCTAssertLessThan(roundN, squareN, "the round disc omits the corners")
        // The far corner (dist² = 8 > (2.5)² = 6.25): square paints it, round leaves it.
        XCTAssertEqual(square.pixel(x: 6, y: 6), .red, "square brush paints the corner")
        XCTAssertEqual(round.pixel(x: 6, y: 6), .white, "round brush leaves the corner")
    }

    func test_brushDab_clampsAtCanvasEdge() {
        var c = RasterCanvas(width: 3, height: 3, fill: .white)
        // Centre at the corner: only the in-bounds part of the disc is painted.
        // The radius-1 disc (dist² ≤ 2.25) admits (0,0),(1,0),(0,1),(1,1); all are
        // in bounds, so the corner dab paints 4 pixels (the full disc quadrant).
        let n = c.brushDab(cx: 0, cy: 0, radius: 1, color: .green)
        XCTAssertEqual(n, 4, "corner dab paints the in-bounds quadrant (0,0),(1,0),(0,1),(1,1)")
        XCTAssertEqual(c.pixel(x: 0, y: 0), .green)
        XCTAssertEqual(c.pixel(x: 1, y: 1), .green)
        XCTAssertEqual(c.pixel(x: 2, y: 2), .white, "far corner outside the disc")
    }

    // MARK: - brush stroke

    func test_brushStroke_isContinuous_noGaps() {
        // A radius-0 horizontal stroke must paint every pixel along the line.
        var c = RasterCanvas(width: 10, height: 1, fill: .white)
        let n = c.brushStroke(from: (0, 0), to: (9, 0), radius: 0, color: .black)
        XCTAssertEqual(n, 10, "every pixel along the segment is marked")
        for x in 0..<10 { XCTAssertEqual(c.pixel(x: x, y: 0), .black, "no gap at x=\(x)") }
    }

    func test_brushStroke_diagonal_hasNoGaps() {
        // A radius-1 diagonal stroke leaves a connected mark (each dab is a disc).
        var c = RasterCanvas(width: 8, height: 8, fill: .white)
        let n = c.brushStroke(from: (0, 0), to: (7, 7), radius: 1, color: .blue)
        XCTAssertGreaterThan(n, 0)
        // Spot-check the endpoints and a midpoint are painted.
        XCTAssertEqual(c.pixel(x: 0, y: 0), .blue)
        XCTAssertEqual(c.pixel(x: 7, y: 7), .blue)
        XCTAssertEqual(c.pixel(x: 4, y: 4), .blue, "midpoint of the diagonal is marked")
    }

    func test_brushStroke_zeroLength_isSingleDab() {
        var c = RasterCanvas(width: 5, height: 5, fill: .white)
        let n = c.brushStroke(from: (2, 2), to: (2, 2), radius: 0, color: .red)
        XCTAssertEqual(n, 1, "a zero-length stroke is one dab")
        XCTAssertEqual(c.pixel(x: 2, y: 2), .red)
    }

    // MARK: - CGImage bridge round-trip

    func test_cgImage_roundTrip_preservesPixels() {
        var c = RasterCanvas(width: 4, height: 3, fill: .white)
        c.setPixel(x: 1, y: 1, to: .red)
        c.setPixel(x: 2, y: 0, to: RGBAColor(r: 12, g: 34, b: 56, a: 255))
        guard let image = c.cgImage() else { return XCTFail("cgImage() returned nil") }
        XCTAssertEqual(image.width, 4)
        XCTAssertEqual(image.height, 3)
        guard let back = RasterCanvas.from(image) else { return XCTFail("from() returned nil") }
        XCTAssertEqual(back.width, 4)
        XCTAssertEqual(back.height, 3)
        // Opaque pixels survive the premultiply→un-premultiply round-trip exactly.
        XCTAssertEqual(back.pixel(x: 1, y: 1), .red)
        XCTAssertEqual(back.pixel(x: 2, y: 0), RGBAColor(r: 12, g: 34, b: 56, a: 255))
        XCTAssertEqual(back.pixel(x: 0, y: 0), .white)
    }

    func test_from_emptyImage_isNilSafe() {
        let c = RasterCanvas(width: 0, height: 0)
        XCTAssertNil(c.cgImage(), "empty canvas yields no image")
    }

    func test_fillRect_fillsClampedRegion() {
        var c = RasterCanvas(width: 6, height: 6, fill: .white)
        let n = c.fillRect(x: 1, y: 1, width: 3, height: 2, to: .red)
        XCTAssertEqual(n, 6, "3x2 region")
        XCTAssertEqual(c.pixel(x: 1, y: 1), .red)
        XCTAssertEqual(c.pixel(x: 3, y: 2), .red)
        XCTAssertEqual(c.pixel(x: 0, y: 0), .white, "outside the rect is untouched")
        let m = c.fillRect(x: 4, y: 4, width: 10, height: 10, to: .blue)
        XCTAssertEqual(m, 4, "off-edge rect clamps to the 2x2 corner")
    }

    func test_blit_compositesOpaqueSrc() {
        var dest = RasterCanvas(width: 6, height: 6, fill: .white)
        let src = RasterCanvas(width: 2, height: 2, fill: .red)
        let n = dest.blit(src, atX: 1, atY: 1)
        XCTAssertEqual(n, 4)
        XCTAssertEqual(dest.pixel(x: 1, y: 1), .red)
        XCTAssertEqual(dest.pixel(x: 2, y: 2), .red)
        XCTAssertEqual(dest.pixel(x: 0, y: 0), .white, "outside the blit is untouched")
    }

    func test_blit_skipsTransparentSrc() {
        var dest = RasterCanvas(width: 4, height: 4, fill: .white)
        let src = RasterCanvas(width: 2, height: 2, fill: .clear)
        XCTAssertEqual(dest.blit(src, atX: 0, atY: 0), 0, "fully-transparent src writes nothing")
        XCTAssertEqual(dest.pixel(x: 0, y: 0), .white)
    }

    func test_over_blendsHalfAlphaRedOverWhite() {
        let out = RasterCanvas.over(RGBAColor(r: 255, g: 0, b: 0, a: 128),
                                    RGBAColor(r: 255, g: 255, b: 255, a: 255))
        XCTAssertEqual(out.a, 255, "opaque dest → opaque result")
        XCTAssertEqual(Int(out.r), 255)
        XCTAssertGreaterThan(Int(out.g), 100, "~half white shows through (≈127)")
        XCTAssertLessThan(Int(out.g), 160)
    }
}
