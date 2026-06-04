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
