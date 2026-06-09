import XCTest
@testable import ViewerCore

/// Teeth for the pure waveform downsampler (TSK-525). Load-bearing contracts:
/// exactly `width` columns, silence→(0,0), full-scale→(±1), correct min/max per
/// span, zoom-window clamping, and zoom-in (≥1 frame/column) behaviour.
final class WaveformReducerTests: XCTestCase {

    func test_widthZeroOrNegative_returnsEmpty() {
        XCTAssertTrue(WaveformReducer.reduce([0, 1, 2], width: 0).isEmpty)
        XCTAssertTrue(WaveformReducer.reduce([0, 1, 2], width: -3).isEmpty)
    }

    func test_silence_allZeroColumns() {
        let peaks = WaveformReducer.reduce([Float](repeating: 0, count: 1000), width: 64)
        XCTAssertEqual(peaks.count, 64)
        XCTAssertTrue(peaks.allSatisfy { $0 == .zero })
    }

    func test_fullScaleAlternating_eachColumnSpansMinusOneToOne() {
        // 1000 samples alternating -1/+1 → every column (≥2 samples wide) sees both.
        let samples = (0..<1000).map { $0 % 2 == 0 ? Float(-1) : Float(1) }
        let peaks = WaveformReducer.reduce(samples, width: 100)
        XCTAssertEqual(peaks.count, 100)
        for p in peaks {
            XCTAssertEqual(p.min, -1)
            XCTAssertEqual(p.max, 1)
        }
    }

    func test_emptyBuffer_yieldsWidthZeroColumns() {
        let peaks = WaveformReducer.reduce([], width: 8)
        XCTAssertEqual(peaks.count, 8)
        XCTAssertTrue(peaks.allSatisfy { $0 == .zero })
    }

    func test_exactSpanMinMax() {
        let samples: [Float] = [0, 0.5, -0.5, 1, -1, 0.25]
        let peaks = WaveformReducer.reduce(samples, width: 2)   // stride 3
        XCTAssertEqual(peaks.count, 2)
        XCTAssertEqual(peaks[0], WaveformPeak(min: -0.5, max: 0.5))   // {0, 0.5, -0.5}
        XCTAssertEqual(peaks[1], WaveformPeak(min: -1, max: 1))       // {1, -1, 0.25}
    }

    func test_zoomInPastResolution_eachColumnIsOneFrame_flatPoint() {
        let samples: [Float] = [0.1, 0.2, 0.3]
        let peaks = WaveformReducer.reduce(samples, width: 6)   // more columns than frames
        XCTAssertEqual(peaks.count, 6)
        // every column covers exactly one frame → min == max
        XCTAssertTrue(peaks.allSatisfy { $0.min == $0.max })
        XCTAssertEqual(peaks.map(\.max), [0.1, 0.1, 0.2, 0.2, 0.3, 0.3])
    }

    func test_window_subrangeIsRespected() {
        let ramp = (0..<10).map { Float($0) }
        let peaks = WaveformReducer.reduce(ramp, width: 1, startFrame: 2, frameCount: 3)  // {2,3,4}
        XCTAssertEqual(peaks, [WaveformPeak(min: 2, max: 4)])
    }

    func test_window_negativeStartClampsToZero() {
        let ramp = (0..<10).map { Float($0) }
        let peaks = WaveformReducer.reduce(ramp, width: 1, startFrame: -5)  // whole buffer
        XCTAssertEqual(peaks, [WaveformPeak(min: 0, max: 9)])
    }

    func test_window_startBeyondEnd_yieldsZeroColumns() {
        let ramp = (0..<10).map { Float($0) }
        let peaks = WaveformReducer.reduce(ramp, width: 4, startFrame: 100, frameCount: 10)
        XCTAssertEqual(peaks.count, 4)
        XCTAssertTrue(peaks.allSatisfy { $0 == .zero })
    }

    func test_window_frameCountOverrunsClampToEnd() {
        let ramp = (0..<10).map { Float($0) }
        let peaks = WaveformReducer.reduce(ramp, width: 1, startFrame: 8, frameCount: 100)  // {8,9}
        XCTAssertEqual(peaks, [WaveformPeak(min: 8, max: 9)])
    }

    func test_columnCountAlwaysEqualsWidth_acrossSizes() {
        let samples = (0..<777).map { Float($0) / 777 }
        for w in [1, 3, 50, 256, 1000, 2000] {
            XCTAssertEqual(WaveformReducer.reduce(samples, width: w).count, w, "width=\(w)")
        }
    }
}
