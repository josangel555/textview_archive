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
    public static func render(_ markdown: String) -> String {
        outcome(markdown).value
    }

    /// Same, but also reporting which engine produced the html.
    public static func outcome(
        _ markdown: String,
        defaults: UserDefaults = .standard,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> CoreOutcome<String> {
        RustCoreFallback.run(
            .markdown, defaults: defaults, environment: environment,
            rust: {
                let rendered = try mdvCoreMarkdownRender(text: markdown)
                return rendered.spliced(Self.enrich)
            },
            swift: { HTMLRenderer.renderSwiftPath(markdown) }
        )
    }

    /// Host-side chunk enrichment — the production twin of the closure the
    /// A/B suite uses (which now calls THIS, so test and app share one
    /// implementation).
    public static func enrich(_ chunk: CoreMarkdownChunk) -> String {
        let visitor = HTMLVisitor()
        switch chunk.kind {
        case "raw_html":
            return HTMLSanitizer.sanitize(chunk.payload)
        case "code":
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
