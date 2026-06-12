import Foundation

/// Loads the vendored mermaid runtime + shim resources from the ViewerUI
/// resource bundle. Each resource is read exactly once per process (via
/// `static let`); the ~2.5 MB UTF-8 string for `mermaid.min.js` is held in
/// memory regardless of how many documents are opened, mirroring the
/// `MarkdownStylesheet.cached` pattern.
///
/// We do NOT take a SwiftPM dep on mermaid — it's a vendored JS blob at
/// `Sources/ViewerUI/Resources/mermaid/mermaid.min.js`, integrity recorded
/// in `VENDOR.md` and asserted by `MermaidVendorTests`.
public enum MermaidBundle {

    /// The full mermaid UMD bundle. Injected as a `WKUserScript` at
    /// `.atDocumentStart` so `window.mermaid` is defined before the page
    /// body parses.
    // NOTE the resource's BASE NAME is "mermaid.min" (the file is
    // mermaid.min.js): forResource:"mermaid" withExtension:"js" silently
    // returned nil and the empty-string fallback ate the failure — every
    // mermaid host degraded to raw source text (TSK-650). Pinned by
    // MermaidVendorTests' non-empty guard now.
    public static let runtime: String = load(name: "mermaid.min", ext: "js")

    /// Our wrapper around `mermaid.run()` — initializes theme, walks the
    /// step manifest, builds the control bar, wires keyboard handlers.
    /// Injected at `.atDocumentEnd`.
    public static let shimJS: String = load(name: "mermaid-shim", ext: "js")

    /// CSS for the `.mdv-mermaid` host + step transitions + control bar.
    /// Concatenated into the page's `<style>` block via
    /// `HTMLRenderer.renderPage(_:stylesheet:extraStylesheet:)` so the
    /// page is styled correctly before the JS shim runs (no flash of
    /// unstyled mermaid hosts).
    public static let shimCSS: String = load(name: "mermaid-shim", ext: "css")

    /// SwiftPM's `.process("Resources")` flattens subdirectories into the
    /// emitted resource bundle, so `Bundle.module.url(subdirectory:)`
    /// would return nil for the `mermaid/` subtree at runtime even though
    /// the source layout nests them. We rely on the flattened layout and
    /// keep `mermaid/` only as a source-tree organization choice.
    private static func load(name: String, ext: String) -> String {
        guard let url = Bundle.module.url(forResource: name, withExtension: ext) else {
            // Resource missing means the SwiftPM build dropped the file
            // — return empty string, the page will still load (mermaid
            // diagrams just won't render).
            return ""
        }
        guard let data = try? Data(contentsOf: url),
              let s = String(data: data, encoding: .utf8) else {
            return ""
        }
        return s
    }
}
