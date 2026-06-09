import XCTest
@testable import ViewerCore

/// Teeth for the amplitude ops (TSK-531): gain (dB scale), peak-normalize, and
/// the peak/RMS level helpers.
final class AudioLevelOpsTests: XCTestCase {

    private func buf(_ samples: [Float], rate: Double = 8000) -> AudioPCMBuffer {
        AudioPCMBuffer(sampleRate: rate, channels: [samples])
    }

    // MARK: - Gain

    func test_gain_zeroDB_isIdentity() {
        let src = buf([0, 0.25, -0.5, 0.9])
        XCTAssertEqual(AudioEditOp.gain(decibels: 0).apply(to: src), src)
    }

    func test_gain_plus20dB_isTimesTen() {
        let out = AudioEditOp.gain(decibels: 20).apply(to: buf([0.05, -0.02]))
        XCTAssertEqual(out.channels[0][0], 0.5, accuracy: 1e-5)
        XCTAssertEqual(out.channels[0][1], -0.2, accuracy: 1e-5)
    }

    func test_gain_minus20dB_isTimesPointOne() {
        let out = AudioEditOp.gain(decibels: -20).apply(to: buf([1.0, -0.5]))
        XCTAssertEqual(out.channels[0][0], 0.1, accuracy: 1e-5)
        XCTAssertEqual(out.channels[0][1], -0.05, accuracy: 1e-5)
    }

    func test_gain_plus6dB_isApproxDouble() {
        let out = AudioEditOp.gain(decibels: 6.0206).apply(to: buf([0.4]))
        XCTAssertEqual(out.channels[0][0], 0.8, accuracy: 1e-3)   // +6.02 dB ≈ ×2
    }

    // MARK: - Normalize

    func test_normalize_bringsPeakToZeroDBFS() {
        let out = AudioEditOp.normalize(targetPeakDB: 0).apply(to: buf([0.25, -0.5, 0.1]))
        XCTAssertEqual(out.peakAmplitude(), 1.0, accuracy: 1e-5)   // loudest (0.5) → full scale
        XCTAssertEqual(out.channels[0][0], 0.5, accuracy: 1e-5)    // everything scaled ×2
        XCTAssertEqual(out.channels[0][1], -1.0, accuracy: 1e-5)
    }

    func test_normalize_negativeTarget() {
        // peak 0.5 → target −6.0206 dBFS (≈0.5 linear) → already there (×~1)
        let out = AudioEditOp.normalize(targetPeakDB: -6.0206).apply(to: buf([0.5, -0.25]))
        XCTAssertEqual(out.peakAmplitude(), 0.5, accuracy: 1e-3)
    }

    func test_normalize_silence_staysSilent() {
        let out = AudioEditOp.normalize(targetPeakDB: 0).apply(to: buf([0, 0, 0]))
        XCTAssertTrue(out.channels[0].allSatisfy { $0 == 0 })
    }

    // MARK: - Level metering

    func test_peakAmplitude_acrossChannels() {
        let b = AudioPCMBuffer(sampleRate: 8000, channels: [[0.3, -0.7], [0.2, 0.65]])
        XCTAssertEqual(b.peakAmplitude(), 0.7, accuracy: 1e-6)   // |−0.7| is the largest
    }

    func test_peakAmplitude_silenceAndEmpty() {
        XCTAssertEqual(buf([0, 0, 0]).peakAmplitude(), 0)
        XCTAssertEqual(AudioPCMBuffer(sampleRate: 8000, channels: []).peakAmplitude(), 0)
    }

    func test_rms_ofConstant_isThatConstant() {
        XCTAssertEqual(buf([0.5, 0.5, 0.5, 0.5]).rmsAmplitude(), 0.5, accuracy: 1e-6)
    }

    func test_rms_ofFullScaleSine_isAboutPoint707() {
        // 10 whole cycles → clean RMS = amplitude / √2.
        let s = (0..<1000).map { sinf(Float(2 * Double.pi * 10 * Double($0) / 1000)) }
        XCTAssertEqual(buf(s).rmsAmplitude(), 0.70710678, accuracy: 0.01)
    }

    // MARK: - Op-list + Codable

    func test_codableRoundTrip() throws {
        let ops: [AudioEditOp] = [.gain(decibels: -3.5), .normalize(targetPeakDB: -1)]
        let data = try JSONEncoder().encode(ops)
        XCTAssertEqual(try JSONDecoder().decode([AudioEditOp].self, from: data), ops)
    }

    func test_document_gainThenNormalize_replays() {
        var doc = AudioDocument(source: buf([0.1, -0.2, 0.05]))
        doc.append(.gain(decibels: 20))                 // ×10 → peak 2.0
        doc.append(.normalize(targetPeakDB: 0))         // back down to peak 1.0
        XCTAssertEqual(doc.rendered().peakAmplitude(), 1.0, accuracy: 1e-5)
    }
}
