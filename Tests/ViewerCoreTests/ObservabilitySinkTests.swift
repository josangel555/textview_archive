import XCTest
@testable import ViewerCore

/// Foundation for item 0a — the `ObservabilitySink` that unblocks all
/// later instrumentation. Covers:
///   - `ObsEvent` / `ObsMetric` record shape + FFI-friendly invariants.
///   - `RingBufferSink` bound + drop-oldest eviction (the content-leak
///     containment guarantee, not just a memory bound).
///   - counter accumulation + gauge last-write-wins + tag-keyed series.
///   - `Obs` global install/swap seam.
///   - basic thread-safety under concurrent emit/counter/gauge.
final class ObservabilitySinkTests: XCTestCase {

    override func tearDown() {
        // Don't let a test-installed sink leak into the next test (or
        // into the LSP/grammar/MCP migration tests in this suite).
        Obs.resetToNoop()
        super.tearDown()
    }

    // MARK: - Event record shape

    func testEventCarriesFlatPrimitivePayload() {
        let e = ObsEvent(
            tsNanos: 123,
            level: .warn,
            subsystem: "lsp",
            message: "override malformed",
            fields: ["path": "/tmp/lsp.json", "code": "42"])
        XCTAssertEqual(e.tsNanos, 123)
        XCTAssertEqual(e.level, .warn)
        XCTAssertEqual(e.subsystem, "lsp")
        XCTAssertEqual(e.message, "override malformed")
        XCTAssertEqual(e.fields["path"], "/tmp/lsp.json")
        XCTAssertEqual(e.fields["code"], "42")
    }

    func testLevelOrderingIsStableForFiltering() {
        // The raw values are a wire contract; assert the ordering the
        // FFI/RPC layer will depend on.
        XCTAssertEqual(ObsLevel.trace.rawValue, 0)
        XCTAssertEqual(ObsLevel.error.rawValue, 4)
        XCTAssertTrue(ObsLevel.trace < ObsLevel.debug)
        XCTAssertTrue(ObsLevel.debug < ObsLevel.info)
        XCTAssertTrue(ObsLevel.info < ObsLevel.warn)
        XCTAssertTrue(ObsLevel.warn < ObsLevel.error)
    }

    func testConvenienceInitStampsTimestamp() {
        let before = ObsClock.nowNanos()
        let e = ObsEvent(level: .info, subsystem: "mcp", message: "hi")
        let after = ObsClock.nowNanos()
        XCTAssertGreaterThan(e.tsNanos, 0)
        XCTAssertGreaterThanOrEqual(e.tsNanos, before)
        XCTAssertLessThanOrEqual(e.tsNanos, after)
        XCTAssertTrue(e.fields.isEmpty)
    }

    func testEventEquatable() {
        let a = ObsEvent(tsNanos: 1, level: .info, subsystem: "git", message: "m")
        let b = ObsEvent(tsNanos: 1, level: .info, subsystem: "git", message: "m")
        let c = ObsEvent(tsNanos: 2, level: .info, subsystem: "git", message: "m")
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
    }

    // MARK: - Ring buffer: ordering + bound + drop-oldest

    func testBufferPreservesChronologicalOrderBeforeWrap() {
        let sink = RingBufferSink(capacity: 8)
        for i in 0..<5 {
            sink.emit(ObsEvent(tsNanos: UInt64(i), level: .info, subsystem: "s", message: "\(i)"))
        }
        let events = sink.snapshotEvents()
        XCTAssertEqual(events.count, 5)
        XCTAssertEqual(events.map(\.message), ["0", "1", "2", "3", "4"])
        XCTAssertEqual(sink.bufferedCount, 5)
        XCTAssertEqual(sink.emittedCount, 5)
    }

    func testBufferIsBoundedAndDropsOldest() {
        let cap = 4
        let sink = RingBufferSink(capacity: cap)
        // Emit well past capacity.
        for i in 0..<10 {
            sink.emit(ObsEvent(tsNanos: UInt64(i), level: .info, subsystem: "s", message: "\(i)"))
        }
        let events = sink.snapshotEvents()
        // Never exceeds capacity.
        XCTAssertEqual(events.count, cap)
        XCTAssertEqual(sink.bufferedCount, cap)
        // Oldest dropped: only the last `cap` survive, in order.
        XCTAssertEqual(events.map(\.message), ["6", "7", "8", "9"])
        // Total ever emitted is tracked separately from retained.
        XCTAssertEqual(sink.emittedCount, 10)
    }

