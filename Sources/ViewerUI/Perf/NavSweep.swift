import Foundation
import ViewerCore

/// TSK-603 — scripted navigation-interaction sweep for VM profiling.
///
/// Drives the common navigation interactions the owner reports as slow —
/// tab switch (every open tab, the lazy-materialize path included),
/// sidebar toggle, view-mode toggle — against a live `DocumentModel`,
/// wrapping each model call in a `PerfSignpost` `interact` interval.
///
/// The intervals are trace ANCHORS, not the measurement itself: they
/// bound the synchronous part of each interaction; the SwiftUI
/// re-render each one triggers shows up in the Time Profiler samples
/// immediately after the interval. `interactionDelayNanos` spaces the
/// interactions (~6/s at the default) so each render burst is separable
/// in the capture. Tests run with `0` to stay instant.
///
/// Invoked by the `nav-sweep` script verb (whole sweep inside ONE verb,
/// mirroring `resize-sweep`, so per-step snapshot artifacts don't
/// pollute the capture) and runnable headless for behavior tests.
@MainActor
public enum NavSweep {

    /// Run `cycles` sweeps. Each cycle: select every open tab in order,
    /// toggle the sidebar twice (off/on), toggle the view mode twice
    /// (there and back). Restores the originally-selected tab at the end
    /// so the sweep is state-neutral apart from lazy-tab materialization.
    ///
    /// - Returns: number of interactions performed (for logs/tests).
    @discardableResult
    public static func run(
        model: DocumentModel,
        cycles: Int,
        interactionDelayNanos: UInt64 = 150_000_000
    ) async -> Int {
        var performed = 0
        let originalIndex = model.tabs.selectedIndex
        for _ in 0..<max(1, cycles) {
            for index in model.tabs.tabs.indices {
                let token = PerfSignpost.begin(.interact, "navSweep.tabSwitch")
                model.selectTab(at: index)
                PerfSignpost.end(token)
                performed += 1
                await pause(interactionDelayNanos)
            }
            for _ in 0..<2 {
                let token = PerfSignpost.begin(.interact, "navSweep.sidebarToggle")
                model.sidebar.toggleVisibility()
                PerfSignpost.end(token)
                performed += 1
                await pause(interactionDelayNanos)
            }
            for _ in 0..<2 {
                let token = PerfSignpost.begin(.interact, "navSweep.viewToggle")
                model.toggleViewMode()
                PerfSignpost.end(token)
                performed += 1
                await pause(interactionDelayNanos)
            }
        }
        if let originalIndex {
            model.selectTab(at: originalIndex)
        }
        return performed
    }

    private static func pause(_ nanos: UInt64) async {
        guard nanos > 0 else { return }
        try? await Task.sleep(nanoseconds: nanos)
    }
}
