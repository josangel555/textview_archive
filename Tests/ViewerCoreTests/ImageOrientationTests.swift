import CoreGraphics
import XCTest
@testable import ViewerCore

/// T1 headless tests for the orientation algebra + rotate/flip verb API
/// (`EditOps+Orientation.swift`). Two layers:
///   • pure group laws + op-coalescing on `ImageDocument` (no rendering);
///   • an exhaustive 8×8 **render-equivalence** property test that pins
///     `EXIFOrientation.then(_:)` against the actual `Renderer` — applying two
///     orientations sequentially must produce byte-identical pixels to applying
///     the single composed orientation. The renderer is ground truth, so this
///     catches any slip in the EXIF↔normal-form mapping or the compose math.
final class ImageOrientationTests: XCTestCase {

    // MARK: - Pure group laws

    func test_then_fourClockwise_isIdentity() {
        var o = EXIFOrientation.up
        for _ in 0..<4 { o = o.then(.right90) }
        XCTAssertEqual(o, .up)
    }

    func test_then_twoClockwise_is180() {
        XCTAssertEqual(EXIFOrientation.right90.then(.right90), .down)
    }

    func test_then_cwThenCcw_isIdentity() {
        XCTAssertEqual(EXIFOrientation.right90.then(.left90), .up)
        XCTAssertEqual(EXIFOrientation.left90.then(.right90), .up)
    }

    func test_then_flipTwice_isIdentity() {
        XCTAssertEqual(EXIFOrientation.upMirrored.then(.upMirrored), .up)
        XCTAssertEqual(EXIFOrientation.downMirrored.then(.downMirrored), .up)
    }

    func test_then_hFlipThenVFlip_is180() {
        // Mirror L↔R then mirror T↔B == rotate 180.
        XCTAssertEqual(EXIFOrientation.upMirrored.then(.downMirrored), .down)
    }

    func test_normalForm_roundTrips() {
        for o in EXIFOrientation.allCases {
            let nf = o.normalForm
            XCTAssertEqual(EXIFOrientation.from(q: nf.q, mirrored: nf.mirrored), o)
        }
    }

    func test_then_isClosedOverTheGroup() {
        // Every composition must land on a valid EXIF case (allCases membership
        // is implicit in the enum, but assert the table never produces a
        // surprising default by checking associativity on a sample triple).
        let a = EXIFOrientation.right90, b = EXIFOrientation.upMirrored, c = EXIFOrientation.left90
        XCTAssertEqual(a.then(b).then(c), a.then(b.then(c)), "compose must be associative")
    }

    // MARK: - Verb coalescing on ImageDocument

    private func doc(_ ops: [EditOp] = []) -> ImageDocument {
        ImageDocument(data: Data([1, 2, 3, 4]), ops: ops)
    }

    func test_verb_rotateCW_appendsWhenNoTrailingOrient() {
        let d = doc().rotatedClockwise()
        XCTAssertEqual(d.ops, [.orient(.right90)])
    }

    func test_verb_rotateCW_twice_coalescesToSingle180Op() {
        let d = doc().rotatedClockwise().rotatedClockwise()
        XCTAssertEqual(d.ops, [.orient(.down)], "two ops must coalesce into one")
    }

    func test_verb_rotateCW_fourTimes_coalescesAwayEntirely() {
        var d = doc()
        for _ in 0..<4 { d = d.rotatedClockwise() }
        XCTAssertEqual(d.ops, [], "identity result drops the op (back to pristine)")
        XCTAssertTrue(d.isPristine)
    }

    func test_verb_flipHorizontal_twice_coalescesAway() {
        XCTAssertEqual(doc().flippedHorizontally().flippedHorizontally().ops, [])
    }

