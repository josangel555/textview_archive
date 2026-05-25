import Foundation

/// Allowlist-based sanitizer for the raw-HTML pass-through that
/// `HTMLRenderer.visitHTMLBlock` / `visitInlineHTML` emit verbatim.
///
/// **Threat model.** Authored markdown can embed arbitrary HTML
/// (CommonMark §6.6). Pre-2026-05-25, those payloads were pasted
/// verbatim into the rendered page and the sole defense was an inline
/// CSP `<meta>` tag (finding §2.1 in
/// `docs/code-review/SECURITY_CONCURRENCY_2026-05-25.md`). That's
/// fragile: `<meta http-equiv>` CSP enforcement differs subtly from
/// header-CSP across WebKit versions, and `<script>` payloads embedded
/// in HTML blocks parse *before* the CSP can take effect in some race
/// windows.
///
/// **Policy.** Strip dangerous constructs at the renderer boundary:
///
///  * Drop entire `<script>`, `<style>`, `<iframe>`, `<object>`,
///    `<embed>`, `<form>`, `<input>`, `<button>`, `<link>`, `<meta>`
///    elements (including their contents).
///  * Remove `on*=` event-handler attributes from any surviving tag.
///  * Rewrite `href` / `src` / `xlink:href` attributes whose value
///    starts with `javascript:` or `vbscript:` to `about:blank`.
///  * Leave all other tags + attributes as-is. CommonMark authors
///    legitimately use `<div class=…>`, `<aside>`, `<figure>`, table
///    markup, MathJax-style `<span>`s — sanitizing those would break
///    real documents.
///
/// **NOT a security boundary against rich HTML attack patterns.** This
/// is defense-in-depth atop the CSP, not a replacement for it. We
/// don't parse-then-reserialize (no DOM in ViewerCore); a sufficiently
/// clever payload could survive the regex pass. Combined with
/// `default-src 'none'` CSP + the navigation policy delegate, the
/// residual surface is "CSS-only UI confusion attacks", which is what
/// we're willing to live with for v1.
public enum HTMLSanitizer {

    /// Tags whose entire element (including descendants until the
    /// matching close tag) is dropped. Names are lowercase; the
    /// matching is case-insensitive at compare time.
    private static let droppedElements: Set<String> = [
        "script", "style", "iframe", "object", "embed",
        "form", "input", "button", "select", "textarea",
        "link", "meta", "base",
    ]

    /// Returns a sanitized copy of `raw`. Pure function — safe to call
    /// from any actor.
    public static func sanitize(_ raw: String) -> String {
        var out = raw
        // Order matters: drop full elements first so we don't waste
        // work scrubbing event handlers on tags that are about to
        // disappear anyway.
        for tag in droppedElements {
            out = stripElement(named: tag, in: out)
        }
        // Strip orphaned close tags (the matched close was already
        // consumed by stripElement; this catches malformed input
        // where there's a close-only).
        for tag in droppedElements {
            out = stripStandaloneClose(named: tag, in: out)
        }
        out = stripEventHandlers(in: out)
        out = neutralizeJavaScriptURLs(in: out)
        return out
    }

    // MARK: - Internals

    /// Remove every `<tag …>…</tag>` (case-insensitive). Greedy match
    /// stops at the first matching close — nested `<tag>` inside is
    /// rare in legit markdown and a no-op for security since we're
    /// erasing the whole region. Self-closing variants
    /// (`<tag/>`, `<tag>` with no close) are also removed.
    static func stripElement(named tag: String, in source: String) -> String {
        let pattern = "(?is)<\(tag)\\b[^>]*?(?:/\\s*>|>.*?</\(tag)\\s*>|>)"
        guard let re = try? NSRegularExpression(
            pattern: pattern, options: []
        ) else { return source }
        let range = NSRange(source.startIndex..., in: source)
        return re.stringByReplacingMatches(
            in: source, options: [], range: range, withTemplate: ""
        )
    }

    /// Strip a stray `</tag>` with no opener earlier in the string.
    /// `stripElement` already eats the close when it eats the open.
    static func stripStandaloneClose(named tag: String, in source: String) -> String {
        let pattern = "(?i)</\(tag)\\s*>"
        guard let re = try? NSRegularExpression(
            pattern: pattern, options: []
        ) else { return source }
        let range = NSRange(source.startIndex..., in: source)
        return re.stringByReplacingMatches(
            in: source, options: [], range: range, withTemplate: ""
        )
    }

    /// Remove `on…="…"` (and single-quoted, and bare-token) variants
    /// from every tag. The regex matches inside `<…>` only so body
    /// text containing the literal "onclick=" survives intact.
    static func stripEventHandlers(in source: String) -> String {
        // Match attribute, allowing optional whitespace + = + quoted
        // or unquoted value. Anchored to whitespace boundary before
        // `on` so `mason-something` doesn't accidentally match.
        let pattern = #"(?i)\s+on[a-z]+\s*=\s*(?:"[^"]*"|'[^']*'|[^\s>]+)"#
        guard let re = try? NSRegularExpression(
            pattern: pattern, options: []
        ) else { return source }
        // We only want to scrub inside tag bodies, not free text. Pull
        // each `<...>` segment, run the regex on it, then stitch.
        return rewriteTagBodies(source) { body in
            let r = NSRange(body.startIndex..., in: body)
            return re.stringByReplacingMatches(
                in: body, options: [], range: r, withTemplate: ""
            )
        }
    }

    /// Rewrite `href="javascript:…"` / `src="…"` etc. to `about:blank`.
    /// We don't rewrite all attribute values — just the URL-bearing
    /// ones — so `<code>` blocks containing literal "javascript:" text
    /// are unaffected.
    static func neutralizeJavaScriptURLs(in source: String) -> String {
        // Comma-separated alternation in the lookbehind for the
        // attribute name. NSRegularExpression supports fixed-width
        // lookbehinds in modern macOS, but to stay portable we
        // capture the attribute name + quote and reproduce it.
        let pattern = #"(?i)(href|src|xlink:href|action|formaction|background|poster)\s*=\s*(["'])\s*(?:javascript|vbscript|data:text/html)[^"']*\2"#
        guard let re = try? NSRegularExpression(
            pattern: pattern, options: []
        ) else { return source }
        let r = NSRange(source.startIndex..., in: source)
        return re.stringByReplacingMatches(
            in: source, options: [], range: r,
            withTemplate: #"$1=$2about:blank$2"#
        )
    }

    /// Apply `transform` to every `<…>` segment in `source`, leaving
    /// text between tags alone. Tolerates `>` inside attribute values
    /// only insofar as the input is well-formed (CommonMark normalizes
    /// most of these). Pathological input that breaks the tokenizer
    /// degrades to "the body of the regex pass still runs, just with
    /// imprecise segmentation" — which is acceptable because the
    /// outer CSP is still in force.
    private static func rewriteTagBodies(
        _ source: String,
        transform: (String) -> String
    ) -> String {
        var out = ""
        out.reserveCapacity(source.count)
        var i = source.startIndex
        while i < source.endIndex {
            if source[i] == "<", let end = source[i...].firstIndex(of: ">") {
                let segment = String(source[i...end])
                out += transform(segment)
                i = source.index(after: end)
            } else {
                out.append(source[i])
                i = source.index(after: i)
            }
        }
        return out
    }
}
