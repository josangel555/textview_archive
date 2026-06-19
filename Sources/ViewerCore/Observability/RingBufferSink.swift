import Foundation
import os

/// Default `ObservabilitySink`: a bounded, thread-safe ring buffer of
/// events plus a small counter/gauge registry, with an optional
/// `os.Logger` fan-out so events still show up in `log stream` / Console
/// for live-app field debugging.
///
/// ## Concurrency
/// A single `NSLock` guards all mutable state. Emit is called from
/// unrelated threads (LSP parse, MCP stdio thread, grammar dlopen), none
/// sharing an isolation domain, so an actor would force every emit site
/// to `await` — unacceptable for a fire-and-forget log call from
/// synchronous code. The lock is held only across O(1) buffer/dictionary
/// mutations; the optional `os_log` fan-out happens OUTSIDE the lock so a
/// slow logging subsystem can't serialise unrelated emitters. Marked
/// `@unchecked Sendable` because the lock provides the mutual exclusion
/// the compiler can't prove.
///
/// ## Bounded by construction
/// The event buffer is a fixed-capacity ring: once full, the oldest
/// event is overwritten (drop-oldest). This is a deliberate
/// content-leak containment measure as much as a memory bound — the
/// buffer holds raw `message` strings (LSP config text, file paths), so
/// it must never grow without bound, must stay in-memory, must never be
/// auto-persisted, and must never be exposed through the MCP host
/// (triage-instrumentation.md risk note; PRIORITIZED_PLAN §5 #7).
///
/// ## FFI placeholder
/// This Swift implementation is a stand-in for what becomes a Rust ring
/// buffer the host reads over RPC. The event/metric *records* are
/// FFI-shaped (see `ObsEvent` / `ObsMetric`); this class is not — it is
/// the host-side aggregator that the Rust core eventually replaces.
public final class RingBufferSink: ObservabilitySink, @unchecked Sendable {

    /// Optional `os_log` / `os_signpost` fan-out configuration.
    public struct OSLogFanout: Sendable {
        /// Reverse-DNS subsystem for the `os.Logger` (e.g.
        /// `"com.markdownviewer.MarkdownViewer"`).
        public let subsystem: String
        /// Minimum level to forward to `os_log`. Events below this are
        /// still ring-buffered but not mirrored to the unified log.
        public let minLevel: ObsLevel

        public init(subsystem: String, minLevel: ObsLevel = .info) {
            self.subsystem = subsystem
            self.minLevel = minLevel
        }
    }

    /// Default ring capacity. ~5k entries comfortably covers a session's
    /// LSP/MCP/grammar chatter while bounding worst-case retained bytes.
    public static let defaultCapacity = 5_000

    /// Cardinality cap on distinct metric series (per kind). A high-cardinality
    /// tag (e.g. a unique id per call) would otherwise grow `counters`/`gauges`
    /// without bound; once a kind hits this cap, NEW series are dropped (existing
    /// series still update) and `droppedMetricSeriesCount` increments.
    public static let maxMetricSeries = 4_096

    private let lock = NSLock()
    private let capacity: Int
    private let fanout: OSLogFanout?

    // Ring buffer state. `storage` is preallocated to `capacity`; `count`
    // tracks fill until wrap, `head` is the next write slot.
    private var storage: [ObsEvent?]
    private var head: Int = 0
    private var filled: Int = 0
    /// Monotonic total events ever emitted (including evicted). Lets a UI
    /// detect "you dropped N events" and gives tests an eviction check.
    private var totalEmitted: UInt64 = 0

    // Metric registry. Keyed by a stable string built from name+tags.
    private var counters: [MetricKey: Double] = [:]
    private var gauges: [MetricKey: Double] = [:]
    /// Count of metric series rejected by the cardinality cap (bounded — not
    /// keyed by tags, so it can't itself leak).
    private var droppedMetricSeries: UInt64 = 0

    /// `os.Logger` cache keyed by event subsystem category, so a Logger
    /// is built once per subsystem rather than per emit.
    private var loggers: [String: Logger] = [:]

    public init(
        capacity: Int = RingBufferSink.defaultCapacity,
        fanout: OSLogFanout? = nil
    ) {
        precondition(capacity > 0, "ring capacity must be positive")
        self.capacity = capacity
        self.fanout = fanout
        self.storage = Array(repeating: nil, count: capacity)
    }

    // MARK: - ObservabilitySink

    public func emit(_ event: ObsEvent) {
        // Decide fan-out under the lock (cheap), perform it after release.
        var loggerToUse: Logger?
        lock.lock()
        storage[head] = event
        head = (head + 1) % capacity
        if filled < capacity { filled += 1 }
        totalEmitted &+= 1
        if let fanout, event.level >= fanout.minLevel {
            loggerToUse = logger(for: event.subsystem, subsystem: fanout.subsystem)
        }
        lock.unlock()

        // os_log fan-out OUTSIDE the lock — a stalled logging subsystem
        // must not block other emitters.
        if let loggerToUse {
            let line = RingBufferSink.format(event)
            switch event.level {
            case .trace, .debug:
                loggerToUse.debug("\(line, privacy: .public)")
            case .info:
                loggerToUse.info("\(line, privacy: .public)")
            case .warn:
                loggerToUse.warning("\(line, privacy: .public)")
            case .error:
                loggerToUse.error("\(line, privacy: .public)")
            }
        }
    }

