import XCTest
import AVFoundation
@testable import ViewerCore

/// Teeth for the save-as encoders (TSK-528): lossless WAV round-trips through
/// our own decoder (samples + honored bit depth), AAC produces a non-empty
/// decodable MPEG-4 file, MP3 is refused (owner-dep gap), and empty input
/// throws. Scratch files go to the per-user temp dir.
final class AudioExporterTests: XCTestCase {

    private var scratch: [URL] = []
    override func tearDownWithError() throws {
        for u in scratch { try? FileManager.default.removeItem(at: u) }
        scratch.removeAll()
    }
    private func tmp(_ ext: String) -> URL {
        let u = FileManager.default.temporaryDirectory
            .appendingPathComponent("mdv-audioenc-\(UUID().uuidString).\(ext)")
        scratch.append(u)
        return u
    }
    private func sineBuffer(freq: Double, rate: Double, frames: Int, amp: Float = 0.5) -> AudioPCMBuffer {
        let s = (0..<frames).map { amp * sinf(Float(2 * Double.pi * freq * Double($0) / rate)) }
        return AudioPCMBuffer(sampleRate: rate, channels: [s])
    }

    func test_wav_int16_roundTrips_andHonorsBitDepth() throws {
        let src = AudioPCMBuffer(sampleRate: 8000, channels: [[0, 0.25, -0.25, 0.5, -0.5]])
        let url = tmp("wav")
        try AudioExporter.encode(src, spec: .init(format: .wav, sampleFormat: .int16), to: url)

        // bit depth honored on disk
        let onDisk = try AVAudioFile(forReading: url)
        XCTAssertEqual(onDisk.fileFormat.streamDescription.pointee.mBitsPerChannel, 16)
        XCTAssertEqual(onDisk.fileFormat.sampleRate, 8000, accuracy: 1e-6)

        // round-trip through our decoder (int16 quantization tolerance)
        let back = try AudioDecoder.decode(contentsOf: url)
        XCTAssertEqual(back.frameCount, 5)
        for (g, w) in zip(back.channels[0], src.channels[0]) {
            XCTAssertEqual(g, w, accuracy: 2e-4)
        }
    }

    func test_wav_float32_roundTrips_exactly() throws {
        let src = AudioPCMBuffer(sampleRate: 44100, channels: [[0.123456, -0.654321, 0.999, -0.999]])
        let url = tmp("wav")
        try AudioExporter.encode(src, spec: .init(format: .wav, sampleFormat: .float32), to: url)
        let back = try AudioDecoder.decode(contentsOf: url)
        for (g, w) in zip(back.channels[0], src.channels[0]) {
            XCTAssertEqual(g, w, accuracy: 1e-6)   // lossless float
        }
    }

    func test_aac_producesNonEmptyDecodableMpeg4File() throws {
        let src = sineBuffer(freq: 440, rate: 44100, frames: 44100)   // ~1s, clearly non-silent
        let url = tmp("m4a")
        try AudioExporter.encode(src, spec: .init(format: .aac, bitRate: 128_000), to: url)

        let size = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        XCTAssertGreaterThan(size, 0)

        let onDisk = try AVAudioFile(forReading: url)
        XCTAssertEqual(onDisk.fileFormat.streamDescription.pointee.mFormatID, kAudioFormatMPEG4AAC)

        let back = try AudioDecoder.decode(contentsOf: url)
        // AAC priming/padding shifts length slightly; just bound it + assert audio survived.
        XCTAssertGreaterThan(back.frameCount, 40000)
        XCTAssertLessThan(back.frameCount, 44100 + 6000)
        let peak = back.channels[0].map(abs).max() ?? 0
        XCTAssertGreaterThan(peak, 0.05, "decoded AAC must not be silent")
    }

    func test_mp3_disabledWhenFFmpegMissing() {
        // The not-found path is forced deterministically (ffmpeg: nil) regardless
        // of whether the host actually has ffmpeg.
        let src = sineBuffer(freq: 440, rate: 8000, frames: 100)
        XCTAssertThrowsError(
            try AudioExporter.encodeMP3(src, spec: .init(format: .mp3), to: tmp("mp3"), ffmpeg: nil)
        ) {
            XCTAssertEqual($0 as? AudioExportError, .mp3FFmpegNotFound)
        }
    }

