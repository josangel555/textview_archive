import XCTest
@testable import ViewerCore

/// Teeth for the pure PCM container (TSK-525): frame/channel/duration accessors,
/// the mono downmix, and the ragged-channel truncation invariant.
final class AudioPCMBufferTests: XCTestCase {

    func test_accessors() {
        let buf = AudioPCMBuffer(sampleRate: 4, channels: [[0, 1, 2, 3, 4, 5, 6, 7]])
        XCTAssertEqual(buf.frameCount, 8)
        XCTAssertEqual(buf.channelCount, 1)
        XCTAssertEqual(buf.sampleRate, 4)
        XCTAssertEqual(buf.duration, 2.0, accuracy: 1e-9)   // 8 frames / 4 Hz
    }

    func test_emptyBuffer() {
        let buf = AudioPCMBuffer(sampleRate: 0, channels: [])
        XCTAssertEqual(buf.frameCount, 0)
        XCTAssertEqual(buf.channelCount, 0)
        XCTAssertEqual(buf.duration, 0)
        XCTAssertTrue(buf.monoSamples().isEmpty)
    }

    func test_monoSamples_passThroughForMono() {
        let buf = AudioPCMBuffer(sampleRate: 8, channels: [[5, 5, 5]])
        XCTAssertEqual(buf.monoSamples(), [5, 5, 5])
    }

    func test_monoSamples_averagesChannels() {
        let buf = AudioPCMBuffer(sampleRate: 8, channels: [[1, 3, -2], [3, 1, 4]])
        XCTAssertEqual(buf.monoSamples(), [2, 2, 1])   // per-frame average
    }

    func test_raggedChannels_truncatedToShortest() {
        let buf = AudioPCMBuffer(sampleRate: 8, channels: [[1, 2, 3], [4, 5]])
        XCTAssertEqual(buf.frameCount, 2)
        XCTAssertEqual(buf.channels, [[1, 2], [4, 5]])
    }
}
