import AppKit
import SwiftUI

/// Static palette of `Color(nsColor:)` wrappers around AppKit's
/// dynamic system colors. `Color(nsColor:)` itself does not cache —
/// every call snapshots the dynamic color into a fresh wrapper.
/// In a per-cell / per-row builder (CSV table, SQLite results,
/// gutter Canvas, tab bar, sidebar rows) those allocations multiply
/// across redraws.
///
/// All callers should reach for `Palette.X` instead of constructing
/// a new `Color(nsColor: .X)`. The values stay dynamic because
/// `NSColor.controlBackgroundColor` etc. ARE dynamic at draw time;
/// SwiftUI re-resolves them on appearance changes.
enum Palette {
    // TSK-641 stage 4: the three MAIN chrome surfaces consult the selected
    // theme (`ChromeTheme.current`) before the system dynamic color. The
    // values stay pre-resolved `Color`s either way (no per-call NSColor →
    // Color wrapping — the allocation contract above holds). Everything
    // else in this palette stays system-native deliberately.
    @MainActor
    static var windowBackground: Color {
        ChromeTheme.current?.windowBackground ?? systemWindowBackground
    }
    @MainActor
    static var textBackground: Color {
        ChromeTheme.current?.textBackground ?? systemTextBackground
    }

    private static let systemWindowBackground = Color(nsColor: .windowBackgroundColor)
    private static let systemTextBackground   = Color(nsColor: .textBackgroundColor)

    static let controlBackground  = Color(nsColor: .controlBackgroundColor)
    static let separator          = Color(nsColor: .separatorColor)
    static let underPageBackground = Color(nsColor: .underPageBackgroundColor)
    static let selectedContentBackground = Color(nsColor: .selectedContentBackgroundColor)
    static let labelColor         = Color(nsColor: .labelColor)
    static let secondaryLabel     = Color(nsColor: .secondaryLabelColor)
    static let tertiaryLabel      = Color(nsColor: .tertiaryLabelColor)

    /// Background swatch for sidebar accordion panels (BOOKMARKS,
    /// SEARCH, GIT, CLAUDE, OUTLINE, etc.). One step away from
    /// `Palette.textBackground` so each panel reads as a distinct
    /// card against the sidebar's outer container background, but
    /// not so dark it feels like a heavy card.
    ///
    /// Built as a dynamic `NSColor` so it re-resolves on light /
    /// dark mode switches. The chosen swatch is intentionally very
    /// light grey in light mode (a hair off the sidebar bg) and a
    /// slightly elevated dark grey in dark mode.
    @MainActor
    static var sidebarPanelBackground: Color {
        ChromeTheme.current?.sidebarPanelBackground ?? systemSidebarPanelBackground
    }

    private static let systemSidebarPanelBackground = Color(nsColor: NSColor(name: nil) { appearance in
        let isDark = appearance.bestMatch(from: [.darkAqua, .vibrantDark, .accessibilityHighContrastDarkAqua, .accessibilityHighContrastVibrantDark]) != nil
        return isDark
            ? NSColor(white: 0.13, alpha: 1.0)
            : NSColor(white: 0.96, alpha: 1.0)
    })

    // MARK: - Find-match highlight (G2)

    /// Base bright-blue swatch for find-match highlights, opaque.
    /// A tuned system-blue (sRGB ≈ #1E6FFF) rather than `NSColor.blue`
    /// / pure `#0000FF`: the latter is too dark/saturated to read text
    /// through and looks muddy in dark mode. This tone stays legible —
    /// readable text on top — in both light and dark appearances. The
    /// per-state alphas below keep the highlight as a translucent wash
    /// over the underlying glyphs rather than painting them out.
    static let findHighlightBlueColor = NSColor(
        srgbRed: 0.118, green: 0.435, blue: 1.0, alpha: 1.0
    )

    /// Background wash for a NON-current find match (NSTextView
    /// temporary attribute). Lower alpha so the active match stands
    /// out against the field of other hits.
    static let findHighlightInactive =
        findHighlightBlueColor.withAlphaComponent(0.28)

    /// Background wash for the CURRENT find match. Stronger alpha so
    /// the active hit pops against the dimmer sibling matches.
    static let findHighlightCurrent =
        findHighlightBlueColor.withAlphaComponent(0.55)
}
