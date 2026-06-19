import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import ViewerCore

/// T1 headless tests for the draw ops (TSK-749): rasterizing filled/stroked
/// rects, ellipses, lines, and text onto the pixel buffer. Fixtures are drawn
/// programmatically; pixels are sampled in TOP-LEFT origin (the same convention
/// as the engine's crop space and the draw ops' coordinates).
final class ImageDrawOpsTests: XCTestCase {

    private struct RGBA: Equatable {
        var r: UInt8, g: UInt8, b: UInt8, a: UInt8
        func close(to other: RGBA, tol: Int = 4) -> Bool {
            abs(Int(r) - Int(other.r)) <= tol
                && abs(Int(g) - Int(other.g)) <= tol
                && abs(Int(b) - Int(other.b)) <= tol
                && abs(Int(a) - Int(other.a)) <= tol
        }
    }

    private func makeContext(width: Int, height: Int) -> CGContext {
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let info = CGImageAlphaInfo.premultipliedFirst.rawValue
            | CGBitmapInfo.byteOrder32Little.rawValue
        return CGContext(data: nil, width: width, height: height,
                         bitsPerComponent: 8, bytesPerRow: 0,
                         space: space, bitmapInfo: info)!
    }

    private func solidImage(width: Int, height: Int,
                            r: CGFloat, g: CGFloat, b: CGFloat) -> CGImage {
        let ctx = makeContext(width: width, height: height)
        ctx.setFillColor(red: r, green: g, blue: b, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()!
    }

    private func solidPNG(width: Int, height: Int,
                          r: CGFloat, g: CGFloat, b: CGFloat) throws -> Data {
        try Exporter.encode(solidImage(width: width, height: height, r: r, g: g, b: b),
                            ExportSpec(format: .png))
    }

    /// Sample a single pixel at top-left `(x, y)`, un-premultiplied to straight RGBA.
    private func sampleRGBA(_ image: CGImage, x: Int, y: Int) -> RGBA {
        let w = image.width, h = image.height
        precondition(x >= 0 && x < w && y >= 0 && y < h, "sample out of bounds")
        let bytesPerRow = w * 4
        var buf = [UInt8](repeating: 0, count: bytesPerRow * h)
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let info = CGImageAlphaInfo.premultipliedLast.rawValue
            | CGBitmapInfo.byteOrder32Big.rawValue // R,G,B,A
        buf.withUnsafeMutableBytes { raw in
            let ctx = CGContext(data: raw.baseAddress, width: w, height: h,
                                bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                                space: space, bitmapInfo: info)!
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        let i = y * bytesPerRow + x * 4
        let r = buf[i], g = buf[i + 1], b = buf[i + 2], a = buf[i + 3]
        if a == 0 { return RGBA(r: 0, g: 0, b: 0, a: 0) }
        let rr = UInt8(min(255, Int(r) * 255 / Int(a)))
        let gg = UInt8(min(255, Int(g) * 255 / Int(a)))
        let bb = UInt8(min(255, Int(b) * 255 / Int(a)))
        return RGBA(r: rr, g: gg, b: bb, a: a)
    }

    // MARK: - DrawColor

    func test_drawColor_clampsChannels() {
        let c = DrawColor(red: 2.0, green: -1.0, blue: 0.5, alpha: 9)
        XCTAssertEqual(c.red, 1)
        XCTAssertEqual(c.green, 0)
        XCTAssertEqual(c.blue, 0.5)
        XCTAssertEqual(c.alpha, 1)
    }

    func test_drawColor_roundTripsCodable() throws {
        let doc = ImageDocument(data: Data([1, 2, 3]))
            .appending(.fillRect(CGRect(x: 1, y: 2, width: 3, height: 4),
                                 DrawColor(red: 0.1, green: 0.2, blue: 0.3, alpha: 0.4)))
        let round = try JSONDecoder().decode(
            ImageDocument.self, from: JSONEncoder().encode(doc))
        XCTAssertEqual(round, doc, "fillRect/DrawColor must round-trip through Codable")
    }

    // MARK: - Fill rect

    func test_fillRect_paintsInteriorAndPreservesDims_andSpaceOutside() throws {
        // White canvas; fill a red rect in the top-left region (source pixel space).
        let data = try solidPNG(width: 100, height: 80, r: 1, g: 1, b: 1)
        let red = DrawColor(red: 1, green: 0, blue: 0)
        let doc = ImageDocument(data: data)
            .appending(.fillRect(CGRect(x: 20, y: 10, width: 40, height: 30), red))
        let out = try Renderer.render(doc)
        XCTAssertEqual(out.width, 100, "draw must not resize the canvas")
        XCTAssertEqual(out.height, 80)
        // Interior of the rect is red.
        XCTAssertTrue(sampleRGBA(out, x: 40, y: 25).close(to: RGBA(r: 255, g: 0, b: 0, a: 255)),
                      "rect interior should be red")
        // Outside the rect is still white (proves top-left coords + clipping).
        XCTAssertTrue(sampleRGBA(out, x: 90, y: 70).close(to: RGBA(r: 255, g: 255, b: 255, a: 255)),
                      "outside the rect must stay white")
        // A point just above the rect (smaller y in top-left space) is white.
        XCTAssertTrue(sampleRGBA(out, x: 40, y: 2).close(to: RGBA(r: 255, g: 255, b: 255, a: 255)),
                      "region above the rect (top of image) must stay white")
    }

    func test_fillRect_outOfBounds_clipsToCanvas_noThrow() throws {
        let data = try solidPNG(width: 50, height: 50, r: 1, g: 1, b: 1)
        let doc = ImageDocument(data: data)
            // Rect extends well past the right/bottom edges — must clip, not crash.
            .appending(.fillRect(CGRect(x: 30, y: 30, width: 200, height: 200),
                                 DrawColor(red: 0, green: 0, blue: 1)))
        let out = try Renderer.render(doc)
        XCTAssertEqual(out.width, 50)
        XCTAssertEqual(out.height, 50)
        XCTAssertTrue(sampleRGBA(out, x: 45, y: 45).close(to: RGBA(r: 0, g: 0, b: 255, a: 255)),
                      "in-bounds part of an oversized rect should paint")
    }

    // MARK: - Fill ellipse

    func test_fillEllipse_paintsCenter_andLeavesCorners() throws {
        let data = try solidPNG(width: 100, height: 100, r: 1, g: 1, b: 1)
        let doc = ImageDocument(data: data)
            .appending(.fillEllipse(CGRect(x: 0, y: 0, width: 100, height: 100),
                                    DrawColor(red: 0, green: 1, blue: 0)))
        let out = try Renderer.render(doc)
        // Center of an inscribed ellipse is filled green.
        XCTAssertTrue(sampleRGBA(out, x: 50, y: 50).close(to: RGBA(r: 0, g: 255, b: 0, a: 255)),
                      "ellipse center should be green")
        // The corner is OUTSIDE the inscribed ellipse → still white.
        XCTAssertTrue(sampleRGBA(out, x: 3, y: 3).close(to: RGBA(r: 255, g: 255, b: 255, a: 255)),
                      "ellipse corner must remain white")
    }

    // MARK: - Stroke line

    func test_strokeLine_paintsAlongPath_notOffIt() throws {
        let data = try solidPNG(width: 100, height: 100, r: 1, g: 1, b: 1)
        // A thick horizontal line at y=50 from x=10 to x=90.
        let doc = ImageDocument(data: data)
            .appending(.strokeLine(from: CGPoint(x: 10, y: 50),
                                   to: CGPoint(x: 90, y: 50),
                                   DrawColor(red: 0, green: 0, blue: 0),
                                   lineWidth: 6))
        let out = try Renderer.render(doc)
        // On the line.
        XCTAssertTrue(sampleRGBA(out, x: 50, y: 50).close(to: RGBA(r: 0, g: 0, b: 0, a: 255)),
                      "on-path pixel should be black")
        // Far from the line — untouched white.
        XCTAssertTrue(sampleRGBA(out, x: 50, y: 10).close(to: RGBA(r: 255, g: 255, b: 255, a: 255)),
                      "off-path pixel must stay white")
    }

    // MARK: - Stroke rect / ellipse outline (edge painted, interior preserved)

    func test_strokeRect_paintsEdge_keepsInterior() throws {
        let data = try solidPNG(width: 100, height: 100, r: 1, g: 1, b: 1)
        let doc = ImageDocument(data: data)
            .appending(.strokeRect(CGRect(x: 20, y: 20, width: 60, height: 60),
                                   DrawColor(red: 0, green: 0, blue: 0),
                                   lineWidth: 4))
        let out = try Renderer.render(doc)
        // On the top edge (y≈20) → black.
        XCTAssertTrue(sampleRGBA(out, x: 50, y: 20).close(to: RGBA(r: 0, g: 0, b: 0, a: 255)),
                      "stroke edge should be black")
        // Deep in the interior → still white (stroke, not fill).
        XCTAssertTrue(sampleRGBA(out, x: 50, y: 50).close(to: RGBA(r: 255, g: 255, b: 255, a: 255)),
                      "stroked rect interior must stay white")
    }

    // MARK: - Draw text

    func test_drawText_paintsDarkPixels_overLightCanvas() throws {
        let data = try solidPNG(width: 200, height: 60, r: 1, g: 1, b: 1)
        let doc = ImageDocument(data: data)
            .appending(.drawText("Hello", origin: CGPoint(x: 10, y: 10),
                                 DrawColor(red: 0, green: 0, blue: 0),
                                 fontSize: 32))
        let out = try Renderer.render(doc)
        XCTAssertEqual(out.width, 200, "text must not resize the canvas")
        XCTAssertEqual(out.height, 60)
        // Scan the text band for at least some near-black glyph pixels.
        var darkCount = 0
        for y in 10..<50 {
            for x in 10..<150 {
                let p = sampleRGBA(out, x: x, y: y)
                if p.r < 80 && p.g < 80 && p.b < 80 { darkCount += 1 }
            }
        }
        XCTAssertGreaterThan(darkCount, 30, "rendered text should leave dark glyph pixels")
    }

    func test_drawText_emptyString_isNoOp() throws {
        let data = try solidPNG(width: 40, height: 40, r: 0.5, g: 0.5, b: 0.5)
        let plain = try Renderer.render(ImageDocument(data: data))
        let withText = try Renderer.render(
            ImageDocument(data: data).appending(
                .drawText("", origin: CGPoint(x: 1, y: 1),
                          DrawColor(red: 0, green: 0, blue: 0), fontSize: 20)))
        let p = sampleRGBA(plain, x: 20, y: 20)
        let t = sampleRGBA(withText, x: 20, y: 20)
        XCTAssertTrue(t.close(to: p, tol: 2), "empty text must not change pixels")
    }

    // MARK: - Composition: draw ops compose & replay through the op list

    func test_drawOpsCompose_inOrder() throws {
        // Fill the whole canvas red, then paint a blue rect over part of it.
        let data = try solidPNG(width: 60, height: 60, r: 1, g: 1, b: 1)
        let doc = ImageDocument(data: data)
            .appending(.fillRect(CGRect(x: 0, y: 0, width: 60, height: 60),
                                 DrawColor(red: 1, green: 0, blue: 0)))
            .appending(.fillRect(CGRect(x: 0, y: 0, width: 30, height: 60),
                                 DrawColor(red: 0, green: 0, blue: 1)))
        let out = try Renderer.render(doc)
        // Left half = blue (painted second, on top), right half = red.
        XCTAssertTrue(sampleRGBA(out, x: 10, y: 30).close(to: RGBA(r: 0, g: 0, b: 255, a: 255)),
                      "left half should be the later blue rect")
        XCTAssertTrue(sampleRGBA(out, x: 50, y: 30).close(to: RGBA(r: 255, g: 0, b: 0, a: 255)),
                      "right half should remain the red rect")
    }

    func test_drawThenCrop_drawIsInSourcePixelSpace() throws {
        // Paint a green rect at (10,10,20x20) then crop to that exact region —
        // the crop result should be fully green (proves draw + crop share coords).
        let data = try solidPNG(width: 80, height: 80, r: 1, g: 1, b: 1)
        let doc = ImageDocument(data: data)
            .appending(.fillRect(CGRect(x: 10, y: 10, width: 20, height: 20),
                                 DrawColor(red: 0, green: 1, blue: 0)))
            .appending(.crop(CGRect(x: 10, y: 10, width: 20, height: 20)))
        let out = try Renderer.render(doc)
        XCTAssertEqual(out.width, 20)
        XCTAssertEqual(out.height, 20)
        XCTAssertTrue(sampleRGBA(out, x: 10, y: 10).close(to: RGBA(r: 0, g: 255, b: 0, a: 255)),
                      "draw + crop must agree on source pixel coordinates")
    }
}
