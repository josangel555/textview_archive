import CoreGraphics
import Foundation

/// A straight (un-premultiplied) 8-bit-per-channel RGBA color, the value type the
/// raster paint tools speak in. The geometry/tonal `EditOp` pipeline is lossless
/// and replayable, but PAINT is fundamentally destructive — a flood fill or a
/// brush dab rewrites pixels in place and cannot be re-derived from `source + ops`.
/// So the paint engine deliberately lives OUTSIDE `EditOp`, operating on a
/// concrete owned pixel buffer (`RasterCanvas`) instead of the op-list.
///
/// Channels are *straight* (not premultiplied): `RGBAColor(r:255, g:0, b:0, a:128)`
/// is "half-transparent pure red", and the canvas premultiplies once at the
/// `CGImage` boundary. Equatable so callers (and tests) can assert exact colors.
public struct RGBAColor: Sendable, Equatable, Codable {
    public var r: UInt8
    public var g: UInt8
    public var b: UInt8
    public var a: UInt8

    public init(r: UInt8, g: UInt8, b: UInt8, a: UInt8 = 255) {
        self.r = r
        self.g = g
        self.b = b
        self.a = a
    }

    /// Common opaque presets so a tool palette doesn't have to spell out bytes.
    public static let black = RGBAColor(r: 0, g: 0, b: 0)
    public static let white = RGBAColor(r: 255, g: 255, b: 255)
    public static let red = RGBAColor(r: 255, g: 0, b: 0)
    public static let green = RGBAColor(r: 0, g: 255, b: 0)
    public static let blue = RGBAColor(r: 0, g: 0, b: 255)
    /// A fully-transparent color (an "erase" fill source).
    public static let clear = RGBAColor(r: 0, g: 0, b: 0, a: 0)
}

/// An owned, mutable straight-RGBA8 pixel buffer — the working surface for the
/// raster paint tools (flood fill, brush). Top-left origin, row-major, exactly
/// `width · height · 4` bytes with no row padding, so pixel math is a flat
/// `(y · width + x) · 4` index with no stride to reason about. This is the
/// "pixels in → pixels out" core the host tests pin: every op is a pure mutation
/// of `pixels` whose effect is asserted byte-for-byte.
///
/// Decode/encode bridges to `CGImage` premultiply at the boundary only, so the
/// in-buffer representation stays straight (un-premultiplied) and the paint math
/// never has to un-multiply mid-op.
public struct RasterCanvas: Sendable, Equatable {
    public let width: Int
    public let height: Int
    /// Straight RGBA8, row-major, top-left origin, length `width·height·4`.
    public private(set) var pixels: [UInt8]

    /// Bytes per pixel — fixed RGBA8.
    public static let bytesPerPixel = 4

    /// Create a canvas of the given size filled with `fill` (default transparent).
    /// A non-positive dimension collapses to a 0×0 empty canvas rather than
    /// trapping, mirroring the engine's "degenerate geometry degrades, never
    /// crashes" discipline.
    public init(width: Int, height: Int, fill: RGBAColor = .clear) {
        let w = max(0, width)
        let h = max(0, height)
        self.width = w
        self.height = h
        var buf = [UInt8](repeating: 0, count: w * h * Self.bytesPerPixel)
        if fill != .clear {
            var i = 0
            while i < buf.count {
                buf[i] = fill.r
                buf[i + 1] = fill.g
                buf[i + 2] = fill.b
                buf[i + 3] = fill.a
                i += Self.bytesPerPixel
            }
        }
        self.pixels = buf
    }

