import Foundation

/// TSK-1488 — the PER-INTERACTION felt-perf measurement layer. The existing
/// window-level `FrameStats` (fps / hitch / isJanky) answers "is the app janky
/// right now"; this answers "which INTERACTION was janky, and by how much" —
/// per-interaction frame-duration percentiles graded against a per-kind budget,
/// so lag is caught by numbers not vibes (the wishlist "flag <60fps
/// interactions"). Pure + host-testable; the live CADisplayLink feed, the on-screen
/// debug HUD, and the `vm-profile.sh` capture are the render/VM tail.

/// Nearest-rank percentiles over a set of per-frame durations (milliseconds).
public struct FramePercentiles: Equatable, Sendable {
    public let count: Int
    public let p50: Double
    public let p95: Double
    public let p99: Double
    public let worst: Double

    public init(count: Int, p50: Double, p95: Double, p99: Double, worst: Double) {
        self.count = count; self.p50 = p50; self.p95 = p95; self.p99 = p99; self.worst = worst
    }

    /// Compute percentiles from frame durations (ms). Empty ⇒ all zero. Uses the
    /// nearest-rank method: for percentile `p`, the value at rank `ceil(p/100·n)`
    /// (1-based) — deterministic, no interpolation, matches how hitch budgets read.
    public static func compute(frameDurationsMs durations: [Double]) -> FramePercentiles {
        guard !durations.isEmpty else {
            return FramePercentiles(count: 0, p50: 0, p95: 0, p99: 0, worst: 0)
        }
        let sorted = durations.sorted()
        func pct(_ p: Double) -> Double {
            let rank = Int((p / 100.0 * Double(sorted.count)).rounded(.up))
            let idx = min(max(rank - 1, 0), sorted.count - 1)
            return sorted[idx]
        }
        return FramePercentiles(
            count: sorted.count, p50: pct(50), p95: pct(95), p99: pct(99),
            worst: sorted[sorted.count - 1])
    }
}

/// A user interaction whose frame timeline is worth grading against a budget.
public enum InteractionKind: String, CaseIterable, Sendable {
    case openFile
    case switchTab
    case paletteKeystroke
    case searchScroll
    case renderUpdate
    case uiNavigation

    /// The p95 FRAME-DURATION budget (ms) for a "smooth" interaction. Interactions
    /// expected to stay at 60fps (typing, scrolling, nav) budget one frame
    /// (16.7ms); a content swap (tab switch, re-render, file open) may drop a
    /// frame or two. Exceeding p95 is what the HUD flags.
    public var p95BudgetMs: Double {
        switch self {
        case .paletteKeystroke, .searchScroll, .uiNavigation: return 16.7   // 60fps
        case .switchTab, .renderUpdate:                       return 33.3   // 1 dropped frame ok
        case .openFile:                                       return 50.0   // brief content-load hitch
        }
    }

    public var label: String {
        switch self {
        case .openFile:         return "Open file"
        case .switchTab:        return "Switch tab"
        case .paletteKeystroke: return "Palette keystroke"
        case .searchScroll:     return "Search scroll"
        case .renderUpdate:     return "Render update"
        case .uiNavigation:     return "UI navigation"
        }
    }
}

/// A completed interaction span: its frame percentiles + the budget verdict.
public struct InteractionSpan: Equatable, Sendable {
    public let kind: InteractionKind
    public let percentiles: FramePercentiles

    public init(kind: InteractionKind, percentiles: FramePercentiles) {
        self.kind = kind; self.percentiles = percentiles
    }

    /// True when the p95 frame during this interaction blew the kind's budget —
    /// i.e. the interaction was felt as janky. `count == 0` never exceeds (nothing
    /// was measured).
    public var exceedsBudget: Bool {
        percentiles.count > 0 && percentiles.p95 > kind.p95BudgetMs
    }
}

/// Records per-interaction frame timelines and keeps a rolling per-kind history.
/// `begin(kind)` → `recordFrame(ms)`* → `end()` closes a span. Not thread-safe by
/// design — it's fed from the main-actor display-link tick; host tests drive it
/// directly. Env-gated for production arming via `isEnabled(env:)` (MDV_PERF_HUD).
public final class InteractionProfiler {

    /// Rolling number of spans kept PER KIND for the HUD/dump.
    public let historyDepth: Int

    private var current: (kind: InteractionKind, frames: [Double])?
    private var history: [InteractionKind: [InteractionSpan]] = [:]

    public init(historyDepth: Int = 20) {
        self.historyDepth = max(1, historyDepth)
    }

    /// The HUD is armed only when `MDV_PERF_HUD` is set to a non-"0" value.
    public static func isEnabled(env: String?) -> Bool {
        guard let env else { return false }
        return env != "0" && !env.isEmpty
    }

    /// Open a span for `kind`. A still-open span is discarded (a new interaction
    /// superseded it before it ended) so a dropped `end()` can't corrupt the next.
    public func begin(_ kind: InteractionKind) {
        current = (kind, [])
    }

    /// Record one frame's duration (ms) against the open span. No-op if none open.
    public func recordFrame(ms: Double) {
        guard current != nil, ms >= 0 else { return }
        current?.frames.append(ms)
    }

    /// Close the open span, append it to the per-kind rolling history (capped at
    /// `historyDepth`), and return it. nil when no span was open.
    @discardableResult
    public func end() -> InteractionSpan? {
        guard let (kind, frames) = current else { return nil }
        current = nil
        let span = InteractionSpan(
            kind: kind, percentiles: FramePercentiles.compute(frameDurationsMs: frames))
        var kindHistory = history[kind] ?? []
        kindHistory.append(span)
        if kindHistory.count > historyDepth {
            kindHistory.removeFirst(kindHistory.count - historyDepth)
        }
        history[kind] = kindHistory
        return span
    }

    /// The rolling spans recorded for `kind` (oldest-first).
    public func spans(for kind: InteractionKind) -> [InteractionSpan] {
        history[kind] ?? []
    }

    /// The most recent span per kind that BLEW its budget — the "these felt janky"
    /// set the HUD/agent reads.
    public func overBudgetSpans() -> [InteractionSpan] {
        InteractionKind.allCases.compactMap { history[$0]?.last(where: { $0.exceedsBudget }) }
    }

    /// A compact, human/agent-readable dump: one line per kind with a recorded
    /// span, showing p50/p95/worst vs budget and a ⚠️ marker when over budget.
    public func dump() -> String {
        let lines = InteractionKind.allCases.compactMap { kind -> String? in
            guard let last = history[kind]?.last, last.percentiles.count > 0 else { return nil }
            let p = last.percentiles
            let flag = last.exceedsBudget ? " ⚠️ OVER" : ""
            return String(
                format: "%@: p50 %.1f  p95 %.1f  worst %.1f  (budget %.1f ms)%@",
                kind.label, p.p50, p.p95, p.worst, kind.p95BudgetMs, flag)
        }
        return lines.isEmpty ? "InteractionProfiler: no spans recorded" : lines.joined(separator: "\n")
    }
}