    func test_mp3_encodesViaFFmpegWhenAvailable() throws {
        // Best-effort: only runs where a host ffmpeg (with libmp3lame) exists;
        // skips elsewhere (e.g. CI without ffmpeg) — the feature is host-tool-gated.
        guard FFmpegLocator.resolve() != nil else {
            throw XCTSkip("no ffmpeg on host — MP3 export feature disabled here")
        }
        let src = sineBuffer(freq: 440, rate: 44100, frames: 44100)   // ~1s, non-silent
        let url = tmp("mp3")
        try AudioExporter.encode(src, spec: .init(format: .mp3, bitRate: 128_000), to: url)

        let bytes = try Data(contentsOf: url)
        XCTAssertGreaterThan(bytes.count, 0)
        // MP3 starts with an ID3 tag ("ID3") or an MPEG frame sync (0xFF 0xEx/0xFx).
        let head = [UInt8](bytes.prefix(3))
        let isID3 = head == Array("ID3".utf8)
        let isFrameSync = head.count >= 2 && head[0] == 0xFF && (head[1] & 0xE0) == 0xE0
        XCTAssertTrue(isID3 || isFrameSync, "output is not an MP3 stream (head=\(head))")

        // And it decodes back to roughly the same duration, non-silent.
        let back = try AudioDecoder.decode(contentsOf: url)
        XCTAssertGreaterThan(back.frameCount, 40000)
        XCTAssertGreaterThan(back.channels[0].map(abs).max() ?? 0, 0.05)
    }

    func test_emptyBuffer_throws() {
        let empty = AudioPCMBuffer(sampleRate: 8000, channels: [[]])
        XCTAssertThrowsError(try AudioExporter.encode(empty, spec: .init(format: .wav), to: tmp("wav"))) {
            XCTAssertEqual($0 as? AudioExportError, .emptyBuffer)
        }
    }

    // MARK: - ffmpeg argv sentinel (argument-injection hardening)

    func test_mp3Args_outputPathIsPrecededByEndOfOptionsSentinel() {
        let args = AudioExporter.mp3Args(input: "/tmp/in.wav", output: "/tmp/out.mp3", bitRate: 128_000)
        guard let outIdx = args.firstIndex(of: "/tmp/out.mp3") else {
            return XCTFail("output path not in argv: \(args)")
        }
        XCTAssertGreaterThan(outIdx, 0)
        XCTAssertEqual(args[outIdx - 1], "--", "output path must be preceded by a -- sentinel")
    }

    func test_mp3Args_dashLeadingOutputPath_isFencedAsPositional() {
        // An output name beginning with '-' must NOT be the last token without a
        // preceding '--', or ffmpeg parses it as a flag (argument injection).
        let args = AudioExporter.mp3Args(input: "/tmp/in.wav", output: "-evil.mp3", bitRate: 128_000)
        guard let outIdx = args.firstIndex(of: "-evil.mp3") else {
            return XCTFail("output path not in argv: \(args)")
        }
        XCTAssertEqual(args[outIdx - 1], "--")
        XCTAssertEqual(outIdx, args.count - 1, "the -- sentinel + output must be the trailing tokens")
    }

    func test_mp3Args_bitRateFloor() {
        let args = AudioExporter.mp3Args(input: "/i", output: "/o", bitRate: 1)
        XCTAssertTrue(args.contains("8k"), "bit rate floored to 8 kbps")
    }

    func test_format_fileExtensions() {
        XCTAssertEqual(AudioExportSpec.Format.aac.fileExtension, "m4a")
        XCTAssertEqual(AudioExportSpec.Format.wav.fileExtension, "wav")
        XCTAssertTrue(AudioExportSpec.Format.caf.isPCM)
        XCTAssertFalse(AudioExportSpec.Format.aac.isPCM)
    }
}
