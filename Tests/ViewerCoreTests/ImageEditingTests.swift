import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import ViewerCore

/// T1 headless tests for the image-editing engine spine. All fixtures are
/// drawn programmatically via `CGContext` (no committed binary blobs), and all
/// scratch files use `FileManager.default.temporaryDirectory`.
///
/// Pixel sampling note: `sampleRGBA(_:x:y:)` reads from a freshly-normalized
/// premultiplied-RGBA8 sRGB context using **top-left** pixel coordinates
/// (CGImage's native row-major convention), so test coordinates match the
/// engine's crop coordinate space.
final class ImageEditingTests: XCTestCase {
    private var tmpDir: URL!

    override func setUpWithError() throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ImageEditingTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmpDir)
    }

    // MARK: - Fixtures (programmatically drawn)

    private struct RGBA: Equatable {
        var r: UInt8, g: UInt8, b: UInt8, a: UInt8
        func close(to other: RGBA, tol: Int = 2) -> Bool {
            abs(Int(r) - Int(other.r)) <= tol
                && abs(Int(g) - Int(other.g)) <= tol
                && abs(Int(b) - Int(other.b)) <= tol
                && abs(Int(a) - Int(other.a)) <= tol
        }
    }

    /// Build a premultiplied-RGBA8 sRGB context to draw fixtures into. Uses the
    /// same format the engine normalizes to, so samples are directly comparable.
    private func makeContext(width: Int, height: Int) -> CGContext {
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let info = CGImageAlphaInfo.premultipliedFirst.rawValue
            | CGBitmapInfo.byteOrder32Little.rawValue
        let ctx = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: space, bitmapInfo: info
        )!
        return ctx
    }

    /// A solid-color image of the given size.
    private func solidImage(width: Int, height: Int, r: CGFloat, g: CGFloat, b: CGFloat) -> CGImage {
        let ctx = makeContext(width: width, height: height)
        ctx.setFillColor(red: r, green: g, blue: b, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()!
    }

    /// A 4-color image split into quadrants. Returns the image plus the color
    /// assigned to each *display* quadrant (top-left, top-right, bottom-left,
    /// bottom-right) in top-left pixel-space terms.
    ///
    /// CGContext draws with a bottom-left origin, so we fill the rect whose
    /// context-Y is high for the TOP quadrants. The returned RGBA values are
    /// what `sampleRGBA` (top-left origin) will read at each quadrant center.
    private func quadrantImage(side: Int) -> (image: CGImage,
                                              topLeft: RGBA, topRight: RGBA,
                                              bottomLeft: RGBA, bottomRight: RGBA) {
        let half = side / 2
        let ctx = makeContext(width: side, height: side)
        // Context Y grows upward. Top half of the *displayed* image is the
        // high-Y band (y in [half, side)). Distinct primary-ish colors.
        // Top-left  (low x, high y)  = red
        ctx.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        ctx.fill(CGRect(x: 0, y: half, width: half, height: half))
        // Top-right (high x, high y) = green
        ctx.setFillColor(red: 0, green: 1, blue: 0, alpha: 1)
        ctx.fill(CGRect(x: half, y: half, width: half, height: half))
        // Bottom-left (low x, low y) = blue
        ctx.setFillColor(red: 0, green: 0, blue: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: half, height: half))
        // Bottom-right (high x, low y) = yellow
        ctx.setFillColor(red: 1, green: 1, blue: 0, alpha: 1)
        ctx.fill(CGRect(x: half, y: 0, width: half, height: half))
        let img = ctx.makeImage()!
        return (img,
                RGBA(r: 255, g: 0, b: 0, a: 255),     // top-left  = red
                RGBA(r: 0, g: 255, b: 0, a: 255),     // top-right = green
                RGBA(r: 0, g: 0, b: 255, a: 255),     // bottom-left = blue
                RGBA(r: 255, g: 255, b: 0, a: 255))   // bottom-right = yellow
    }

    /// PNG-encode a CGImage to a temp file and return the URL (for URL-source
    /// document tests).
    private func writePNG(_ image: CGImage, name: String) throws -> URL {
        let data = try Exporter.encode(image, ExportSpec(format: .png))
        let url = tmpDir.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    // MARK: - Pixel sampling (top-left origin)

    /// Sample a single pixel at top-left `(x, y)` from `image`. Redraws into a
    /// known premultiplied-RGBA8 sRGB context (so format is canonical), reads
    /// the row-major buffer, and un-premultiplies to straight RGBA for
    /// comparison against the (opaque) fixture colors.
    private func sampleRGBA(_ image: CGImage, x: Int, y: Int) -> RGBA {
        let w = image.width, h = image.height
        precondition(x >= 0 && x < w && y >= 0 && y < h, "sample out of bounds")
        let bytesPerRow = w * 4
        var buf = [UInt8](repeating: 0, count: bytesPerRow * h)
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let info = CGImageAlphaInfo.premultipliedLast.rawValue
            | CGBitmapInfo.byteOrder32Big.rawValue // R,G,B,A byte order
        buf.withUnsafeMutableBytes { raw in
            let ctx = CGContext(
                data: raw.baseAddress, width: w, height: h,
                bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                space: space, bitmapInfo: info
            )!
            // Draw 1:1; context is bottom-left origin, so to read top-left (x,y)
            // we draw normally and index with a flipped row below.
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        // Drawing a CGImage into a freshly-created raw RGBA bitmap context
        // lands memory row 0 at the image's TOP (display origin), so a top-left
        // (x, y) maps directly to buffer row `y` — NO manual flip (the earlier
        // `h-1-y` flip read the vertically-mirrored pixel, surfacing as a
        // red↔blue "swap" on the quadrant fixtures).
        let i = y * bytesPerRow + x * 4
        let r = buf[i], g = buf[i + 1], b = buf[i + 2], a = buf[i + 3]
        // premultipliedLast → un-premultiply (a==255 for opaque fixtures, no-op).
        if a == 0 { return RGBA(r: 0, g: 0, b: 0, a: 0) }
        let rr = UInt8(min(255, Int(r) * 255 / Int(a)))
        let gg = UInt8(min(255, Int(g) * 255 / Int(a)))
        let bb = UInt8(min(255, Int(b) * 255 / Int(a)))
        return RGBA(r: rr, g: gg, b: bb, a: a)
    }

    // MARK: - Resize dimensions

    func test_resize_exactDimensions() throws {
        let doc = ImageDocument(data: try Exporter.encode(
            solidImage(width: 800, height: 600, r: 0.2, g: 0.4, b: 0.6),
            ExportSpec(format: .png)))
            .appending(.resize(width: 400, height: 300))
        let out = try Renderer.render(doc)
        XCTAssertEqual(out.width, 400)
        XCTAssertEqual(out.height, 300)
    }

    func test_aspectFit_roundingRule() throws {
        // 1000x500 into a 400x400 box ⇒ scale 0.4 ⇒ 400x200.
        let fit = EditOp.aspectFit(source: CGSize(width: 1000, height: 500),
                                   into: CGSize(width: 400, height: 400))
        XCTAssertEqual(fit.width, 400)
        XCTAssertEqual(fit.height, 200)

        let doc = ImageDocument(data: try Exporter.encode(
            solidImage(width: 1000, height: 500, r: 0.5, g: 0.5, b: 0.5),
            ExportSpec(format: .png)))
            .appending(.resize(width: fit.width, height: fit.height))
        let out = try Renderer.render(doc)
        XCTAssertEqual(out.width, 400)
        XCTAssertEqual(out.height, 200)
    }

    // MARK: - Color controls / tonal adjustment (TSK-344)

    func test_colorControls_identity_preservesColorAndDims() throws {
        let data = try Exporter.encode(
            solidImage(width: 64, height: 48, r: 0.5, g: 0.3, b: 0.7),
            ExportSpec(format: .png))
        let plain = try Renderer.render(ImageDocument(data: data))
        let adjusted = try Renderer.render(
            ImageDocument(data: data)
                .appending(.colorControls(brightness: 0, contrast: 1, saturation: 1)))
        XCTAssertEqual(adjusted.width, 64)
        XCTAssertEqual(adjusted.height, 48, "color op must not change geometry")
        // Identity (0,1,1) vs the un-adjusted render: same pixel (CI round-trip
        // tolerance a touch looser than the lossless CG paths).
        let p = sampleRGBA(plain, x: 32, y: 24)
        let a = sampleRGBA(adjusted, x: 32, y: 24)
        XCTAssertTrue(a.close(to: p, tol: 6),
                      "identity colorControls changed the color: \(p) -> \(a)")
    }

    func test_colorControls_saturationZero_graysOutColor() throws {
        // A saturated red, desaturated to 0, must collapse to neutral gray
        // (R≈G≈B) at the center.
        let doc = ImageDocument(data: try Exporter.encode(
            solidImage(width: 32, height: 32, r: 0.9, g: 0.1, b: 0.1),
            ExportSpec(format: .png)))
            .appending(.colorControls(brightness: 0, contrast: 1, saturation: 0))
        let c = sampleRGBA(try Renderer.render(doc), x: 16, y: 16)
        XCTAssertTrue(abs(Int(c.r) - Int(c.g)) <= 3 && abs(Int(c.g) - Int(c.b)) <= 3,
                      "saturation 0 should grayscale (R≈G≈B), got \(c)")
    }

    // MARK: - Paint stroke as a lossless op (TSK-1055)

    func test_paintStroke_op_paints_and_composes_in_the_op_list() throws {
        let data = try Exporter.encode(
            solidImage(width: 32, height: 32, r: 1, g: 1, b: 1),
            ExportSpec(format: .png))
        let red = RGBAColor(r: 255, g: 0, b: 0)
        // A single dab at the center, radius 2 — rides the op-list like any EditOp.
        let painted = try Renderer.render(
            ImageDocument(data: data)
                .appending(.paintStroke(points: [CGPoint(x: 16, y: 16)], radius: 2,
                                        color: red, square: false)))
        let center = sampleRGBA(painted, x: 16, y: 16)
        XCTAssertTrue(center.r > 200 && center.g < 60 && center.b < 60,
                      "paintStroke op did not paint red at the dab center: \(center)")
        let corner = sampleRGBA(painted, x: 0, y: 0)
        XCTAssertTrue(corner.r > 200 && corner.g > 200 && corner.b > 200,
                      "paintStroke op painted outside the dab radius: \(corner)")
        // Rendering the op-list WITHOUT the stroke (an undo) restores the base pixel.
        let plainCenter = sampleRGBA(try Renderer.render(ImageDocument(data: data)), x: 16, y: 16)
        XCTAssertTrue(plainCenter.r > 200 && plainCenter.g > 200 && plainCenter.b > 200,
                      "removing the paintStroke op (undo) must restore the base pixel")
    }

    // MARK: - Polygon fill as a lossless op (TSK-1084/1085)

    func test_fillPolygon_op_fills_triangle_interior_not_exterior() throws {
        let data = try Exporter.encode(
            solidImage(width: 32, height: 32, r: 1, g: 1, b: 1),
            ExportSpec(format: .png))
        let red = DrawColor(red: 1, green: 0, blue: 0)
        // A triangle covering the center (top, bottom-left, bottom-right).
        let tri = [CGPoint(x: 16, y: 4), CGPoint(x: 4, y: 28), CGPoint(x: 28, y: 28)]
        let filled = try Renderer.render(
            ImageDocument(data: data).appending(.fillPolygon(points: tri, color: red)))
        // Interior point (10..22 at y=16) is filled red.
        let center = sampleRGBA(filled, x: 16, y: 16)
        XCTAssertTrue(center.r > 200 && center.g < 60 && center.b < 60,
                      "fillPolygon did not fill the triangle interior: \(center)")
        // A corner OUTSIDE the triangle stays white (no over-fill).
        let corner = sampleRGBA(filled, x: 0, y: 0)
        XCTAssertTrue(corner.r > 200 && corner.g > 200 && corner.b > 200,
                      "fillPolygon spilled outside the triangle: \(corner)")
        // Undo (op removed) restores the base pixel — it rides the lossless op-list.
        let plainCenter = sampleRGBA(try Renderer.render(ImageDocument(data: data)), x: 16, y: 16)
        XCTAssertTrue(plainCenter.r > 200 && plainCenter.g > 200 && plainCenter.b > 200,
                      "removing the fillPolygon op (undo) must restore the base pixel")
    }

    func test_strokePolygon_op_outlines_not_fills() throws {
        let data = try Exporter.encode(
            solidImage(width: 32, height: 32, r: 1, g: 1, b: 1),
            ExportSpec(format: .png))
        let red = DrawColor(red: 1, green: 0, blue: 0)
        let tri = [CGPoint(x: 16, y: 4), CGPoint(x: 4, y: 28), CGPoint(x: 28, y: 28)]
        let stroked = try Renderer.render(
            ImageDocument(data: data).appending(.strokePolygon(points: tri, color: red, lineWidth: 4)))
        // A point ON the left edge (x≈10 at y=16 in either context orientation) is stroked.
        let edge = sampleRGBA(stroked, x: 10, y: 16)
        XCTAssertTrue(edge.r > 180 && edge.g < 80 && edge.b < 80,
                      "strokePolygon did not stroke the triangle edge: \(edge)")
        // The interior is NOT filled — distinguishes an outline from a fill.
        let interior = sampleRGBA(stroked, x: 16, y: 16)
        XCTAssertTrue(interior.r > 200 && interior.g > 200 && interior.b > 200,
                      "strokePolygon filled the interior (should only outline): \(interior)")
    }

    func test_colorControls_brightnessUp_lightens() throws {
        let base = solidImage(width: 32, height: 32, r: 0.4, g: 0.4, b: 0.4)
        let before = sampleRGBA(try Renderer.render(ImageDocument(data:
            try Exporter.encode(base, ExportSpec(format: .png)))), x: 16, y: 16)
        let after = sampleRGBA(try Renderer.render(
            ImageDocument(data: try Exporter.encode(base, ExportSpec(format: .png)))
                .appending(.colorControls(brightness: 0.3, contrast: 1, saturation: 1))),
            x: 16, y: 16)
        XCTAssertGreaterThan(Int(after.r), Int(before.r) + 10,
                             "brightness +0.3 should lighten (\(before.r) -> \(after.r))")
    }

    func test_colorControls_survivesDocumentCodableRoundTrip() throws {
        // The op must persist in a serialized ImageDocument (workspace snapshot /
        // non-destructive history). Guards the EditOp Codable conformance.
        let doc = ImageDocument(data: Data([1, 2, 3]))
            .appending(.colorControls(brightness: -0.2, contrast: 1.5, saturation: 0.8))
        let round = try JSONDecoder().decode(
            ImageDocument.self, from: JSONEncoder().encode(doc))
        XCTAssertEqual(round, doc, "colorControls op must round-trip through Codable")
    }

    // MARK: - Exposure (EV; TSK-344)

    func test_exposure_identity_preservesColor() throws {
        let data = try Exporter.encode(
            solidImage(width: 48, height: 32, r: 0.4, g: 0.5, b: 0.6),
            ExportSpec(format: .png))
        let plain = try Renderer.render(ImageDocument(data: data))
        let adjusted = try Renderer.render(
            ImageDocument(data: data).appending(.exposure(ev: 0)))
        XCTAssertEqual(adjusted.width, 48)
        XCTAssertEqual(adjusted.height, 32, "exposure must not change geometry")
        let p = sampleRGBA(plain, x: 24, y: 16)
        let a = sampleRGBA(adjusted, x: 24, y: 16)
        XCTAssertTrue(a.close(to: p, tol: 6), "ev 0 changed the color: \(p) -> \(a)")
    }

    func test_exposure_positiveEV_lightens() throws {
        // +1 EV ≈ doubling light in linear space — a mid-tone must get brighter.
        let base = solidImage(width: 32, height: 32, r: 0.3, g: 0.3, b: 0.3)
        let data = try Exporter.encode(base, ExportSpec(format: .png))
        let before = sampleRGBA(try Renderer.render(ImageDocument(data: data)), x: 16, y: 16)
        let after = sampleRGBA(
            try Renderer.render(ImageDocument(data: data).appending(.exposure(ev: 1))),
            x: 16, y: 16)
        XCTAssertGreaterThan(Int(after.r), Int(before.r) + 10,
                             "+1 EV should lighten (\(before.r) -> \(after.r))")
    }

    func test_exposure_survivesDocumentCodableRoundTrip() throws {
        let doc = ImageDocument(data: Data([4, 5, 6]))
            .appending(.exposure(ev: -1.5))
        let round = try JSONDecoder().decode(
            ImageDocument.self, from: JSONEncoder().encode(doc))
        XCTAssertEqual(round, doc, "exposure op must round-trip through Codable")
    }

    // MARK: - Shadow/highlight + Sharpen (TSK-344)

    /// A left/right two-tone fixture with an INTERIOR vertical edge at x=width/2.
    /// Distinct dark (left) and light (right) regions for shadow-lift and
    /// edge-sharpen tests; the edge is interior so filter border effects don't
    /// contaminate the samples.
    private func verticalSplitImage(width: Int, height: Int,
                                    left: (CGFloat, CGFloat, CGFloat),
                                    right: (CGFloat, CGFloat, CGFloat)) -> CGImage {
        let ctx = makeContext(width: width, height: height)
        let half = width / 2
        ctx.setFillColor(red: left.0, green: left.1, blue: left.2, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: half, height: height))
        ctx.setFillColor(red: right.0, green: right.1, blue: right.2, alpha: 1)
        ctx.fill(CGRect(x: half, y: 0, width: width - half, height: height))
        return ctx.makeImage()!
    }

    func test_shadowHighlight_identity_preservesColor() throws {
        let data = try Exporter.encode(
            solidImage(width: 40, height: 40, r: 0.5, g: 0.5, b: 0.5),
            ExportSpec(format: .png))
        let plain = try Renderer.render(ImageDocument(data: data))
        let same = try Renderer.render(
            ImageDocument(data: data).appending(.shadowHighlight(shadow: 0, highlight: 1)))
        let p = sampleRGBA(plain, x: 20, y: 20)
        let s = sampleRGBA(same, x: 20, y: 20)
        XCTAssertTrue(s.close(to: p, tol: 6), "identity (0,1) changed the color: \(p) -> \(s)")
    }

    func test_shadowHighlight_shadowLift_brightensDarkRegion() throws {
        // Dark left / light right gives the tone-mapper a real shadow region.
        // Lifting shadows must brighten the dark region (sampled away from the edge).
        let img = verticalSplitImage(width: 80, height: 40, left: (0.12, 0.12, 0.12),
                                     right: (0.7, 0.7, 0.7))
        let data = try Exporter.encode(img, ExportSpec(format: .png))
        let darkX = 20 // well inside the left (dark) region
        let before = sampleRGBA(try Renderer.render(ImageDocument(data: data)), x: darkX, y: 20)
        let after = sampleRGBA(
            try Renderer.render(ImageDocument(data: data)
                .appending(.shadowHighlight(shadow: 1, highlight: 1))),
            x: darkX, y: 20)
        XCTAssertGreaterThan(Int(after.r), Int(before.r) + 5,
                             "shadow lift should brighten dark region (\(before.r) -> \(after.r))")
    }

    func test_shadowHighlight_survivesDocumentCodableRoundTrip() throws {
        let doc = ImageDocument(data: Data([7, 8, 9]))
            .appending(.shadowHighlight(shadow: 0.6, highlight: 0.4))
        let round = try JSONDecoder().decode(
            ImageDocument.self, from: JSONEncoder().encode(doc))
        XCTAssertEqual(round, doc, "shadowHighlight op must round-trip through Codable")
    }

    func test_sharpen_identity_preservesColor() throws {
        let data = try Exporter.encode(
            solidImage(width: 40, height: 40, r: 0.45, g: 0.55, b: 0.35),
            ExportSpec(format: .png))
        let plain = try Renderer.render(ImageDocument(data: data))
        let same = try Renderer.render(
            ImageDocument(data: data).appending(.sharpen(sharpness: 0)))
        XCTAssertEqual(same.width, 40)
        XCTAssertEqual(same.height, 40, "sharpen must not change geometry")
        let p = sampleRGBA(plain, x: 20, y: 20)
        let s = sampleRGBA(same, x: 20, y: 20)
        XCTAssertTrue(s.close(to: p, tol: 6), "sharpness 0 changed the color: \(p) -> \(s)")
    }

    func test_sharpen_flatRegion_isNoOp() throws {
        // No edges ⇒ unsharp-mask overshoot is zero ⇒ a solid fill is unchanged
        // even at high sharpness.
        let data = try Exporter.encode(
            solidImage(width: 40, height: 40, r: 0.5, g: 0.4, b: 0.6),
            ExportSpec(format: .png))
        let plain = sampleRGBA(try Renderer.render(ImageDocument(data: data)), x: 20, y: 20)
        let sharp = sampleRGBA(
            try Renderer.render(ImageDocument(data: data).appending(.sharpen(sharpness: 2))),
            x: 20, y: 20)
        XCTAssertTrue(sharp.close(to: plain, tol: 3),
                      "sharpen on a flat region should be a no-op: \(plain) -> \(sharp)")
    }

    func test_sharpen_edge_increasesContrast() throws {
        // At an edge, sharpening overshoots: the dark side just left of the edge
        // darkens, the light side just right lightens ⇒ cross-edge contrast grows.
        let w = 80
        let img = verticalSplitImage(width: w, height: 40, left: (0.3, 0.3, 0.3),
                                     right: (0.6, 0.6, 0.6))
        let data = try Exporter.encode(img, ExportSpec(format: .png))
        let half = w / 2
        let plain = try Renderer.render(ImageDocument(data: data))
        let sharp = try Renderer.render(
            ImageDocument(data: data).appending(.sharpen(sharpness: 2)))
        let beforeContrast = Int(sampleRGBA(plain, x: half, y: 20).r)
            - Int(sampleRGBA(plain, x: half - 1, y: 20).r)
        let afterContrast = Int(sampleRGBA(sharp, x: half, y: 20).r)
            - Int(sampleRGBA(sharp, x: half - 1, y: 20).r)
        XCTAssertGreaterThan(afterContrast, beforeContrast + 3,
                             "sharpen should increase edge contrast (\(beforeContrast) -> \(afterContrast))")
    }

    func test_sharpen_survivesDocumentCodableRoundTrip() throws {
        let doc = ImageDocument(data: Data([1, 1, 2, 3]))
            .appending(.sharpen(sharpness: 0.8))
        let round = try JSONDecoder().decode(
            ImageDocument.self, from: JSONEncoder().encode(doc))
        XCTAssertEqual(round, doc, "sharpen op must round-trip through Codable")
    }

    // MARK: - Histogram (analysis; TSK-344)

    func test_histogram_solidColor_concentratesInExpectedBins() throws {
        // A full-rect solid fill is byte-uniform (no anti-aliasing), so each
        // channel collapses onto its fixture value. Distinct per-channel values
        // (200/100/50) prove the R/G/B mapping — a red↔blue swap would fail.
        let w = 40, h = 30
        let img = solidImage(width: w, height: h, r: 200 / 255, g: 100 / 255, b: 50 / 255)
        let hist = try Renderer.histogram(img)

        XCTAssertEqual(hist.pixelCount, w * h)
        // Structural: every pixel counted exactly once in every channel.
        XCTAssertEqual(hist.red.reduce(0, +), w * h)
        XCTAssertEqual(hist.green.reduce(0, +), w * h)
        XCTAssertEqual(hist.blue.reduce(0, +), w * h)
        XCTAssertEqual(hist.luma.reduce(0, +), w * h)

        // All mass within ±2 of the expected bin (CG quantization slack), and
        // the peak lands on the fixture color.
        XCTAssertEqual(hist.red[198...202].reduce(0, +), w * h)
        XCTAssertEqual(hist.green[98...102].reduce(0, +), w * h)
        XCTAssertEqual(hist.blue[48...52].reduce(0, +), w * h)
        XCTAssertLessThanOrEqual(abs(Histogram.peakBin(hist.red) - 200), 2)
        XCTAssertLessThanOrEqual(abs(Histogram.peakBin(hist.green) - 100), 2)
        XCTAssertLessThanOrEqual(abs(Histogram.peakBin(hist.blue) - 50), 2)
        // Rec.601 luma of (200,100,50) = round(0.299·200+0.587·100+0.114·50)=124.
        XCTAssertLessThanOrEqual(abs(Histogram.peakBin(hist.luma) - 124), 2)
    }

    func test_histogram_quadrants_exactBinSplit() throws {
        // Pure 0/255 fills → exact bins (no rounding). Quadrants: red, green,
        // blue, yellow — each side²/4 px. Per channel, count the 255-quadrants.
        let side = 100
        let total = side * side
        let quad = total / 4
        let hist = try Renderer.histogram(quadrantImage(side: side).image)

        XCTAssertEqual(hist.pixelCount, total)
        // Red is 255 in the red + yellow quadrants, 0 elsewhere.
        XCTAssertEqual(hist.red[255], 2 * quad)
        XCTAssertEqual(hist.red[0], 2 * quad)
        XCTAssertEqual(hist.red[1...254].reduce(0, +), 0, "no intermediate red values")
        // Green is 255 in the green + yellow quadrants.
        XCTAssertEqual(hist.green[255], 2 * quad)
        XCTAssertEqual(hist.green[0], 2 * quad)
        // Blue is 255 only in the blue quadrant — a red↔blue swap would read 3·quad.
        XCTAssertEqual(hist.blue[255], quad)
        XCTAssertEqual(hist.blue[0], 3 * quad)
    }

    // MARK: - Crop

    func test_crop_topLeftQuadrant_centerSampleMatchesColor() throws {
        let side = 200
        let fx = quadrantImage(side: side)
        // Crop the top-left quadrant in SOURCE PIXEL SPACE (top-left origin):
        // x in [0, half), y in [0, half).
        let half = side / 2
        let doc = ImageDocument(data: try Exporter.encode(fx.image, ExportSpec(format: .png)))
            .appending(.crop(CGRect(x: 0, y: 0, width: half, height: half)))
        let out = try Renderer.render(doc)
        XCTAssertEqual(out.width, half)
        XCTAssertEqual(out.height, half)
        // Center of the cropped result should be the top-left quadrant color.
        let center = sampleRGBA(out, x: half / 2, y: half / 2)
        XCTAssertTrue(center.close(to: fx.topLeft, tol: 2),
                      "cropped center \(center) != topLeft \(fx.topLeft)")
    }

    func test_crop_centerSample_sanityAcrossQuadrants() throws {
        // Sanity that the fixture's quadrant→color mapping is what sampleRGBA
        // reads, so the crop test above is meaningful.
        let side = 100
        let fx = quadrantImage(side: side)
        let q = side / 4
        XCTAssertTrue(sampleRGBA(fx.image, x: q, y: q).close(to: fx.topLeft))
        XCTAssertTrue(sampleRGBA(fx.image, x: 3 * q, y: q).close(to: fx.topRight))
        XCTAssertTrue(sampleRGBA(fx.image, x: q, y: 3 * q).close(to: fx.bottomLeft))
        XCTAssertTrue(sampleRGBA(fx.image, x: 3 * q, y: 3 * q).close(to: fx.bottomRight))
    }

    // MARK: - Solid-fill resize (no edge bleed)

    func test_solidFillResize_cornersUnchanged() throws {
        let src = solidImage(width: 256, height: 256, r: 0.8, g: 0.3, b: 0.1)
        let expected = sampleRGBA(src, x: 1, y: 1) // any pixel of the solid fill
        let doc = ImageDocument(data: try Exporter.encode(src, ExportSpec(format: .png)))
            .appending(.resize(width: 64, height: 64))
        let out = try Renderer.render(doc)
        XCTAssertEqual(out.width, 64)
        XCTAssertEqual(out.height, 64)
        for (cx, cy) in [(0, 0), (63, 0), (0, 63), (63, 63), (32, 32)] {
            let s = sampleRGBA(out, x: cx, y: cy)
            XCTAssertTrue(s.close(to: expected, tol: 2),
                          "corner (\(cx),\(cy)) bled: \(s) vs \(expected)")
        }
    }

    // MARK: - JPEG quality monotonicity (property)

    func test_jpegQuality_byteSizesStrictlyIncreasing() throws {
        // A noisy image so quality actually moves bytes (a flat fill compresses
        // to near-identical sizes regardless of quality).
        let img = noiseImage(width: 256, height: 256)
        let q30 = try Exporter.encode(img, ExportSpec(format: .jpeg, quality: 0.3)).count
        let q60 = try Exporter.encode(img, ExportSpec(format: .jpeg, quality: 0.6)).count
        let q90 = try Exporter.encode(img, ExportSpec(format: .jpeg, quality: 0.9)).count
        XCTAssertLessThan(q30, q60, "q0.3 (\(q30)) !< q0.6 (\(q60))")
        XCTAssertLessThan(q60, q90, "q0.6 (\(q60)) !< q0.9 (\(q90))")
    }

    /// Deterministic pseudo-random RGB noise so JPEG quality has signal to act
    /// on. Pure LCG fill — no randomness, so the test is reproducible.
    private func noiseImage(width: Int, height: Int) -> CGImage {
        let ctx = makeContext(width: width, height: height)
        var state: UInt64 = 0x9E3779B97F4A7C15
        func next() -> CGFloat {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return CGFloat((state >> 33) & 0xFF) / 255.0
        }
        // 4x4 noisy tiles keep the draw cheap while producing high-frequency
        // content that resists low-quality JPEG compression.
        let tile = 4
        for ty in stride(from: 0, to: height, by: tile) {
            for tx in stride(from: 0, to: width, by: tile) {
                ctx.setFillColor(red: next(), green: next(), blue: next(), alpha: 1)
                ctx.fill(CGRect(x: tx, y: ty, width: tile, height: tile))
            }
        }
        return ctx.makeImage()!
    }

    // MARK: - PNG lossless round-trip

    func test_pngRoundTrip_dimsAndPixelExact() throws {
        let fx = quadrantImage(side: 128)
        let data = try Exporter.encode(fx.image, ExportSpec(format: .png))
        // Re-decode via the engine's own decode path.
        let decoded = try Renderer.decode(.data(data))
        XCTAssertEqual(decoded.width, 128)
        XCTAssertEqual(decoded.height, 128)
        // Top-left quadrant center pixel must round-trip exactly (lossless).
        let s = sampleRGBA(decoded, x: 32, y: 32)
        XCTAssertTrue(s.close(to: fx.topLeft, tol: 0),
                      "PNG not lossless: \(s) vs \(fx.topLeft)")
    }

    // MARK: - Re-open exported data: UTI + dims

    func test_exportedData_reportsExpectedUTIAndDims() throws {
        let img = solidImage(width: 320, height: 240, r: 0.1, g: 0.7, b: 0.5)

        for format in ExportSpec.Format.allCases {
            // HEIC encode can be unavailable in some headless/CI sandboxes;
            // skip the format if encode itself throws rather than fail.
            let data: Data
            do {
                data = try Exporter.encode(img, ExportSpec(format: format, quality: 0.9))
            } catch {
                if format == .heic { continue }
                throw error
            }
            guard let src = CGImageSourceCreateWithData(data as CFData, nil) else {
                return XCTFail("could not reopen \(format) data")
            }
            let typeID = CGImageSourceGetType(src) as String?
            XCTAssertEqual(typeID, format.utType.identifier,
                           "UTI mismatch for \(format)")
            let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
            XCTAssertEqual(props?[kCGImagePropertyPixelWidth] as? Int, 320)
            XCTAssertEqual(props?[kCGImagePropertyPixelHeight] as? Int, 240)
        }
    }

    // MARK: - Orientation bakes pixels (axis swap)

    func test_orient_right90_swapsAxes() throws {
        let fx = quadrantImage(side: 100)
        let doc = ImageDocument(data: try Exporter.encode(fx.image, ExportSpec(format: .png)))
            .appending(.orient(.right90))
        let out = try Renderer.render(doc)
        // Square fixture so dims don't reveal the swap; use a non-square check.
        let rect = solidImage(width: 80, height: 40, r: 0.2, g: 0.2, b: 0.9)
        let rdoc = ImageDocument(data: try Exporter.encode(rect, ExportSpec(format: .png)))
            .appending(.orient(.right90))
        let rout = try Renderer.render(rdoc)
        XCTAssertEqual(rout.width, 40, "right90 must swap W/H")
        XCTAssertEqual(rout.height, 80)
        XCTAssertEqual(out.width, 100) // square stays square
    }

    // MARK: - Model laws

    func test_law_appendThenUndo_rendersIdentical() throws {
        let src = quadrantImage(side: 96).image
        let base = ImageDocument(data: try Exporter.encode(src, ExportSpec(format: .png)))
        let edited = base.appending(.resize(width: 48, height: 48)).undoingLast()
        XCTAssertEqual(edited, base, "append then undo must equal original")

        let before = try Renderer.render(base)
        let after = try Renderer.render(edited)
        XCTAssertEqual(before.width, after.width)
        XCTAssertEqual(before.height, after.height)
        // Spot-check a quadrant center renders identically.
        XCTAssertEqual(sampleRGBA(before, x: 24, y: 24), sampleRGBA(after, x: 24, y: 24))
    }

    func test_law_revert_clearsOps() throws {
        let doc = ImageDocument(data: Data([0, 1, 2, 3]))
            .appending(.resize(width: 10, height: 10))
            .appending(.orient(.down))
        XCTAssertFalse(doc.isPristine)
        let reverted = doc.reverted()
        XCTAssertTrue(reverted.ops.isEmpty)
        XCTAssertTrue(reverted.isPristine)
        XCTAssertEqual(reverted, ImageDocument(data: Data([0, 1, 2, 3])))
    }

    func test_law_codableRoundTrip_dataSource() throws {
        let doc = ImageDocument(data: Data([10, 20, 30, 40]), ops: [
            .crop(CGRect(x: 1, y: 2, width: 3, height: 4)),
            .resize(width: 100, height: 50),
            .orient(.left90),
        ])
        let encoded = try JSONEncoder().encode(doc)
        let decoded = try JSONDecoder().decode(ImageDocument.self, from: encoded)
        XCTAssertEqual(decoded, doc)
    }

    func test_law_codableRoundTrip_urlSource() throws {
        let url = tmpDir.appendingPathComponent("ref.png")
        let doc = ImageDocument(contentsOf: url, ops: [.orient(.upMirrored)])
        let encoded = try JSONEncoder().encode(doc)
        let decoded = try JSONDecoder().decode(ImageDocument.self, from: encoded)
        XCTAssertEqual(decoded, doc)
    }

    // MARK: - URL source decodes (end-to-end through a temp file)

    func test_urlSource_rendersFromTempFile() throws {
        let img = solidImage(width: 120, height: 90, r: 0.3, g: 0.6, b: 0.2)
        let url = try writePNG(img, name: "src.png")
        let doc = ImageDocument(contentsOf: url).appending(.resize(width: 60, height: 45))
        let out = try Renderer.render(doc)
        XCTAssertEqual(out.width, 60)
        XCTAssertEqual(out.height, 45)
    }

    func test_decode_emptyData_throwsSourceDecodeFailed() {
        XCTAssertThrowsError(try Renderer.decode(.data(Data()))) { error in
            XCTAssertEqual(error as? ImageEditError, .sourceDecodeFailed)
        }
    }

    func test_crop_outOfBounds_clampsRatherThanThrows() throws {
        let img = solidImage(width: 50, height: 50, r: 1, g: 1, b: 1)
        // Rect extends beyond bounds; intersection is the in-bounds region.
        let doc = ImageDocument(data: try Exporter.encode(img, ExportSpec(format: .png)))
            .appending(.crop(CGRect(x: 25, y: 25, width: 100, height: 100)))
        let out = try Renderer.render(doc)
        XCTAssertEqual(out.width, 25)
        XCTAssertEqual(out.height, 25)
    }
}
