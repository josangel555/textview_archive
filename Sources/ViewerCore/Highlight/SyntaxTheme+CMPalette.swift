import AppKit
import ViewerKit

/// TSK-602 — ViewOnly ↔ Editor highlight parity.
///
/// The source view colors TreeSitter runs through `SyntaxTheme`; the CM6
/// editor used to ship its own palettes (`oneDark` / CM's default light),
/// so toggling ViewOnly changed every color. This export makes
/// `SyntaxTheme` the single source of truth: the palette rides the
/// `setTheme` bridge message and the JS host builds its `HighlightStyle`
/// from these exact hex values.
extension SyntaxTheme {
    /// Chrome keys carried alongside the per-token colors. Kept distinct
    /// from `TokenKind` raw values (none of these collide).
    public enum CMPaletteChromeKey: String, CaseIterable {
        case background
        case defaultText
        case gutterText
        case gutterBackground
    }

    /// The wire palette: every `TokenKind` raw value plus the chrome
    /// keys, each mapped to `#RRGGBB`. Total = TokenKind.allCases.count
    /// + 4 entries; the JS side ignores keys it doesn't know.
    public var cmPalette: [String: String] {
        var out: [String: String] = [:]
        for kind in TokenKind.allCases {
            out[kind.rawValue] = Self.cssHex(color(for: kind))
        }
        out[CMPaletteChromeKey.background.rawValue] = Self.cssHex(background)
        out[CMPaletteChromeKey.defaultText.rawValue] = Self.cssHex(defaultText)
        out[CMPaletteChromeKey.gutterText.rawValue] = Self.cssHex(gutterText)
        out[CMPaletteChromeKey.gutterBackground.rawValue] = Self.cssHex(gutterBackground)
        return out
    }

    /// `#RRGGBB` in sRGB. Theme colors are constructed from sRGB
    /// components, so the conversion is lossless for shipped themes.
    static func cssHex(_ color: NSColor) -> String {
        let srgb = color.usingColorSpace(.sRGB) ?? color
        let r = Int((srgb.redComponent * 255).rounded())
        let g = Int((srgb.greenComponent * 255).rounded())
        let b = Int((srgb.blueComponent * 255).rounded())
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}
