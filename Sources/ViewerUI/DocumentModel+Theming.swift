import AppKit
import SwiftUI
import ViewerCore

// Active-theme derivation (TSK-1110 SRP slice; TSK-641) — the computed views over
// the `themeOverride` / `selectedThemeID` stored state (which stays on
// DocumentModel). All read-only derivations, no stored state, no visibility
// widening. Behavior-preserving move out of DocumentModel.swift.
extension DocumentModel {

    /// The active definition when a catalog theme is selected.
    public var activeThemeDefinition: ThemeDefinition? {
        guard let id = selectedThemeID else { return nil }
        return ThemeStore.shared.all().first { $0.id == id }
    }

    public var activeTheme: SyntaxTheme {
        if let def = activeThemeDefinition { return SyntaxTheme(from: def) }
        if let o = themeOverride { return SyntaxTheme.named(o) }
        return SyntaxTheme.resolved(forAppearance: NSApp?.effectiveAppearance)
    }

    /// TSK-641 (editor surface): the CM6 palette of the SELECTED catalog
    /// theme, or nil when no theme is selected (the editor then keeps the
    /// TSK-602 appearance-keyed legacy pair). Derived, not stored — a
    /// selectedThemeID change republishes and the editor coordinator's
    /// palette dedupe decides whether a setTheme actually ships.
    public var activeThemeCMPalette: [String: String]? {
        activeThemeDefinition.map { SyntaxTheme(from: $0).cmPalette }
    }

    /// The rendered view's extra stylesheet: the mermaid shim always, plus
    /// the active theme's token override when a catalog theme is selected.
    /// Pure composition — unit-tested; both renderPage sites use it.
    public var themedExtraStylesheet: String {
        guard let def = activeThemeDefinition else { return MermaidBundle.shimCSS }
        // pageCSS re-themes the reading page (bg/prose); tokCSS re-themes the
        // syntax tokens + code surface. nil theme → shim only (system-following).
        return MermaidBundle.shimCSS + "\n" + def.pageCSS() + "\n" + def.tokCSS()
    }
}
