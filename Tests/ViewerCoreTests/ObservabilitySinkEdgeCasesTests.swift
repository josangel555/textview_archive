import XCTest
@testable import ViewerCore

/// Edge-case coverage for `RingBufferSink` beyond `ObservabilitySinkTests`.
///
/// The base suite covers the happy path (one wrap, basic accumulation,
/// last-write-wins, tag-order independence for one gauge). This file
/// pins the corners that bite in production:
///   - eviction order across *multiple* full wraps (head cycles past 0).
///   - `totalEmitted` vs retained drop accounting (the "you dropped N"
///     signal a triage UI shows).
///   - tag-order independence for *counters* (not just gauges) and the
///     empty-tags / no-tags equivalence.
///   - tag *value* (not just key) discriminating a series.
///   - negative counter deltas (accepted-but-discouraged per protocol).
///   - degenerate capacity-1 ring.
///   - read methods are non-mutating (idempotent snapshots).
final class ObservabilitySinkEdgeCasesTests: XCTestCase {

    // MARK: - Eviction order across multiple wraps

    /// The base suite only wraps once. Drive the ring past TWO full
    /// capacities so `head` cycles back through 0 — a circular-index bug
    /// (e.g. an off-by-one in the wrapped read) surfaces here, not at the
    /// first wrap.
    func test_multipleWraps_retainsLastCapacityInOrder() {
        let cap = 4
        let sink = RingBufferSink(capacity: cap)
        // 13 emits = 3 full wraps + 1 → head lands mid-buffer, not at 0.
        for i in 0..<13 {
            sink.emit(ObsEvent(tsNanos: UInt64(i), level: .info,
                               subsystem: "s", message: "\(i)"))
        }
        XCTAssertEqual(sink.snapshotEvents().map(\.message),
                       ["9", "10", "11", "12"],
                       "after multiple wraps the last `cap` survive in order")
        XCTAssertEqual(sink.bufferedCount, cap)
        XCTAssertEqual(sink.emittedCount, 13)
    }

    /// Exactly `2 * capacity` emits: head wraps to 0 precisely. The
    /// surviving window is the second full batch, in order.
    func test_exactlyTwoFullWraps_headLandsAtZero() {
        let cap = 5
        let sink = RingBufferSink(capacity: cap)
        for i in 0..<(2 * cap) {
            sink.emit(ObsEvent(tsNanos: UInt64(i), level: .info,
                               subsystem: "s", message: "\(i)"))
        }
        XCTAssertEqual(sink.snapshotEvents().map(\.message),
                       ["5", "6", "7", "8", "9"])
        XCTAssertEqual(sink.emittedCount, UInt64(2 * cap))
    }

    // MARK: - Drop accounting (totalEmitted − retained)

    /// The eviction signal a triage UI shows is `emitted − buffered`.
    /// Pin it directly so the two counters can't drift out of the
    /// drop-count invariant.
    func test_dropCount_isEmittedMinusBuffered() {
        let cap = 8
        let sink = RingBufferSink(capacity: cap)
        let total = 30
        for i in 0..<total {
            sink.emit(ObsEvent(level: .info, subsystem: "s", message: "\(i)"))
        }
        XCTAssertEqual(sink.emittedCount, UInt64(total))
        XCTAssertEqual(sink.bufferedCount, cap)
        let dropped = sink.emittedCount - UInt64(sink.bufferedCount)
        XCTAssertEqual(dropped, UInt64(total - cap),
                       "dropped = emitted − retained")
    }

    /// Before any wrap, nothing is dropped — emitted == buffered.
    func test_noDrops_beforeCapacityReached() {
        let sink = RingBufferSink(capacity: 16)
        for i in 0..<10 {
            sink.emit(ObsEvent(level: .debug, subsystem: "s", message: "\(i)"))
        }
        XCTAssertEqual(sink.emittedCount, 10)
        XCTAssertEqual(sink.bufferedCount, 10)
        XCTAssertEqual(sink.emittedCount - UInt64(sink.bufferedCount), 0)
    }

    /// `emittedCount` is monotonic and counts evicted events too — it must
    /// NOT reset or cap at `capacity`.
    func test_emittedCount_isMonotonicPastCapacity() {
        let sink = RingBufferSink(capacity: 2)
        var last: UInt64 = 0
        for i in 0..<20 {
            sink.emit(ObsEvent(level: .info, subsystem: "s", message: "\(i)"))
            let now = sink.emittedCount
            XCTAssertGreaterThan(now, last)
            last = now
        }
        XCTAssertEqual(last, 20)
        XCTAssertEqual(sink.bufferedCount, 2)
    }

    // MARK: - Counter tag-order independence + empty-tags equivalence

