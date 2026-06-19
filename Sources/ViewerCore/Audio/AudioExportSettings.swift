import Foundation

/// The user's Save-As choices for the audio editor's "Save a Copy…" sheet,
/// decoupled from the on-screen controls so the format/quality → `AudioExportSpec`
/// mapping is host-testable (TSK-535). The view owns one of these as the
/// `NSSavePanel` accessory's state; `spec()` is what feeds `AudioExporter`.
///
/// Why a separate model from `AudioExportSpec`: the spec carries only the three
/// fields the encoder consumes (format, PCM sample format, lossy bit rate). This
/// model adds the *presentation* layer — the curated bit-rate / bit-depth menus
/// and the "which knob applies to which format" rules — that the sheet needs but
/// the encoder must not know about. Keeping them apart means the menu lists and
/// the file-extension ↔ format inference live in one host-tested place instead
/// of being scattered through the SwiftUI view.
public struct AudioExportSettings: Equatable, Sendable {

    /// The container/codec to write. Mirrors `AudioExportSpec.Format` so the
    /// picker can iterate `Format.allCases` directly.
    public var format: AudioExportSpec.Format

    /// PCM bit depth / sample type — only meaningful for the lossless containers
    /// (`format.isPCM`); ignored otherwise. Curated subset of
    /// `AudioExportSpec.SampleFormat`.
    public var sampleFormat: AudioExportSpec.SampleFormat

    /// Target bit rate (bits/sec) for the lossy codecs (AAC / MP3); ignored for
    /// PCM. Constrained to `lossyBitRates` by the UI.
    public var bitRate: Int

    public init(
        format: AudioExportSpec.Format = .wav,
        sampleFormat: AudioExportSpec.SampleFormat = .int16,
        bitRate: Int = 128_000
    ) {
        self.format = format
        self.sampleFormat = sampleFormat
        self.bitRate = bitRate
    }

    // MARK: - Curated menus

    /// Bit-rate choices offered for lossy formats, in bits/sec. Kept to the
    /// common, broadly-supported AAC/MP3 ladder so the menu stays short.
    public static let lossyBitRates: [Int] = [
        96_000, 128_000, 160_000, 192_000, 256_000, 320_000,
    ]

    /// PCM bit-depth choices offered for lossless formats. `float32` is the
    /// lossless-round-trip option; the integer depths trade size for precision.
    public static let pcmSampleFormats: [AudioExportSpec.SampleFormat] = [
        .int16, .int24, .int32, .float32,
    ]

    /// True when the bit-rate control should be enabled for `format` (lossy
    /// codecs only). The sheet greys the bit-rate menu out otherwise.
    public var bitRateApplies: Bool { !format.isPCM }

    /// True when the bit-depth control applies (PCM containers only).
    public var sampleFormatApplies: Bool { format.isPCM }

    // MARK: - Mapping

    /// The encoder spec these settings resolve to. Fields irrelevant to the
    /// chosen format are still carried (the encoder ignores them), but are
    /// normalized to a sane default so an out-of-list value can't leak through:
    /// a non-curated bit rate snaps to the nearest curated rung.
    public func spec() -> AudioExportSpec {
        AudioExportSpec(
            format: format,
            sampleFormat: sampleFormatApplies ? sampleFormat : .int16,
            bitRate: bitRateApplies ? Self.snapBitRate(bitRate) : 128_000)
    }

    /// Snap an arbitrary bit rate to the nearest value in `lossyBitRates`.
    /// Defensive: the UI binds to the curated list, but a programmatic/migrated
    /// value shouldn't reach the encoder unconstrained.
    public static func snapBitRate(_ raw: Int) -> Int {
        lossyBitRates.min(by: { abs($0 - raw) < abs($1 - raw) }) ?? 128_000
    }

    // MARK: - File-extension inference

    /// Map a destination file extension (the one the user typed/kept in the save
    /// panel) to the matching export format, defaulting to WAV for anything
    /// unrecognized. Centralizes the inference that previously lived inline in
    /// the view so it's covered by one host test.
    public static func format(forExtension ext: String) -> AudioExportSpec.Format {
        switch ext.lowercased() {
        case "aiff", "aif": return .aiff
        case "caf": return .caf
        case "m4a", "aac": return .aac
        case "mp3": return .mp3
        default: return .wav
        }
    }

    /// A suggested default filename for `sourceName` under this settings' format,
    /// e.g. `song` + `.aac` → `song-edited.m4a`. Keeps the "-edited" suffix the
    /// sheet uses and the format-correct extension in one place.
    public func suggestedFileName(forSource sourceName: String) -> String {
        "\(sourceName)-edited.\(format.fileExtension)"
    }
}
