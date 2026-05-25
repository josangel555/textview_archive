import Foundation

/// Helpers for embedding JSON / strings inside JavaScript source text
/// produced by interpolation (e.g.
/// `webView.evaluateJavaScript("foo(\(json));")`).
///
/// `JSONSerialization` does NOT escape `U+2028 LINE SEPARATOR` and
/// `U+2029 PARAGRAPH SEPARATOR`. Both are legal inside a JSON string,
/// but in JavaScript source they are line terminators — embedding
/// them raw inside a JS string literal breaks parsing (pre-ES2019)
/// or, in some engines, breaks the surrounding statement. This is a
/// realistic hazard for: PDF→Markdown exports, Word paste, LSP
/// hover docs, diagnostic messages, find-bar queries, etc.
///
/// Use `JSStringEmbedding.sanitize(_:)` after `JSONSerialization` and
/// before string-interpolating the result into a JS source fragment.
public enum JSStringEmbedding {
    /// Escape `U+2028` and `U+2029` to their `\uXXXX` JS-string forms.
    /// Idempotent — the escapes are already valid JS/JSON, so running
    /// twice is a no-op on already-sanitized input.
    public static func sanitize(_ jsonOrJSStringLiteral: String) -> String {
        // String.replacingOccurrences fast-paths absent substrings, so
        // the common (ASCII) case pays only the scan cost.
        var s = jsonOrJSStringLiteral
        if s.contains("\u{2028}") {
            s = s.replacingOccurrences(of: "\u{2028}", with: "\\u2028")
        }
        if s.contains("\u{2029}") {
            s = s.replacingOccurrences(of: "\u{2029}", with: "\\u2029")
        }
        return s
    }
}
