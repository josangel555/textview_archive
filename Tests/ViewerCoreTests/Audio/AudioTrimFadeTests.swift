import XCTest
@testable import ViewerCore

/// Host teeth for the trim/fade SELECTION → `AudioEditOp` mapping (TSK-534).
/// The draggable handles are the VM render tail; this pins the selection→ops
/// policy (which ops, in what order, addressing which frame space) plus the
/// end-to-end render through the already-tested `AudioDocument`.
final class AudioTrimFadeTests: XCTestCase {

    private let sr = 1000.0   // 1 kHz → 1 frame per ms, easy frame↔second math

    func test_noSelection_noOps() {
        let ops = AudioTrimFade.ops(
            trimStart: 0, trimEnd: 2000, totalFrames: 2000,
            fadeInSeconds: 0, fadeOutSeconds: 0, sampleRate: sr, shape: .linear)
        XCTAssertTrue(ops.isEmpty, "full range + no fades exports a faithful copy, no ops")
    }

    func test_trimSubrange_emitsTrimOp() {
        let ops = AudioTrimFade.ops(
            trimStart: 200, trimEnd: 800, totalFrames: 2000,
            fadeInSeconds: 0, fadeOutSeconds: 0, sampleRate: sr, shape: .linear)
        XCTAssertEqual(ops, [.trim(startFrame: 200, endFrame: 800)])
    }

    func test_fadesAddressTrimmedSpace_afterTrim() {
        // trim to [200,800) → 600-frame buffer; 0.1s fades = 100 frames each,
        // at the trimmed buffer's start and end.
        let ops = AudioTrimFade.ops(
            trimStart: 200, trimEnd: 800, totalFrames: 2000,
            fadeInSeconds: 0.1, fadeOutSeconds: 0.1, sampleRate: sr, shape: .equalPower)
        XCTAssertEqual(ops, [
            .trim(startFrame: 200, endFrame: 800),
            .fade(startFrame: 0, endFrame: 100, direction: .in, shape: .equalPower),
            .fade(startFrame: 500, endFrame: 600, direction: .out, shape: .equalPower),
        ])
    }

    func test_fadeOnly_noTrimOp_addressesWholeBuffer() {
        let ops = AudioTrimFade.ops(
            trimStart: 0, trimEnd: 1000, totalFrames: 1000,
            fadeInSeconds: 0.2, fadeOutSeconds: 0, sampleRate: sr, shape: .linear)
        XCTAssertEqual(ops, [.fade(startFrame: 0, endFrame: 200, direction: .in, shape: .linear)],
                       "no trim op when the range is whole; fade addresses the full buffer")
    }

    func test_fadeLongerThanClip_clampsToLength() {
        // 10s fade over a 0.5s (500-frame) clip → capped at the buffer length.
        let ops = AudioTrimFade.ops(
            trimStart: 0, trimEnd: 500, totalFrames: 500,
            fadeInSeconds: 10, fadeOutSeconds: 0, sampleRate: sr, shape: .linear)
        XCTAssertEqual(ops, [.fade(startFrame: 0, endFrame: 500, direction: .in, shape: .linear)])
    }

    func test_clampsInvertedAndOutOfRange() {
        // end < start and start past the end → clamped to an empty in-range trim.
        let ops = AudioTrimFade.ops(
            trimStart: 9000, trimEnd: 50, totalFrames: 1000,
            fadeInSeconds: 1, fadeOutSeconds: 1, sampleRate: sr, shape: .linear)
        // start clamps to 1000, end clamps to >= start (1000) → trim(1000,1000),
        // an empty selection; len 0 ⇒ no fades.
        XCTAssertEqual(ops, [.trim(startFrame: 1000, endFrame: 1000)])
    }

    func test_hasEdits_matchesOpsPresence() {
        XCTAssertFalse(AudioTrimFade.hasEdits(
            trimStart: 0, trimEnd: 100, totalFrames: 100,
            fadeInSeconds: 0, fadeOutSeconds: 0, sampleRate: sr, shape: .linear))
        XCTAssertTrue(AudioTrimFade.hasEdits(
            trimStart: 10, trimEnd: 100, totalFrames: 100,
            fadeInSeconds: 0, fadeOutSeconds: 0, sampleRate: sr, shape: .linear))
    }

    /// End-to-end: the ops actually trim + fade a real buffer when rendered.
    func test_endToEnd_renderTrimsAndFades() {
        let n = 1000
        let src = AudioPCMBuffer(sampleRate: sr, channels: [[Float](repeating: 1, count: n)])
        let ops = AudioTrimFade.ops(
            trimStart: 100, trimEnd: 600, totalFrames: n,
            fadeInSeconds: 0.05, fadeOutSeconds: 0, sampleRate: sr, shape: .linear)
        let out = AudioDocument(source: src, ops: ops).rendered()
        XCTAssertEqual(out.frameCount, 500, "trimmed to [100,600)")
        XCTAssertEqual(out.channels[0].first ?? -1, 0, accuracy: 1e-6, "linear fade-in starts at silence")
        XCTAssertEqual(out.channels[0].last ?? -1, 1, accuracy: 1e-6, "tail is un-faded full scale")
    }
}
