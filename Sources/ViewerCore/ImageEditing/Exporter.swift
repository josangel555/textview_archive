import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Headless encoder: serializes a rendered `CGImage` to container bytes via a
/// single ImageIO `CGImageDestination` path keyed on the `ExportSpec.Format`
/// UTI. Stateless and `Sendable`.
///
/// One code path for all three formats — the only per-format variation is the
/// destination UTI and whether the lossy `kCGImageDestinationLossyCompressionQuality`
/// key is set. PNG ignores quality (it's lossless); JPEG/HEIC honor it.
public enum Exporter {

    /// Encode `image` to `Data` per `spec`. Throws `ImageEditError.encodeFailed`
    /// if the destination can't be created for the format UTI or finalization
    /// fails (e.g. HEIC encode unavailable on the running OS/codec).
    public static func encode(_ image: CGImage, _ spec: ExportSpec) throws -> Data {
        let buffer = NSMutableData()
        let uti = spec.format.utType.identifier as CFString
        guard let dest = CGImageDestinationCreateWithData(buffer as CFMutableData, uti, 1, nil) else {
            throw ImageEditError.encodeFailed
        }

        var properties: [CFString: Any] = [:]
        if spec.format.isLossy {
            // ImageIO clamps internally too, but `ExportSpec.init` already
            // clamped `quality` to 0...1.
            properties[kCGImageDestinationLossyCompressionQuality] = spec.quality
        }
        if spec.stripMetadata {
            // Best-effort metadata stripping. `…MetadataAndOpacity` removes any
            // metadata not explicitly re-added; we add none, so the output
            // carries only the bytes ImageIO must keep. Belt-and-suspenders:
            // also disable thumbnail embedding so a source thumbnail (which can
            // itself carry EXIF) isn't copied through.
            properties[kCGImageMetadataShouldExcludeGPS] = true
            properties[kCGImageDestinationMergeMetadata] = false
        }

        CGImageDestinationAddImage(dest, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            throw ImageEditError.encodeFailed
        }
        return buffer as Data
    }

    /// Convenience: render `doc` then encode in one call. The common
    /// "open → edit → export" sequence.
    public static func export(_ doc: ImageDocument, _ spec: ExportSpec) throws -> Data {
        let image = try Renderer.render(doc)
        return try encode(image, spec)
    }

    /// Convert an existing image FILE to `spec`'s format/quality (TSK-1325 — image
    /// format/quality change). Decodes the first frame via ImageIO, then re-encodes
    /// through `encode`. A pure file→bytes transform (no editing ops) — host-testable;
    /// the convert UI (pick target format + quality) is the ViewerUI tail. Throws
    /// `sourceNotReadable` (missing/unreadable path), `sourceDecodeFailed` (not an
    /// image ImageIO can decode), or `encodeFailed` (unsupported write UTI).
    public static func convert(contentsOf url: URL, to spec: ExportSpec) throws -> Data {
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            throw ImageEditError.sourceNotReadable
        }
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            throw ImageEditError.sourceDecodeFailed
        }
        return try encode(image, spec)
    }
}