    /// The base suite proves tag-order independence for a *gauge*. Counters
    /// share the same `MetricKey` hashing, but the *accumulation* path is
    /// distinct (`+=` vs overwrite), so pin that reordered tags fold into
    /// ONE counter series that sums correctly.
    func test_counter_tagOrderIndependent_accumulatesIntoOneSeries() {
        let sink = RingBufferSink(capacity: 4)
        sink.counter("req", 2, ["lang": "swift", "kind": "hover"])
        sink.counter("req", 3, ["kind": "hover", "lang": "swift"]) // reordered
        sink.counter("req", 5, ["lang": "swift", "kind": "hover"])
        XCTAssertEqual(sink.counterValue("req", ["kind": "hover", "lang": "swift"]),
                       10, "reordered tags must not split the counter series")
        // Exactly one series exists for this name.
        let series = sink.snapshotMetrics().filter { $0.name == "req" }
        XCTAssertEqual(series.count, 1)
    }

    /// `counter(name)` (no tags) and `counter(name, delta, [:])` (explicit
    /// empty) must address the SAME series — the convenience overload
    /// defaults to `[:]`.
    func test_emptyTags_andNoTags_areSameSeries() {
        let sink = RingBufferSink(capacity: 4)
        sink.counter("c")               // convenience → [:]
        sink.counter("c", 4, [:])       // explicit empty
        XCTAssertEqual(sink.counterValue("c"), 5)
        XCTAssertEqual(sink.counterValue("c", [:]), 5)
        XCTAssertEqual(sink.snapshotMetrics().filter { $0.name == "c" }.count, 1)
    }

    /// A series with tags is distinct from the same-named series with NO
    /// tags — they must not collide.
    func test_taggedAndUntagged_sameName_areDistinctSeries() {
        let sink = RingBufferSink(capacity: 4)
        sink.counter("hits", 1, [:])
        sink.counter("hits", 7, ["host": "a"])
        XCTAssertEqual(sink.counterValue("hits"), 1)
        XCTAssertEqual(sink.counterValue("hits", ["host": "a"]), 7)
    }

    /// Different tag *values* (same key) split the series — keying is on
    /// the full (key,value) set, not just the key names.
    func test_differentTagValues_splitSeries() {
        let sink = RingBufferSink(capacity: 4)
        sink.gauge("temp", 50, ["zone": "cpu"])
        sink.gauge("temp", 30, ["zone": "gpu"])
        XCTAssertEqual(sink.gaugeValue("temp", ["zone": "cpu"]), 50)
        XCTAssertEqual(sink.gaugeValue("temp", ["zone": "gpu"]), 30)
    }

    // MARK: - Counter delta edge cases

    /// Negative deltas are "accepted but discouraged" per the protocol
    /// doc — pin that they actually subtract (the path isn't clamped).
    func test_counter_negativeDelta_subtracts() {
        let sink = RingBufferSink(capacity: 4)
        sink.counter("balance", 10, [:])
        sink.counter("balance", -3, [:])
        XCTAssertEqual(sink.counterValue("balance"), 7)
    }

    func test_counter_zeroDelta_isNoOpButCreatesSeries() {
        let sink = RingBufferSink(capacity: 4)
        sink.counter("c", 0, [:])
        XCTAssertEqual(sink.counterValue("c"), 0)
        // A zero-delta touch still materializes the series in snapshots.
        XCTAssertEqual(sink.snapshotMetrics().filter { $0.name == "c" }.count, 1)
    }

    func test_counterValue_untouchedSeries_isZero() {
        let sink = RingBufferSink(capacity: 4)
        XCTAssertEqual(sink.counterValue("never.touched"), 0)
    }

    // MARK: - Gauge last-write-wins edge cases

    func test_gauge_overwriteToLowerThenHigher_tracksLatest() {
        let sink = RingBufferSink(capacity: 4)
        sink.gauge("g", 100, [:])
        sink.gauge("g", 1, [:])
        sink.gauge("g", 42, [:])
        XCTAssertEqual(sink.gaugeValue("g"), 42, "gauge tracks the latest write")
    }

    func test_gauge_negativeAndZero_areStoredVerbatim() {
        let sink = RingBufferSink(capacity: 4)
        sink.gauge("delta", -5.5, [:])
        XCTAssertEqual(sink.gaugeValue("delta"), -5.5)
        sink.gauge("delta", 0, [:])
        XCTAssertEqual(sink.gaugeValue("delta"), 0)
    }

    func test_gaugeValue_untouchedSeries_isNil() {
        let sink = RingBufferSink(capacity: 4)
        XCTAssertNil(sink.gaugeValue("absent"),
                     "an unset gauge is nil, distinct from a 0 value")
    }

    /// A counter and a gauge sharing a name are independent series — the
    /// registries are separate, so reading one never returns the other.
    func test_counterAndGauge_sameName_doNotAlias() {
        let sink = RingBufferSink(capacity: 4)
        sink.counter("dual", 9, [:])
        sink.gauge("dual", 2.0, [:])
        XCTAssertEqual(sink.counterValue("dual"), 9)
        XCTAssertEqual(sink.gaugeValue("dual"), 2.0)
        let dual = sink.snapshotMetrics().filter { $0.name == "dual" }
        XCTAssertEqual(dual.count, 2)
        XCTAssertEqual(Set(dual.map(\.kind)), [.counter, .gauge])
    }

    // MARK: - Degenerate capacity-1 ring

