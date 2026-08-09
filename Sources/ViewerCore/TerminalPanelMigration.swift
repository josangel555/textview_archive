import Foundation

/// One-shot migration of the LEGACY special-cased terminal pane state
/// (`TerminalPaneLayout.isOpen` / `paneEdge`) into the unified panel model
/// (owner rework 2026-08-09: the terminal is a regular tool window —
/// `SidebarPanelKind.terminal`). A user who had the pane open keeps it
/// open in the same dock after updating; a user who never opened it sees
/// no change (the panel defaults hidden on the bottom rail).
///
/// Pure-read + explicit apply: `pendingMigration` only READS; the caller
/// (`PanelLayoutStore.init`) applies the result to its assignment/
/// overrides and stamps `markMigrated` so this runs exactly once.
public enum TerminalPanelMigration {
    /// Stamped after the migration has been applied. Pinned by test.
    public static let markerKey = "MarkdownViewer.terminal.migratedToPanel"
    /// The legacy keys, spelled literally — the fields they backed are
    /// gone from `TerminalPaneLayout`, but old defaults still carry them.
    public static let legacyOpenKey = "MarkdownViewer.terminal.isOpen"
    public static let legacyPaneEdgeKey = "MarkdownViewer.terminal.paneEdge"

    public struct Result: Equatable, Sendable {
        /// Where the legacy pane was docked (legacy raw values are a
        /// subset-equal spelling of `PanelEdge`'s, so they map directly;
        /// unknown/absent → `.bottom`, the classic home).
        public let edge: PanelEdge
        /// Whether the pane was open (→ force the panel `.shown`).
        public let shown: Bool
    }

    /// The legacy state to migrate, or nil when already migrated / no
    /// legacy state exists (fresh install).
    public static func pendingMigration(in defaults: UserDefaults) -> Result? {
        guard !defaults.bool(forKey: markerKey) else { return nil }
        guard defaults.object(forKey: legacyOpenKey) != nil else { return nil }
        let edge = defaults.string(forKey: legacyPaneEdgeKey)
            .flatMap(PanelEdge.init(rawValue:)) ?? .bottom
        return Result(edge: edge, shown: defaults.bool(forKey: legacyOpenKey))
    }

    public static func markMigrated(in defaults: UserDefaults) {
        defaults.set(true, forKey: markerKey)
    }
}
