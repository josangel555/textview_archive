import Foundation

/// Feature gate for the notebook (`.ipynb`) cell-list view.
///
/// **Default OFF** — `.ipynb` files keep their current behavior (shown as raw
/// JSON via `TextDisplayView`) until the notebook subsystem is past its
/// foundation slice. This gate flips the experimental cell-list renderer on.
///
/// Two independent opt-ins (either flips it ON):
///   1. `UserDefaults` key `MarkdownViewer.experimental.notebooks == true`
///      (a future Settings toggle; persisted, survives relaunch).
///   2. env var `MDV_NOTEBOOKS=1` (per-run override for CI / `swift run` smoke;
///      wins even if the default is false).
///
/// Mirrors `RustCSVGate`'s shape so the host and any Settings view consult ONE
/// predicate. Lives in ViewerCore (SwiftUI-free) so the routing code can gate
/// without importing the UI layer.
public enum NotebookGate {

    /// Persisted UserDefaults key for the (future) Settings toggle.
    public static let defaultsKey = "MarkdownViewer.experimental.notebooks"

    /// Per-run env override. `MDV_NOTEBOOKS=1` forces ON.
    public static let envVar = "MDV_NOTEBOOKS"

    /// Is the notebook cell-list view enabled for this run? Precedence:
    /// env override → persisted toggle → false.
    public static func isEnabled(
        defaults: UserDefaults = .standard,
        environment: [String: String]? = nil
    ) -> Bool {
        let env = environment ?? ProcessInfo.processInfo.environment
        if let raw = env[envVar] {
            return raw == "1" || raw.lowercased() == "true"
        }
        return defaults.bool(forKey: defaultsKey)
    }

    /// TSK-717 — should `url` render through the notebook cell-list view? True
    /// only for a `.ipynb` file AND when the experimental gate is enabled.
    /// Routing seam for the content view (off by default ⇒ no default-path impact).
    public static func handles(
        _ url: URL,
        defaults: UserDefaults = .standard,
        environment: [String: String]? = nil
    ) -> Bool {
        url.pathExtension.lowercased() == "ipynb"
            && isEnabled(defaults: defaults, environment: environment)
    }
}
