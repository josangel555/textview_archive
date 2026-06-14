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
}
