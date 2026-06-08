import CoreGraphics
import CoreImage
import Foundation
import ImageIO

/// Pure, headless image-edit renderer: turns an `ImageDocument`
/// (`source + ops`) into a concrete `CGImage`. Stateless — every method is
/// `static` and takes everything it needs as arguments — so it's trivially
/// `Sendable` and safe to call from any actor.
///
/// Pipeline contract (mirrors the engine spec):
///   1. Decode the source to a `CGImage` via ImageIO.
///   2. **Normalize once** to premultiplied-RGBA8 in the sRGB color space by
///      redrawing into a known-format `CGContext`. After this step every
///      subsequent op operates on a canonical raster, so crop/resize math
///      never has to reason about exotic source pixel formats, bit depths, or
///      color spaces.
///   3. Apply ops front-to-back: **crop before resize** (cropping first means
///      the expensive resample only touches the kept region), then orient.
///
/// All redraws go through CoreGraphics. A `vImageScale_ARGB8888` fast path for
/// the resize step is an intentional perf follow-up — for the PoC spine the
/// CoreGraphics high-quality interpolation draw is correct and simpler to keep
/// bug-free; see the `resize` note below.
public enum Renderer {

    // MARK: - Public entry point

    /// Render the document to a final `CGImage`. Decodes the source, normalizes
    /// it, then replays `doc.ops` in order. Throws `ImageEditError` on decode /
    /// context / geometry failures rather than returning a degenerate image.
    public static func render(_ doc: ImageDocument) throws -> CGImage {
        var image = try normalized(decode(doc.source))
        for op in doc.ops {
            image = try apply(op, to: image)
        }
        return image
    }

    // MARK: - Decode

