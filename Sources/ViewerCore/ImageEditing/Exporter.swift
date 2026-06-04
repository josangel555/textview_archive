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
}
