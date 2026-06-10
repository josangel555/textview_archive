#if DEBUG
import Foundation

/// TSK-615 body-evaluation probe — DEBUG-only, not compiled into release
/// builds.
///
/// The distributed-re-evaluation residual (TSK-613 after-capture) has no
/// single hot frame — the cost is WIDTH: how many chrome subtrees re-body
/// per model republish. Wall-clock can't rank that (debug VM numbers are
/// noisy run-to-run); COUNTS can. Each top-level chrome view's `body`
/// opens with `let _ = BodyProbe.tick("Name")`, and
/// `ChromeBodyEvalCountTests` realizes the full ContentView tree, fires
/// one interaction of each kind, and pins per-view body-eval bounds — so
/// a future widening (a view re-bodying on a republish it used to skip)
/// fails the host gate with the offending view named.
///
/// `tick` must stay O(1) and allocation-free on the happy path: it runs
/// inside `body` on the main thread for every instrumented view.
@MainActor
public enum BodyProbe {
    public private(set) static var counts: [String: Int] = [:]
    /// Probe is off by default so production DEBUG runs don't pay the
    /// dictionary write per body; tests flip it on around a window.
    public static var enabled = false

    /// Called at the top of an instrumented `body`. Returns a value so it
    /// can sit in a ViewBuilder as `let _ = BodyProbe.tick("X")`.
    @discardableResult
    public static func tick(_ name: String) -> Int {
        guard enabled else { return 0 }
        let next = (counts[name] ?? 0) + 1
        counts[name] = next
        return next
    }

    public static func count(_ name: String) -> Int { counts[name] ?? 0 }

    public static func reset() { counts = [:] }
}
#endif