    func testBufferExactlyAtCapacity() {
        let sink = RingBufferSink(capacity: 3)
        for i in 0..<3 {
            sink.emit(ObsEvent(tsNanos: UInt64(i), level: .info, subsystem: "s", message: "\(i)"))
        }
        XCTAssertEqual(sink.snapshotEvents().map(\.message), ["0", "1", "2"])
        // One more wraps exactly once.
        sink.emit(ObsEvent(tsNanos: 3, level: .info, subsystem: "s", message: "3"))
        XCTAssertEqual(sink.snapshotEvents().map(\.message), ["1", "2", "3"])
    }

    func testResetClearsBufferAndCounts() {
        let sink = RingBufferSink(capacity: 4)
        for i in 0..<6 {
            sink.emit(ObsEvent(level: .info, subsystem: "s", message: "\(i)"))
        }
        sink.counter("c", 5, [:])
        sink.gauge("g", 1.0, [:])
        sink.reset()
        XCTAssertTrue(sink.snapshotEvents().isEmpty)
        XCTAssertEqual(sink.bufferedCount, 0)
        XCTAssertEqual(sink.emittedCount, 0)
        XCTAssertEqual(sink.counterValue("c"), 0)
        XCTAssertNil(sink.gaugeValue("g"))
    }

    // MARK: - Counters + gauges

    func testCounterAccumulates() {
        let sink = RingBufferSink(capacity: 4)
        sink.counter("subprocess.spawned", 1, [:])
        sink.counter("subprocess.spawned", 1, [:])
        sink.counter("subprocess.spawned", 3, [:])
        XCTAssertEqual(sink.counterValue("subprocess.spawned"), 5)
    }

    func testCounterConvenienceDefaultDeltaOne() {
        let sink = RingBufferSink(capacity: 4)
        sink.counter("c")
        sink.counter("c")
        XCTAssertEqual(sink.counterValue("c"), 2)
    }

    func testGaugeIsLastWriteWins() {
        let sink = RingBufferSink(capacity: 4)
        sink.gauge("lsp.servers.active", 3, [:])
        sink.gauge("lsp.servers.active", 1, [:])
        XCTAssertEqual(sink.gaugeValue("lsp.servers.active"), 1)
    }

    func testMetricsAreKeyedByNameAndTags() {
        let sink = RingBufferSink(capacity: 4)
        sink.counter("req", 1, ["lang": "swift"])
        sink.counter("req", 2, ["lang": "rust"])
        sink.counter("req", 4, ["lang": "swift"])
        XCTAssertEqual(sink.counterValue("req", ["lang": "swift"]), 5)
        XCTAssertEqual(sink.counterValue("req", ["lang": "rust"]), 2)
        // Tag order must not split a series.
        sink.gauge("m", 1, ["a": "1", "b": "2"])
        sink.gauge("m", 9, ["b": "2", "a": "1"])
        XCTAssertEqual(sink.gaugeValue("m", ["a": "1", "b": "2"]), 9)
    }

    func testSnapshotMetricsRoundTripsShape() {
        let sink = RingBufferSink(capacity: 4)
        sink.counter("c", 7, ["k": "v"])
        sink.gauge("g", 2.5, [:])
        let metrics = sink.snapshotMetrics()
        XCTAssertEqual(metrics.count, 2)
        let counter = metrics.first { $0.kind == .counter }
        let gauge = metrics.first { $0.kind == .gauge }
        XCTAssertEqual(counter?.name, "c")
        XCTAssertEqual(counter?.value, 7)
        XCTAssertEqual(counter?.tags, ["k": "v"])
        XCTAssertEqual(gauge?.name, "g")
        XCTAssertEqual(gauge?.value, 2.5)
    }

    // MARK: - Formatting (the os_log / text-export rendering)

    func testFormatRendersSubsystemLevelAndSortedFields() {
        let e = ObsEvent(
            tsNanos: 1, level: .warn, subsystem: "lsp",
            message: "bad", fields: ["b": "2", "a": "1"])
        // Fields rendered in deterministic sorted-key order.
        XCTAssertEqual(RingBufferSink.format(e), "[lsp] WARN bad {a=1 b=2}")
    }

