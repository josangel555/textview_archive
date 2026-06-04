import Foundation

/// A terminal SGR colour. Kept as a small abstract enum (no `NSColor`)
/// so the whole terminal model stays in ViewerCore and is host-testable
/// without AppKit. The view layer (`ViewerUI`) resolves these to concrete
/// `NSColor`s at draw time — the same capture→trait→colour split the
/// highlighter uses (LESSONS / DESIGN §11).
///
/// We model the classic 16-colour palette (the 8 base ANSI colours plus
/// their bright variants) plus a `default` sentinel meaning "the
/// view's default fg/bg". 256-colour and truecolor (`ESC[38;2;r;g;bm`)
/// are OUT OF SCOPE for this dep-free v1 and are parsed-then-ignored
/// (they fall back to `.default`) rather than garbling the grid.
public enum TerminalColor: UInt8, Sendable, Equatable, Hashable {
    case `default` = 0
    case black
    case red
    case green
    case yellow
    case blue
    case magenta
    case cyan
    case white
    case brightBlack
    case brightRed
    case brightGreen
    case brightYellow
    case brightBlue
    case brightMagenta
    case brightCyan
    case brightWhite

    /// Map an ANSI SGR colour index (the `3x` / `4x` family) to a case.
    /// `base` is 30 for foreground, 40 for background. `bright` is true
    /// for the `9x` / `10x` (bright) family.
    static func fromSGR(_ value: Int, base: Int, bright: Bool) -> TerminalColor? {
        let idx = value - base
        guard (0...7).contains(idx) else { return nil }
        let raw = UInt8(idx) + (bright ? 9 : 1)
        return TerminalColor(rawValue: raw)
    }
}

/// Per-cell rendition attributes that survive across writes. Mirrors the
/// SGR state machine: a write to the screen stamps the *current* pen
/// attributes onto each cell.
public struct CellAttributes: Sendable, Equatable, Hashable {
    public var fg: TerminalColor
    public var bg: TerminalColor
    public var bold: Bool
    public var underline: Bool
    public var inverse: Bool

    public init(
        fg: TerminalColor = .default,
        bg: TerminalColor = .default,
        bold: Bool = false,
        underline: Bool = false,
        inverse: Bool = false
    ) {
        self.fg = fg
        self.bg = bg
        self.bold = bold
        self.underline = underline
        self.inverse = inverse
    }

    public static let `default` = CellAttributes()

    /// Reset every attribute to defaults (`ESC[0m` / `ESC[m`).
    public mutating func reset() { self = .default }

    /// Foreground colour after applying `inverse` (swap fg/bg) and the
    /// bold→bright promotion most terminals do for the base 8 colours.
    public var effectiveFg: TerminalColor {
        let base = inverse ? bg : fg
        guard bold else { return base }
        // Bold promotes a base ANSI colour to its bright sibling
        // (the historical "bold = bright" behaviour). `.default` and
        // already-bright colours are left untouched.
        switch base {
        case .black:   return .brightBlack
        case .red:     return .brightRed
        case .green:   return .brightGreen
        case .yellow:  return .brightYellow
        case .blue:    return .brightBlue
        case .magenta: return .brightMagenta
        case .cyan:    return .brightCyan
        case .white:   return .brightWhite
        default:       return base
        }
    }

    /// Background colour after applying `inverse`.
    public var effectiveBg: TerminalColor { inverse ? fg : bg }
}

/// A single character cell in the terminal grid.
///
/// `char` holds one `Character`. A blank cell is a space with default
/// attributes. We deliberately store `Character` (a grapheme cluster)
/// rather than a scalar so combining marks / emoji render as one cell —
/// good enough for a basic shell; true wide-character (CJK double-width)
/// column accounting is out of scope for v1 (a wide glyph occupies one
/// logical cell and may visually overflow, which the shell tolerates).
public struct TerminalCell: Sendable, Equatable {
    public var char: Character
    public var attributes: CellAttributes

    public init(char: Character = " ", attributes: CellAttributes = .default) {
        self.char = char
        self.attributes = attributes
    }

    public static let blank = TerminalCell()

    public var isBlank: Bool { char == " " && attributes == .default }
}
