import XCTest
@testable import ViewerCore

/// Teeth for the FFT spectrum (TSK-526). A pure sine must peak in the bin whose
/// frequency maps to the tone; DC lands in bin 0; silence sits at the floor.
final class SpectrumAnalyzerTests: XCTestCase {

    private func sine(_ freq: Double, sampleRate: Double, count: Int, amplitude: Float = 0.9) -> [Float] {
        (0..<count).map { Float(amplitude) * sinf(Float(2.0 * Double.pi * freq * Double($0) / sampleRate)) }
    }

    func test_sine_peakBinMapsToFrequency() {
        let sr = 8000.0, fft = 2048
        let f = 1000.0
        let bins = SpectrumAnalyzer.analyze(sine(f, sampleRate: sr, count: fft),
                                            sampleRate: sr, fftSize: fft)!
        XCTAssertEqual(bins.magnitudesDB.count, fft / 2)
        let peak = bins.peakBin
        // expected bin = f / binResolution (= f * fft / sr)
        let expected = Int((f / bins.binResolution).rounded())
        XCTAssertLessThanOrEqual(abs(peak - expected), 1, "peak bin \(peak) vs expected \(expected)")
        // and the peak bin's frequency is within one bin of the tone
        XCTAssertEqual(Double(bins.binFrequencies[peak]), f, accuracy: bins.binResolution * 1.5)
    }

    func test_secondTone_peakTracksHigherFrequency() {
        let sr = 44100.0, fft = 4096
        let f = 5000.0
        let bins = SpectrumAnalyzer.analyze(sine(f, sampleRate: sr, count: fft),
                                            sampleRate: sr, fftSize: fft)!
        XCTAssertEqual(Double(bins.binFrequencies[bins.peakBin]), f, accuracy: bins.binResolution * 1.5)
    }

    func test_dcOffset_peaksAtBinZero() {
        let sr = 8000.0, fft = 1024
        let dc = [Float](repeating: 0.7, count: fft)   // constant → all energy at DC
        let bins = SpectrumAnalyzer.analyze(dc, sampleRate: sr, fftSize: fft)!
        XCTAssertEqual(bins.peakBin, 0)
    }

    func test_silence_allBinsAtFloor() {
        let sr = 8000.0, fft = 512, floor: Float = -120
        let bins = SpectrumAnalyzer.analyze([Float](repeating: 0, count: fft),
                                            sampleRate: sr, fftSize: fft, floorDB: floor)!
        XCTAssertTrue(bins.magnitudesDB.allSatisfy { $0 == floor })
    }

    func test_nonPowerOfTwoFFTSize_returnsNil() {
        XCTAssertNil(SpectrumAnalyzer.analyze([0, 1, 2], sampleRate: 8000, fftSize: 1000))
        XCTAssertNil(SpectrumAnalyzer.analyze([0, 1, 2], sampleRate: 8000, fftSize: 0))
        XCTAssertNil(SpectrumAnalyzer.analyze([0, 1, 2], sampleRate: 0, fftSize: 1024))
    }

    func test_binFrequencies_spanDcToNyquist() {
        let sr = 48000.0, fft = 2048
        let bins = SpectrumAnalyzer.analyze(sine(1000, sampleRate: sr, count: fft),
                                            sampleRate: sr, fftSize: fft)!
        XCTAssertEqual(bins.binFrequencies.count, fft / 2)
        XCTAssertEqual(bins.binFrequencies.first!, 0)
        XCTAssertEqual(bins.binResolution, sr / Double(fft), accuracy: 1e-9)
        // last bin is just under Nyquist
        XCTAssertEqual(Double(bins.binFrequencies.last!), sr / 2 - bins.binResolution, accuracy: 1e-3)
    }

    func test_shortInput_zeroPadded_stillAnalyzes() {
        // fewer samples than fftSize → zero-padded, no crash, valid bin count.
        let bins = SpectrumAnalyzer.analyze(sine(440, sampleRate: 8000, count: 100),
                                            sampleRate: 8000, fftSize: 1024)!
        XCTAssertEqual(bins.magnitudesDB.count, 512)
    }
}
