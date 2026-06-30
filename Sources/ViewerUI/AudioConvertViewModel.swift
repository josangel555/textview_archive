import Foundation
import ViewerCore

/// TSK-1323 / TSK-1324 — view-model for audio extract/convert. One controller serves both:
/// `dropVideo == true` extracts the audio track from a video file (TSK-1323); `false` converts an
/// audio file's format/quality (TSK-1324). Holds the target format + bit rate over a source URL;
/// `convert()` runs the host-tested `AudioExporter.transcodeFile` (ffmpeg) OFF the main thread and
/// returns the output URL. ffmpeg is a best-effort host tool — when it's absent, convert() surfaces
/// a graceful error rather than crashing. The SwiftUI panel + menu trigger are the render tail.
@MainActor
public final class AudioConvertViewModel: ObservableObject {
    public let sourceURL: URL
    /// true = extract-audio-from-video (strip the video stream); false = audio format/quality convert.
    public let dropVideo: Bool
    @Published public var format: AudioExportSpec.Format
    @Published public var bitRate: Int = 128_000
    @Published public private(set) var lastError: String?
    @Published public private(set) var isConverting = false
    private let ffmpegOverride: String?

    public init(sourceURL: URL, dropVideo: Bool,
                initialFormat: AudioExportSpec.Format = .aac, ffmpegOverride: String? = nil) {
        self.sourceURL = sourceURL
        self.dropVideo = dropVideo
        self.format = initialFormat
        self.ffmpegOverride = ffmpegOverride
    }

    /// The closed set of target formats (wav/aiff/caf/aac/mp3).
    public var availableFormats: [AudioExportSpec.Format] { AudioExportSpec.Format.allCases }

    /// Whether the bit-rate knob applies (lossy formats only — PCM uses bit depth instead).
    public var isBitRateMeaningful: Bool { !format.isPCM }

    /// Extract/convert off-main; returns the output URL, or nil on failure (`lastError` set).
    public func convert() async -> URL? {
        lastError = nil
        isConverting = true
        defer { isConverting = false }
        let spec = AudioExportSpec(format: format, bitRate: bitRate)
        let src = sourceURL
        let drop = dropVideo
        let override = ffmpegOverride
        let kind = drop ? "audio" : "converted"
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "\(sourceURL.deletingPathExtension().lastPathComponent)-\(kind)-\(UUID().uuidString).\(format.fileExtension)")
        do {
            try await Task.detached {
                try AudioExporter.transcodeFile(input: src, output: out, spec: spec,
                                                dropVideo: drop, ffmpegOverride: override)
            }.value
            return out
        } catch {
            lastError = Self.describe(error)
            return nil
        }
    }

    private static func describe(_ error: Error) -> String {
        if let e = error as? AudioExportError, case .mp3FFmpegNotFound = e {
            return "ffmpeg isn't available — install it (e.g. `brew install ffmpeg`) to convert audio."
        }
        return "Audio conversion failed: \(error.localizedDescription)"
    }
}
