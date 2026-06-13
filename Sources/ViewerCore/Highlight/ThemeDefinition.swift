import AppKit

/// The platform-free theme model (TSK-641) — the SINGLE upstream all four
/// color surfaces derive from (SyntaxTheme/NSAttributedString runs, the
/// rendered view's `tok-*` CSS, the CM6 editor payload, chrome accents),
/// and the target TSK-642's VS Code theme import maps onto.
///
/// Colors are HEX STRINGS (`#RRGGBB` / `#RGB` / `#RRGGBBAA`) so the model
/// is Codable, diffable, and platform-free: user themes persist as JSON
/// under Application Support and round-trip losslessly.
public struct ThemeDefinition: Codable, Equatable, Sendable {
    /// Stable identifier (also the filename stem for user themes).
    public var id: String
    /// Display name for pickers.
    public var displayName: String
    /// Whether the theme is dark (drives appearance pairing + chrome).
    public var isDark: Bool

    /// Surface colors.
    public var background: String
    public var foreground: String
    public var gutterText: String
    public var gutterBackground: String

    /// Token colors keyed by `TokenKind.rawValue`. Missing kinds fall back
    /// to `foreground` at conversion time.
    public var tokens: [String: String]

    /// Chrome accent slots (stage-2 consumers; optional so imports without
    /// chrome data stay valid).
    public var accent: String?
    public var selectionBackground: String?

    /// Chrome SURFACE slots (TSK-641 stage 4 — the fourth color surface).
    /// All optional: a theme without them still themes the chrome via the
    /// `ChromeColors` fallback derivation (sidebar ← `background`, bars +
    /// panels ← `gutterBackground`), so imports and hand-written themes get
    /// a coherent full-window look with zero extra required fields. Persisted
    /// user-theme JSON without these keys decodes fine (optionals).
    public var sidebarBackground: String?
    /// Tab strip / status bar / section-header bars (`Palette.windowBackground`).
    public var barBackground: String?
    /// Sidebar accordion panel cards (`Palette.sidebarPanelBackground`).
    public var panelBackground: String?

    public init(
        id: String, displayName: String, isDark: Bool,
        background: String, foreground: String,
        gutterText: String, gutterBackground: String,
        tokens: [String: String],
        accent: String? = nil, selectionBackground: String? = nil,
        sidebarBackground: String? = nil, barBackground: String? = nil,
        panelBackground: String? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.isDark = isDark
        self.background = background
        self.foreground = foreground
        self.gutterText = gutterText
        self.gutterBackground = gutterBackground
        self.tokens = tokens
        self.accent = accent
        self.selectionBackground = selectionBackground
        self.sidebarBackground = sidebarBackground
        self.barBackground = barBackground
        self.panelBackground = panelBackground
    }
}

// MARK: - Hex color parsing

public enum ThemeColor {
    /// Parse `#RGB`, `#RRGGBB`, `#RRGGBBAA` (case-insensitive, `#` optional).
    /// Returns nil for malformed input — callers decide the fallback.
    public static func parse(_ hex: String) -> NSColor? {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.allSatisfy(\.isHexDigit) else { return nil }
        func channel(_ sub: Substring) -> CGFloat? {
            UInt8(sub, radix: 16).map { CGFloat($0) / 255 }
        }
        switch s.count {
        case 3:
            let chars = Array(s)
            guard let r = UInt8(String([chars[0], chars[0]]), radix: 16),
                  let g = UInt8(String([chars[1], chars[1]]), radix: 16),
                  let b = UInt8(String([chars[2], chars[2]]), radix: 16) else { return nil }
            return NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255,
                           blue: CGFloat(b) / 255, alpha: 1)
        case 6, 8:
            let chars = Array(s)
            guard let r = channel(Substring(String(chars[0...1]))),
                  let g = channel(Substring(String(chars[2...3]))),
                  let b = channel(Substring(String(chars[4...5]))) else { return nil }
            let a: CGFloat
            if s.count == 8 {
                guard let alpha = channel(Substring(String(chars[6...7]))) else { return nil }
                a = alpha
            } else {
                a = 1
            }
            return NSColor(srgbRed: r, green: g, blue: b, alpha: a)
        default:
            return nil
        }
    }

    /// Render an NSColor back to `#RRGGBB` (or `#RRGGBBAA` when alpha < 1).
    public static func hex(_ color: NSColor) -> String {
        let c = color.usingColorSpace(.sRGB) ?? color
        let r = Int(round(c.redComponent * 255))
        let g = Int(round(c.greenComponent * 255))
        let b = Int(round(c.blueComponent * 255))
        let a = Int(round(c.alphaComponent * 255))
        if a < 255 {
            return String(format: "#%02X%02X%02X%02X", r, g, b, a)
        }
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}

