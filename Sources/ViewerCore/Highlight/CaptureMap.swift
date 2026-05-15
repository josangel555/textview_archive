import Foundation

/// Tree-sitter capture names follow a dotted hierarchy:
/// `@keyword.control.return` falls back to `@keyword.control` falls
/// back to `@keyword`. We walk that hierarchy right-to-left, dropping
/// one segment at a time, looking up each prefix in `Self.table`. First
/// hit wins. Unmapped names → `nil` (default theme color renders them).
enum CaptureMap {

    /// Most-specific → coarse fallback. Order doesn't matter — we walk
    /// the dotted name, not the dictionary.
    static let table: [String: TokenKind] = [
        // Keywords
        "keyword":            .keyword,
        "conditional":        .keyword,
        "repeat":             .keyword,
        "include":            .keyword,
        "import":             .keyword,
        "exception":          .keyword,
        // Strings / characters
        "string":             .string,
        "character":          .string,
        "string.special.key": .tagAttribute,   // JSON keys → tagAttribute-ish
        "string.escape":      .escape,
        "escape":             .escape,
        "string.regexp":      .regex,
        // Comments
        "comment":            .comment,
        // Numbers / constants
        "number":             .number,
        "float":              .number,
        "boolean":            .builtin,
        "constant":           .constant,
        "constant.builtin":   .builtin,
        // Types / classes
        "type":               .type,
        "type.builtin":       .builtin,
        "class":              .type,
        // Functions / methods
        "function":           .function,
        "method":             .function,
        "function.call":      .function,
        "function.builtin":   .builtin,
        "function.macro":     .function,
        // Variables / parameters
        "variable":           .variable,
        "parameter":          .variable,
        "property":           .variable,
        "field":              .variable,
        // Attributes / annotations
        "attribute":          .attribute,
        "annotation":         .attribute,
        // Operators / punctuation
        "operator":           .operator,
        "punctuation":        .punctuation,
        "punctuation.bracket":  .punctuation,
        "punctuation.delimiter": .punctuation,
        "punctuation.special":  .punctuation,
        // Markup (markdown, etc.)
        "text.title":         .heading,
        "markup.heading":     .heading,
        "text.uri":           .link,
        "markup.link":        .link,
        "markup.link.url":    .link,
        "text.emphasis":      .emphasis,
        "markup.italic":      .emphasis,
        "text.strong":        .strong,
        "markup.bold":        .strong,
        // XML / HTML
        "tag":                .tag,
        "tag.attribute":      .tagAttribute,
    ]

    /// Walk the dotted name right-to-left, dropping segments until a
    /// hit. Returns nil if nothing matches — caller renders that span
    /// in the theme's default color.
    static func kind(forCapture name: String) -> TokenKind? {
        var prefix: Substring = Substring(name)
        while !prefix.isEmpty {
            if let kind = table[String(prefix)] {
                return kind
            }
            guard let dot = prefix.lastIndex(of: ".") else { return nil }
            prefix = prefix[prefix.startIndex..<dot]
        }
        return nil
    }
}
