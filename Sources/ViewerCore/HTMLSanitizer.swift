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
///    starts with `javascript:`, `vbscript:`, or `data:text/html`
///    to `about:blank`.
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

    /// Remove every `<tag …>…</tag>` (case-insensitive). The match
    /// stops at the first matching close — nested `<tag>` inside is
    /// rare in legit markdown and a no-op for security since we're
    /// erasing the whole region. Self-closing variants
    /// (`<tag/>`, `<tag>` with no close) are also removed.
    ///
    /// WV-3: the open tag's real boundary is found with the **quote-aware**
    /// `tagEnd` tokenizer, not a `[^>]*?` attribute run. A `>` inside a
    /// quoted attribute value (`<script foo="a>b">…`) does NOT terminate
    /// the open tag, so the element's residual tail can no longer leak as
    /// live markup. Mirrors the WV-1 fix already applied to
    /// `rewriteTagBodies`/`tagEnd`; `stripElement` is the load-bearing
    /// element-drop layer and must use the same structural boundaries.
    static func stripElement(named tag: String, in source: String) -> String {
        var out = ""
        out.reserveCapacity(source.count)
        var i = source.startIndex
        while i < source.endIndex {
            guard source[i] == "<",
                  let openEnd = matchOpenTag(named: tag, in: source, from: i)
            else {
                out.append(source[i])
                i = source.index(after: i)
                continue
            }
            // openEnd is the index of the open tag's closing `>`.
            // Self-closing (`<tag … />`) drops just the open tag.
            if isSelfClosing(in: source, openTagEnd: openEnd) {
                i = source.index(after: openEnd)
                continue
            }
            // Otherwise scan for the first matching `</tag …>`; if found,
            // erase through it, else drop just the open tag (matching the
            // old regex's bare-`>` fallback for an unterminated element).
            let afterOpen = source.index(after: openEnd)
            if let closeRange = matchCloseTag(named: tag, in: source, from: afterOpen) {
                i = closeRange.upperBound
            } else {
                i = afterOpen
            }
        }
        return out
    }

    /// If a `<tag …>` open tag starts at `start`, return the index of its
    /// closing `>` (quote-aware); else `nil`. Requires a word boundary
    /// after the tag name so `<scriptx>` is not matched as `<script>`.
    private static func matchOpenTag(
        named tag: String, in source: String, from start: String.Index
    ) -> String.Index? {
        // Must begin with `<` + tag name (case-insensitive).
        var i = source.index(after: start)   // skip '<'
        for ch in tag {
            guard i < source.endIndex,
                  source[i].lowercased() == String(ch)
            else { return nil }
            i = source.index(after: i)
        }
        // Word boundary: next char must end the name (not an HTML name
        // char). HTML tag names are ASCII letters/digits/`-`/`_`/`:`.
        if i < source.endIndex {
            let c = source[i]
            if c.isLetter || c.isNumber || c == "-" || c == "_" || c == ":" {
                return nil
            }
        }
        return tagEnd(in: source, from: start)
    }

    /// Whether the character immediately before the open tag's closing
    /// `>` is a `/` (optionally with trailing whitespace before `>`),
    /// i.e. the element is self-closing.
    private static func isSelfClosing(
        in source: String, openTagEnd: String.Index
    ) -> Bool {
        var j = openTagEnd
        while j > source.startIndex {
            j = source.index(before: j)
            let c = source[j]
            if c == "/" { return true }
            if c == " " || c == "\t" || c == "\n" || c == "\r" { continue }
            return false
        }
        return false
    }

    /// Find the first `</tag …>` close tag at or after `from`
    /// (case-insensitive, quote-aware for the optional trailing `>`),
    /// returning the range covering `<` … `>`. `nil` if none.
    private static func matchCloseTag(
        named tag: String, in source: String, from: String.Index
    ) -> Range<String.Index>? {
        var i = from
        while i < source.endIndex {
            guard source[i] == "<" else {
                i = source.index(after: i)
                continue
            }
            var j = source.index(after: i)   // skip '<'
            guard j < source.endIndex, source[j] == "/" else {
                i = source.index(after: i)
                continue
            }
            j = source.index(after: j)       // skip '/'
            var matched = true
            for ch in tag {
                guard j < source.endIndex,
                      source[j].lowercased() == String(ch)
                else { matched = false; break }
                j = source.index(after: j)
            }
            if matched, let end = tagEnd(in: source, from: i) {
                // Allow only whitespace between the name and the `>`.
                var k = j
                var ok = true
                while k < end {
                    let c = source[k]
                    if !(c == " " || c == "\t" || c == "\n" || c == "\r") {
                        ok = false; break
                    }
                    k = source.index(after: k)
                }
                if ok {
                    return i..<source.index(after: end)
                }
            }
            i = source.index(after: i)
        }
        return nil
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
    ///
    /// WV-2: handles BOTH quoted and **unquoted** values. The original
    /// regex required a surrounding quote (`(["'])…\2`), so
    /// `<a href=javascript:alert(1)>` (a perfectly valid HTML unquoted
    /// attribute) sailed through untouched. We run two passes:
    ///   1. quoted form — rewrites the value between the quotes,
    ///      preserving the quote char;
    ///   2. unquoted form — a bare `javascript:`/`vbscript:`/
    ///      `data:text/html` token up to the next whitespace or `>`.
    static func neutralizeJavaScriptURLs(in source: String) -> String {
        let urlAttrs = "href|src|xlink:href|action|formaction|background|poster"
        // (1) Quoted: capture attr name + quote char, reproduce them.
        let quoted = #"(?i)("# + urlAttrs + #")\s*=\s*(["'])\s*(?:javascript|vbscript|data:text/html)[^"']*\2"#
        // (2) Unquoted: value runs to whitespace or the tag close `>`.
        //     The leading whitespace requirement on the attr name keeps
        //     us from matching mid-token; `\s*=\s*` allows `href =`.
        let unquoted = #"(?i)("# + urlAttrs + #")\s*=\s*(?:javascript|vbscript|data:text/html)[^\s>]*"#

        var out = source
        if let re = try? NSRegularExpression(pattern: quoted, options: []) {
            let r = NSRange(out.startIndex..., in: out)
            out = re.stringByReplacingMatches(
                in: out, options: [], range: r,
                withTemplate: #"$1=$2about:blank$2"#
            )
        }
        if let re = try? NSRegularExpression(pattern: unquoted, options: []) {
            let r = NSRange(out.startIndex..., in: out)
            out = re.stringByReplacingMatches(
                in: out, options: [], range: r,
                withTemplate: #"$1=about:blank"#
            )
        }
        return out
    }

    /// Apply `transform` to every `<…>` segment in `source`, leaving
    /// text between tags alone.
    ///
    /// WV-1: the tag's closing `>` is found **quote-aware** — a `>`
    /// inside a single- or double-quoted attribute value does NOT end
    /// the tag. The previous `firstIndex(of: ">")` cut the segment at
    /// the first literal `>`, so a payload like
    /// `<a href="javascript:x>" onclick="steal()">` was split such that
    /// the `onclick=` handler fell OUTSIDE the scanned segment and
    /// survived `stripEventHandlers`. Tracking the quote state means the
    /// whole tag (handler included) is handed to `transform`.
    private static func rewriteTagBodies(
        _ source: String,
        transform: (String) -> String
    ) -> String {
        var out = ""
        out.reserveCapacity(source.count)
        var i = source.startIndex
        while i < source.endIndex {
            if source[i] == "<", let end = tagEnd(in: source, from: i) {
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

    /// Index of the `>` that closes the tag opened at `start`, skipping
    /// any `>` that sits inside a `"…"` or `'…'` attribute value.
    /// Returns `nil` if the tag is never closed (caller then treats the
    /// `<` as literal text). Mirrors the HTML tokenizer's rule that a
    /// quote toggles "inside attribute value" and `>` only terminates
    /// the tag when outside quotes.
    private static func tagEnd(in source: String, from start: String.Index) -> String.Index? {
        var i = source.index(after: start)   // skip the '<'
        var quote: Character? = nil
        while i < source.endIndex {
            let c = source[i]
            if let q = quote {
                if c == q { quote = nil }
            } else if c == "\"" || c == "'" {
                quote = c
            } else if c == ">" {
                return i
            }
            i = source.index(after: i)
        }
        return nil
    }
}
