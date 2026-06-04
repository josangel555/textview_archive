import AppKit
import ViewerCore

/// Resolves the abstract `TerminalColor` (ViewerCore, AppKit-free) to a
/// concrete `NSColor` at draw time — the capture→trait→colour split the
/// rest of the app uses (DESIGN §11). A muted, system-aware 16-colour
/// ANSI palette tuned to read on both light and dark terminal
/// backgrounds; `.default` resolves to `nil` so the caller substitutes
/// the view's default fg/bg (label / textBackground).
enum TerminalPalette {
    /// Foreground/background swatch for an ANSI colour, or `nil` for
    /// `.default` (caller uses its own default fg/bg).
    static func nsColor(_ c: TerminalColor) -> NSColor? {
        switch c {
        case .default:       return nil
        case .black:         return NSColor(srgbRed: 0.20, green: 0.20, blue: 0.20, alpha: 1)
        case .red:           return NSColor(srgbRed: 0.80, green: 0.16, blue: 0.13, alpha: 1)
        case .green:         return NSColor(srgbRed: 0.18, green: 0.60, blue: 0.18, alpha: 1)
        case .yellow:        return NSColor(srgbRed: 0.69, green: 0.55, blue: 0.05, alpha: 1)
        case .blue:          return NSColor(srgbRed: 0.16, green: 0.42, blue: 0.85, alpha: 1)
        case .magenta:       return NSColor(srgbRed: 0.66, green: 0.24, blue: 0.66, alpha: 1)
        case .cyan:          return NSColor(srgbRed: 0.13, green: 0.57, blue: 0.62, alpha: 1)
        case .white:         return NSColor(srgbRed: 0.78, green: 0.78, blue: 0.78, alpha: 1)
        case .brightBlack:   return NSColor(srgbRed: 0.45, green: 0.45, blue: 0.45, alpha: 1)
        case .brightRed:     return NSColor(srgbRed: 0.94, green: 0.33, blue: 0.31, alpha: 1)
        case .brightGreen:   return NSColor(srgbRed: 0.30, green: 0.79, blue: 0.30, alpha: 1)
        case .brightYellow:  return NSColor(srgbRed: 0.90, green: 0.76, blue: 0.18, alpha: 1)
        case .brightBlue:    return NSColor(srgbRed: 0.36, green: 0.60, blue: 0.98, alpha: 1)
        case .brightMagenta: return NSColor(srgbRed: 0.85, green: 0.45, blue: 0.85, alpha: 1)
        case .brightCyan:    return NSColor(srgbRed: 0.30, green: 0.78, blue: 0.82, alpha: 1)
        case .brightWhite:   return NSColor(srgbRed: 0.96, green: 0.96, blue: 0.96, alpha: 1)
        }
    }
}