// MARK: - Surface conversions

extension SyntaxTheme {
    /// Build a SyntaxTheme from a definition. Unknown/missing token kinds
    /// fall back to the definition's foreground; malformed hex falls back
    /// per-slot (never fails the whole theme).
    public init(from def: ThemeDefinition) {
        let fg = ThemeColor.parse(def.foreground) ?? .textColor
        var colors: [TokenKind: NSColor] = [:]
        for kind in TokenKind.allCases {
            if let hex = def.tokens[kind.rawValue], let c = ThemeColor.parse(hex) {
                colors[kind] = c
            }
        }
        self.init(
            name: def.isDark ? .xcodeDark : .xcodeLight,
            background: ThemeColor.parse(def.background) ?? .textBackgroundColor,
            defaultText: fg,
            gutterText: ThemeColor.parse(def.gutterText) ?? fg,
            gutterBackground: ThemeColor.parse(def.gutterBackground)
                ?? (ThemeColor.parse(def.background) ?? .textBackgroundColor),
            colors: colors
        )
    }
}

extension ThemeDefinition {
    /// The rendered view's token-color override block — splices through the
    /// EXISTING `renderPage(extraStylesheet:)` hook (no template change).
    /// Only `tok-*` + code-block surface colors; layout/typography stay in
    /// the base stylesheet.
    public func tokCSS() -> String {
        var out = "/* theme: \(id) */\n"
        out += "pre, code { background-color: \(background); color: \(foreground); }\n"
        for kind in TokenKind.allCases {
            guard let hex = tokens[kind.rawValue] else { continue }
            out += ".tok-\(kind.rawValue.lowercased()) { color: \(hex); }\n"
        }
        return out
    }

    /// Re-theme the rendered markdown PAGE (reading background + prose), not
    /// just the syntax tokens, by overriding markdown.css's `:root` custom
    /// properties from the theme (TSK-815). markdown.css's page bg + text +
    /// code/link colors all read these vars and otherwise follow SYSTEM
    /// appearance (`-apple-system-*`), so a selected dark theme on a light-mode
    /// system left the reading view LIGHT — the Dark-Mode gap. Appended AFTER
    /// markdown.css in the `<style>` block, so this `:root` wins by cascade. The
    /// translucent grey rules (`--mdv-rule`/`--mdv-*-border`) are appearance-
    /// agnostic and deliberately left alone. Only emitted when a theme is
    /// selected (nil → system-following, byte-identical to before).
    public func pageCSS() -> String {
        var out = ":root {\n"
        out += "  --mdv-bg: \(background);\n"
        out += "  --mdv-fg: \(foreground);\n"
        out += "  --mdv-fg-secondary: \(gutterText);\n"
        out += "  --mdv-code-bg: \(gutterBackground);\n"
        if let link = accent { out += "  --mdv-link: \(link);\n" }
        out += "}\n"
        return out
    }
}

// MARK: - Built-ins (the incumbents, expressed losslessly as definitions)

extension ThemeDefinition {
    /// Express a hardcoded SyntaxTheme as a definition (the lossless
    /// bridge that lets the built-ins live in the same model user themes
    /// and VS Code imports use).
    public static func from(_ theme: SyntaxTheme, id: String, displayName: String, isDark: Bool) -> ThemeDefinition {
        var tokens: [String: String] = [:]
        for kind in TokenKind.allCases {
            tokens[kind.rawValue] = ThemeColor.hex(theme.color(for: kind))
        }
        return ThemeDefinition(
            id: id, displayName: displayName, isDark: isDark,
            background: ThemeColor.hex(theme.background),
            foreground: ThemeColor.hex(theme.defaultText),
            gutterText: ThemeColor.hex(theme.gutterText),
            gutterBackground: ThemeColor.hex(theme.gutterBackground),
            tokens: tokens
        )
    }

    public static let builtIns: [ThemeDefinition] = [
        .from(.xcodeLight, id: "xcode-light", displayName: "Xcode Light", isDark: false),
        .from(.xcodeDark, id: "xcode-dark", displayName: "Xcode Dark", isDark: true),
    ]
}
