import XCTest
@testable import ViewerCore

/// Teeth for the non-destructive audio edit ops (TSK-527): trim range/clamp,
/// fade envelopes (linear & equal-power, in & out), silence invariance, and the
/// op-list replay / undo / revert on AudioDocument.
final class AudioDocumentTests: XCTestCase {

    private func constant(_ v: Float, frames: Int, channels: Int = 1, rate: Double = 8000) -> AudioPCMBuffer {
        AudioPCMBuffer(sampleRate: rate, channels: (0..<channels).map { _ in [Float](repeating: v, count: frames) })
    }
    private func ramp(_ frames: Int, rate: Double = 8000) -> AudioPCMBuffer {
        AudioPCMBuffer(sampleRate: rate, channels: [(0..<frames).map { Float($0) }])
    }

    // MARK: - Trim

    func test_trim_lengthEqualsRange_andSlicesCorrectly() {
        let out = AudioEditOp.trim(startFrame: 10, endFrame: 60).apply(to: ramp(100))
        XCTAssertEqual(out.frameCount, 50)
        XCTAssertEqual(out.channels[0].first, 10)
        XCTAssertEqual(out.channels[0].last, 59)
        XCTAssertEqual(out.sampleRate, 8000)        // preserved
    }

    func test_trim_outOfRange_clampsToBuffer() {
        let out = AudioEditOp.trim(startFrame: -5, endFrame: 1000).apply(to: ramp(100))
        XCTAssertEqual(out.frameCount, 100)          // whole buffer
        XCTAssertEqual(out.channels[0].first, 0)
        XCTAssertEqual(out.channels[0].last, 99)
    }

    func test_trim_invertedRange_yieldsEmpty_preservingChannels() {
        let out = AudioEditOp.trim(startFrame: 80, endFrame: 20).apply(to: constant(1, frames: 100, channels: 2))
        XCTAssertEqual(out.frameCount, 0)
        XCTAssertEqual(out.channelCount, 2)          // channel count preserved
    }

    // MARK: - Fade envelopes

    func test_fadeIn_linear_zeroToOne_midpointHalf() {
        let out = AudioEditOp.fade(startFrame: 0, endFrame: 101, direction: .in, shape: .linear)
            .apply(to: constant(1, frames: 101))
        let s = out.channels[0]
        XCTAssertEqual(s.first!, 0, accuracy: 1e-6)
        XCTAssertEqual(s.last!, 1, accuracy: 1e-6)
        XCTAssertEqual(s[50], 0.5, accuracy: 1e-6)   // linear midpoint
    }

    func test_fadeIn_equalPower_midpointIsMinus3dB() {
        let out = AudioEditOp.fade(startFrame: 0, endFrame: 101, direction: .in, shape: .equalPower)
            .apply(to: constant(1, frames: 101))
        XCTAssertEqual(out.channels[0][50], 0.70710678, accuracy: 1e-4)   // sin(π/4)
        XCTAssertEqual(out.channels[0].first!, 0, accuracy: 1e-6)
        XCTAssertEqual(out.channels[0].last!, 1, accuracy: 1e-6)
    }

    func test_fadeOut_linear_oneToZero_symmetric() {
        let out = AudioEditOp.fade(startFrame: 0, endFrame: 101, direction: .out, shape: .linear)
            .apply(to: constant(1, frames: 101))
        let s = out.channels[0]
        XCTAssertEqual(s.first!, 1, accuracy: 1e-6)
        XCTAssertEqual(s.last!, 0, accuracy: 1e-6)
        XCTAssertEqual(s[50], 0.5, accuracy: 1e-6)
    }

    func test_fadeOut_equalPower_midpointIsMinus3dB() {
        let out = AudioEditOp.fade(startFrame: 0, endFrame: 101, direction: .out, shape: .equalPower)
            .apply(to: constant(1, frames: 101))
        XCTAssertEqual(out.channels[0][50], 0.70710678, accuracy: 1e-4)   // cos(π/4)
    }

    func test_fade_onlyAffectsItsRange() {
        let out = AudioEditOp.fade(startFrame: 20, endFrame: 40, direction: .in, shape: .linear)
            .apply(to: constant(1, frames: 100))
        let s = out.channels[0]
        XCTAssertEqual(s[10], 1, accuracy: 1e-6)     // before the fade — untouched
        XCTAssertEqual(s[20], 0, accuracy: 1e-6)     // fade start = 0 gain
        XCTAssertEqual(s[39], 1, accuracy: 1e-6)     // fade end = full gain
        XCTAssertEqual(s[50], 1, accuracy: 1e-6)     // after the fade — untouched
    }

    func test_fade_silenceStaysSilent() {
        let out = AudioEditOp.fade(startFrame: 0, endFrame: 100, direction: .in, shape: .equalPower)
            .apply(to: constant(0, frames: 100))
        XCTAssertTrue(out.channels[0].allSatisfy { $0 == 0 })
    }

    // MARK: - Document op-list / undo / revert

    func test_document_noOps_rendersSource() {
        let doc = AudioDocument(source: ramp(100))
        XCTAssertEqual(doc.rendered(), doc.source)
    }

    func test_document_replaysOpsInOrder_andUndoRevert() {
        var doc = AudioDocument(source: constant(1, frames: 100))
        doc.append(.trim(startFrame: 0, endFrame: 50))
        doc.append(.fade(startFrame: 0, endFrame: 50, direction: .out, shape: .linear))

        let rendered = doc.rendered()
        XCTAssertEqual(rendered.frameCount, 50)               // trim applied
        XCTAssertEqual(rendered.channels[0].first!, 1, accuracy: 1e-6)   // fade-out starts at full
        XCTAssertEqual(rendered.channels[0].last!, 0, accuracy: 1e-6)    // …ends at 0

        doc.undo()                                            // drop the fade
        let afterUndo = doc.rendered()
        XCTAssertEqual(afterUndo.frameCount, 50)
        XCTAssertTrue(afterUndo.channels[0].allSatisfy { $0 == 1 })  // only trim remains

        doc.revert()                                          // back to source
        XCTAssertEqual(doc.rendered(), doc.source)
    }

    func test_document_undoOnEmpty_isNil() {
        var doc = AudioDocument(source: ramp(10))
        XCTAssertNil(doc.undo())
    }

    func test_op_codableRoundTrips() throws {
        let ops: [AudioEditOp] = [
            .trim(startFrame: 5, endFrame: 20),
            .fade(startFrame: 0, endFrame: 10, direction: .out, shape: .equalPower),
        ]
        let data = try JSONEncoder().encode(ops)
        XCTAssertEqual(try JSONDecoder().decode([AudioEditOp].self, from: data), ops)
    }
}
