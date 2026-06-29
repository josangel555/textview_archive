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
    /// MP3 export is requested but no `ffmpeg` executable was found on the host
    /// (and none was supplied in Settings) — the feature is disabled. WAV/AAC
    /// are unaffected. (AVFoundation can decode but not encode MP3 on macOS;
    /// per the owner decision MP3 is encoded via an external host `ffmpeg`,
    /// best-effort located, never bundled or vendored.)
    case mp3FFmpegNotFound
    /// `ffmpeg` was found and run but exited non-zero (carries the exit code) —
    /// e.g. the build lacks `libmp3lame`, or the args were rejected.
    case ffmpegFailed(Int32)
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

    public static func encode(
        _ buffer: AudioPCMBuffer,
        spec: AudioExportSpec,
        to url: URL,
        ffmpegOverride: String? = nil
    ) throws {
        guard buffer.frameCount > 0, buffer.channelCount > 0 else { throw AudioExportError.emptyBuffer }
        if spec.format == .mp3 {
            try encodeMP3(buffer, spec: spec, to: url,
                          ffmpeg: FFmpegLocator.resolve(override: ffmpegOverride))
            return
        }

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
            throw AudioExportError.mp3FFmpegNotFound   // handled above; defensive
        }

        do {
            let file = try AVAudioFile(forWriting: url, settings: settings)
            try file.write(from: pcm)
        } catch {
            throw AudioExportError.writeFailed
        }
    }

    // MARK: - MP3 (external host ffmpeg)

    /// Encode `buffer` to MP3 at `url` via the resolved host `ffmpeg`. We first
    /// write a lossless intermediate WAV with our own PCM encoder, then transcode
    /// it with `ffmpeg -codec:a libmp3lame`. `ffmpeg == nil` ⇒ feature disabled.
    /// Internal (not private) so the not-found path is host-testable deterministically.
    static func encodeMP3(
        _ buffer: AudioPCMBuffer,
        spec: AudioExportSpec,
        to url: URL,
        ffmpeg: URL?
    ) throws {
        guard let ffmpeg else { throw AudioExportError.mp3FFmpegNotFound }

        let tempWav = FileManager.default.temporaryDirectory
            .appendingPathComponent("mdv-mp3src-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: tempWav) }
        try encode(buffer, spec: AudioExportSpec(format: .wav, sampleFormat: .int16), to: tempWav)

        try runFFmpeg(ffmpeg, mp3Args(input: tempWav.path, output: url.path, bitRate: spec.bitRate))
    }

    /// Build the `ffmpeg` argv for an MP3 transcode. The output path is placed
    /// AFTER a `--` end-of-options sentinel so an output path beginning with `-`
    /// (e.g. an NSSavePanel name like `-foo.mp3`) parses as a positional file,
    /// not an ffmpeg flag (argument-injection nuisance). The input path is
    /// already fenced behind `-i` and is our own UUID temp name, but we keep it
    /// before the sentinel since ffmpeg's `--` applies to the trailing output.
    /// Internal so the sentinel placement is host-testable without spawning.
    static func mp3Args(input: String, output: String, bitRate: Int) -> [String] {
        let kbps = max(8, bitRate / 1000)
        return [
            "-y", "-hide_banner", "-loglevel", "error",
            "-i", input,
            "-codec:a", "libmp3lame", "-b:a", "\(kbps)k",
            "-f", "mp3", "--", output,
        ]
    }

    /// Run `ffmpeg` with an explicit args array (NO shell — paths can't inject)
    /// and a minimal environment, via the shared `ProcessRunner` (timeout +
    /// SIGTERM→SIGKILL escalation + concurrent drain) — actually mirroring
    /// `GitClient.run`, which routes through `ProcessRunner.run(timeout:)`. The
    /// `timeout` guards against a wedged ffmpeg blocking the calling/export thread
    /// forever (the prior raw `waitUntilExit()` had no bail). Default 600s is
    /// generous: an audio re-encode of even a multi-hour file is minutes, so this
    /// never cuts a legit export but still bails a true hang. Throws on spawn
    /// failure, timeout, or a non-zero exit.
    /// `internal` (was private) so AudioExporterFFmpegTests can drive the timeout
    /// path with a stand-in binary (no real ffmpeg needed).
    @discardableResult
    static func runFFmpeg(_ exe: URL, _ args: [String], timeout: TimeInterval = 600) throws -> Int32 {
        let p = Process()
        p.executableURL = exe
        p.arguments = args
        p.standardInput = FileHandle.nullDevice
        // stdout/stderr are drained (and discarded) by ProcessRunner; ffmpeg's
        // progress goes to stderr, which we don't need.
        // Pass only a tiny env allowlist (don't leak the app's *_TOKEN/_SECRET).
        let src = ProcessInfo.processInfo.environment
        var env: [String: String] = [:]
        for key in ["PATH", "HOME", "TMPDIR", "LANG"] where src[key] != nil { env[key] = src[key] }
        p.environment = env

        let result: ProcessRunner.Result
        do {
            result = try ProcessRunner.run(p, timeout: timeout, maxOutputBytes: 16 * 1024 * 1024)
        } catch {
            throw AudioExportError.writeFailed
        }
        // A wedged ffmpeg that hit the wall-clock timeout (SIGTERM→SIGKILL'd) is
        // surfaced as a failure (sentinel -1) rather than a silent partial file.
        guard !result.timedOut else { throw AudioExportError.ffmpegFailed(-1) }
        guard result.terminationStatus == 0 else {
            throw AudioExportError.ffmpegFailed(result.terminationStatus)
        }
        return result.terminationStatus
    }
}
