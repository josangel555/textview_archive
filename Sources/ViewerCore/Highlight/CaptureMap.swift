import Foundation

/// Tree-sitter capture names follow a dotted hierarchy:
/// `@keyword.control.return` falls back to `@keyword.control` falls
/// back to `@keyword`. We walk that hierarchy right-to-left, dropping
/// one segment at a time, looking up each prefix in `Self.table`. First
/// hit wins. Unmapped names → `nil` (default theme color renders them).
enum CaptureMap {

    /// Capture-prefix → kind. Derived from the single canonical
    /// `HighlightScopeMap` (TSK-962) so the Source path and the CM6 path can't
    /// drift their scope→kind tables. Order doesn't matter — we walk the dotted
    /// name, not the dictionary.
    static let table: [String: TokenKind] = HighlightScopeMap.captureTable

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
