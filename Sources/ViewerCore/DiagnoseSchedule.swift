import Foundation

/// TSK-493 — scheduling math for the `--diagnose` view-tree dump.
///
/// The dump used to fire unconditionally two run-loop ticks after launch,
/// which races `MDV_UI_SCENE` (applied after its own delay, default 0.6s):
/// a scene-driven state could never be captured by the dump. The harness
/// now sets `MDV_DIAGNOSE_DELAY` to sequence dump-after-scene.
///
/// Pure parse so the host suite pins the contract; `main.swift` wires the
/// resulting delay into a `DispatchQueue.asyncAfter`.
public enum DiagnoseSchedule {

    /// A typo'd huge delay must not hang a harness run forever.
    public static let maxDelay: Double = 30

    /// Parse `MDV_DIAGNOSE_DELAY`. nil / non-numeric / non-positive → 0
    /// (the legacy immediate dump); values are capped at `maxDelay`.
    public static func delay(_ raw: String?) -> Double {
        guard let raw, let v = Double(raw), v > 0 else { return 0 }
        return min(v, maxDelay)
    }
}
