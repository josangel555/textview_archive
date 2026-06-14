import Foundation

/// Helpers for "Open Rendered in Browser" — write the rendered Markdown to a
/// temp `.html` and hand it to the default browser. Pure naming logic here (the
/// write + `NSWorkspace.open` are the render/AppKit tail).
public enum BrowserPreview {

    /// A filesystem-safe `.html` temp filename derived from a document stem:
    /// every char outside `[A-Za-z0-9._-]` (Unicode letters/digits included) →
    /// `-`; leading/trailing `-`/`.` trimmed (no hidden/odd names); empty → a
    /// `preview` fallback. Stable per stem so re-opening a doc overwrites its
    /// own temp file rather than accumulating.
    public static func tempFileName(stem: String) -> String {
        var out = ""
        for c in stem {
            if c.isLetter || c.isNumber || c == "-" || c == "_" || c == "." { out.append(c) }
            else { out.append("-") }
        }
        let trimmed = out.trimmingCharacters(in: CharacterSet(charactersIn: "-."))
        return (trimmed.isEmpty ? "preview" : trimmed) + ".html"
    }
}
