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
    static func nsColor(_ c: TerminalColor) -> NSColor? {
        switch c {
        case .default:
            return nil
        case .ansi(let n):
            return ansiColor(n)
        case .indexed(let n):
            return indexedColor(n)
        case .rgb(let r, let g, let b):
            return NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255,
                           blue: CGFloat(b) / 255, alpha: 1)
        }
    }

    /// The tuned 16-colour palette (8 base + 8 bright).
    private static func ansiColor(_ n: UInt8) -> NSColor? {
        switch n {
        case 0:  return NSColor(srgbRed: 0.20, green: 0.20, blue: 0.20, alpha: 1)  // black
        case 1:  return NSColor(srgbRed: 0.80, green: 0.16, blue: 0.13, alpha: 1)  // red
        case 2:  return NSColor(srgbRed: 0.18, green: 0.60, blue: 0.18, alpha: 1)  // green
        case 3:  return NSColor(srgbRed: 0.69, green: 0.55, blue: 0.05, alpha: 1)  // yellow
        case 4:  return NSColor(srgbRed: 0.16, green: 0.42, blue: 0.85, alpha: 1)  // blue
        case 5:  return NSColor(srgbRed: 0.66, green: 0.24, blue: 0.66, alpha: 1)  // magenta
        case 6:  return NSColor(srgbRed: 0.13, green: 0.57, blue: 0.62, alpha: 1)  // cyan
        case 7:  return NSColor(srgbRed: 0.78, green: 0.78, blue: 0.78, alpha: 1)  // white
        case 8:  return NSColor(srgbRed: 0.45, green: 0.45, blue: 0.45, alpha: 1)  // brightBlack
        case 9:  return NSColor(srgbRed: 0.94, green: 0.33, blue: 0.31, alpha: 1)  // brightRed
        case 10: return NSColor(srgbRed: 0.30, green: 0.79, blue: 0.30, alpha: 1)  // brightGreen
        case 11: return NSColor(srgbRed: 0.90, green: 0.76, blue: 0.18, alpha: 1)  // brightYellow
        case 12: return NSColor(srgbRed: 0.36, green: 0.60, blue: 0.98, alpha: 1)  // brightBlue
        case 13: return NSColor(srgbRed: 0.85, green: 0.45, blue: 0.85, alpha: 1)  // brightMagenta
        case 14: return NSColor(srgbRed: 0.30, green: 0.78, blue: 0.82, alpha: 1)  // brightCyan
        case 15: return NSColor(srgbRed: 0.96, green: 0.96, blue: 0.96, alpha: 1)  // brightWhite
        default: return indexedColor(n)   // defensive (n>15 never reaches here via .ansi)
        }
    }

    /// xterm 256-colour resolution: 0–15 → the 16-palette, 16–231 → the
    /// 6×6×6 colour cube, 232–255 → the greyscale ramp.
    private static func indexedColor(_ n: UInt8) -> NSColor? {
        if n < 16 { return ansiColor(n) }
        if n >= 232 {
            // Greyscale ramp: 24 steps from ~8 to ~238.
            let level = Int(n) - 232
            let v = CGFloat(8 + level * 10) / 255
            return NSColor(srgbRed: v, green: v, blue: v, alpha: 1)
        }
        // 6×6×6 cube. Each axis level 0 → 0, levels 1–5 → 55 + 40·level.
        let idx = Int(n) - 16
        let r = (idx / 36) % 6
        let g = (idx / 6) % 6
        let b = idx % 6
        func channel(_ level: Int) -> CGFloat {
            level == 0 ? 0 : CGFloat(55 + level * 40) / 255
        }
        return NSColor(srgbRed: channel(r), green: channel(g), blue: channel(b), alpha: 1)
    }
}
