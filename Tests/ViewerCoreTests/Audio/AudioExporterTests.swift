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

    func test_mp3_isRefused_ownerDepGap() {
        let src = sineBuffer(freq: 440, rate: 8000, frames: 100)
        XCTAssertThrowsError(try AudioExporter.encode(src, spec: .init(format: .mp3), to: tmp("mp3"))) {
            XCTAssertEqual($0 as? AudioExportError, .mp3RequiresExternalEncoder)
        }
    }

    func test_emptyBuffer_throws() {
        let empty = AudioPCMBuffer(sampleRate: 8000, channels: [[]])
        XCTAssertThrowsError(try AudioExporter.encode(empty, spec: .init(format: .wav), to: tmp("wav"))) {
            XCTAssertEqual($0 as? AudioExportError, .emptyBuffer)
        }
    }

    func test_format_fileExtensions() {
        XCTAssertEqual(AudioExportSpec.Format.aac.fileExtension, "m4a")
        XCTAssertEqual(AudioExportSpec.Format.wav.fileExtension, "wav")
        XCTAssertTrue(AudioExportSpec.Format.caf.isPCM)
        XCTAssertFalse(AudioExportSpec.Format.aac.isPCM)
    }
}
