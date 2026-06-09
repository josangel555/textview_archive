import Foundation
import AVFoundation

/// "Save audio as…" settings — the audio analogue of the image `ExportSpec`.
/// Geometry/sample concerns (which frames) live on `AudioEditOp`; this carries
/// only the *encoding* choice so re-encoding from `source + ops` stays
/// deterministic. TSK-528.
public struct AudioExportSpec: Equatable, Sendable {

    public enum Format: String, Equatable, Sendable, CaseIterable {
        case wav, aiff, caf   // lossless linear PCM
        case aac              // lossy, native (AVFoundation)
        case mp3              // lossy — NOT encodable by AVFoundation on macOS

        public var fileExtension: String {
            switch self {
            case .wav: return "wav"
            case .aiff: return "aiff"
            case .caf: return "caf"
            case .aac: return "m4a"   // AAC lives in an MPEG-4 (.m4a) container
            case .mp3: return "mp3"
            }
        }
        /// True for the linear-PCM containers (bit depth applies).
        public var isPCM: Bool { self == .wav || self == .aiff || self == .caf }
    }

    /// PCM sample format (ignored for lossy formats).
    public enum SampleFormat: String, Equatable, Sendable, CaseIterable {
        case int16, int24, int32, float32
        public var bits: Int {
            switch self {
            case .int16: return 16
            case .int24: return 24
            case .int32, .float32: return 32
            }
        }
        public var isFloat: Bool { self == .float32 }
    }

    public let format: Format
    /// PCM bit depth / sample type. Ignored for `.aac` / `.mp3`.
    public let sampleFormat: SampleFormat
    /// Target bit rate in bits/sec for lossy formats (e.g. 128_000). Ignored for PCM.
    public let bitRate: Int

    public init(format: Format, sampleFormat: SampleFormat = .int16, bitRate: Int = 128_000) {
        self.format = format
        self.sampleFormat = sampleFormat
        self.bitRate = bitRate
    }
}

public enum AudioExportError: Error, Equatable {
    case emptyBuffer
    /// AVFoundation can DECODE but not ENCODE MP3 on macOS — encoding needs an
    /// external encoder (e.g. LAME), a new dependency that is an owner decision.
    case mp3RequiresExternalEncoder
    case writeFailed
}

/// Encode an `AudioPCMBuffer` to a file. Lossless PCM (WAV/AIFF/CAF) and AAC are
/// handled natively by `AVAudioFile` (a system framework — it writes the target
/// settings, converting from our float buffer; no `AVAssetWriter` needed and no
/// new dependency). This is pure file I/O — headless-test-safe.
///
/// Sample-rate CONVERSION on export (resampling via `AVAudioConverter`) is a
/// follow-up; this slice encodes at the buffer's own sample rate while honoring
/// the requested container / bit depth / bit rate.
public enum AudioExporter {

    public static func encode(_ buffer: AudioPCMBuffer, spec: AudioExportSpec, to url: URL) throws {
        guard buffer.frameCount > 0, buffer.channelCount > 0 else { throw AudioExportError.emptyBuffer }
        if spec.format == .mp3 { throw AudioExportError.mp3RequiresExternalEncoder }

        let rate = buffer.sampleRate
        let channelCount = buffer.channelCount

        // Build a standard float source buffer at the buffer's own rate; the
        // file write converts it to the target settings.
        guard let srcFormat = AVAudioFormat(
                standardFormatWithSampleRate: rate, channels: AVAudioChannelCount(channelCount)),
              let pcm = AVAudioPCMBuffer(
                pcmFormat: srcFormat, frameCapacity: AVAudioFrameCount(buffer.frameCount)) else {
            throw AudioExportError.writeFailed
        }
        pcm.frameLength = AVAudioFrameCount(buffer.frameCount)
        guard let dst = pcm.floatChannelData else { throw AudioExportError.writeFailed }
        for c in 0..<channelCount {
            buffer.channels[c].withUnsafeBufferPointer { src in
                dst[c].update(from: src.baseAddress!, count: buffer.frameCount)
            }
        }

        var settings: [String: Any] = [
            AVSampleRateKey: rate,
            AVNumberOfChannelsKey: channelCount,
        ]
        switch spec.format {
        case .wav, .aiff, .caf:
            settings[AVFormatIDKey] = kAudioFormatLinearPCM
            settings[AVLinearPCMBitDepthKey] = spec.sampleFormat.bits
            settings[AVLinearPCMIsFloatKey] = spec.sampleFormat.isFloat
            settings[AVLinearPCMIsBigEndianKey] = (spec.format == .aiff)
            settings[AVLinearPCMIsNonInterleaved] = false
        case .aac:
            settings[AVFormatIDKey] = kAudioFormatMPEG4AAC
            settings[AVEncoderBitRateKey] = spec.bitRate
        case .mp3:
            throw AudioExportError.mp3RequiresExternalEncoder   // handled above; defensive
        }

        do {
            let file = try AVAudioFile(forWriting: url, settings: settings)
            try file.write(from: pcm)
        } catch {
            throw AudioExportError.writeFailed
        }
    }
}
