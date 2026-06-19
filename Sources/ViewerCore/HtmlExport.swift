import Foundation

/// Builds a STANDALONE HTML document for export / clipboard (TSK-675 / a core
/// markdown-app feature). A pure CONSUMER of the rendered body + stylesheet — it
/// does NOT modify the (Rust-ported) markdown→HTML engine, so it's migration-safe.
///
/// Crucially this is NOT `HTMLRenderer.renderPage`: that page carries a strict
/// `default-src 'none'` Content-Security-Policy appropriate for the in-app
/// WKWebView. This export document carries a DELIBERATELY LOOSER CSP that still
/// permits the feature's external images (`img-src https: data:`) so an
/// exported/Open-in-Browser file renders as authored, while keeping the
/// no-script / no-frame / no-network backbone.
///
/// SECURITY (TSK-966). The standalone document is opened in a normal browser
/// with `file://` privileges, where the regex `HTMLSanitizer` (which has
/// confirmed bypasses) would be the SOLE defense. Two independent layers fix
/// this:
///   1. The CALLER renders author-embedded HTML in `.escape` mode
///      (`HTMLRenderer.AuthorHTMLDisposition.escape`), so no author markup
///      reaches this document live — the renderer is removed as an injection
///      vector entirely.
///   2. The `<meta http-equiv="Content-Security-Policy">` below is the second,
///      independent layer: even if a body somehow carried live markup,
///      `script-src` is denied (implied by `default-src 'none'`), inline event
///      handlers can't run, and there is no `connect-src` exfil channel.
public enum HtmlExport {

    /// CSP for the standalone export / Open-in-Browser document (TSK-966).
    ///
    /// Deliberately looser than the in-app `default-src 'none'` so the export's
    /// headline feature — EXTERNAL images — still renders in a browser:
    ///   * `img-src https: data:` — remote https images + inline `data:` URIs
    ///     (the in-app path forbids https images; the export permits them).
    ///   * `style-src 'unsafe-inline'` — the embedded `<style>` block + any
    ///     inline `style=` attributes the stylesheet/body rely on.
    ///   * everything else falls to `default-src 'none'`: NO scripts, NO
    ///     frames, NO `connect-src` (beacon/exfil), NO `<base>` retargeting,
    ///     NO form posts, NO objects/plugins.
    public static let csp: String =
        "default-src 'none'; img-src https: data:; style-src 'unsafe-inline'; "
        + "font-src data:; base-uri 'none'; form-action 'none';"

    /// A complete `<!DOCTYPE html>` document embedding `body` + `stylesheet`, with
    /// `title` HTML-escaped into `<title>` and a restrictive (but image-
    /// permitting) CSP (TSK-966 — see type doc).
    public static func standaloneDocument(body: String, stylesheet: String, title: String) -> String {
        """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="\(csp)">
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
