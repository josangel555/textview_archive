import Foundation

/// Per-symbol delta between two `FlameProfile`s — the data model behind a
/// **differential flame graph** / memory-diff view (TSK-715). Compares a
/// `baseline` profile against an `after` profile and reports, for every symbol,
/// how its self-cost changed. This is the classic "what got slower / what
/// allocated more between two snapshots" answer:
///   - positive `delta` (grew) → conventionally drawn RED,
///   - negative `delta` (shrank) → conventionally drawn BLUE/green.
///
/// Pure logic, host-testable. Built on `FlameProfile.hotFrames`, so it works
/// equally for CPU sample profiles and heap/byte profiles (the model is
/// unit-agnostic), which is why one engine serves both flame-chart regression
/// diffs and memory diffs.
public struct FlameProfileDiff: Equatable, Sendable {

    /// One symbol's change between the two profiles.
    public struct Row: Equatable, Sendable, Identifiable {
        public let name: String
        /// Total self-weight for this symbol in the baseline profile (0 if new).
        public let baselineSelf: Int64
        /// Total self-weight for this symbol in the after profile (0 if gone).
        public let afterSelf: Int64
        public var id: String { name }

        /// `after − baseline`. Positive = grew, negative = shrank.
        public var delta: Int64 { afterSelf - baselineSelf }
        /// Symbol present only in `after` (a regression's new cost).
        public var isAdded: Bool { baselineSelf == 0 && afterSelf > 0 }
        /// Symbol present only in `baseline` (cost that disappeared).
        public var isRemoved: Bool { afterSelf == 0 && baselineSelf > 0 }

        public init(name: String, baselineSelf: Int64, afterSelf: Int64) {
            self.name = name
            self.baselineSelf = baselineSelf
            self.afterSelf = afterSelf
        }
    }

    /// Every symbol that appears in either profile, sorted by the absolute
    /// magnitude of its `delta` descending (biggest movers first), ties broken
    /// by name. Symbols with `delta == 0` are included only when their weight
    /// is non-zero in both (unchanged-but-present) — see `changedRows`.
    public let rows: [Row]
    /// `after.totalWeight − baseline.totalWeight` — the net change overall.
    public let totalDelta: Int64

    public init(rows: [Row], totalDelta: Int64) {
        self.rows = rows
        self.totalDelta = totalDelta
    }

    /// Rows whose cost actually moved (`delta != 0`), biggest mover first.
    public var changedRows: [Row] { rows.filter { $0.delta != 0 } }
}

public extension FlameProfile {

    /// Diff `self` (treated as the BASELINE / "before") against `after`,
    /// rolling each symbol's self-weight across all call paths (via
    /// `hotFrames`) and reporting the per-symbol delta.
    func diff(against after: FlameProfile) -> FlameProfileDiff {
        var base: [String: Int64] = [:]
        for h in hotFrames() { base[h.name] = h.selfWeight }
        var now: [String: Int64] = [:]
        for h in after.hotFrames() { now[h.name] = h.selfWeight }

        let names = Set(base.keys).union(now.keys)
        let rows = names
            .map { name in
                FlameProfileDiff.Row(
                    name: name,
                    baselineSelf: base[name] ?? 0,
                    afterSelf: now[name] ?? 0)
            }
            .sorted {
                let a = abs($0.delta), b = abs($1.delta)
                return a != b ? a > b : $0.name < $1.name
            }
        return FlameProfileDiff(
            rows: rows,
            totalDelta: after.totalWeight - totalWeight)
    }
}