    func test_verb_coalesceOnlyAcrossAdjacentTrailingOrient() {
        // An intervening crop changes the coordinate frame → no coalesce.
        let d = doc().rotatedClockwise()
            .appending(.crop(CGRect(x: 0, y: 0, width: 2, height: 2)))
            .rotatedClockwise()
        XCTAssertEqual(d.ops, [.orient(.right90),
                               .crop(CGRect(x: 0, y: 0, width: 2, height: 2)),
                               .orient(.right90)],
                       "rotation after a crop is a distinct op, not coalesced")
    }

    func test_verb_coalesceAcrossTrailingOrient_afterACrop() {
        // …but two rotations that ARE adjacent (after the crop) still coalesce.
        let d = doc()
            .appending(.crop(CGRect(x: 0, y: 0, width: 2, height: 2)))
            .rotatedClockwise()
            .rotatedClockwise()
        XCTAssertEqual(d.ops, [.crop(CGRect(x: 0, y: 0, width: 2, height: 2)),
                               .orient(.down)])
    }

    // MARK: - Render-equivalence property (the proof against the renderer)

    /// 3×3 image, each cell a distinct color. Square so axis-swap orientations
    /// keep the dimensions uniform for a full-grid pixel compare; per-cell
    /// distinct so D4 acts faithfully (any wrong composition moves a cell).
    private func distinct3x3() -> CGImage {
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let info = CGImageAlphaInfo.premultipliedFirst.rawValue
            | CGBitmapInfo.byteOrder32Little.rawValue
        let ctx = CGContext(data: nil, width: 3, height: 3, bitsPerComponent: 8,
                            bytesPerRow: 0, space: space, bitmapInfo: info)!
        // Nine visually-separated colors, one per cell.
        let colors: [(CGFloat, CGFloat, CGFloat)] = [
            (1.0, 0.0, 0.0), (0.0, 1.0, 0.0), (0.0, 0.0, 1.0),
            (1.0, 1.0, 0.0), (1.0, 0.0, 1.0), (0.0, 1.0, 1.0),
            (1.0, 0.5, 0.0), (0.5, 0.0, 1.0), (0.3, 0.3, 0.3),
        ]
        var i = 0
        for y in 0..<3 {
            for x in 0..<3 {
                let (r, g, b) = colors[i]; i += 1
                ctx.setFillColor(red: r, green: g, blue: b, alpha: 1)
                ctx.fill(CGRect(x: x, y: y, width: 1, height: 1))
            }
        }
        return ctx.makeImage()!
    }

