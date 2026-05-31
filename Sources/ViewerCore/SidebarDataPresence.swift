import Foundation

/// Single source of truth for "does this panel have data to show?".
///
/// Extracted from the inline predicates that lived in
/// `SidebarView.panelVisibility` so BOTH the accordion (inside
/// `SidebarView`) and the shoulder rail (outside it) read the same
/// heuristic. If the two read different logic, the rail button's
/// filled-state and the accordion's presence diverge.
///
/// This is `dataPresent` ONLY — the raw heuristic. The explicit
/// user-intent override (`.auto` / `.shown` / `.hidden`) is layered on
/// top by `PanelVisibilityResolver`. Pure-logic, host-testable.
public enum SidebarDataPresence {
    /// Cross-cutting inputs the predicate needs. Booleans rather than
    /// the live models so the evaluator stays pure + trivially testable;
    /// the view layer computes these from `sidebar` / `model`.
    public struct Inputs: Sendable, Equatable {
        public var hasRoot: Bool
        public var hasRepo: Bool
        public var hasLSPLanguage: Bool
        public var claudeHasTranscripts: Bool

        public init(
            hasRoot: Bool = false,
            hasRepo: Bool = false,
            hasLSPLanguage: Bool = false,
            claudeHasTranscripts: Bool = false
        ) {
            self.hasRoot = hasRoot
            self.hasRepo = hasRepo
            self.hasLSPLanguage = hasLSPLanguage
            self.claudeHasTranscripts = claudeHasTranscripts
        }
    }

    /// Data-presence for every panel kind. Mirrors the prior inline
    /// predicates exactly:
    ///   - `.bookmarks` / `.pluginSections`: always present (fixed
    ///     "(empty)" envelope is intentional; a plugin section appears
    ///     regardless of whether a folder is open).
    ///   - `.lspNavigation` / `.lspProblems`: present whenever a root is
    ///     open (they hold cross-file state useful even when the active
    ///     tab isn't an LSP language).
    ///   - `.git` / `.claudeTimeline` / `.lspOutline`: gated on their
    ///     specific data condition AND a root.
    public static func evaluate(_ i: Inputs) -> [SidebarPanelKind: Bool] {
        [
            .files:           i.hasRoot,
            .bookmarks:       true,
            .searchAnywhere:  i.hasRoot,
            .git:             i.hasRoot && i.hasRepo,
            .claudeTimeline:  i.hasRoot && i.claudeHasTranscripts,
            .lspOutline:      i.hasRoot && i.hasLSPLanguage,
            .lspNavigation:   i.hasRoot,
            .lspProblems:     i.hasRoot,
            .pluginSections:  true,
        ]
    }

    /// Convenience: data-presence for a single panel. Avoids building
    /// the whole dictionary when a caller only needs one panel.
    public static func isPresent(_ kind: SidebarPanelKind, _ i: Inputs) -> Bool {
        evaluate(i)[kind] ?? false
    }
}
