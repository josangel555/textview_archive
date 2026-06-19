import Foundation
import SwiftUI
import ViewerCore

/// Status-bar memory readout (TSK-366).
///
/// Two pieces: a **pure formatter** (`StatusBarMemory`, host-testable) and a
/// **cheap always-on sampler** (`StatusBarMemorySampler`).
///
/// Honesty + perf, deliberately: the headline is the app's own
/// `phys_footprint` — a single `task_info(TASK_VM_INFO)` syscall on self, no
/// process-walk — so it is safe to sample continuously while the (always-
/// visible) status bar is shown. There is NO honest per-tab RSS for a
/// `WKWebView` app (resident memory lives in shared XPC helpers with no pid;
/// see `ProcessMemory`), so the per-tab figure is the loaded document's
/// content-byte PROXY, shown only in the tooltip and labelled as such. The
/// expensive WebKit-helper pid-walk stays in the opt-in Memory tool window
/// (`ObservabilityProjection`) — the status bar never imposes a per-process
/// scan on every user.
enum StatusBarMemory {

    /// Build the chip label + tooltip.
    ///
    /// - `appFootprintBytes`: `nil` (the `task_info` call failed) renders "—"
    ///   rather than a fabricated 0.
    /// - `tabContentBytes`: `nil` omits the per-tab line from the tooltip.
    static func format(
        appFootprintBytes: UInt64?,
        tabContentBytes: Int?
    ) -> (label: String, tooltip: String) {
        let label = appFootprintBytes.map(ByteFormat.mib) ?? "—"
        var tooltip = "App memory — phys_footprint of the main process"
            + " (excludes the shared WebKit helper processes)."
        if let tb = tabContentBytes, tb >= 0 {
            tooltip += " This tab's loaded content: \(ByteFormat.human(tb))"
                + " — a byte proxy, not the tab's RSS (a WKWebView tab has no"
                + " honest per-tab memory)."
        }
        tooltip += " Open the Memory tool window for the WebKit-helper breakdown."
        return (label, tooltip)
    }
}

/// Samples ONLY `ProcessMemory.appFootprintBytes()` (one cheap `task_info`
/// syscall — microseconds, no allocation, no pid-walk) at a modest cadence, so
/// the always-visible status bar can show a live app-memory figure without the
/// per-process scan the WebKit-helper sum requires. `@MainActor` because it
/// drives a SwiftUI `@Published`; the timer is owned + invalidated by the view
/// lifecycle (`start()`/`stop()`).
@MainActor
final class StatusBarMemorySampler: ObservableObject {
    @Published private(set) var appFootprintBytes: UInt64?

    /// `nonisolated(unsafe)` so the nonisolated `deinit` can read it to
    /// invalidate (see the deinit note). The class is `@MainActor`, and every
    /// non-deinit access goes through main, so the unsafe escape is confined
    /// to teardown.
    private nonisolated(unsafe) var timer: Timer?
    private let interval: TimeInterval

    init(interval: TimeInterval = 1.5) {
        self.interval = interval
    }

    func start() {
        guard timer == nil else { return }
        sampleNow()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sampleNow() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// L-mem backstop (M14, TSK-989): `start()` schedules a repeating `Timer`
    /// on the run loop. The block captures `[weak self]`, so the timer does
    /// NOT retain the sampler — which means this `deinit` CAN run while the
    /// timer is still scheduled and live on the run loop. Without invalidating
    /// it here, that timer keeps firing `self?.sampleNow()` (a no-op now that
    /// self is gone) every `interval` FOREVER — a leaked run-loop source.
    /// `stop()` is the normal path but it is wired solely to the chip view's
    /// `onDisappear` (StatusBarMemoryChip), so any teardown that skips that
    /// (future caller, view-graph quirk) would otherwise leak. The deinit is
    /// the unconditional backstop.
    deinit {
        timer?.invalidate()
    }

    /// Test seam (M14, TSK-989): the scheduled timer, so a host test can take
    /// a reference, drop the sampler WITHOUT calling `stop()`, and assert the
    /// deinit invalidated it (`timer.isValid == false`). Not for production use.
    var timerForTesting: Timer? { timer }

    private func sampleNow() {
        ingest(ProcessMemory.appFootprintBytes())
    }

    /// Change-gated publish. `@Published` fires `objectWillChange` on EVERY
    /// assignment (it is not Equatable-gated), so re-writing the same byte count
    /// every 1.5 s would re-body the whole StatusBar even when memory is flat —
    /// a forever-idle re-render (perf audit 2026-06-14, finding #4). Skip the
    /// write when unchanged. Internal so a host test can drive it without a timer.
    func ingest(_ value: UInt64?) {
        guard value != appFootprintBytes else { return }
        appFootprintBytes = value
    }
}

/// The status-bar memory chip as its OWN view (TSK-366 fix / perf audit #4).
/// Owning the `@StateObject` sampler HERE means the 1.5s tick re-bodies only
/// this chip — never the whole `StatusBar` (its git chip + every metric). That
/// restores the narrow-observation invariant `ChromeBodyEvalCountTests` pins
/// (StatusBar must not re-body for reasons orthogonal to its own data flow).
/// `tabContentBytes` + `fontSize` are passed in, so the chip doesn't observe
/// the model — the parent re-creates it (cheaply) when those change.
struct StatusBarMemoryChip: View {
    let tabContentBytes: Int?
    let fontSize: CGFloat
    @StateObject private var sampler = StatusBarMemorySampler()

    var body: some View {
        let fmt = StatusBarMemory.format(
            appFootprintBytes: sampler.appFootprintBytes,
            tabContentBytes: tabContentBytes)
        HStack(spacing: 3) {
            Text("Mem")
                .font(.system(size: fontSize, weight: .medium))
                .foregroundStyle(.secondary)
            Text(fmt.label)
                .font(.system(size: fontSize, design: .monospaced))
                .foregroundStyle(.primary)
        }
        .fixedSize()
        .help(fmt.tooltip)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Memory: \(fmt.label). \(fmt.tooltip)")
        .accessibilityIdentifier("mdv.statusBar.memory")
        .onAppear { sampler.start() }
        .onDisappear { sampler.stop() }
    }
}
