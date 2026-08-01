import Foundation

/// I-04 (owner intake 2026-08-01): "indent markers on a file detected as 4SP
/// are 2 spaces apart." The status bar DETECTED the file's indentation
/// (`RustIndentAdapter`) but nothing plumbed it into the editor — the CM6
/// `indentUnit` facet (which drives the indent-guide pitch, Tab inserts, and
/// indent commands) always used the GLOBAL Settings preference (default
/// 2-space). This parser turns the detector's display string into a
/// `CMIndentation` so `EditorCoordinator` can apply a per-tab override:
/// the file's own indent beats the global default when confidently detected.
extension CMIndentation {

    /// Parse `RustIndentAdapter.detect`'s display string — `"Spaces (N)"`,
    /// `"Tabs"`, or `"—"` (no/unknown). Returns nil when there is nothing
    /// confident to override with. `tabWidth` supplies the display width for
    /// a tabs-file (the detector reports style, not width).
    static func parseDetected(_ display: String, tabWidth: Int = 4) -> CMIndentation? {
        if display == "Tabs" {
            return .tabs(width: max(1, min(16, tabWidth)))
        }
        guard display.hasPrefix("Spaces ("), display.hasSuffix(")"),
              let n = Int(display.dropFirst("Spaces (".count).dropLast()),
              (1...16).contains(n)
        else { return nil }
        return .spaces(n)
    }
}