    /// Straight-RGBA sample at top-left (x, y) — same redraw-into-canonical
    /// approach as ImageEditingTests (no Y-flip; row 0 = display top).
    private func sampleRGBA(_ image: CGImage, x: Int, y: Int) -> [UInt8] {
        let w = image.width, h = image.height
        let bpr = w * 4
        var buf = [UInt8](repeating: 0, count: bpr * h)
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let info = CGImageAlphaInfo.premultipliedLast.rawValue
            | CGBitmapInfo.byteOrder32Big.rawValue
        buf.withUnsafeMutableBytes { raw in
            let ctx = CGContext(data: raw.baseAddress, width: w, height: h,
                                bitsPerComponent: 8, bytesPerRow: bpr,
                                space: space, bitmapInfo: info)!
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        let i = y * bpr + x * 4
        return [buf[i], buf[i + 1], buf[i + 2], buf[i + 3]]
    }

    private func pixelsEqual(_ a: CGImage, _ b: CGImage) -> Bool {
        guard a.width == b.width, a.height == b.height else { return false }
        for y in 0..<a.height {
            for x in 0..<a.width {
                let pa = sampleRGBA(a, x: x, y: y)
                let pb = sampleRGBA(b, x: x, y: y)
                // Pure 90°/flip remaps don't resample, so expect exact; allow a
                // ±1 channel slack against any edge rounding.
                for c in 0..<4 where abs(Int(pa[c]) - Int(pb[c])) > 1 { return false }
            }
        }
        return true
    }

    /// 2×2, 4 distinct colors at top-left corners TL/TR/BL/BR (ids 0/1/2/3).
    private func corners2x2() -> CGImage {
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let info = CGImageAlphaInfo.premultipliedFirst.rawValue
            | CGBitmapInfo.byteOrder32Little.rawValue
        let ctx = CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8,
                            bytesPerRow: 0, space: space, bitmapInfo: info)!
        // context is bottom-left origin: top display row is high context-y.
        ctx.setFillColor(red: 1, green: 0, blue: 0, alpha: 1); ctx.fill(CGRect(x: 0, y: 1, width: 1, height: 1)) // TL=0 red
        ctx.setFillColor(red: 0, green: 1, blue: 0, alpha: 1); ctx.fill(CGRect(x: 1, y: 1, width: 1, height: 1)) // TR=1 green
        ctx.setFillColor(red: 0, green: 0, blue: 1, alpha: 1); ctx.fill(CGRect(x: 0, y: 0, width: 1, height: 1)) // BL=2 blue
        ctx.setFillColor(red: 1, green: 1, blue: 0, alpha: 1); ctx.fill(CGRect(x: 1, y: 0, width: 1, height: 1)) // BR=3 yellow
        return ctx.makeImage()!
    }
    private func cornerId(_ image: CGImage, x: Int, y: Int) -> Int {
        let p = sampleRGBA(image, x: x, y: y)
        let r = p[0] > 128, g = p[1] > 128, b = p[2] > 128
        if r && !g && !b { return 0 }; if !r && g && !b { return 1 }
        if !r && !g && b { return 2 }; if r && g && !b { return 3 }
        return -1
    }

    /// Pins each orientation's exact corner permutation as the Renderer bakes
    /// it — ground truth derived empirically. Guards the `.leftMirrored` fix
    /// (it must be the MAIN-diagonal transpose [0,2,1,3], distinct from
    /// `.rightMirrored`'s anti-diagonal [3,1,2,0]); a regression to the old
    /// off-canvas transform would surface here.
    func test_renderer_orientationCornerPermutations_pinAllEight() throws {
        // srcToOut[srcCorner] = output corner it lands at.
        let expected: [EXIFOrientation: [Int]] = [
            .up: [0, 1, 2, 3], .upMirrored: [1, 0, 3, 2],
            .down: [3, 2, 1, 0], .downMirrored: [2, 3, 0, 1],
            .leftMirrored: [0, 2, 1, 3], .right90: [2, 0, 3, 1],
            .rightMirrored: [3, 1, 2, 0], .left90: [1, 3, 0, 2],
        ]
        let src = try Exporter.encode(corners2x2(), ExportSpec(format: .png))
        for (o, srcToOut) in expected {
            let out = try Renderer.render(ImageDocument(data: src).appending(.orient(o)))
            let outToSrc = [cornerId(out, x: 0, y: 0), cornerId(out, x: 1, y: 0),
                            cornerId(out, x: 0, y: 1), cornerId(out, x: 1, y: 1)]
            var actual = [0, 0, 0, 0]
            for outCorner in 0..<4 { actual[outToSrc[outCorner]] = outCorner }
            XCTAssertEqual(actual, srcToOut, "orientation \(o) corner permutation mismatch")
        }
    }

    func test_then_matchesSequentialRender_forAll64Pairs() throws {
        let src = try Exporter.encode(distinct3x3(), ExportSpec(format: .png))
        for a in EXIFOrientation.allCases {
            for b in EXIFOrientation.allCases {
                let sequential = try Renderer.render(
                    ImageDocument(data: src).appending(.orient(a)).appending(.orient(b)))
                let composed = try Renderer.render(
                    ImageDocument(data: src).appending(.orient(a.then(b))))
                XCTAssertTrue(pixelsEqual(sequential, composed),
                              "orient(\(a)) then orient(\(b)) != orient(\(a).then(\(b))=\(a.then(b)))")
            }
        }
    }
}
