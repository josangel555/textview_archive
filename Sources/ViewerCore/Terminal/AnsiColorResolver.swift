import Foundation

/// An RGB triple in 0...1 (AppKit-free), the resolved form of a `TerminalColor`.
public struct AnsiRGB: Equatable, Sendable {
    public var r: Double
    public var g: Double
    public var b: Double
    public init(_ r: Double, _ g: Double, _ b: Double) { self.r = r; self.g = g; self.b = b }
}

/// TSK-1175 — a named 16-colour ANSI theme (8 base + 8 bright). The 256-colour
/// cube + greyscale ramp are computed (theme-independent); only indices 0–15 vary
/// by theme. Pure data so the terminal can offer selectable colour schemes.
public struct AnsiTheme: Sendable, Equatable {
    public let name: String
    /// The 16 base colours (indices 0–15). Exactly 16 entries.
    public let colors: [AnsiRGB]
    public init(name: String, colors: [AnsiRGB]) {
        self.name = name
        self.colors = colors
    }

    /// The app's tuned default palette (muted, readable on light + dark) — the
    /// EXACT values the terminal shipped, so selecting it changes nothing.
    public static let `default` = AnsiTheme(name: "Default", colors: [
        AnsiRGB(0.20, 0.20, 0.20), AnsiRGB(0.80, 0.16, 0.13), AnsiRGB(0.18, 0.60, 0.18),
        AnsiRGB(0.69, 0.55, 0.05), AnsiRGB(0.16, 0.42, 0.85), AnsiRGB(0.66, 0.24, 0.66),
        AnsiRGB(0.13, 0.57, 0.62), AnsiRGB(0.78, 0.78, 0.78), AnsiRGB(0.45, 0.45, 0.45),
        AnsiRGB(0.94, 0.33, 0.31), AnsiRGB(0.30, 0.79, 0.30), AnsiRGB(0.90, 0.76, 0.18),
        AnsiRGB(0.36, 0.60, 0.98), AnsiRGB(0.85, 0.45, 0.85), AnsiRGB(0.30, 0.78, 0.82),
        AnsiRGB(0.96, 0.96, 0.96),
    ])

    /// The classic xterm 16-colour palette (a selectable alternative).
    public static let classic = AnsiTheme(name: "Classic (xterm)", colors: [
        c(0, 0, 0), c(205, 0, 0), c(0, 205, 0), c(205, 205, 0),
        c(0, 0, 238), c(205, 0, 205), c(0, 205, 205), c(229, 229, 229),
        c(127, 127, 127), c(255, 0, 0), c(0, 255, 0), c(255, 255, 0),
        c(92, 92, 255), c(255, 0, 255), c(0, 255, 255), c(255, 255, 255),
    ])

    /// All built-in themes, in display order.
    public static let builtIns: [AnsiTheme] = [.default, .classic]

    /// Look up a built-in theme by `name`; falls back to `.default` for an unknown
    /// name (e.g. a stale preference value). TSK-1312.
    public static func named(_ name: String) -> AnsiTheme {
        builtIns.first { $0.name == name } ?? .default
    }

    private static func c(_ r: Int, _ g: Int, _ b: Int) -> AnsiRGB {
        AnsiRGB(Double(r) / 255, Double(g) / 255, Double(b) / 255)
    }
}

/// TSK-1175 — pure resolver from the abstract `TerminalColor` to an `AnsiRGB`,
/// against a chosen `AnsiTheme`. Host-testable (no AppKit); the rendering layer
/// turns `AnsiRGB` into its platform colour. `.default` resolves to nil (the
/// caller substitutes the view's own fg/bg).
public enum AnsiColorResolver {
    public static func rgb(_ color: TerminalColor, theme: AnsiTheme = .default) -> AnsiRGB? {
        switch color {
        case .default:
            return nil
        case let .ansi(n):
            return theme.colors[Int(min(n, 15))]
        case let .indexed(n):
            return indexed(n, theme: theme)
        case let .rgb(r, g, b):
            return AnsiRGB(Double(r) / 255, Double(g) / 255, Double(b) / 255)
        }
    }

    /// xterm-256 resolution: 0–15 → the theme palette, 16–231 → the 6×6×6 cube,
    /// 232–255 → the 24-step greyscale ramp.
    public static func indexed(_ n: UInt8, theme: AnsiTheme = .default) -> AnsiRGB {
        if n < 16 { return theme.colors[Int(n)] }
        if n >= 232 {
            let v = Double(8 + (Int(n) - 232) * 10) / 255   // ~8…238
            return AnsiRGB(v, v, v)
        }
        let idx = Int(n) - 16
        func channel(_ level: Int) -> Double { level == 0 ? 0 : Double(55 + level * 40) / 255 }
        return AnsiRGB(channel((idx / 36) % 6), channel((idx / 6) % 6), channel(idx % 6))
    }
}
