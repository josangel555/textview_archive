import Foundation
import RustCore
import ViewerKit

/// Routes markdown→HTML rendering through the Rust core (TSK-648; engine
/// port TSK-631) when the `.markdown` gate is on, falling back to the Swift
/// `HTMLVisitor` path otherwise. The seam lives inside `HTMLRenderer.render`
/// so every consumer (the memoized rendered-lens path, the split pane) routes
/// without change and the `renderPage` CSP wrapper stays byte-identical.
///
/// The rust core returns STRUCTURAL html plus enrichment chunks; the splice
/// applies the host-coupled pieces here, at the render trust boundary:
///   • `raw_html`  → `HTMLSanitizer.sanitize` (the security barrier — raw
///     markup never crosses the wire un-sanitized into the page);
///   • `code`      → TreeSitter `tok-*` spans (or plain escape for unknown
///     languages) — retires when the TSK-660 highlight port lands;
///   • any UNKNOWN kind (version skew with a newer core) → the payload
///     ESCAPED as visible text: degrade visibly, never inject raw.
///
/// Documented behavioral divergence on the rust path: no PARSE-03
/// leading-nesting refusal — pulldown-cmark is an iterative pull parser, so
/// a `>`-nesting bomb renders fully instead of returning the truncation
/// marker (the Swift path keeps its guard for the fallback).
public enum RustMarkdownAdapter {

    /// `HTMLRenderer.render`'s routed body.
    public static func render(
        _ markdown: String,
        authorHTML: HTMLRenderer.AuthorHTMLDisposition = .sanitize
    ) -> String {
        outcome(markdown, authorHTML: authorHTML).value
    }

    /// Same, but also reporting which engine produced the html.
    public static func outcome(
        _ markdown: String,
        authorHTML: HTMLRenderer.AuthorHTMLDisposition = .sanitize,
        defaults: UserDefaults = .standard,
        environment: [String: String]? = nil
    ) -> CoreOutcome<String> {
        RustCoreFallback.run(
            .markdown, defaults: defaults, environment: environment,
            rust: {
                let rendered = try mdvCoreMarkdownRender(text: markdown)
                return rendered.spliced { enrich($0, authorHTML: authorHTML) }
            },
            swift: { HTMLRenderer.renderSwiftPath(markdown, authorHTML: authorHTML) }
        )
    }

    /// Host-side chunk enrichment — the production twin of the closure the
    /// A/B suite uses (which now calls THIS, so test and app share one
    /// implementation). `authorHTML` mirrors the Swift visitor: in-app
    /// sanitizes (CSP backstops), the export path escapes (TSK-966).
    public static func enrich(
        _ chunk: CoreMarkdownChunk,
        authorHTML: HTMLRenderer.AuthorHTMLDisposition = .sanitize
    ) -> String {
        let visitor = HTMLVisitor()
        switch chunk.kind {
        case "raw_html":
            switch authorHTML {
            case .sanitize: return HTMLSanitizer.sanitize(chunk.payload)
            case .escape:   return visitor.htmlEscape(chunk.payload)
            }
        case "code":
            // NOTE (TSK-713): diagram routing for dot/plantuml fences on the
            // rust render path is NOT done here. The rust core emits a `code`
            // chunk for the fence BODY only — it has already written the
            // enclosing `<pre><code class="language-…">` wrapper to the
            // structural HTML (see rust-core markdown.rs `TagEnd::CodeBlock`).
            // Returning a `<figure>` host element from here would nest it
            // inside that `<pre><code>` and break the markup. Centralized
            // diagram routing for the rust path is a follow-up slice that needs
            // a Rust-side full-host render (the same treatment mermaid already
            // gets via `crate::mermaid::render_host`, TSK-661) so no chunk
            // round-trips. The Swift fallback path (`HTMLVisitor.visitCodeBlock`)
            // routes dot/plantuml through the registry today.
            let lang = HighlightLanguage.detect(fromInfoString: chunk.lang)
            if lang != .plainText {
                let runs = RustHighlightAdapter.tokenize(chunk.payload, language: lang)
                return visitor.spanned(chunk.payload, runs: runs)
            }
            return visitor.htmlEscape(chunk.payload)
        default:
            // Version-skew safety: a newer core may emit kinds this build
            // doesn't know. Escaped-as-text keeps the content visible
            // without ever splicing un-sanitized markup.
            return visitor.htmlEscape(chunk.payload)
        }
    }
}
