import Foundation

/// Pure width schedule for the `resize-sweep` script verb (TSK-592).
///
/// A profiling capture needs the window to resize CONTINUOUSLY while the
/// trace records, without the script runner's per-step snapshot landing
/// between frames — so the whole sweep runs inside one verb, and this
/// type owns the math the verb animates: a triangle wave from `minW` out
/// to `maxW` and back across `steps` increments.
///
/// Pure + host-testable; the AppKit side (`setFrame` per tick) lives in
/// `ScriptRunner.runScriptStep`.
public enum ResizeSweep {
    /// Width for increment `i` of `steps` (inclusive endpoints): i=0 →
    /// `minW`, i=steps/2 → `maxW`, i=steps → `minW`. Degenerate inputs
    /// clamp rather than trap (steps < 1 behaves as a single hold at
    /// `minW`; reversed bounds are swapped).
    public static func width(at i: Int, minW: Double, maxW: Double, steps: Int) -> Double {
        let lo = min(minW, maxW)
        let hi = max(minW, maxW)
        guard steps >= 1 else { return lo }
        let t = Double(min(max(i, 0), steps)) / Double(steps)
        let phase = t < 0.5 ? t * 2 : (1 - t) * 2
        return lo + (hi - lo) * phase
    }
}