    func testFormatWithoutFields() {
        let e = ObsEvent(tsNanos: 1, level: .error, subsystem: "grammar", message: "boom")
        XCTAssertEqual(RingBufferSink.format(e), "[grammar] ERROR boom")
    }

    // MARK: - Global install seam

    func testGlobalDefaultsToNoop() {
        Obs.resetToNoop()
        XCTAssertTrue(Obs.shared is NoopObservabilitySink)
        // Emitting against the no-op must not crash.
        Obs.shared.emit(.info, "x", "y")
    }

    func testInstallSwapsSink() {
        let capture = RingBufferSink(capacity: 16)
        Obs.install(capture)
        Obs.shared.emit(.warn, "lsp", "captured")
        XCTAssertEqual(capture.snapshotEvents().map(\.message), ["captured"])
    }

    func testInstallIfNeededRespectsExistingSink() {
        let first = RingBufferSink(capacity: 4)
        Obs.install(first)
        let installed = Obs.installIfNeeded { RingBufferSink(capacity: 4) }
        XCTAssertFalse(installed, "should not clobber an already-installed sink")
        // Over a fresh no-op default it should install.
        Obs.resetToNoop()
        let installed2 = Obs.installIfNeeded { first }
        XCTAssertTrue(installed2)
    }

    // MARK: - Migration smoke: LSP/grammar warnings reach an installed sink

    func testLSPWarningFlowsThroughGlobalSink() {
        let capture = RingBufferSink(capacity: 32)
        Obs.install(capture)
        LSPLog.resetCaptured()
        LSPLog.warn("LSP override malformed JSON: /tmp/lsp.json")
        // Routed to the sink (subsystem "lsp", level warn)…
        let events = capture.snapshotEvents()
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.subsystem, "lsp")
        XCTAssertEqual(events.first?.level, .warn)
        // …and still satisfies the legacy capture seam.
        XCTAssertTrue(LSPLog.captured().contains(where: { $0.contains("malformed") }))
        LSPLog.resetCaptured()
    }

    // MARK: - Thread-safety

    func testConcurrentEmitsAreBoundedAndConsistent() {
        let cap = 256
        let sink = RingBufferSink(capacity: cap)
        let threads = 8
        let perThread = 1_000
        let group = DispatchGroup()
        for t in 0..<threads {
            DispatchQueue.global().async(group: group) {
                for i in 0..<perThread {
                    sink.emit(ObsEvent(
                        level: .info, subsystem: "s",
                        message: "\(t)-\(i)"))
                }
            }
        }
        group.wait()
        // Buffer never exceeds capacity even under concurrent writers…
        XCTAssertEqual(sink.bufferedCount, cap)
        XCTAssertEqual(sink.snapshotEvents().count, cap)
        // …and every emit is counted.
        XCTAssertEqual(sink.emittedCount, UInt64(threads * perThread))
    }

    func testConcurrentCountersSumExactly() {
        let sink = RingBufferSink(capacity: 16)
        let threads = 8
        let perThread = 5_000
        let group = DispatchGroup()
        for _ in 0..<threads {
            DispatchQueue.global().async(group: group) {
                for _ in 0..<perThread {
                    sink.counter("hits", 1, [:])
                }
            }
        }
        group.wait()
        XCTAssertEqual(sink.counterValue("hits"), Double(threads * perThread))
    }

    func testConcurrentMixedOpsDoNotCrash() {
        let sink = RingBufferSink(capacity: 64)
        let group = DispatchGroup()
        for k in 0..<6 {
            DispatchQueue.global().async(group: group) {
                for i in 0..<2_000 {
                    switch i % 3 {
                    case 0: sink.emit(ObsEvent(level: .debug, subsystem: "s", message: "\(k)"))
                    case 1: sink.counter("c", 1, ["k": "\(k)"])
                    default: sink.gauge("g", Double(i), ["k": "\(k)"])
                    }
                }
            }
        }
        group.wait()
        // No assertion on exact values for the mixed test — the point is
        // the lock holds under contention (no crash / no data race under
        // TSan). Sanity: snapshots are internally consistent.
        XCTAssertLessThanOrEqual(sink.snapshotEvents().count, sink.bufferCapacity)
        XCTAssertGreaterThan(sink.snapshotMetrics().count, 0)
    }
}
