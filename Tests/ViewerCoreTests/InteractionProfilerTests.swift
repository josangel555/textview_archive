import Testing
@testable import ViewerCore

/// TSK-1488 — the per-interaction felt-perf layer: percentile math, budget
/// verdicts, and profiler span bookkeeping.
struct InteractionProfilerTests {

    // MARK: - FramePercentiles (nearest-rank)

    @Test func percentiles_empty_isAllZero() {
        let p = FramePercentiles.compute(frameDurationsMs: [])
        #expect(p == FramePercentiles(count: 0, p50: 0, p95: 0, p99: 0, worst: 0))
    }

    @Test func percentiles_nearestRank_pickTheRightSample() {
        // 1…10 ms. nearest-rank: p50 → rank ceil(.5·10)=5 → sorted[4]=5;
        // p95 → rank ceil(.95·10)=10 → sorted[9]=10; worst=10.
        let p = FramePercentiles.compute(frameDurationsMs: [10, 1, 8, 3, 6, 2, 9, 4, 7, 5])
        #expect(p.count == 10)
        #expect(p.p50 == 5)
        #expect(p.p95 == 10)
        #expect(p.p99 == 10)
        #expect(p.worst == 10)
    }

    @Test func percentiles_singleFrame_allEqualThatFrame() {
        let p = FramePercentiles.compute(frameDurationsMs: [42])
        #expect(p.p50 == 42 && p.p95 == 42 && p.worst == 42)
    }

    // MARK: - InteractionSpan budget verdict (teeth)

    @Test func span_underBudget_isSmooth() {
        // Palette keystroke budget 16.7ms; all frames at 12ms → smooth.
        let span = InteractionSpan(
            kind: .paletteKeystroke,
            percentiles: FramePercentiles.compute(frameDurationsMs: [12, 11, 13, 12, 12]))
        #expect(span.exceedsBudget == false)
    }

    @Test func span_p95OverBudget_isJanky() {
        // One 40ms hitch among 12ms frames pushes p95 over the 16.7ms budget.
        let span = InteractionSpan(
            kind: .paletteKeystroke,
            percentiles: FramePercentiles.compute(frameDurationsMs: [12, 12, 12, 40, 12]))
        #expect(span.percentiles.p95 == 40)
        #expect(span.exceedsBudget == true)
    }

    @Test func span_budgetsAreKindSpecific() {
        // A 30ms p95 is OVER for a keystroke (16.7) but UNDER for a tab switch (33.3).
        let frames = [30.0, 30, 30]
        #expect(InteractionSpan(kind: .paletteKeystroke,
            percentiles: .compute(frameDurationsMs: frames)).exceedsBudget == true)
        #expect(InteractionSpan(kind: .switchTab,
            percentiles: .compute(frameDurationsMs: frames)).exceedsBudget == false)
    }

    @Test func span_noFrames_neverExceeds() {
        #expect(InteractionSpan(kind: .paletteKeystroke,
            percentiles: .compute(frameDurationsMs: [])).exceedsBudget == false)
    }

    // MARK: - InteractionProfiler bookkeeping

    @Test func profiler_beginRecordEnd_closesASpan() {
        let prof = InteractionProfiler()
        prof.begin(.switchTab)
        prof.recordFrame(ms: 10); prof.recordFrame(ms: 40); prof.recordFrame(ms: 12)
        let span = prof.end()
        #expect(span?.kind == .switchTab)
        #expect(span?.percentiles.worst == 40)
        #expect(prof.spans(for: .switchTab).count == 1)
    }

    @Test func profiler_endWithoutBegin_isNil() {
        #expect(InteractionProfiler().end() == nil)
    }

    @Test func profiler_recordWithoutBegin_isNoOp() {
        let prof = InteractionProfiler()
        prof.recordFrame(ms: 99)          // dropped — no open span
        prof.begin(.openFile)
        prof.recordFrame(ms: 10)
        #expect(prof.end()?.percentiles.count == 1)   // only the post-begin frame
    }

    @Test func profiler_newBegin_discardsUnendedSpan() {
        let prof = InteractionProfiler()
        prof.begin(.openFile); prof.recordFrame(ms: 999)   // never ended
        prof.begin(.switchTab); prof.recordFrame(ms: 10)
        let span = prof.end()
        #expect(span?.kind == .switchTab)
        #expect(span?.percentiles.worst == 10)             // the 999 is gone
        #expect(prof.spans(for: .openFile).isEmpty)
    }

    @Test func profiler_historyIsCappedPerKind() {
        let prof = InteractionProfiler(historyDepth: 3)
        for ms in [10.0, 20, 30, 40, 50] {
            prof.begin(.renderUpdate); prof.recordFrame(ms: ms); prof.end()
        }
        let spans = prof.spans(for: .renderUpdate)
        #expect(spans.count == 3)                           // capped
        #expect(spans.map { $0.percentiles.worst } == [30, 40, 50])   // newest kept
    }

    @Test func profiler_overBudgetSpans_collectsTheJankyOnes() {
        let prof = InteractionProfiler()
        prof.begin(.paletteKeystroke); prof.recordFrame(ms: 50); prof.end()   // over 16.7
        prof.begin(.switchTab); prof.recordFrame(ms: 10); prof.end()          // under 33.3
        let over = prof.overBudgetSpans()
        #expect(over.map(\.kind) == [.paletteKeystroke])
    }

    @Test func profiler_dump_flagsOverBudget() {
        let prof = InteractionProfiler()
        prof.begin(.searchScroll); prof.recordFrame(ms: 60); prof.end()
        let dump = prof.dump()
        #expect(dump.contains("Search scroll"))
        #expect(dump.contains("OVER"))
    }

    @Test func profiler_dump_emptyMessage() {
        #expect(InteractionProfiler().dump() == "InteractionProfiler: no spans recorded")
    }

    // MARK: - env gate

    @Test func isEnabled_onlyForNonZeroValue() {
        #expect(InteractionProfiler.isEnabled(env: nil) == false)
        #expect(InteractionProfiler.isEnabled(env: "") == false)
        #expect(InteractionProfiler.isEnabled(env: "0") == false)
        #expect(InteractionProfiler.isEnabled(env: "1") == true)
        #expect(InteractionProfiler.isEnabled(env: "hud") == true)
    }
}