    public func counter(_ name: String, _ delta: Int64, _ tags: [String: String]) {
        let key = MetricKey(name: name, tags: tags)
        lock.lock()
        if counters[key] == nil && counters.count >= Self.maxMetricSeries {
            droppedMetricSeries &+= 1          // cardinality cap: drop new series
        } else {
            counters[key, default: 0] += Double(delta)
        }
        lock.unlock()
    }

    public func gauge(_ name: String, _ value: Double, _ tags: [String: String]) {
        let key = MetricKey(name: name, tags: tags)
        lock.lock()
        if gauges[key] == nil && gauges.count >= Self.maxMetricSeries {
            droppedMetricSeries &+= 1          // cardinality cap: drop new series
        } else {
            gauges[key] = value
        }
        lock.unlock()
    }

    // MARK: - Read API (host-side consumers; never the MCP host)

    /// Snapshot of buffered events in chronological order (oldest first).
    /// Copies out under the lock so callers never see torn state.
    public func snapshotEvents() -> [ObsEvent] {
        lock.lock()
        defer { lock.unlock() }
        guard filled > 0 else { return [] }
        if filled < capacity {
            // Not yet wrapped: slots [0, head) in order.
            return (0..<head).compactMap { storage[$0] }
        }
        // Wrapped: oldest is at `head`, walk forward circularly.
        var out: [ObsEvent] = []
        out.reserveCapacity(filled)
        for i in 0..<capacity {
            let idx = (head + i) % capacity
            if let e = storage[idx] { out.append(e) }
        }
        return out
    }

    /// Number of events currently retained (≤ capacity).
    public var bufferedCount: Int {
        lock.lock(); defer { lock.unlock() }
        return filled
    }

    /// Total events ever emitted, including those evicted by wrap.
    public var emittedCount: UInt64 {
        lock.lock(); defer { lock.unlock() }
        return totalEmitted
    }

    public var bufferCapacity: Int { capacity }

    /// Snapshot of all metric series (counters + gauges).
    public func snapshotMetrics() -> [ObsMetric] {
        lock.lock(); defer { lock.unlock() }
        var out: [ObsMetric] = []
        out.reserveCapacity(counters.count + gauges.count)
        for (key, value) in counters {
            out.append(ObsMetric(
                name: key.name, kind: .counter, value: value, tags: key.tags))
        }
        for (key, value) in gauges {
            out.append(ObsMetric(
                name: key.name, kind: .gauge, value: value, tags: key.tags))
        }
        return out
    }

    /// Current counter value for `(name, tags)`, or 0 if never touched.
    public func counterValue(_ name: String, _ tags: [String: String] = [:]) -> Double {
        let key = MetricKey(name: name, tags: tags)
        lock.lock(); defer { lock.unlock() }
        return counters[key] ?? 0
    }

    /// Current gauge value for `(name, tags)`, or nil if never set.
    public func gaugeValue(_ name: String, _ tags: [String: String] = [:]) -> Double? {
        let key = MetricKey(name: name, tags: tags)
        lock.lock(); defer { lock.unlock() }
        return gauges[key]
    }

    /// Number of metric series rejected by the cardinality cap (test seam +
    /// observability — a non-zero value means high-cardinality tags are leaking
    /// at a call site).
    public var droppedMetricSeriesCount: UInt64 {
        lock.lock(); defer { lock.unlock() }
        return droppedMetricSeries
    }

    /// Drop all buffered events and metrics. Test seam (and a future
    /// "clear log" UI affordance).
    public func reset() {
        lock.lock(); defer { lock.unlock() }
        for i in storage.indices { storage[i] = nil }
        head = 0
        filled = 0
        totalEmitted = 0
        counters.removeAll()
        gauges.removeAll()
        droppedMetricSeries = 0
    }

    // MARK: - Internals

    /// MUST be called with `lock` held.
    private func logger(for category: String, subsystem: String) -> Logger {
        if let existing = loggers[category] { return existing }
        let made = Logger(subsystem: subsystem, category: category)
        loggers[category] = made
        return made
    }

    /// Single-line human-readable rendering of an event (for os_log and
    /// any text export). Mirrors the legacy stderr formats so existing
    /// grep habits keep working.
    static func format(_ event: ObsEvent) -> String {
        var line = "[\(event.subsystem)] \(event.level.label) \(event.message)"
        if !event.fields.isEmpty {
            // Deterministic ordering for stable output / testability.
            let rendered = event.fields
                .sorted { $0.key < $1.key }
                .map { "\($0.key)=\($0.value)" }
                .joined(separator: " ")
            line += " {\(rendered)}"
        }
        return line
    }

    /// Stable composite key for a metric series. Tags are folded into a
    /// canonical sorted string so `[a:1,b:2]` and `[b:2,a:1]` collide.
    private struct MetricKey: Hashable {
        let name: String
        let tags: [String: String]

        static func == (lhs: MetricKey, rhs: MetricKey) -> Bool {
            lhs.name == rhs.name && lhs.tags == rhs.tags
        }

        func hash(into hasher: inout Hasher) {
            hasher.combine(name)
            // Order-independent tag hashing.
            var acc = 0
            for (k, v) in tags { acc ^= (k.hashValue ^ v.hashValue) }
            hasher.combine(acc)
        }
    }
}
