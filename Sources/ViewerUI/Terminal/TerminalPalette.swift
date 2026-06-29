import AppKit
import ViewerCore

/// Resolves the abstract `TerminalColor` (ViewerCore, AppKit-free) to a
/// concrete `NSColor` at draw time — the capture→trait→colour split the
/// rest of the app uses (DESIGN §11). `.default` resolves to `nil` so the
/// caller substitutes the view's default fg/bg (label / textBackground).
///
/// Colour forms:
///   • `.ansi(0...15)`     — a muted, system-aware 16-colour palette tuned
///     to read on both light and dark terminal backgrounds.
///   • `.indexed(0...255)` — xterm 256: 0–15 alias the 16-colour palette,
///     16–231 the 6×6×6 cube, 232–255 the 24-step greyscale ramp.
///   • `.rgb(r,g,b)`       — 24-bit truecolor, taken verbatim.
@MainActor
enum TerminalPalette {
    /// Foreground/background swatch for a `TerminalColor`, or `nil` for
    /// `.default` (caller uses its own default fg/bg).
    ///
    /// PERF: the 256 palette entries (`.ansi`/`.indexed`) resolve to a
    /// shared, precomputed `NSColor` — the terminal draw path calls this
    /// twice per attribute-run per frame, and a heavily-coloured prompt has
    /// dozens of runs, so allocating a fresh `NSColor` each time was real
    /// per-frame churn. Only truecolor (`.rgb`, rare) still allocates.
    static func nsColor(_ c: TerminalColor) -> NSColor? {
        switch c {
        case .default:
            return nil
        case .ansi(let n):
            return activePalette[Int(n)]
        case .indexed(let n):
            return activePalette[Int(n)]
        case .rgb(let r, let g, let b):
            return NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255,
                           blue: CGFloat(b) / 255, alpha: 1)
        }
    }

    /// The active 16-colour theme NAME (TSK-1312) — selects indices 0–15 of the
    /// palette; 16–255 are theme-independent. Set from the `terminalColorThemeName`
    /// preference by the terminal view. `didSet` rebuilds `activePalette` once on
    /// change, so the draw hot-path stays a direct array index (no per-call lookup).
    /// Default = the muted shipped palette ("Default"), so existing users see no change.
    static var activeThemeName: String = AnsiTheme.default.name {
        didSet { if activeThemeName != oldValue { activePalette = Self.buildPalette(activeThemeName) } }
    }

    /// The full xterm-256 palette for `activeThemeName`, resolved from the pure
    /// `AnsiColorResolver` (TSK-1175 — one source of truth for the colour math;
    /// host-tested). Indices 0–15 are the theme, 16–231 the 6×6×6 cube, 232–255 the
    /// greyscale ramp. Precomputed shared immutable `NSColor`s (the draw path calls
    /// `nsColor` twice per attribute-run per frame, so a fresh alloc each time was
    /// real churn); rebuilt only on a theme change.
    private static var activePalette: [NSColor] = buildPalette(AnsiTheme.default.name)

    private static func buildPalette(_ name: String) -> [NSColor] {
        let theme = AnsiTheme.named(name)
        return (0...255).map { n in
            let c = AnsiColorResolver.indexed(UInt8(n), theme: theme)
            return NSColor(srgbRed: CGFloat(c.r), green: CGFloat(c.g), blue: CGFloat(c.b), alpha: 1)
        }
    }
}
