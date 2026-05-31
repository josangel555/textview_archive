import Combine
import Foundation
import SwiftUI
import ViewerCore

/// `@MainActor` UI projection over the core `RingBufferSink`.
///
/// ## Why a poll, not an observe-and-republish
/// `RingBufferSink` is a lock-guarded value aggregator written from
/// unrelated background threads (LSP parse, MCP stdio, grammar dlopen) —
/// it is deliberately **not** an `ObservableObject`. Wiring the sink's
/// every-emit into SwiftUI would re-introduce exactly the
/// republish-amplification regression `LESSONS.md` (REPUB-1, lines
/// ~1140–1184) spent effort killing: a keystroke that emits a trace
/// event would fan a `@Published` change into the view tree. Instead the
/// UI **polls** on a slow timer and republishes a single coarse
/// `version: Int` only when something actually changed. The view tree
/// re-renders at most at the poll rate, never per emit.
///
/// The projection holds the live `RingBufferSink` (the same instance
/// installed into `Obs.shared` at launch) and copies snapshots out of it
/// under the sink's own lock. It owns no business state — it is a pure
/// read-side view onto the sink plus a periodic `ProcessMemory` sample.
@MainActor
public final class ObservabilityProjection: ObservableObject {

    /// Coarse change token. Bumped (and a fresh snapshot published) only
    /// when the sink's emitted-count, metric set, or memory sample
    /// actually moved since the last tick — so an idle app with a paused
    /// log stream stops re-rendering the views.
    @Published public private(set) var version: Int = 0

    /// Last snapshot of the ring buffer (chronological, oldest first).
    @Published public private(set) var events: [ObsEvent] = []

    /// Last snapshot of all metric series.
    @Published public private(set) var metrics: [ObsMetric] = []

    /// Total events ever emitted (incl. evicted) — lets the logs UI show
    /// "showing N of M (oldest dropped)".
    @Published public private(set) var totalEmitted: UInt64 = 0

    /// Ring capacity, for the "N / capacity" readout.
    @Published public private(set) var bufferCapacity: Int = 0

    /// Latest OS memory sample (app footprint + WebKit-helper sum).
    @Published public private(set) var memory: ProcessMemorySample =
        ProcessMemorySample(
            appFootprintBytes: nil,
            webKitHelperBytes: 0,
            webKitHelperCount: 0,
            helpersComplete: true)

    /// The live sink. `nil` when no `RingBufferSink` is installed (e.g.
    /// `Obs.shared` is still the `NoopObservabilitySink` — the views show
    /// an empty/“not installed” state rather than crash).
    private let sink: RingBufferSink?

    /// Poll cadence. 1 Hz keeps the views responsive without the
    /// per-emit cost and matches the ~1 Hz `task_info` sampling cap
    /// (triage-instrumentation.md). The memory sample (which walks every
    /// pid) is gated to run at most this often.
    private let interval: TimeInterval

    private var timer: AnyCancellable?
    private var lastEmittedSeen: UInt64 = 0
    private var lastMetricsHash: Int = 0

    /// - Parameters:
    ///   - sink: the live `RingBufferSink` (pass the instance the host
    ///     installed into `Obs.shared`). `nil` is tolerated.
    ///   - interval: poll cadence in seconds (default 1.0).
    public init(sink: RingBufferSink?, interval: TimeInterval = 1.0) {
        self.sink = sink
        self.interval = interval
    }

    /// Begin polling. Call from `.onAppear`; idempotent. The timer is
    /// torn down in `stop()` / `deinit` so a closed tool window stops
    /// sampling memory.
    public func start() {
        guard timer == nil else { return }
        // Pull an immediate sample so the view isn't blank for one tick.
        tick()
        timer = Timer.publish(every: interval, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.tick() }
    }

    /// Stop polling. Call from `.onDisappear`.
    public func stop() {
        timer?.cancel()
        timer = nil
    }

    /// Clear the ring buffer + metrics (UI "clear" affordance). Bumps
    /// `version` so the views refresh immediately.
    public func clear() {
        sink?.reset()
        lastEmittedSeen = 0
        lastMetricsHash = 0
        tick()
    }

    /// One poll: snapshot the sink + memory, and republish *only* if
    /// something changed.
    private func tick() {
        // Memory sampling is the expensive part (walks every pid); it is
        // gated to the poll cadence and is intentionally on the main
        // actor here because the tool window is a low-frequency,
        // user-opened surface. If profiling ever shows the pid walk
        // stalling the main thread, hop it to a detached task — the
        // sample type is `Sendable`.
        let mem = ProcessMemory.sample()

        guard let sink else {
            // No real sink installed: surface only the memory sample.
            if mem != memory {
                memory = mem
                version &+= 1
            }
            return
        }

        let emitted = sink.emittedCount
        let metricSnapshot = sink.snapshotMetrics()
        let metricsHash = ObservabilityProjection.hash(metricSnapshot)

        let eventsChanged = emitted != lastEmittedSeen
        let metricsChanged = metricsHash != lastMetricsHash
        let memChanged = mem != memory

        guard eventsChanged || metricsChanged || memChanged else { return }

        if eventsChanged {
            events = sink.snapshotEvents()
            totalEmitted = emitted
            bufferCapacity = sink.bufferCapacity
            lastEmittedSeen = emitted
        }
        if metricsChanged {
            metrics = metricSnapshot
            lastMetricsHash = metricsHash
        }
        if memChanged {
            memory = mem
        }
        version &+= 1
    }

    /// Order-independent hash of the metric set so the projection can
    /// detect a changed value without diffing every series. Folds
    /// `(name, value, tag-set)` of each series.
    private static func hash(_ metrics: [ObsMetric]) -> Int {
        var acc = 0
        for m in metrics {
            var h = Hasher()
            h.combine(m.name)
            h.combine(m.value)
            h.combine(m.kind)
            // Tag order independence: XOR per-tag hashes.
            var tagAcc = 0
            for (k, v) in m.tags { tagAcc ^= (k.hashValue ^ v.hashValue) }
            h.combine(tagAcc)
            acc ^= h.finalize()
        }
        return acc
    }
}
