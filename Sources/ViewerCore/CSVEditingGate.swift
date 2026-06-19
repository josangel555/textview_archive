import Foundation

/// TSK-711 — feature gate for the in-progress editable-CSV grid. **Default
/// OFF**: the shipping CSV view stays read-only until the full editable grid
/// (later slices: full-grid editing, save-back, column ops) is complete. This
/// gate exists from day one so the foundation slice (the double-click cell
/// editor wired to `EditableCSVModel`) can land dark behind a stable opt-in.
///
/// Two independent opt-ins (either flips it ON), mirroring `RustCSVGate`:
///   1. `UserDefaults` key `MarkdownViewer.experimental.csvEditing == true`
///      (a future Settings toggle; persisted, survives relaunch).
///   2. env var `MDV_CSV_EDIT=1` (per-run override for dev / CI / UI tests).
///
/// SwiftUI-free (lives in ViewerCore) so the gate is host-testable and the UI
/// layer reads ONE predicate.
public enum CSVEditingGate {

    /// Persisted UserDefaults key for the (future) Settings toggle.
    public static let defaultsKey = "MarkdownViewer.experimental.csvEditing"

    /// Per-run env override. `MDV_CSV_EDIT=1` (or `true`) forces ON.
    public static let envVar = "MDV_CSV_EDIT"

    /// Is in-place CSV cell editing enabled for this run? Precedence:
    /// env override (a hard `1`/`true` ON, anything else OFF) → explicit
    /// persisted toggle (either direction) → default OFF.
    public static func isEnabled(
        defaults: UserDefaults = .standard,
        environment: [String: String]? = nil
    ) -> Bool {
        let raw: String?
        if let environment {
            raw = environment[envVar]
        } else if let c = getenv(envVar) {
            raw = String(cString: c)
        } else {
            raw = nil
        }
        if let raw {
            return raw == "1" || raw.lowercased() == "true"
        }
        if defaults.object(forKey: defaultsKey) != nil {
            return defaults.bool(forKey: defaultsKey)
        }
        return false   // default OFF — read-only grid ships until the epic completes
    }
}
