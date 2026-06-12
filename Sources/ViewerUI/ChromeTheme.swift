import SwiftUI
import AppKit
import ViewerCore

/// TSK-641 stage 4 — the CHROME surface of the theme engine.
///
/// `Palette`'s main-surface accessors (`textBackground`, `windowBackground`,
/// `sidebarPanelBackground`) consult `ChromeTheme.current` before falling
/// back to the system dynamic colors. `DocumentModel` sets `current` when
/// `selectedThemeID` changes (and at init); the same `@Published` change
/// re-bodies the chrome views, so they read the new values on that pass.
/// nil = no theme selected = system-native chrome, byte-identical to the
/// pre-theming behavior.
///
/// The long tail of SEMANTIC colors (labels, separators, selection) stays
/// system-native deliberately — that's the macOS-citizen look the ticket
/// scopes; only the four main surfaces follow the theme.
@MainActor
enum ChromeTheme {
    /// The active theme's chrome colors, or nil for system-native.
    static var current: ChromeColors?
}

/// Pre-resolved SwiftUI `Color`s for the themed chrome surfaces. Computed
/// ONCE per theme change — `Palette`'s accessors hand these out directly,
/// preserving Palette's no-per-call-allocation contract for per-cell/row
/// builders.
struct ChromeColors {
    let textBackground: Color
    let windowBackground: Color
    let sidebarPanelBackground: Color

    /// Derive the chrome surfaces from a theme definition. Explicit chrome
    /// slots win; the fallbacks keep every theme coherent without them:
    /// sidebar/content ← `background`, bars + panel cards ←
    /// `gutterBackground` (the off-background tone every theme carries).
    /// A malformed slot degrades to its fallback, never to a crash.
    init(from def: ThemeDefinition) {
        let bg = ThemeColor.parse(def.background) ?? .textBackgroundColor
        let off = ThemeColor.parse(def.gutterBackground) ?? bg
        textBackground = Color(
            nsColor: def.sidebarBackground.flatMap(ThemeColor.parse) ?? bg)
        windowBackground = Color(
            nsColor: def.barBackground.flatMap(ThemeColor.parse) ?? off)
        sidebarPanelBackground = Color(
            nsColor: def.panelBackground.flatMap(ThemeColor.parse) ?? off)
    }
}