    /// Decode the source reference to a `CGImage` using ImageIO. We always
    /// take index 0 (the primary image) — multi-frame containers (animated
    /// GIF/HEIC sequences) are out of scope for the spine.
    static func decode(_ source: ImageSource) throws -> CGImage {
        let imageSource: CGImageSource
        switch source {
        case .url(let url):
            // Resolve symlinks and require a readable regular file before
            // handing the path to ImageIO, matching `BinaryFileLoader`'s
            // guard discipline (a dir/fifo would otherwise reach ImageIO).
            let resolved = url.resolvingSymlinksInPath()
            let attrs = try? FileManager.default.attributesOfItem(atPath: resolved.path)
            guard (attrs?[.type] as? FileAttributeType) == .typeRegular else {
                throw ImageEditError.sourceNotReadable
            }
            guard let src = CGImageSourceCreateWithURL(resolved as CFURL, nil) else {
                throw ImageEditError.sourceDecodeFailed
            }
            imageSource = src
        case .data(let data):
            guard !data.isEmpty,
                  let src = CGImageSourceCreateWithData(data as CFData, nil) else {
                throw ImageEditError.sourceDecodeFailed
            }
            imageSource = src
        }
        guard CGImageSourceGetCount(imageSource) > 0,
              let cg = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
            throw ImageEditError.sourceDecodeFailed
        }
        return cg
    }

    // MARK: - Normalize

    /// The canonical working color space: sRGB. Constructed once; `CGColorSpace`
    /// is reference-counted and thread-safe to share.
    private static let workingColorSpace: CGColorSpace =
        CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

    /// Premultiplied RGBA8, little-endian (`BGRA` byte order in memory). This
    /// is the format `CGContext` is happiest drawing into on Apple silicon and
    /// the one all downstream ops assume.
    private static let workingBitmapInfo: CGBitmapInfo = CGBitmapInfo(
        rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue
            | CGBitmapInfo.byteOrder32Little.rawValue
    )

    /// Redraw `image` into a fresh premultiplied-RGBA8 sRGB context of the same
    /// pixel dimensions. Idempotent in spirit — running it on an
    /// already-normalized image returns an identical raster — but always
    /// performed once so the rest of the pipeline has a single format to reason
    /// about.
    static func normalized(_ image: CGImage) throws -> CGImage {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { throw ImageEditError.degenerateGeometry }
        let ctx = try makeContext(width: width, height: height)
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let out = ctx.makeImage() else { throw ImageEditError.contextCreationFailed }
        return out
    }

    // MARK: - Op dispatch

    static func apply(_ op: EditOp, to image: CGImage) throws -> CGImage {
        switch op {
        case .crop(let rect):       return try crop(image, to: rect)
        case .resize(let w, let h): return try resize(image, width: w, height: h)
        case .orient(let o):        return try orient(image, orientation: o)
        case .colorControls(let b, let c, let s):
            return try colorControls(image, brightness: b, contrast: c, saturation: s)
        case .exposure(let ev):     return try exposure(image, ev: ev)
        }
    }

    // MARK: - Crop

    /// Crop in source pixel space. The incoming `rect` uses a **top-left**
    /// origin (image convention), which matches `CGImage.cropping(to:)`'s pixel
    /// coordinate system (CGImage is row-major from the top), so no Y-flip is
    /// needed. The rect is integralized and intersected with the image bounds;
    /// a zero-area intersection throws `degenerateGeometry`.
    static func crop(_ image: CGImage, to rect: CGRect) throws -> CGImage {
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        // `integral` rounds origin down and size up to whole pixels; intersect
        // with bounds so an out-of-range rect clamps rather than reading OOB.
        let clamped = rect.integral.intersection(bounds)
        guard !clamped.isNull, clamped.width >= 1, clamped.height >= 1 else {
            throw ImageEditError.degenerateGeometry
        }
        guard let cropped = image.cropping(to: clamped) else {
            throw ImageEditError.degenerateGeometry
        }
        // `cropping(to:)` shares the parent's backing store and inherits its
        // (already-normalized) format, so no renormalize is needed here.
        return cropped
    }

    // MARK: - Resize

    /// Resample to an exact `width` x `height` via a high-quality CoreGraphics
    /// draw into a target-sized context. Non-positive dimensions throw.
    ///
    /// NOTE (perf follow-up): for large downscales this is the obvious place to
    /// swap in `vImageScale_ARGB8888` (Lanczos), which is materially faster than
    /// CG's draw for big rasters. Kept on CoreGraphics for the spine because the
    /// format is already the premultiplied-ARGB8888 vImage wants, so the
    /// migration is a localized change with no pipeline ripple.
    static func resize(_ image: CGImage, width: Int, height: Int) throws -> CGImage {
        guard width >= 1, height >= 1 else { throw ImageEditError.degenerateGeometry }
        let ctx = try makeContext(width: width, height: height)
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let out = ctx.makeImage() else { throw ImageEditError.contextCreationFailed }
        return out
    }

    // MARK: - Orient

    /// Bake an EXIF orientation into pixels. Builds a destination context sized
    /// for the *displayed* axes (swapped for the 90°/270° cases), applies the
    /// affine transform that maps stored pixels to display pixels, and redraws.
    ///
    /// The transform is composed in the context's coordinate space (origin at
    /// bottom-left, Y up — CoreGraphics default for a bitmap context), so the
    /// flips/rotations below are expressed in that frame.
    static func orient(_ image: CGImage, orientation: EXIFOrientation) throws -> CGImage {
        guard orientation != .up else { return image }
        // `.leftMirrored` (main-diagonal transpose) is expressed as two
        // already-correct primitives — `.rightMirrored` (anti-diagonal) then
        // `.down` (180°) compose to the main-diagonal reflection. The direct
        // chained transform here previously drew off-canvas (all-black); reusing
        // verified primitives is bulletproof. Pinned by ImageOrientationTests.
        if orientation == .leftMirrored {
            return try orient(orient(image, orientation: .rightMirrored), orientation: .down)
        }
        let w = image.width
        let h = image.height
        guard w > 0, h > 0 else { throw ImageEditError.degenerateGeometry }

        // Destination dimensions: swap for the quarter-turn cases.
        let dstW = orientation.swapsAxes ? h : w
        let dstH = orientation.swapsAxes ? w : h
        let ctx = try makeContext(width: dstW, height: dstH)
        ctx.interpolationQuality = .high

        // Compose the transform mapping the source raster into the destination
        // context. We then draw the (unrotated) image into a w×h rect at the
        // origin; the transform reorients it. Math derived for the standard
        // bottom-left-origin CG bitmap context.
        var t = CGAffineTransform.identity
        switch orientation {
        case .up:
            break // handled by early return
        case .upMirrored:
            // Horizontal flip.
            t = CGAffineTransform(translationX: CGFloat(w), y: 0).scaledBy(x: -1, y: 1)
        case .down:
            // 180° rotation.
            t = CGAffineTransform(translationX: CGFloat(w), y: CGFloat(h)).rotated(by: .pi)
        case .downMirrored:
            // Vertical flip.
            t = CGAffineTransform(translationX: 0, y: CGFloat(h)).scaledBy(x: 1, y: -1)
        case .leftMirrored:
            // Transpose across the MAIN diagonal: (x, y) → (y, x). The previous
            // chained form was a mis-translated copy of `.rightMirrored`'s
            // anti-diagonal map and drew entirely off-canvas (all-black output);
            // the explicit swap matrix maps the w×h source draw rect cleanly
            // into the h×w destination. Pinned by ImageOrientationTests.
            t = CGAffineTransform(a: 0, b: 1, c: 1, d: 0, tx: 0, ty: 0)
        case .right90:
            // 90° clockwise as displayed → rotate the stored raster +90° here.
            t = CGAffineTransform(translationX: CGFloat(h), y: 0).rotated(by: .pi / 2)
        case .rightMirrored:
            // Transverse: rotate +90° then v-flip.
            t = CGAffineTransform(translationX: 0, y: 0)
                .rotated(by: .pi / 2)
                .scaledBy(x: 1, y: -1)
        case .left90:
            // 90° counter-clockwise as displayed.
            t = CGAffineTransform(translationX: 0, y: CGFloat(w)).rotated(by: -.pi / 2)
        }
        ctx.concatenate(t)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let out = ctx.makeImage() else { throw ImageEditError.contextCreationFailed }
        return out
    }

    // MARK: - Tonal adjustment (CIColorControls)

    /// Apply brightness/contrast/saturation via Core Image's `CIColorControls`,
    /// then re-normalize to the canonical working format so subsequent ops see a
    /// consistent raster. Identity is `(0, 1, 1)`. Headless — `CIContext` needs
    /// no window/GPU surface (software renderer is fine for the PoC). Geometry is
    /// preserved (render at the input extent), so this never changes dimensions.
    /// Any Core Image failure degrades to a throw rather than a force-unwrap.
    static func colorControls(
        _ image: CGImage, brightness: Double, contrast: Double, saturation: Double
    ) throws -> CGImage {
        let input = CIImage(cgImage: image)
        guard let filter = CIFilter(name: "CIColorControls", parameters: [
            kCIInputImageKey: input,
            kCIInputBrightnessKey: brightness,
            kCIInputContrastKey: contrast,
            kCIInputSaturationKey: saturation,
        ]), let output = filter.outputImage else {
            throw ImageEditError.contextCreationFailed
        }
        let ciContext = CIContext(options: [.workingColorSpace: workingColorSpace])
        guard let cg = ciContext.createCGImage(output, from: input.extent) else {
            throw ImageEditError.contextCreationFailed
        }
        return try normalized(cg)
    }

    /// Apply an exposure adjustment in photographic stops via Core Image's
    /// `CIExposureAdjust` (`inputEV`). Identity is `ev = 0`. Scales in linear
    /// light (`output = input · 2^EV`), so it brightens/darkens like a camera's
    /// exposure dial rather than `colorControls`'s additive brightness. Headless
    /// (software `CIContext`), geometry-preserving, re-normalized to the canonical
    /// raster for downstream ops. Degrades to a throw on any Core Image failure.
    static func exposure(_ image: CGImage, ev: Double) throws -> CGImage {
        let input = CIImage(cgImage: image)
        guard let filter = CIFilter(name: "CIExposureAdjust", parameters: [
            kCIInputImageKey: input,
            kCIInputEVKey: ev,
        ]), let output = filter.outputImage else {
            throw ImageEditError.contextCreationFailed
        }
        let ciContext = CIContext(options: [.workingColorSpace: workingColorSpace])
        guard let cg = ciContext.createCGImage(output, from: input.extent) else {
            throw ImageEditError.contextCreationFailed
        }
        return try normalized(cg)
    }

    // MARK: - Histogram (analysis — never mutates the image)

    /// Compute the per-channel intensity `Histogram` of `image`. Redraws into the
    /// canonical premultiplied-RGBA8 sRGB context first, so the byte layout is
    /// known and independent of the source `CGImage`'s format/bit-depth/color
    /// space; then un-premultiplies each sample (true straight color, even with
    /// transparency) and bins R/G/B plus a Rec.601 luma channel. O(width·height)
    /// with four 256-int tally arrays — fine for an interactive readout.
    ///
    /// NOTE (perf follow-up): `vImageHistogramCalculation_ARGB8888` (Accelerate)
    /// is the obvious fast path for large rasters — the working format is already
    /// the 8-bit-per-channel layout vImage wants. Kept as an explicit, verifiable
    /// loop for the PoC (and because vImage tallies premultiplied bytes without
    /// the un-premultiply this does), mirroring the `resize` vImage note.
    static func histogram(_ image: CGImage) throws -> Histogram {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { throw ImageEditError.degenerateGeometry }
        let ctx = try makeContext(width: width, height: height)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let base = ctx.data else { throw ImageEditError.contextCreationFailed }

        var red = [Int](repeating: 0, count: Histogram.binCount)
        var green = [Int](repeating: 0, count: Histogram.binCount)
        var blue = [Int](repeating: 0, count: Histogram.binCount)
        var luma = [Int](repeating: 0, count: Histogram.binCount)
        let bytesPerRow = ctx.bytesPerRow
        let ptr = base.assumingMemoryBound(to: UInt8.self)

        for y in 0..<height {
            let row = y * bytesPerRow
            for x in 0..<width {
                let i = row + x * 4
                // premultipliedFirst + byteOrder32Little ⇒ memory bytes B,G,R,A.
                let b = ptr[i], g = ptr[i + 1], r = ptr[i + 2], a = ptr[i + 3]
                let r8: Int, g8: Int, b8: Int
                switch a {
                case 0:   (r8, g8, b8) = (0, 0, 0)
                case 255: (r8, g8, b8) = (Int(r), Int(g), Int(b))
                default:
                    // Un-premultiply: straight = premultiplied · 255 / alpha,
                    // rounded (+af/2) and clamped to the 8-bit ceiling.
                    let af = Int(a)
                    r8 = min(255, (Int(r) * 255 + af / 2) / af)
                    g8 = min(255, (Int(g) * 255 + af / 2) / af)
                    b8 = min(255, (Int(b) * 255 + af / 2) / af)
                }
                red[r8] += 1
                green[g8] += 1
                blue[b8] += 1
                // Rec.601 luma, integer-rounded (+500 of the /1000 scale).
                luma[min(255, (r8 * 299 + g8 * 587 + b8 * 114 + 500) / 1000)] += 1
            }
        }
        return Histogram(red: red, green: green, blue: blue, luma: luma,
                         pixelCount: width * height)
    }

    // MARK: - Context factory

    /// Build a premultiplied-RGBA8 sRGB bitmap context of the given pixel size,
    /// letting CoreGraphics pick the row stride (passing `bytesPerRow: 0`).
    private static func makeContext(width: Int, height: Int) throws -> CGContext {
        guard let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: workingColorSpace,
            bitmapInfo: workingBitmapInfo.rawValue
        ) else {
            throw ImageEditError.contextCreationFailed
        }
        return ctx
    }
}
