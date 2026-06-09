import XCTest
import AVFoundation
@testable import ViewerCore

/// End-to-end teeth for `AudioDecoder` (TSK-525): write a known float-PCM file
/// with `AVAudioFile` (system framework, headless-safe — no audio session /
/// hardware), decode it back through our path, and assert the buffer matches.
/// Scratch files live in the per-user temp dir per the never-write-to-Documents
/// rule.
final class AudioDecoderTests: XCTestCase {

    private var scratch: [URL] = []

    override func tearDownWithError() throws {
        for url in scratch { try? FileManager.default.removeItem(at: url) }
        scratch.removeAll()
    }

    /// Write `channels` (deinterleaved float) to a lossless CAF and return its URL.
    private func writeFloatPCM(_ channels: [[Float]], sampleRate: Double) throws -> URL {
        let chCount = AVAudioChannelCount(channels.count)
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: chCount)!
        let n = channels.first?.count ?? 0
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n))!
        buffer.frameLength = AVAudioFrameCount(n)
        let dst = buffer.floatChannelData!
        for c in channels.indices {
            for i in 0..<n { dst[c][i] = channels[c][i] }
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mdv-audiodec-\(UUID().uuidString).caf")
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
        scratch.append(url)
        return url
    }

    func test_decode_stereoRoundTrips() throws {
        let left:  [Float] = [0, 0.25, -0.25, 1, -1]
        let right: [Float] = [0.5, -0.5, 0.1, -0.1, 0]
        let url = try writeFloatPCM([left, right], sampleRate: 8000)

        let buf = try AudioDecoder.decode(contentsOf: url)
        XCTAssertEqual(buf.sampleRate, 8000, accuracy: 1e-6)
        XCTAssertEqual(buf.channelCount, 2)
        XCTAssertEqual(buf.frameCount, 5)
        XCTAssertEqual(buf.duration, 5.0 / 8000.0, accuracy: 1e-9)

        for (got, want) in zip(buf.channels[0], left) {
            XCTAssertEqual(got, want, accuracy: 1e-5)
        }
        for (got, want) in zip(buf.channels[1], right) {
            XCTAssertEqual(got, want, accuracy: 1e-5)
        }
    }

    func test_decode_monoRoundTrips_andFeedsReducer() throws {
        let mono = (0..<128).map { sin(Float($0) * 0.1) }   // a known sine
        let url = try writeFloatPCM([mono], sampleRate: 44100)

        let buf = try AudioDecoder.decode(contentsOf: url)
        XCTAssertEqual(buf.channelCount, 1)
        XCTAssertEqual(buf.frameCount, 128)

        // The decoded buffer feeds the reducer end-to-end.
        let peaks = WaveformReducer.reduce(buf.monoSamples(), width: 16)
        XCTAssertEqual(peaks.count, 16)
        // a non-silent sine must produce at least one column with spread
        XCTAssertTrue(peaks.contains { $0.max > $0.min })
    }

    func test_decode_nonAudioFile_throwsUnreadable() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mdv-audiodec-\(UUID().uuidString).txt")
        try "not audio".data(using: .utf8)!.write(to: url)
        scratch.append(url)

        XCTAssertThrowsError(try AudioDecoder.decode(contentsOf: url)) { error in
            XCTAssertEqual(error as? AudioDecodeError, .unreadable)
        }
    }
}
