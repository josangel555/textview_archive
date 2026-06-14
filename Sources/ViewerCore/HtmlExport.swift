import Foundation

/// Builds a STANDALONE HTML document for export / clipboard (TSK-675 / a core
/// markdown-app feature). A pure CONSUMER of the rendered body + stylesheet — it
/// does NOT modify the (Rust-ported) markdown→HTML engine, so it's migration-safe.
///
/// Crucially this is NOT `HTMLRenderer.renderPage`: that page carries a strict
/// no-network Content-Security-Policy appropriate for the in-app WKWebView, which
/// would BLOCK external images/fonts when the user opens the exported file in a
/// normal browser. The export document omits the CSP so it renders as authored.
public enum HtmlExport {

    /// A complete `<!DOCTYPE html>` document embedding `body` + `stylesheet`, with
    /// `title` HTML-escaped into `<title>`. No CSP (see type doc).
    public static func standaloneDocument(body: String, stylesheet: String, title: String) -> String {
        """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(escape(title))</title>
        <style>
        \(stylesheet)
        </style>
        </head>
        <body>
        \(body)
        </body>
        </html>
        """
    }

    /// Default export filename for a source file: same stem, `.html` extension
    /// (`notes.md` → `notes.html`). Falls back to `export.html` for an empty stem.
    public static func htmlFilename(for url: URL) -> String {
        let stem = url.deletingPathExtension().lastPathComponent
        return (stem.isEmpty ? "export" : stem) + ".html"
    }

    /// Minimal HTML-text escape for `<title>` (`&` first so it doesn't double-escape).
    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
         .replacingOccurrences(of: "<", with: "&lt;")
         .replacingOccurrences(of: ">", with: "&gt;")
    }

    /// Make `html` self-contained by inlining LOCAL image references as
    /// `data:` URIs, so an exported file stays portable when moved away from its
    /// images. Each `src="X"` whose `X` is a local path (not http/https/data/
    /// protocol-relative/anchor) is passed to `readData`; on a hit it becomes
    /// `data:<mime>;base64,…` (MIME from `X`'s extension). Misses/external refs
    /// are left untouched. Pure — `readData` is injected, so it's host-testable.
    /// (Operates on the controlled rendered-Markdown HTML, where `src="…"` only
    /// occurs on `<img>` — the sanitizer/CSP forbids other src-bearing tags.)
    public static func inlineLocalImages(_ html: String, readData: (String) -> Data?) -> String {
        let marker = "src=\""
        var out = ""
        out.reserveCapacity(html.count)
        var idx = html.startIndex
        while let r = html.range(of: marker, range: idx..<html.endIndex) {
            out += html[idx..<r.upperBound]                 // through `src="`
            guard let close = html.range(of: "\"", range: r.upperBound..<html.endIndex) else {
                idx = r.upperBound; break
            }
            let src = String(html[r.upperBound..<close.lowerBound])
            if isLocalImageRef(src), let data = readData(src),
               let mime = mimeType(forPathExtension: (src as NSString).pathExtension) {
                out += "data:\(mime);base64,\(data.base64EncodedString())"
            } else {
                out += src                                  // leave as-is
            }
            out += "\""
            idx = close.upperBound
        }
        out += html[idx..<html.endIndex]
        return out
    }

    /// True for a path we should try to inline (not external / data / anchor).
    static func isLocalImageRef(_ src: String) -> Bool {
        if src.isEmpty || src.hasPrefix("#") || src.hasPrefix("//") || src.hasPrefix("data:") {
            return false
        }
        if let colon = src.firstIndex(of: ":") {
            let scheme = src[src.startIndex..<colon]
            if !scheme.isEmpty, scheme.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "+" || $0 == "-" || $0 == "." }),
               !scheme.contains("/") {
                return false   // http:, https:, file:, …
            }
        }
        return true
    }

    static func mimeType(forPathExtension ext: String) -> String? {
        switch ext.lowercased() {
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "svg": return "image/svg+xml"
        case "webp": return "image/webp"
        case "bmp": return "image/bmp"
        case "heic": return "image/heic"
        default: return nil
        }
    }
}
