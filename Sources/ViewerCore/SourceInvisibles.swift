import AppKit

/// Pure model for rendering readable "show invisibles" markers in the
/// **read-only `NSTextView` source view** (TSK-364).
///
/// ## Why this exists
/// `NSLayoutManager.showsInvisibleCharacters = true` draws spaces / tabs /
/// line-breaks in the OS's built-in faint grey (`tertiaryLabelColor`), and
/// there is **no public API to recolor or restyle those markers**. The only
/// AppKit hook is subclassing `NSLayoutManager` and overriding
/// `drawGlyphs(forGlyphRange:at:)` — which is the documented compositor-bug
/// trigger in this codebase (LESSONS.md "Things to NOT do") and is therefore
/// off-limits. So the editable CodeMirror 6 path got the readable
/// IntelliJ-style invisibles (`.cm-invisible`) while the source view stayed
/// stuck on the washed-out OS grey ("invisibles too grey").
///
/// ## The compositor-safe approach
/// Instead of touching the layout manager, the source view draws its own
/// marker glyphs in a **separate SwiftUI `Canvas` overlay** synced to the
/// textView's scroll position — exactly the pattern `SourceGutterView` uses
/// for line numbers (a `Canvas` driven by `SourceScrollState`, computed in a
/// scroll-notification handler, never inside `NSScrollView.tile()`). That
/// path never subclasses `NSLayoutManager` and never attaches an
/// `NSRulerView`, so it carries none of the compositor risk.
///
/// This type is the host-testable core of that overlay: it decides the
/// marker color (theme-derived, matching the CM6 `.cm-invisible` tone) and,
/// given the text of a visible line, the per-column marker glyphs to paint.
/// The SwiftUI overlay (`SourceInvisiblesView`) is a thin renderer over this.
public enum SourceInvisibles {

    /// The kind of whitespace a marker stands in for. The glyph and the
    /// horizontal extent differ per kind (a tab spans to the next tab stop;
    /// a space is one cell).
    public enum MarkerKind: Equatable, Sendable {
        case space
        case tab
    }

    /// A single marker to paint on a visible line.
    public struct Marker: Equatable, Sendable {
        /// 0-based UTF-16 column of the whitespace character on its line.
        /// (Source lines here are ASCII-whitespace runs interspersed with
        /// content; column == offset in the line's UTF-16 view, which for the
        /// whitespace characters we mark is identical to the scalar offset.)
        public let column: Int
        public let kind: MarkerKind
        public init(column: Int, kind: MarkerKind) {
            self.column = column
            self.kind = kind
        }

        /// The glyph drawn for this marker. Middle-dot for a space, a thin
        /// right-arrow for a tab — the IntelliJ / VS Code convention the
        /// editable CM6 path also uses.
        public var glyph: String {
            switch kind {
            case .space: return "\u{00B7}"   // · MIDDLE DOT
            case .tab:   return "\u{2192}"   // → RIGHTWARDS ARROW
            }
        }
    }

    /// The pilcrow drawn at a line ending when line-break markers are shown.
    public static let lineBreakGlyph = "\u{00B6}"   // ¶ PILCROW

    /// Compute the whitespace markers for a single visible line of source.
    ///
    /// Only ASCII space (0x20) and tab (0x09) are marked; every other
    /// character (including content and non-breaking spaces) is left alone so
    /// the markers never compete with the code. The returned markers are in
    /// ascending column order.
    ///
    /// - Parameter line: the text of one logical line, WITHOUT its trailing
    ///   newline (the caller strips it; the line-break marker is handled
    ///   separately via `lineBreakGlyph`). Accepts any `StringProtocol` so the
    ///   overlay can pass a `Substring` slice without allocating a `String`.
    public static func markers<S: StringProtocol>(forLine line: S) -> [Marker] {
        guard !line.isEmpty else { return [] }
        var out: [Marker] = []
        var column = 0
        // Iterate UTF-16 so `column` matches the textView's glyph indexing
        // (NSTextView / NSLayoutManager are UTF-16-based). Space and tab are
        // each one UTF-16 unit, so this stays exact even with multi-unit
        // content characters elsewhere on the line.
        for unit in line.utf16 {
            switch unit {
            case 0x20: out.append(Marker(column: column, kind: .space))
            case 0x09: out.append(Marker(column: column, kind: .tab))
            default:   break
            }
            column += 1
        }
        return out
    }

    /// The readable marker color for a theme — a subtle-but-legible secondary
    /// tone, NOT the washed-out OS grey. Mirrors the editable path's
    /// `.cm-invisible` CSS: it tracks macOS `secondaryLabelColor`
    /// (light: ~rgba(60,60,67,0.55), dark: ~rgba(235,235,245,0.50)) so the
    /// markers stay visible against both backgrounds without shouting over the
    /// code. Derived from the theme's `background` luminance rather than the
    /// live `NSAppearance` so the color matches the theme actually painting
    /// the source (the two can diverge, e.g. a light theme in a dark window).
    public static func markerColor(for theme: SyntaxTheme) -> NSColor {
        if isDark(theme.background) {
            return NSColor(srgbRed: 235.0 / 255.0, green: 235.0 / 255.0,
                           blue: 245.0 / 255.0, alpha: 0.50)
        } else {
            return NSColor(srgbRed: 60.0 / 255.0, green: 60.0 / 255.0,
                           blue: 67.0 / 255.0, alpha: 0.55)
        }
    }

    /// Perceived-luminance test on a theme background. Uses the Rec. 601
    /// coefficients on the sRGB components; the 0.5 threshold cleanly splits
    /// the shipped light (white) and dark (near-black) backgrounds and any
    /// future themes in between.
    static func isDark(_ color: NSColor) -> Bool {
        let srgb = color.usingColorSpace(.sRGB) ?? color
        let r = srgb.redComponent
        let g = srgb.greenComponent
        let b = srgb.blueComponent
        let luminance = 0.299 * r + 0.587 * g + 0.114 * b
        return luminance < 0.5
    }
}
