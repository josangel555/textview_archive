import Foundation
import UniformTypeIdentifiers
import ViewerCore

/// TSK-1325 — view-model for image format/quality conversion. Holds the target format + quality
/// over a source image file; `convert()` runs the host-tested `Exporter.convert` OFF the main
/// thread and writes the result to a temp file (the caller opens it in a new tab). Pure controller
/// logic so it's host-testable; the SwiftUI panel + menu trigger are the render tail (the console
/// template — slice 2).
@MainActor
public final class ConvertImageViewModel: ObservableObject {
    public let sourceURL: URL
    @Published public var format: ExportSpec.Format
    @Published public var quality: Double = 0.9
    @Published public private(set) var lastError: String?
    @Published public private(set) var isConverting = false

    public init(sourceURL: URL, initialFormat: ExportSpec.Format = .png) {
        self.sourceURL = sourceURL
        self.format = initialFormat
    }

    /// The closed set of encodable target formats the picker offers.
    public var availableFormats: [ExportSpec.Format] { ExportSpec.Format.allCases }

    /// Whether the quality knob applies to the current target (lossy only).
    public var isQualityMeaningful: Bool { format.isLossy }

    /// Convert the source to the selected format/quality, writing to a temp file off-main.
    /// Returns the output URL, or nil on failure (`lastError` set). The CPU-bound decode+encode
    /// runs on a detached task so a large image never blocks the main thread.
    public func convert() async -> URL? {
        lastError = nil
        isConverting = true
        defer { isConverting = false }
        let spec = ExportSpec(format: format, quality: quality)
        let src = sourceURL
        let ext = format.utType.preferredFilenameExtension ?? "img"
        let baseName = sourceURL.deletingPathExtension().lastPathComponent
        do {
            return try await Task.detached {
                let data = try Exporter.convert(contentsOf: src, to: spec)
                let out = FileManager.default.temporaryDirectory
                    .appendingPathComponent("\(baseName)-converted-\(UUID().uuidString).\(ext)")
                try data.write(to: out)
                return out
            }.value
        } catch let e as ImageEditError {
            lastError = Self.describe(e)
            return nil
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    private static func describe(_ e: ImageEditError) -> String {
        switch e {
        case .sourceNotReadable:  return "The image file could not be read."
        case .sourceDecodeFailed: return "That file isn't an image this app can decode."
        case .encodeFailed:       return "Couldn't encode to the chosen format."
        default:                  return "Conversion failed."
        }
    }
}
