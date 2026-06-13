import XCTest
@testable import ViewerUI

/// TSK-275 — the FPS/jank math, judged against the display's NOMINAL
/// cadence (the load-bearing design point: 120 Hz panels must not
/// false-jank, 60 Hz panels must not be flagged for being 60). The live
/// display-link feed is the glance; everything below is the contract.
@MainActor
final class FrameStatsTests: HeadlessUITestCase {

    /// Synthesize a timestamp run at `hz`, with optional stall gaps
    /// injected after given frame indices.
    private func run(
        hz: Double, frames: Int, stallsAfter: [Int: TimeInterval] = [:]
    ) -> [TimeInterval] {
        let dt = 1.0 / hz
        var t = 0.0
        var out = [t]
        for i in 0..<frames {
            t += dt + (stallsAfter[i] ?? 0)
            out.append(t)
        }
        return out
    }

    func test_clean60Hz_isNotJanky() {
        let stats = FrameStats.compute(
            timestamps: run(hz: 60, frames: 120), nominalInterval: 1.0 / 60)
        XCTAssertEqual(stats.fps, 60, accuracy: 0.5)
        XCTAssertEqual(stats.hitchCount, 0)
        XCTAssertFalse(stats.isJanky, "a clean 60Hz panel at 60fps is healthy")
    }

    func test_clean120Hz_isNotJanky_judgedAgainstItsOwnNominal() {
        let stats = FrameStats.compute(
            timestamps: run(hz: 120, frames: 240), nominalInterval: 1.0 / 120)
        XCTAssertEqual(stats.fps, 120, accuracy: 1.0)
        XCTAssertFalse(stats.isJanky)
        XCTAssertEqual(stats.nominalFPS, 120, accuracy: 0.1)
    }

    func test_aStall_countsHitches_andFlagsJank() {
        // One 100ms stall in an otherwise clean 60Hz run = one missed-frame
        // hitch (interval ≫ 1.5 × 16.7ms) and a janky window.
        let stats = FrameStats.compute(
            timestamps: run(hz: 60, frames: 120, stallsAfter: [60: 0.100]),
            nominalInterval: 1.0 / 60)
        XCTAssertEqual(stats.hitchCount, 1)
        XCTAssertTrue(stats.isJanky)
        XCTAssertLessThan(stats.fps, 60)
    }

    func test_sustainedSlow_isJanky_evenWithoutSingleBigHitches() {
        // 45fps steady on a 60Hz panel: every interval is 22.2ms — under
        // the 1.5× hitch bar (25ms), so hitchCount stays 0; the sustained
        // sub-nominal fps must still flag.
        let stats = FrameStats.compute(
            timestamps: run(hz: 45, frames: 90), nominalInterval: 1.0 / 60)
        XCTAssertEqual(stats.hitchCount, 0, "22ms intervals are under the hitch bar")
        XCTAssertTrue(stats.isJanky, "sustained 45fps on a 60Hz panel is jank")
    }

    func test_degenerateInputs_yieldZeroes_neverCrash() {
        XCTAssertEqual(FrameStats.compute(timestamps: [], nominalInterval: 1.0 / 60).fps, 0)
        XCTAssertEqual(FrameStats.compute(timestamps: [1.0], nominalInterval: 1.0 / 60).fps, 0)
        XCTAssertEqual(FrameStats.compute(timestamps: [1, 1], nominalInterval: 1.0 / 60).fps, 0)
        XCTAssertEqual(FrameStats.compute(timestamps: [1, 2], nominalInterval: 0).fps, 0)
        XCTAssertFalse(FrameStats.compute(timestamps: [], nominalInterval: 0).isJanky)
    }

    /// Wiring pins: the strip is mounted, lifecycle-bound, and the
    /// monitor's publish discipline constants hold (per-frame republish
    /// is the #215 class).
    func test_metricsView_wiring_andPublishDiscipline() throws {
        XCTAssertGreaterThanOrEqual(FrameRateMonitor.publishInterval, 0.25,
                                    "stats must never publish per-frame")
        XCTAssertLessThanOrEqual(FrameRateMonitor.windowSize, 600)
        let mv = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/ViewerUI/Observability/MetricsView.swift"),
            encoding: .utf8)
        XCTAssertTrue(mv.contains("fpsStrip"), "the FPS strip must be mounted")
        XCTAssertTrue(mv.contains("frameMonitor.stop()"),
                      "the link must stop on disappear — zero cost when closed")
        XCTAssertTrue(mv.contains("stats.isJanky ? Color.red"),
                      "jank must paint the readout red (the ticket's contract)")
    }
}