    /// A capacity-1 ring always retains exactly the most recent event;
    /// every emit past the first is a drop. Boundary for the wrap math.
    func test_capacityOne_retainsOnlyLatest() {
        let sink = RingBufferSink(capacity: 1)
        sink.emit(ObsEvent(tsNanos: 0, level: .info, subsystem: "s", message: "a"))
        XCTAssertEqual(sink.snapshotEvents().map(\.message), ["a"])
        sink.emit(ObsEvent(tsNanos: 1, level: .info, subsystem: "s", message: "b"))
        sink.emit(ObsEvent(tsNanos: 2, level: .info, subsystem: "s", message: "c"))
        XCTAssertEqual(sink.snapshotEvents().map(\.message), ["c"])
        XCTAssertEqual(sink.bufferedCount, 1)
        XCTAssertEqual(sink.emittedCount, 3)
        XCTAssertEqual(sink.emittedCount - UInt64(sink.bufferedCount), 2)
    }

    // MARK: - Reads are non-mutating

    /// `snapshotEvents` / `snapshotMetrics` must not consume or reorder
    /// state — repeated reads return identical results, and counts are
    /// unchanged after reading.
    func test_snapshots_areIdempotent() {
        let sink = RingBufferSink(capacity: 8)
        for i in 0..<5 {
            sink.emit(ObsEvent(tsNanos: UInt64(i), level: .info,
                               subsystem: "s", message: "\(i)"))
        }
        sink.counter("c", 3, ["k": "v"])
        sink.gauge("g", 1.0, [:])

        let firstEvents = sink.snapshotEvents()
        let secondEvents = sink.snapshotEvents()
        XCTAssertEqual(firstEvents, secondEvents)
        XCTAssertEqual(sink.bufferedCount, 5, "reading must not drain the buffer")
        XCTAssertEqual(sink.emittedCount, 5)

        let firstMetrics = sink.snapshotMetrics().count
        let secondMetrics = sink.snapshotMetrics().count
        XCTAssertEqual(firstMetrics, secondMetrics)
        XCTAssertEqual(sink.counterValue("c", ["k": "v"]), 3,
                       "reading metrics must not reset them")
    }

    /// `bufferedCount` never exceeds capacity even mid-fill, and equals
    /// the snapshot length at every step.
    func test_bufferedCount_tracksSnapshotLength_throughFill() {
        let cap = 4
        let sink = RingBufferSink(capacity: cap)
        for i in 0..<10 {
            sink.emit(ObsEvent(level: .info, subsystem: "s", message: "\(i)"))
            XCTAssertEqual(sink.bufferedCount, sink.snapshotEvents().count)
            XCTAssertLessThanOrEqual(sink.bufferedCount, cap)
        }
    }

    // MARK: - reset() restores empty-buffer invariants

    func test_reset_thenEmit_behavesLikeFreshSink() {
        let sink = RingBufferSink(capacity: 3)
        for i in 0..<10 {
            sink.emit(ObsEvent(level: .info, subsystem: "s", message: "old\(i)"))
        }
        sink.reset()
        // Post-reset the ring fills from scratch (no stale head offset).
        sink.emit(ObsEvent(level: .info, subsystem: "s", message: "n0"))
        sink.emit(ObsEvent(level: .info, subsystem: "s", message: "n1"))
        XCTAssertEqual(sink.snapshotEvents().map(\.message), ["n0", "n1"])
        XCTAssertEqual(sink.emittedCount, 2, "emittedCount restarts after reset")
        XCTAssertEqual(sink.bufferedCount, 2)
    }

    // TSK-1005: the metric registry must be bounded by tag cardinality — a
    // high-cardinality tag (unique value per call) can't grow counters/gauges
    // without bound. TEETH: pre-cap, distinctSeries would equal the push count.
    func test_metricRegistry_isBoundedByCardinality() {
        let sink = RingBufferSink(capacity: 16)
        let over = RingBufferSink.maxMetricSeries + 500
        for i in 0..<over {
            sink.counter("req", 1, ["id": "\(i)"])   // unique tag per call
            sink.gauge("lat", Double(i), ["id": "\(i)"])
        }
        let metrics = sink.snapshotMetrics()
        let counters = metrics.filter { $0.kind == .counter }.count
        let gauges = metrics.filter { $0.kind == .gauge }.count
        XCTAssertLessThanOrEqual(counters, RingBufferSink.maxMetricSeries)
        XCTAssertLessThanOrEqual(gauges, RingBufferSink.maxMetricSeries)
        XCTAssertGreaterThan(sink.droppedMetricSeriesCount, 0,
                             "high-cardinality series should be dropped past the cap")

        // An EXISTING series still updates after the cap is hit.
        sink.counter("req", 9, ["id": "0"])
        XCTAssertEqual(sink.counterValue("req", ["id": "0"]), 10)
    }

    func test_metricRegistry_belowCap_keepsEverySeries() {
        let sink = RingBufferSink(capacity: 16)
        for i in 0..<100 { sink.counter("c", 1, ["id": "\(i)"]) }
        XCTAssertEqual(sink.snapshotMetrics().filter { $0.kind == .counter }.count, 100)
        XCTAssertEqual(sink.droppedMetricSeriesCount, 0)
    }
}
