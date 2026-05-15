import AppKit
import ViewerKit

/// Maps `TokenKind`s to concrete colors. Themes are tiny — a dictionary
/// plus a few defaults. Shipped themes use hand-picked hex values
/// (rather than `NSColor.systemX`) so the source view's colors match
/// across light/dark without relying on system accent shifts.
public struct SyntaxTheme: Sendable, Equatable {
    public enum Name: String, Sendable, CaseIterable, Codable {
        case xcodeLight
        case xcodeDark
    }

    public let name: Name
    public let background: NSColor
    public let defaultText: NSColor
    public let gutterText: NSColor
    public let gutterBackground: NSColor
    public let colors: [TokenKind: NSColor]

    public func color(for kind: TokenKind) -> NSColor {
        colors[kind] ?? defaultText
    }

    /// Xcode-default-ish on `NSColor.textBackgroundColor`. Used in
    /// `.aqua` (light) appearance.
    public static let xcodeLight: SyntaxTheme = .init(
        name: .xcodeLight,
        background:       NSColor(srgbRed: 1.00, green: 1.00, blue: 1.00, alpha: 1),
        defaultText:      NSColor(srgbRed: 0.11, green: 0.11, blue: 0.12, alpha: 1),
        gutterText:       NSColor(srgbRed: 0.50, green: 0.50, blue: 0.52, alpha: 1),
        gutterBackground: NSColor(srgbRed: 0.96, green: 0.96, blue: 0.97, alpha: 1),
        colors: [
            .keyword:      hex(0xAD3DA4),
            .string:       hex(0xC41A16),
            .escape:       hex(0xC41A16),
            .regex:        hex(0xC41A16),
            .comment:      hex(0x53716A),
            .number:       hex(0x1C00CF),
            .type:         hex(0x7030A0),
            .function:     hex(0x4B21B0),
            .variable:     hex(0x1C1C1E),
            .attribute:    hex(0x7030A0),
            .operator:     hex(0x1C1C1E),
            .punctuation:  hex(0x1C1C1E),
            .builtin:      hex(0x27378E),
            .constant:     hex(0x27378E),
            .heading:      hex(0x1F6FEB),
            .link:         hex(0x1F6FEB),
            .emphasis:     hex(0x1C1C1E),
            .strong:       hex(0x1C1C1E),
            .tag:          hex(0xAD3DA4),
            .tagAttribute: hex(0x836C28),
        ]
    )

    /// Xcode-dark-ish on a dark background. Used in `.darkAqua`.
    public static let xcodeDark: SyntaxTheme = .init(
        name: .xcodeDark,
        background:       NSColor(srgbRed: 0.12, green: 0.13, blue: 0.16, alpha: 1),
        defaultText:      NSColor(srgbRed: 0.87, green: 0.87, blue: 0.88, alpha: 1),
        gutterText:       NSColor(srgbRed: 0.50, green: 0.52, blue: 0.55, alpha: 1),
        gutterBackground: NSColor(srgbRed: 0.10, green: 0.11, blue: 0.13, alpha: 1),
        colors: [
            .keyword:      hex(0xFC5FA3),
            .string:       hex(0xFC6A5D),
            .escape:       hex(0xFC6A5D),
            .regex:        hex(0xFC6A5D),
            .comment:      hex(0x6C7986),
            .number:       hex(0xD0BF69),
            .type:         hex(0x9EF1DD),
            .function:     hex(0x67B7A4),
            .variable:     hex(0xDFDFE0),
            .attribute:    hex(0xD0BF69),
            .operator:     hex(0xDFDFE0),
            .punctuation:  hex(0xDFDFE0),
            .builtin:      hex(0x9EF1DD),
            .constant:     hex(0x9EF1DD),
            .heading:      hex(0x41A1C0),
            .link:         hex(0x41A1C0),
            .emphasis:     hex(0xDFDFE0),
            .strong:       hex(0xDFDFE0),
            .tag:          hex(0xFC5FA3),
            .tagAttribute: hex(0xD9C97C),
        ]
    )

    /// Pick a shipped theme by name.
    public static func named(_ name: Name) -> SyntaxTheme {
        switch name {
        case .xcodeLight: return .xcodeLight
        case .xcodeDark:  return .xcodeDark
        }
    }

    /// Resolve the right theme for the given appearance. Default for
    /// `nil` is light — the same as system-default-Aqua.
    public static func resolved(forAppearance appearance: NSAppearance?) -> SyntaxTheme {
        let best = appearance?.bestMatch(from: [.aqua, .darkAqua]) ?? .aqua
        return best == .darkAqua ? .xcodeDark : .xcodeLight
    }
}

private func hex(_ value: UInt32) -> NSColor {
    let r = CGFloat((value >> 16) & 0xFF) / 255.0
    let g = CGFloat((value >>  8) & 0xFF) / 255.0
    let b = CGFloat( value        & 0xFF) / 255.0
    return NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
}

// NSColor isn't Sendable, but our SyntaxTheme is used as immutable
// reference data — the colors are constant for the lifetime of a
// theme. The unchecked conformance reflects that contract.
extension NSColor: @retroactive @unchecked Sendable {}
