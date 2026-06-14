import Foundation
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

    private var timer: Timer?
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

    private func sampleNow() {
        appFootprintBytes = ProcessMemory.appFootprintBytes()
    }
}
