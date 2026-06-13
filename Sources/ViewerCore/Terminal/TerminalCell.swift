import Foundation

/// A terminal SGR colour. Kept as a small abstract enum (no `NSColor`)
/// so the whole terminal model stays in ViewerCore and is host-testable
/// without AppKit. The view layer (`ViewerUI`) resolves these to concrete
/// `NSColor`s at draw time — the same capture→trait→colour split the
/// highlighter uses (LESSONS / DESIGN §11).
///
/// Cases:
///   • `.default`        — the view's default fg/bg.
///   • `.ansi(0...15)`   — the classic 16-colour palette (8 base + 8
///     bright). The base 8 (0–7) are subject to the historical
///     bold→bright promotion.
///   • `.indexed(0...255)` — an xterm 256-colour index (`ESC[38;5;n`):
///     0–15 alias the 16-colour palette, 16–231 the 6×6×6 cube, 232–255
///     the greyscale ramp. NOT bold-promoted (an explicit index is exact).
///   • `.rgb(r,g,b)`     — 24-bit truecolor (`ESC[38;2;r;g;b`).
///
/// The 16 named statics (`.red`, `.brightGreen`, …) are readability/test
/// aliases onto `.ansi(0...15)`.
public enum TerminalColor: Sendable, Equatable, Hashable {
    case `default`
    case ansi(UInt8)
    case indexed(UInt8)
    case rgb(UInt8, UInt8, UInt8)

    public static let black         = TerminalColor.ansi(0)
    public static let red           = TerminalColor.ansi(1)
    public static let green         = TerminalColor.ansi(2)
    public static let yellow        = TerminalColor.ansi(3)
    public static let blue          = TerminalColor.ansi(4)
    public static let magenta       = TerminalColor.ansi(5)
    public static let cyan          = TerminalColor.ansi(6)
    public static let white         = TerminalColor.ansi(7)
    public static let brightBlack   = TerminalColor.ansi(8)
    public static let brightRed     = TerminalColor.ansi(9)
    public static let brightGreen   = TerminalColor.ansi(10)
    public static let brightYellow  = TerminalColor.ansi(11)
    public static let brightBlue    = TerminalColor.ansi(12)
    public static let brightMagenta = TerminalColor.ansi(13)
    public static let brightCyan    = TerminalColor.ansi(14)
    public static let brightWhite   = TerminalColor.ansi(15)

    /// Map an ANSI SGR colour index (the `3x` / `4x` family) to a case.
    /// `base` is 30 for foreground, 40 for background. `bright` is true
    /// for the `9x` / `10x` (bright) family. Returns nil for an
    /// out-of-range index (e.g. the `38`/`48` extended-colour introducers).
    static func fromSGR(_ value: Int, base: Int, bright: Bool) -> TerminalColor? {
        let idx = value - base
        guard (0...7).contains(idx) else { return nil }
        return .ansi(UInt8(idx) + (bright ? 8 : 0))
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
        // Bold promotes a base ANSI colour (0–7) to its bright sibling
        // (8–15) — the historical "bold = bright" behaviour. `.default`,
        // already-bright `.ansi`, and explicit `.indexed`/`.rgb` are left
        // untouched (an explicit extended colour is exact, not promoted).
        if case let .ansi(n) = base, n < 8 { return .ansi(n + 8) }
        return base
    }

    /// Background colour after applying `inverse`.
    public var effectiveBg: TerminalColor { inverse ? fg : bg }
}

/// A single character cell in the terminal grid.
///
/// `char` holds one `Character` (a grapheme cluster, so combining marks stay
/// with their base). A DOUBLE-WIDTH glyph (CJK / emoji) occupies TWO cells: the
/// lead cell holds the character, the next cell is a `isWideTrailer` placeholder
/// so the grid stays column-aligned (TSK-731). Trailers are skipped when
/// reconstructing line text.
public struct TerminalCell: Sendable, Equatable {
    public var char: Character
    public var attributes: CellAttributes
    /// True for the SECOND cell of a double-width glyph — a placeholder holding
    /// the column after a wide lead. (TSK-731.)
    public var isWideTrailer: Bool

    public init(char: Character = " ", attributes: CellAttributes = .default,
                isWideTrailer: Bool = false) {
        self.char = char
        self.attributes = attributes
        self.isWideTrailer = isWideTrailer
    }

    public static let blank = TerminalCell()

    public var isBlank: Bool { char == " " && attributes == .default && !isWideTrailer }
}
