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
            return palette256[Int(n)]
        case .indexed(let n):
            return palette256[Int(n)]
        case .rgb(let r, let g, let b):
            return NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255,
                           blue: CGFloat(b) / 255, alpha: 1)
        }
    }

    /// The full xterm-256 palette, resolved once from the pure
    /// `AnsiColorResolver` (TSK-1175 — one source of truth for the colour math;
    /// host-tested). Indices 0–15 are the active theme, 16–231 the 6×6×6 cube,
    /// 232–255 the greyscale ramp — `.ansi`/`.indexed` both index straight in.
    /// `NSColor` is immutable, so sharing instances across draws/threads is safe.
    private static let palette256: [NSColor] = (0...255).map { n in
        let c = AnsiColorResolver.indexed(UInt8(n), theme: .default)
        return NSColor(srgbRed: CGFloat(c.r), green: CGFloat(c.g), blue: CGFloat(c.b), alpha: 1)
    }
}
