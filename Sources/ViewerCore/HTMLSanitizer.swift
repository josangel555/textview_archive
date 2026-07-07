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
///  * Remove `on*=` event-handler attributes from any surviving tag —
///    including handlers abutting a previous attribute's closing quote
///    (`href="x"onclick=…`) or separated only by a `/` (`<svg/onload=…>`).
///  * Rewrite `href` / `src` / `xlink:href` attributes whose value
///    starts with `javascript:`, `vbscript:`, or `data:text/html`
///    to `about:blank`. The scheme is compared AFTER HTML-entity
///    decoding + ASCII-control-char stripping, so browser-decoded but
///    source-obfuscated schemes (`&#x6a;avascript:`, `jav\tascript:`)
///    are caught too.
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

    /// Tags whose entire element (including descendants until the matching
    /// close tag) is dropped. SINGLE-SOURCED from `HTMLSanitizerPolicy`
    /// (TSK-1507 s4) so the native + WebUI render paths sanitize identically.
    private static var droppedElements: Set<String> { HTMLSanitizerPolicy.droppedElements }

    /// TSK-1189 trusted mode (a LOCAL, user-opted-in document keeps its own
    /// `<script>`/`<style>` so a JS-render bundle can paint; every other drop
    /// + `javascript:`/`on*=` neutralization stays). Derived from the policy.
    private static var trustedDroppedElements: Set<String> {
        HTMLSanitizerPolicy.trustedDroppedElements
    }

    /// Returns a sanitized copy of `raw`. Pure function — safe to call from any
    /// actor. `trusted` (default `false`, so any caller that forgets gets the
    /// hardened path) keeps the document's own `<script>`/`<style>`; it must be
    /// fed SOLELY by `HTMLTrustPolicy.isTrusted` (local + opted-in).
    public static func sanitize(_ raw: String, trusted: Bool = false) -> String {
        var out = raw
        let drop = trusted ? trustedDroppedElements : droppedElements
        // Order matters: drop full elements first so we don't waste
        // work scrubbing event handlers on tags that are about to
        // disappear anyway.
        for tag in drop {
            out = stripElement(named: tag, in: out)
        }
        // Strip orphaned close tags (the matched close was already
        // consumed by stripElement; this catches malformed input
        // where there's a close-only).
        for tag in drop {
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
    ///
    /// H1b: the handler-name anchor is `[\s/"']` — NOT just `\s+`. HTML
    /// treats `/` and a closing quote as attribute separators, so a
    /// handler can abut the previous attribute's closing quote
    /// (`href="x"onclick=…`) or follow a slash (`<svg/onload=…>`); both
    /// are live handlers the old `\s+on` anchor sailed past. We keep the
    /// preceding boundary char (it belongs to the previous attribute /
    /// the tag) and drop only the handler that follows it.
    static func stripEventHandlers(in source: String) -> String {
        // Boundary before `on`: ASCII whitespace, `/`, a closing quote,
        // or the `<tagname` itself. We capture the boundary char (group 1)
        // and re-emit it via the template so we don't eat the previous
        // attribute's quote. Unicode-escaped class avoids a literal quote
        // inside the raw-string delimiter.
        let pattern = #"(?i)([\s/"'])on[a-z]+\s*=\s*(?:"[^"]*"|'[^']*'|[^\s>]+)"#
        guard let re = try? NSRegularExpression(
            pattern: pattern, options: []
        ) else { return source }
        // We only want to scrub inside tag bodies, not free text. Pull
        // each `<...>` segment, run the regex on it, then stitch.
        return rewriteTagBodies(source) { body in
            // Loop until a pass makes no change: a single pass can leave a
            // second handler whose boundary char was consumed as the first
            // handler's match prefix (the captured boundary is re-emitted,
            // so adjacency is preserved across passes).
            var current = body
            while true {
                let r = NSRange(current.startIndex..., in: current)
                let next = re.stringByReplacingMatches(
                    in: current, options: [], range: r, withTemplate: "$1"
                )
                if next == current { return next }
                current = next
            }
        }
    }

    /// URL-bearing attribute names whose value is scheme-checked. Single-
    /// sourced from `HTMLSanitizerPolicy` (TSK-1507 s4).
    private static var urlBearingAttrs: Set<String> { HTMLSanitizerPolicy.urlBearingAttributes }

    /// Schemes that execute script when a browser resolves the URL (compared
    /// against the decoded, lowercased leading scheme token). Single-sourced.
    private static var dangerousSchemes: Set<String> { HTMLSanitizerPolicy.dangerousSchemes }

    /// Rewrite `href="javascript:…"` / `src="…"` etc. to `about:blank`.
    /// We don't rewrite all attribute values — just the URL-bearing
    /// ones — so `<code>` blocks containing literal "javascript:" text
    /// are unaffected.
    ///
    /// H1b: the old regex matched the LITERAL token `javascript` /
    /// `vbscript` / `data:text/html` in the raw attribute value, so a
    /// browser-decoded but source-obfuscated scheme slipped past —
    /// `&#x6a;avascript:` (numeric entity), `&Tab;javascript:` (named
    /// entity), and `jav\tascript:` / `jav\nascript:` (embedded C0
    /// control chars) all decode to a live `javascript:` URL in WebKit
    /// yet never matched the literal. We now tokenize each tag's
    /// attributes quote-aware, DECODE the value (numeric/named HTML
    /// entities) and STRIP ASCII control chars BEFORE extracting the
    /// leading scheme, then rewrite the whole attribute to
    /// `name="about:blank"` if the decoded scheme is script-bearing.
    /// This also subsumes the WV-2 unquoted-value case.
    static func neutralizeJavaScriptURLs(in source: String) -> String {
        return rewriteTagBodies(source) { body in
            rewriteDangerousURLAttrs(inTag: body)
        }
    }

    /// Given a single `<…>` tag segment, rewrite any URL-bearing
    /// attribute whose decoded value carries a dangerous scheme to
    /// `name="about:blank"`. Non-URL attrs and safe schemes are left
    /// byte-for-byte unchanged.
    private static func rewriteDangerousURLAttrs(inTag tag: String) -> String {
        // Only operate on a well-formed `<…>` segment.
        guard let first = tag.first, first == "<" else { return tag }
        let chars = Array(tag)
        var out = ""
        out.reserveCapacity(tag.count)
        var i = 0
        let n = chars.count
        // Emit `<` and the tag name verbatim; attribute scan starts after.
        out.append(chars[i]); i += 1
        // Walk the rest, copying through, but recognising `name=value`
        // attribute spans so we can inspect URL-bearing ones.
        while i < n {
            let c = chars[i]
            // An attribute name starts at a name char following a
            // separator. Detect a potential `name = value` run.
            if isAttrNameStart(c) {
                let nameStart = i
                var j = i
                while j < n, isAttrNameChar(chars[j]) { j += 1 }
                let name = String(chars[nameStart..<j]).lowercased()
                // Skip whitespace before a possible `=`.
                var k = j
                while k < n, isASCIIWhitespace(chars[k]) { k += 1 }
                if k < n, chars[k] == "=", urlBearingAttrs.contains(name) {
                    // Parse the value (quoted or unquoted).
                    var v = k + 1
                    while v < n, isASCIIWhitespace(chars[v]) { v += 1 }
                    if v < n, chars[v] == "\"" || chars[v] == "'" {
                        let quote = chars[v]
                        let valStart = v + 1
                        var w = valStart
                        while w < n, chars[w] != quote { w += 1 }
                        let value = String(chars[valStart..<w])
                        if hasDangerousScheme(value) {
                            out.append("\(name)=\(quote)about:blank\(quote)")
                        } else {
                            out.append(contentsOf: chars[nameStart...min(w, n - 1)])
                        }
                        i = (w < n) ? w + 1 : w   // skip past closing quote
                        continue
                    } else {
                        // Unquoted: value runs to whitespace or `>`.
                        let valStart = v
                        var w = valStart
                        while w < n, !isASCIIWhitespace(chars[w]), chars[w] != ">" { w += 1 }
                        let value = String(chars[valStart..<w])
                        if hasDangerousScheme(value) {
                            out.append("\(name)=about:blank")
                        } else {
                            out.append(contentsOf: chars[nameStart..<w])
                        }
                        i = w
                        continue
                    }
                }
                // Not a URL attr (or no `=`): copy the name verbatim and
                // continue from j so we don't re-scan it.
                out.append(contentsOf: chars[nameStart..<j])
                i = j
                continue
            }
            out.append(c)
            i += 1
        }
        return out
    }

    /// True if the attribute value, once HTML-decoded and stripped of
    /// ASCII control chars, begins with a script-bearing scheme.
    private static func hasDangerousScheme(_ rawValue: String) -> Bool {
        let decoded = decodeEntitiesAndStripControls(rawValue)
        // Leading whitespace is ignored by URL parsers.
        let trimmed = decoded.drop(while: { $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\r" })
        guard let colon = trimmed.firstIndex(of: ":") else { return false }
        let scheme = trimmed[trimmed.startIndex..<colon].lowercased()
        // A real scheme is a single token of [a-z0-9+.-]; anything else
        // (a path with a `:` in it, e.g. `a:b` in a query) isn't a scheme.
        guard !scheme.isEmpty,
              scheme.allSatisfy({ ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "+" || $0 == "-" || $0 == "." })
        else { return false }
        if dangerousSchemes.contains(scheme) { return true }
        // `data:` is only dangerous when it renders attacker HTML; keep
        // legitimate `data:image/png;…` srcs working (parity with the
        // pre-H1b literal `data:text/html`).
        if scheme == "data" {
            let afterColon = trimmed[trimmed.index(after: colon)...].lowercased()
            return afterColon.hasPrefix("text/html")
        }
        return false
    }

    /// Decode numeric (`&#NN;` / `&#xHH;`) and a small set of named HTML
    /// entities, and drop ASCII C0 control chars (`\x00`–`\x1f`) plus
    /// DEL (`\x7f`). Browsers strip these from a URL scheme before
    /// resolving it, so we must too before the scheme comparison. We
    /// deliberately only decode the named entities a scheme-obfuscation
    /// payload would use (`&Tab;`, `&NewLine;`, `&colon;`); a full named-
    /// entity table is unnecessary for the scheme prefix.
    static func decodeEntitiesAndStripControls(_ value: String) -> String {
        let named: [String: Unicode.Scalar] = [
            "tab": "\u{09}", "newline": "\u{0a}", "colon": ":",
            "sol": "/", "lpar": "(", "rpar": ")", "comma": ",",
        ]
        let scalars = Array(value.unicodeScalars)
        var result = String.UnicodeScalarView()
        var i = 0
        let n = scalars.count
        func appendIfPrintable(_ u: Unicode.Scalar) {
            if u.value > 0x1f && u.value != 0x7f { result.append(u) }
        }
        while i < n {
            let sc = scalars[i]
            guard sc == "&" else {
                appendIfPrintable(sc)
                i += 1
                continue
            }
            var j = i + 1
            if j < n, scalars[j] == "#" {
                j += 1
                var hex = false
                if j < n, scalars[j] == "x" || scalars[j] == "X" { hex = true; j += 1 }
                let digitsStart = j
                while j < n {
                    let d = scalars[j]
                    let isDec = ("0"..."9").contains(d)
                    let isHexAlpha = hex && (("a"..."f").contains(d) || ("A"..."F").contains(d))
                    if isDec || isHexAlpha { j += 1 } else { break }
                }
                if j > digitsStart {
                    let numStr = String(String.UnicodeScalarView(scalars[digitsStart..<j]))
                    if let code = UInt32(numStr, radix: hex ? 16 : 10),
                       let u = Unicode.Scalar(code) {
                        if j < n, scalars[j] == ";" { j += 1 }  // optional `;`
                        appendIfPrintable(u)
                        i = j
                        continue
                    }
                }
            } else if j < n {
                // Named entity: letters up to a `;` (bounded length).
                let nameStart = j
                while j < n, j - nameStart < 12,
                      ("a"..."z").contains(scalars[j]) || ("A"..."Z").contains(scalars[j]) {
                    j += 1
                }
                if j > nameStart, j < n, scalars[j] == ";" {
                    let name = String(String.UnicodeScalarView(scalars[nameStart..<j])).lowercased()
                    if let u = named[name] {
                        j += 1  // consume `;`
                        appendIfPrintable(u)
                        i = j
                        continue
                    }
                }
            }
            // Not a recognised entity: emit the `&` literally.
            appendIfPrintable(sc)
            i += 1
        }
        return String(result)
    }

    private static func isASCIIWhitespace(_ c: Character) -> Bool {
        c == " " || c == "\t" || c == "\n" || c == "\r"
    }

    /// HTML attribute names are ASCII letters/digits/`-`/`_`/`:`.
    private static func isAttrNameStart(_ c: Character) -> Bool {
        c.isLetter || c == "_" || c == ":"
    }

    private static func isAttrNameChar(_ c: Character) -> Bool {
        c.isLetter || c.isNumber || c == "-" || c == "_" || c == ":" || c == "."
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