    /// Wrap an existing straight-RGBA8 buffer. Returns `nil` if `pixels` is not
    /// exactly `width·height·4` bytes — a length mismatch is a programmer error
    /// we surface rather than silently read out of bounds.
    public init?(width: Int, height: Int, pixels: [UInt8]) {
        guard width >= 0, height >= 0,
              pixels.count == width * height * Self.bytesPerPixel else { return nil }
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    /// True for a 0-area canvas (the degenerate / empty case).
    public var isEmpty: Bool { width == 0 || height == 0 }

    // MARK: - Pixel access

    /// Flat byte index of pixel `(x, y)`, or `nil` if out of bounds.
    @inline(__always)
    private func index(x: Int, y: Int) -> Int? {
        guard x >= 0, x < width, y >= 0, y < height else { return nil }
        return (y * width + x) * Self.bytesPerPixel
    }

    /// Read the straight RGBA color at `(x, y)`, or `nil` if out of bounds.
    public func pixel(x: Int, y: Int) -> RGBAColor? {
        guard let i = index(x: x, y: y) else { return nil }
        return RGBAColor(r: pixels[i], g: pixels[i + 1], b: pixels[i + 2], a: pixels[i + 3])
    }

    /// Set the straight RGBA color at `(x, y)`. Out-of-bounds is a silent no-op
    /// so brush math at the edge never has to clamp every candidate by hand.
    public mutating func setPixel(x: Int, y: Int, to color: RGBAColor) {
        guard let i = index(x: x, y: y) else { return }
        pixels[i] = color.r
        pixels[i + 1] = color.g
        pixels[i + 2] = color.b
        pixels[i + 3] = color.a
    }

    /// TSK-1066 — fill an axis-aligned rect (clamped to the canvas) with `color`.
    /// Returns the pixel count written. Delete-selection = fill with `.clear`.
    @discardableResult
    public mutating func fillRect(
        x: Int, y: Int, width: Int, height: Int, to color: RGBAColor
    ) -> Int {
        let x0 = Swift.max(0, x), y0 = Swift.max(0, y)
        let x1 = Swift.min(self.width, x + width), y1 = Swift.min(self.height, y + height)
        guard x1 > x0, y1 > y0 else { return 0 }
        var written = 0
        for py in y0..<y1 {
            for px in x0..<x1 {
                setPixel(x: px, y: py, to: color)
                written += 1
            }
        }
        return written
    }

    /// TSK-1066 — composite `src` onto this canvas with its top-left at `(ox, oy)`,
    /// alpha-blending src OVER dest (straight-alpha "source-over"). Out-of-bounds
    /// pixels are skipped. Returns the count of dest pixels touched. Paste = blit
    /// the decoded clipboard image.
    @discardableResult
    public mutating func blit(_ src: RasterCanvas, atX ox: Int, atY oy: Int) -> Int {
        var written = 0
        for sy in 0..<src.height {
            let dy = oy + sy
            guard dy >= 0, dy < height else { continue }
            for sx in 0..<src.width {
                let dx = ox + sx
                guard dx >= 0, dx < width, let s = src.pixel(x: sx, y: sy), s.a > 0 else { continue }
                if s.a == 255 {
                    setPixel(x: dx, y: dy, to: s)
                } else if let d = pixel(x: dx, y: dy) {
                    setPixel(x: dx, y: dy, to: Self.over(s, d))
                }
                written += 1
            }
        }
        return written
    }

    /// Straight-alpha "source-over" composite of `s` over `d`.
    static func over(_ s: RGBAColor, _ d: RGBAColor) -> RGBAColor {
        let sa = Double(s.a) / 255, da = Double(d.a) / 255
        let oa = sa + da * (1 - sa)
        guard oa > 0 else { return RGBAColor(r: 0, g: 0, b: 0, a: 0) }
        func ch(_ sc: UInt8, _ dc: UInt8) -> UInt8 {
            let v = (Double(sc) * sa + Double(dc) * da * (1 - sa)) / oa
            return UInt8(Swift.max(0, Swift.min(255, v.rounded())))
        }
        return RGBAColor(r: ch(s.r, d.r), g: ch(s.g, d.g), b: ch(s.b, d.b),
                         a: UInt8((oa * 255).rounded()))
    }

    // MARK: - Color pick (the eyedropper)

    /// Sample the color under `(x, y)` — the eyedropper / color-picker tool.
    /// Returns `nil` if the point is outside the canvas. A pure read; the canvas
    /// is unchanged.
    public func pickColor(x: Int, y: Int) -> RGBAColor? { pixel(x: x, y: y) }

    // MARK: - Flood fill (the paint bucket)

    /// Flood-fill the contiguous region of pixels matching the seed pixel's color
    /// at `(x, y)`, replacing them with `replacement`. 4-connected (N/E/S/W),
    /// matching every common paint-bucket tool. `tolerance` (0…255) is the
    /// maximum per-channel absolute difference for a pixel to count as "same
    /// region" — `0` requires an exact match, higher values bleed across soft
    /// gradients.
    ///
    /// Implementation notes:
    ///  - Iterative explicit stack (NOT recursion): a recursive flood fill blows
    ///    the call stack on a large uniform region (a 4000×4000 fill ≈ 16M deep).
    ///  - Early-out when the seed already equals `replacement` (within tolerance):
    ///    otherwise the fill spins forever revisiting already-"matching" pixels.
    ///  - A `visited` bitmap bounds the work at O(width·height) regardless of
    ///    region shape, so a spiral or comb region can't re-push a pixel.
    ///
    /// Returns the number of pixels changed (0 if the seed is out of bounds or
    /// already the replacement color), so the UI/tests can assert the fill spread.
    @discardableResult
    public mutating func floodFill(
        x: Int, y: Int, with replacement: RGBAColor, tolerance: UInt8 = 0
    ) -> Int {
        guard let seed = pixel(x: x, y: y) else { return 0 }
        // No-op guard: if the seed already matches the replacement (exactly), the
        // fill would change nothing and the spin-forever risk is moot. We test
        // EXACT equality here (not tolerance) so a tolerant fill still re-paints a
        // near-but-not-equal seed to the precise replacement color.
        if seed == replacement { return 0 }

        let tol = Int(tolerance)
        var visited = [Bool](repeating: false, count: width * height)
        var stack: [(Int, Int)] = [(x, y)]
        var changed = 0

        while let (cx, cy) = stack.popLast() {
            let flat = cy * width + cx
            if visited[flat] { continue }
            visited[flat] = true
            guard let here = pixel(x: cx, y: cy), Self.matches(here, seed, tolerance: tol) else {
                continue
            }
            setPixel(x: cx, y: cy, to: replacement)
            changed += 1
            // 4-connected neighbors; bounds are enforced by `pixel`/`index`.
            if cx + 1 < width { stack.append((cx + 1, cy)) }
            if cx - 1 >= 0 { stack.append((cx - 1, cy)) }
            if cy + 1 < height { stack.append((cx, cy + 1)) }
            if cy - 1 >= 0 { stack.append((cx, cy - 1)) }
        }
        return changed
    }

    /// Per-channel tolerance match: every channel (including alpha) within `tol`
    /// of the seed. `tol == 0` is exact equality. Alpha is included so a fill
    /// doesn't bleed from an opaque region into a transparent hole.
    @inline(__always)
    static func matches(_ a: RGBAColor, _ b: RGBAColor, tolerance tol: Int) -> Bool {
        abs(Int(a.r) - Int(b.r)) <= tol
            && abs(Int(a.g) - Int(b.g)) <= tol
            && abs(Int(a.b) - Int(b.b)) <= tol
            && abs(Int(a.a) - Int(b.a)) <= tol
    }

    // MARK: - Brush (a single dab + a swept stroke)

    /// Stamp a single circular brush dab centred on `(cx, cy)` with the given
    /// `radius` (in pixels) and `color`. A radius of `0` paints exactly the one
    /// centre pixel; `radius` r paints the filled disc of pixels whose centre is
    /// within `r + 0.5` of `(cx, cy)` (the `+0.5` gives a visually rounder edge
    /// at small radii). Hard-edged (no anti-aliasing) for deterministic,
    /// byte-exact host testing. Out-of-canvas pixels are skipped.
    ///
    /// Returns the count of pixels written (clamped to the canvas), so a stroke
    /// can be asserted to have actually marked the surface.
    @discardableResult
    public mutating func brushDab(
        cx: Int, cy: Int, radius: Int, color: RGBAColor, square: Bool = false
    ) -> Int {
        let r = max(0, radius)
        if r == 0 {
            if index(x: cx, y: cy) != nil {
                setPixel(x: cx, y: cy, to: color)
                return 1
            }
            return 0
        }
        // Squared-distance test against (r + 0.5)^2 avoids per-pixel sqrt.
        let limit = (Double(r) + 0.5) * (Double(r) + 0.5)
        var written = 0
        for dy in -r...r {
            let py = cy + dy
            guard py >= 0, py < height else { continue }
            for dx in -r...r {
                let px = cx + dx
                guard px >= 0, px < width else { continue }
                if square || Double(dx * dx + dy * dy) <= limit {
                    setPixel(x: px, y: py, to: color)
                    written += 1
                }
            }
        }
        return written
    }

    /// Sweep a brush along the straight segment from `(x0, y0)` to `(x1, y1)`,
    /// stamping a `brushDab` at every integer step so a dragged stroke leaves a
    /// continuous mark instead of disconnected dabs. Uses a dense step count
    /// (max axis delta + 1) — simpler than Bresenham and, because each step is a
    /// full radius-`r` disc, it cannot leave gaps for any radius ≥ 0.
    ///
    /// Returns the count of distinct pixels written (a `visited` set dedupes the
    /// overlap between adjacent dabs), so a stroke's coverage is assertable.
    @discardableResult
    public mutating func brushStroke(
        from start: (x: Int, y: Int), to end: (x: Int, y: Int),
        radius: Int, color: RGBAColor, square: Bool = false
    ) -> Int {
        let steps = max(abs(end.x - start.x), abs(end.y - start.y))
        var visited = Set<Int>()
        let r = max(0, radius)
        let limit = (Double(r) + 0.5) * (Double(r) + 0.5)

        func stampDab(cx: Int, cy: Int) {
            if r == 0 {
                if let i = index(x: cx, y: cy) {
                    setPixel(x: cx, y: cy, to: color)
                    visited.insert(i)
                }
                return
            }
            for dy in -r...r {
                let py = cy + dy
                guard py >= 0, py < height else { continue }
                for dx in -r...r {
                    let px = cx + dx
                    guard px >= 0, px < width else { continue }
                    if (square || Double(dx * dx + dy * dy) <= limit), let i = index(x: px, y: py) {
                        setPixel(x: px, y: py, to: color)
                        visited.insert(i)
                    }
                }
            }
        }

        if steps == 0 {
            stampDab(cx: start.x, cy: start.y)
            return visited.count
        }
        for s in 0...steps {
            let t = Double(s) / Double(steps)
            // Round to nearest integer pixel along the line.
            let px = Int((Double(start.x) + t * Double(end.x - start.x)).rounded())
            let py = Int((Double(start.y) + t * Double(end.y - start.y)).rounded())
            stampDab(cx: px, cy: py)
        }
        return visited.count
    }

    /// TSK-1082 — airbrush: stamp a RANDOM subset of the radius-`radius` disc
    /// around `(cx, cy)` — each in-disc pixel is painted with probability
    /// `density` (clamped 0…1). Repeated dabs build up coverage. Returns the
    /// pixel count written. The RNG is injected so callers/tests control it
    /// (density 1 → the whole disc; density 0 → nothing).
    @discardableResult
    public mutating func spray<G: RandomNumberGenerator>(
        cx: Int, cy: Int, radius: Int, density: Double, color: RGBAColor, using rng: inout G
    ) -> Int {
        let r = Swift.max(0, radius)
        let limit = (Double(r) + 0.5) * (Double(r) + 0.5)
        let d = Swift.max(0, Swift.min(1, density))
        var written = 0
        for dy in -r...r {
            let py = cy + dy
            guard py >= 0, py < height else { continue }
            for dx in -r...r {
                let px = cx + dx
                guard px >= 0, px < width, Double(dx * dx + dy * dy) <= limit else { continue }
                if Double.random(in: 0..<1, using: &rng) < d {
                    setPixel(x: px, y: py, to: color)
                    written += 1
                }
            }
        }
        return written
    }

    // MARK: - CGImage bridge

    /// Build a straight-RGBA8 sRGB `CGImage` from the canvas (for preview/export).
    /// Returns `nil` for an empty canvas or if CoreGraphics can't make the image.
    /// Uses `alphaInfo = .last` (RGBA byte order, non-premultiplied) matching the
    /// in-buffer representation.
    ///
    /// The pixel bytes are handed to a `CFData`-backed `CGDataProvider`, which the
    /// returned `CGImage` retains — so the backing store outlives this call (no
    /// dangling pointer from a borrowed `withUnsafeBytes` scope).
    public func cgImage() -> CGImage? {
        guard !isEmpty else { return nil }
        let cs = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let bytesPerRow = width * Self.bytesPerPixel
        let data = Data(pixels) as CFData
        guard let provider = CGDataProvider(data: data) else { return nil }
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: cs,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }

    /// Decode a `CGImage` into a straight-RGBA8 canvas (top-left origin), redrawing
    /// into a known-format context so the source's pixel format / color space is
    /// normalized away — the same "normalize once" discipline `Renderer` uses.
    /// Returns `nil` for a degenerate (0-area) image or on a CoreGraphics failure.
    ///
    /// CoreGraphics bitmap contexts only draw into PREMULTIPLIED alpha layouts
    /// (`.premultipliedLast` here), so after the draw we un-premultiply each pixel
    /// back to straight RGBA — the in-buffer representation the paint math and
    /// `pixel(x:y:)` assume. Without this an alpha-`a` red pixel would store
    /// `r·a/255`, and a later `pickColor` would report the wrong color.
    public static func from(_ image: CGImage) -> RasterCanvas? {
        let w = image.width, h = image.height
        guard w > 0, h > 0 else { return nil }
        let cs = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        var buf = [UInt8](repeating: 0, count: w * h * bytesPerPixel)
        let made: Bool = buf.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(
                data: raw.baseAddress,
                width: w, height: h,
                bitsPerComponent: 8,
                bytesPerRow: w * bytesPerPixel,
                space: cs,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard made else { return nil }
        // Un-premultiply in place: straight = premultiplied · 255 / alpha (rounded),
        // clamped to the 8-bit ceiling. Mirrors `Renderer.histogram`'s un-premultiply.
        var i = 0
        while i < buf.count {
            let a = Int(buf[i + 3])
            if a != 0, a != 255 {
                buf[i] = UInt8(min(255, (Int(buf[i]) * 255 + a / 2) / a))
                buf[i + 1] = UInt8(min(255, (Int(buf[i + 1]) * 255 + a / 2) / a))
                buf[i + 2] = UInt8(min(255, (Int(buf[i + 2]) * 255 + a / 2) / a))
            } else if a == 0 {
                // Fully transparent: no defined color; leave channels at 0.
                buf[i] = 0; buf[i + 1] = 0; buf[i + 2] = 0
            }
            i += bytesPerPixel
        }
        return RasterCanvas(width: w, height: h, pixels: buf)
    }
}
