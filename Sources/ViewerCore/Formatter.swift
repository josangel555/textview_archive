import Foundation

/// Pretty-printing for structured text formats.
///
/// Supported: JSON, XML, JS, CSS. Future: YAML, TOML.
///
/// Each format degrades gracefully — if parsing fails, the original
/// content is returned (so a malformed JSON file doesn't become empty).
/// JS and CSS use dependency-free lexical re-indenters (see `prettyPrintJS`
/// / `prettyPrintCSS`) that only ever rewrite whitespace OUTSIDE
/// string/comment (and, for JS, template/regex) literals, so they can never
/// alter code meaning.
public enum Formatter {

    public enum SupportedFormat: String, CaseIterable, Sendable {
        case json
        case xml
        case js
        case css
        /// Markdown pipe-table alignment. NOT produced by `detect` (markdown has
        /// no format view lens by design) — invoked explicitly by the in-place
        /// "Align Markdown Tables" editor command (TSK-350).
        case markdown

        /// Detect a supported format from a URL's path extension.
        ///
        /// NB: `.jsonl` is deliberately absent — JSON-Lines is one JSON
        /// value *per line*, not a single document, so `JSONSerialization`
        /// would fail and `prettyPrintJSON` would return the content
        /// unchanged. Mapping it here offered a Format affordance that
        /// could never format (didFormat:false). `.svg` is likewise absent:
        /// `FileTypeDetector` classifies it as `.image` (preview/HEX only),
        /// so it never reaches a Formatter — listing it as `.xml` was dead
        /// config that leaked a contradictory third identity for SVG.
        public static func detect(_ url: URL) -> SupportedFormat? {
            switch url.pathExtension.lowercased() {
            case "json":
                return .json
            case "xml", "plist", "xib", "storyboard", "html", "htm", "xhtml":
                // XMLDocument handles these as XML; HTML strictness is
                // looser via the .documentTidyHTML option (we pass that).
                return .xml
            case "js", "mjs", "cjs":
                // Minified/one-line JS → structural re-indent. `.jsx`/`.ts`
                // are deliberately absent: their extra syntax (JSX elements,
                // type annotations) isn't modelled by the brace re-indenter,
                // so offering Format there would mis-indent without warning.
                return .js
            case "css":
                // Minified CSS → structural re-indent. `.scss`/`.less` are
                // deliberately absent: they add `//` line comments (and nesting
                // syntax) the plain-CSS lexer doesn't model, so a `;` or `{`
                // inside a `//` comment would be mis-read.
                return .css
            // NB: `.md` is intentionally NOT detected here. `detect` gates the
            // format VIEW LENS (`.formatted`) + the Format toggle, and markdown
            // deliberately has no format mode (its lenses are Rendered/Source —
            // FormatToggleTests). Markdown table alignment (`.markdown` /
            // `prettyPrintMarkdown`) is surfaced as an IN-PLACE editor command
            // instead (TSK-350), so it never adds a `.formatted` lens.
            default:
                return nil
            }
        }
    }

    /// Pretty-print `content` as `format`. Returns the original string
    /// unchanged on parse failure — callers should validate by comparing
    /// length / content if they need a hard "did it format" signal.
    public static func prettyPrint(_ content: String, as format: SupportedFormat) -> String {
        switch format {
        case .json: return prettyPrintJSON(content)
        case .xml:  return prettyPrintXML(content)
        case .js:   return prettyPrintJS(content)
        case .css:  return prettyPrintCSS(content)
        case .markdown: return prettyPrintMarkdown(content)
        }
    }

    /// Convenience: detect format from URL and pretty-print, or return
    /// the original if the file extension isn't formattable.
    public static func prettyPrintIfFormattable(
        _ content: String,
        url: URL
    ) -> (formatted: String, didFormat: Bool) {
        guard let format = SupportedFormat.detect(url) else {
            return (content, false)
        }
        let out = prettyPrint(content, as: format)
        return (out, out != content)
    }

    // MARK: - JSON

    private static func prettyPrintJSON(_ content: String) -> String {
        guard let data = content.data(using: .utf8) else { return content }
        guard let obj = try? JSONSerialization.jsonObject(
            with: data,
            options: [.fragmentsAllowed]
        ) else { return content }
        // .sortedKeys makes pretty-printed output deterministic (great
        // for diffing). Skip if it'd reorder a meaningful key sequence
        // — but most JSON files are configuration, where sorted is fine.
        guard let pretty = try? JSONSerialization.data(
            withJSONObject: obj,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        ) else { return content }
        return String(data: pretty, encoding: .utf8) ?? content
    }

    // MARK: - XML

    private static func prettyPrintXML(_ content: String) -> String {
        guard let data = content.data(using: .utf8) else { return content }
        var options: XMLNode.Options = []
        // Permissive parsing so a near-XML HTML document doesn't fail.
        options.insert(.documentTidyHTML)
        options.insert(.documentTidyXML)
        let doc: XMLDocument
        do {
            doc = try XMLDocument(data: data, options: options)
        } catch {
            return content
        }
        return doc.xmlString(options: [.nodePrettyPrint])
    }

    // MARK: - JavaScript

    private static let jsIndentUnit = "  "

    /// Keywords after which a `/` begins a regex literal (not division).
    private static let jsRegexPrecedingKeywords: Set<String> = [
        "return", "typeof", "instanceof", "in", "of", "new", "delete",
        "void", "do", "else", "yield", "await", "case",
    ]

    /// `}`-trailing words that CONTINUE the previous statement and so must
    /// stay on the same line as the closing brace (`}else`, `}catch`, …)
    /// rather than starting a fresh statement line.
    private static let jsBraceContinuationWords: Set<String> = [
        "else", "catch", "finally", "while", "instanceof", "in", "of",
    ]

    private static func jsIsWord(_ c: Character) -> Bool {
        c == "_" || c == "$" || c.isLetter || c.isNumber
    }

    private static func jsIsWordStart(_ c: Character) -> Bool {
        c == "_" || c == "$" || c.isLetter
    }

    /// A dependency-free re-indenter for minified / one-line JavaScript.
    ///
    /// This is deliberately NOT a full beautifier (no AST, no third-party
    /// parser). It is a lexical-state machine that restores block structure by
    /// inserting newlines + indentation around `{`, `}` and statement-ending
    /// `;`, while tracking string, template, line/block comment and regex
    /// context so those structural characters are ignored inside literals.
    ///
    /// Correctness guarantee: it **only ever changes whitespace OUTSIDE
    /// literals** — every non-whitespace character, and every byte inside a
    /// string / template / comment / regex, is preserved exactly and in order.
    /// So it can never change the code's meaning; the worst failure mode is
    /// awkward indentation (and Pretty-Print is a display-only transform, so
    /// there is no data-loss risk regardless). The invariant is pinned by the
    /// `jsSignificantContent` differential test.
    ///
    /// Regex-vs-division disambiguation uses the standard "preceding token"
    /// heuristic (a `/` is a regex iff the previous significant token is an
    /// operator/opener or a regex-preceding keyword), which covers the vast
    /// majority of real code.
    private static func prettyPrintJS(_ content: String) -> String {
        let chars = Array(content)
        let n = chars.count
        guard n > 0 else { return content }

        var out = ""
        out.reserveCapacity(n + n / 4)

        var indent = 0
        var atLineStart = true       // nothing emitted on the current line yet
        var pendingSpace = false     // collapsed run of code whitespace, unflushed
        var parenDepth = 0
        var bracketDepth = 0
        var lastSig: Character? = nil // last significant code char emitted
        var lastWord = ""            // identifier currently/last being built
        var prevValue = false        // prev significant token was a complete value
        // Brace stack: `.block` = a real `{…}` we indent; `.interp` = a `${…}`
        // template interpolation whose `}` returns us to the template string.
        enum Brace { case block, interp }
        var braceStack: [Brace] = []

        func flushBeforeToken() {
            if atLineStart {
                for _ in 0..<max(0, indent) { out += jsIndentUnit }
                atLineStart = false
                pendingSpace = false
            } else if pendingSpace {
                out.append(" ")
                pendingSpace = false
            }
        }

        // Emit one significant code character (operator/punctuation/word char).
        func emitCode(_ c: Character) {
            flushBeforeToken()
            out.append(c)
            lastSig = c
            if jsIsWord(c) { lastWord.append(c) } else { lastWord = "" }
            prevValue = false
        }

        // Emit a complete literal (string/template/regex) verbatim. The body
        // is already accumulated; this just flushes layout + records that a
        // value token closed (so a following `/` is division).
        func emitLiteral(_ s: String) {
            flushBeforeToken()
            out += s
            lastSig = s.last
            lastWord = ""
            prevValue = true
        }

        func newlineBreak() {
            pendingSpace = false
            if !atLineStart {
                out.append("\n")
                atLineStart = true
            }
        }

        func regexAllowedHere() -> Bool {
            guard let p = lastSig else { return true } // start of input
            if prevValue { return false }              // value end → division
            if jsIsWord(p) { return jsRegexPrecedingKeywords.contains(lastWord) }
            return true                                // operator/opener → regex
        }

        func indexOfNextNonWS(after k: Int) -> Int? {
            var j = k + 1
            while j < n, chars[j] == " " || chars[j] == "\t"
                || chars[j] == "\n" || chars[j] == "\r" { j += 1 }
            return j < n ? j : nil
        }

        var i = 0
        while i < n {
            let c = chars[i]

            // Whitespace in code → collapse to a single pending space.
            if c == " " || c == "\t" || c == "\n" || c == "\r" {
                if !atLineStart { pendingSpace = true }
                i += 1
                continue
            }

            // Comments.
            if c == "/", i + 1 < n, chars[i + 1] == "/" {
                var j = i
                var lit = ""
                while j < n, chars[j] != "\n", chars[j] != "\r" {
                    lit.append(chars[j]); j += 1
                }
                emitLiteral(lit)
                // A `//` comment runs to end-of-line; force the break so the
                // next token can't be swallowed onto the comment line.
                newlineBreak()
                i = j
                continue
            }
            if c == "/", i + 1 < n, chars[i + 1] == "*" {
                var j = i + 2
                var lit = "/*"
                while j < n {
                    if chars[j] == "*", j + 1 < n, chars[j + 1] == "/" {
                        lit += "*/"; j += 2; break
                    }
                    lit.append(chars[j]); j += 1
                }
                emitLiteral(lit)
                i = j
                continue
            }

            // Regex literal.
            if c == "/", regexAllowedHere() {
                var j = i + 1
                var lit = "/"
                var inClass = false
                var closed = false
                while j < n {
                    let r = chars[j]
                    lit.append(r)
                    if r == "\\", j + 1 < n {
                        lit.append(chars[j + 1]); j += 2; continue
                    }
                    if r == "\n" || r == "\r" { break } // unterminated; bail
                    if r == "[" { inClass = true }
                    else if r == "]" { inClass = false }
                    else if r == "/" && !inClass { j += 1; closed = true; break }
                    j += 1
                }
                if closed {
                    while j < n, jsIsWord(chars[j]) { lit.append(chars[j]); j += 1 }
                    emitLiteral(lit)
                    i = j
                    continue
                }
                // Not a real regex (no close) — fall through, treat `/` as code.
            }

            // String literals.
            if c == "'" || c == "\"" {
                let quote = c
                var j = i + 1
                var lit = String(c)
                while j < n {
                    let s = chars[j]
                    lit.append(s)
                    if s == "\\", j + 1 < n { lit.append(chars[j + 1]); j += 2; continue }
                    if s == quote { j += 1; break }
                    j += 1
                }
                emitLiteral(lit)
                i = j
                continue
            }

            // Template literal — may embed `${ code }`; scan to the matching
            // backtick, switching to code at each interpolation.
            if c == "`" {
                flushBeforeToken()
                out.append("`")
                lastSig = "`"; lastWord = ""; prevValue = true
                i += 1
                var done = false
                while i < n, !done {
                    let t = chars[i]
                    if t == "\\", i + 1 < n {
                        out.append(t); out.append(chars[i + 1]); i += 2; continue
                    }
                    if t == "`" { out.append("`"); i += 1; done = true; break }
                    if t == "$", i + 1 < n, chars[i + 1] == "{" {
                        out += "${"
                        braceStack.append(.interp)
                        lastSig = "{"; lastWord = ""; prevValue = false
                        i += 2
                        // Re-enter the main loop in code mode until the
                        // matching `}` pops this interpolation.
                        break
                    }
                    out.append(t); i += 1
                }
                if done { prevValue = true; lastSig = "`" }
                continue
            }

            // Structural: open brace.
            if c == "{" {
                // Empty block `{}` (possibly with whitespace) stays inline.
                if let k = indexOfNextNonWS(after: i), chars[k] == "}" {
                    emitCode("{")
                    out.append("}")
                    lastSig = "}"; lastWord = ""; prevValue = false
                    i = k + 1
                    continue
                }
                emitCode("{")
                braceStack.append(.block)
                indent += 1
                newlineBreak()
                i += 1
                continue
            }

            // Structural: close brace.
            if c == "}" {
                let kind = braceStack.popLast() ?? .block
                if kind == .interp {
                    // End of `${…}`: emit `}` and resume the template string.
                    flushBeforeToken()
                    out.append("}")
                    i += 1
                    var done = false
                    while i < n, !done {
                        let t = chars[i]
                        if t == "\\", i + 1 < n {
                            out.append(t); out.append(chars[i + 1]); i += 2; continue
                        }
                        if t == "`" { out.append("`"); i += 1; done = true; break }
                        if t == "$", i + 1 < n, chars[i + 1] == "{" {
                            out += "${"
                            braceStack.append(.interp)
                            lastSig = "{"; lastWord = ""; prevValue = false
                            i += 2
                            break
                        }
                        out.append(t); i += 1
                    }
                    if done { lastSig = "`"; lastWord = ""; prevValue = true }
                    continue
                }
                // Block close: dedent, brace on its own line.
                indent -= 1
                newlineBreak()
                emitCode("}")
                i += 1
                // Start a new line before the next statement, unless what
                // follows continues this one (`else`/`catch`/…) or is a
                // closer / chain / separator that belongs inline.
                if parenDepth == 0, bracketDepth == 0,
                   let k = indexOfNextNonWS(after: i - 1) {
                    let nc = chars[k]
                    if jsIsWordStart(nc) {
                        var w = ""
                        var m = k
                        while m < n, jsIsWord(chars[m]) { w.append(chars[m]); m += 1 }
                        if !jsBraceContinuationWords.contains(w) { newlineBreak() }
                    }
                }
                continue
            }

            // Statement separator.
            if c == ";" {
                emitCode(";")
                if parenDepth == 0, bracketDepth == 0 { newlineBreak() }
                i += 1
                continue
            }

            // Depth tracking for ( ) [ ].
            if c == "(" { emitCode("("); parenDepth += 1; i += 1; continue }
            if c == ")" {
                emitCode(")")
                parenDepth = max(0, parenDepth - 1)
                prevValue = true
                i += 1
                continue
            }
            if c == "[" { emitCode("["); bracketDepth += 1; i += 1; continue }
            if c == "]" {
                emitCode("]")
                bracketDepth = max(0, bracketDepth - 1)
                prevValue = true
                i += 1
                continue
            }

            // Any other code character.
            emitCode(c)
            i += 1
        }

        // Trim a trailing newline introduced by a final structural break.
        while out.hasSuffix("\n") { out.removeLast() }
        return out
    }

    /// Extracts the "significant" content of a JS source — every byte except
    /// whitespace that lies OUTSIDE a string / template / comment / regex
    /// literal, with such whitespace collapsed to a single space only where it
    /// separates two identifier characters (so token boundaries are kept).
    ///
    /// Used by tests as an INDEPENDENT lexer: `prettyPrintJS` must preserve
    /// `jsSignificantContent` exactly. If the formatter were to drop/reorder a
    /// character, or mis-lex a regex such that it injected a newline inside the
    /// literal, this projection of input and output would diverge.
    static func jsSignificantContent(_ content: String) -> String {
        let chars = Array(content)
        let n = chars.count
        var out: [Character] = []
        out.reserveCapacity(n)

        func emit(_ c: Character) { out.append(c) }

        var prevWasWord = false
        var pendingSpace = false
        func emitCode(_ c: Character) {
            let isW = (c == "_" || c == "$" || c.isLetter || c.isNumber)
            if pendingSpace {
                if prevWasWord && isW { emit(" ") }
                pendingSpace = false
            }
            emit(c)
            prevWasWord = isW
        }
        func emitVerbatim(_ s: [Character]) {
            // A literal/comment is significant in full; it cannot start a
            // word-merge with a following identifier across a space.
            pendingSpace = false
            for ch in s { emit(ch) }
            prevWasWord = false
        }

        func regexAllowed(_ lastSig: Character?, _ lastWord: String, _ prevValue: Bool) -> Bool {
            guard let p = lastSig else { return true }
            if prevValue { return false }
            if p == "_" || p == "$" || p.isLetter || p.isNumber {
                return jsRegexPrecedingKeywords.contains(lastWord)
            }
            return true
        }

        var lastSig: Character? = nil
        var lastWord = ""
        var prevValue = false
        func sawCode(_ c: Character) {
            lastSig = c
            if c == "_" || c == "$" || c.isLetter || c.isNumber { lastWord.append(c) }
            else { lastWord = "" }
            prevValue = false
        }
        func sawValue(_ last: Character?) { lastSig = last; lastWord = ""; prevValue = true }

        var i = 0
        var templateDepth = 0   // backtick nesting via `${`
        var interpBraces: [Int] = []
        while i < n {
            let c = chars[i]
            if c == " " || c == "\t" || c == "\n" || c == "\r" { pendingSpace = true; i += 1; continue }

            if c == "/", i + 1 < n, chars[i + 1] == "/" {
                var j = i; var lit: [Character] = []
                while j < n, chars[j] != "\n", chars[j] != "\r" { lit.append(chars[j]); j += 1 }
                emitVerbatim(lit); sawValue(lit.last); i = j; continue
            }
            if c == "/", i + 1 < n, chars[i + 1] == "*" {
                var j = i + 2; var lit: [Character] = ["/", "*"]
                while j < n {
                    if chars[j] == "*", j + 1 < n, chars[j + 1] == "/" { lit += ["*", "/"]; j += 2; break }
                    lit.append(chars[j]); j += 1
                }
                emitVerbatim(lit); sawValue(lit.last); i = j; continue
            }
            if c == "/", regexAllowed(lastSig, lastWord, prevValue) {
                var j = i + 1; var lit: [Character] = ["/"]; var inClass = false; var closed = false
                while j < n {
                    let r = chars[j]; lit.append(r)
                    if r == "\\", j + 1 < n { lit.append(chars[j + 1]); j += 2; continue }
                    if r == "\n" || r == "\r" { break }
                    if r == "[" { inClass = true } else if r == "]" { inClass = false }
                    else if r == "/" && !inClass { j += 1; closed = true; break }
                    j += 1
                }
                if closed {
                    while j < n, (chars[j] == "_" || chars[j] == "$" || chars[j].isLetter || chars[j].isNumber) {
                        lit.append(chars[j]); j += 1
                    }
                    emitVerbatim(lit); sawValue(lit.last); i = j; continue
                }
            }
            if c == "'" || c == "\"" {
                let q = c; var j = i + 1; var lit: [Character] = [c]
                while j < n {
                    let s = chars[j]; lit.append(s)
                    if s == "\\", j + 1 < n { lit.append(chars[j + 1]); j += 2; continue }
                    if s == q { j += 1; break }
                    j += 1
                }
                emitVerbatim(lit); sawValue(lit.last); i = j; continue
            }
            if c == "`" {
                emitVerbatim(["`"]); templateDepth += 1; interpBraces.append(0)
                lastSig = "`"; lastWord = ""; prevValue = true; i += 1
                // scan template body
                while i < n {
                    let t = chars[i]
                    if t == "\\", i + 1 < n { emitVerbatim([t, chars[i + 1]]); i += 2; continue }
                    if t == "`" { emitVerbatim(["`"]); templateDepth -= 1; interpBraces.removeLast(); sawValue("`"); i += 1; break }
                    if t == "$", i + 1 < n, chars[i + 1] == "{" {
                        emitVerbatim(["$", "{"]); i += 2
                        lastSig = "{"; lastWord = ""; prevValue = false
                        break // resume code mode in the outer loop
                    }
                    emitVerbatim([t]); i += 1
                }
                continue
            }
            if c == "}", let top = interpBraces.last, top == 0, templateDepth > 0 {
                // Close of `${…}` → resume the enclosing template.
                emitVerbatim(["}"]); i += 1
                while i < n {
                    let t = chars[i]
                    if t == "\\", i + 1 < n { emitVerbatim([t, chars[i + 1]]); i += 2; continue }
                    if t == "`" { emitVerbatim(["`"]); templateDepth -= 1; interpBraces.removeLast(); sawValue("`"); i += 1; break }
                    if t == "$", i + 1 < n, chars[i + 1] == "{" {
                        emitVerbatim(["$", "{"]); i += 2; lastSig = "{"; lastWord = ""; prevValue = false; break
                    }
                    emitVerbatim([t]); i += 1
                }
                continue
            }
            if c == "{", templateDepth > 0, !interpBraces.isEmpty {
                interpBraces[interpBraces.count - 1] += 1
            }
            if c == "}", templateDepth > 0, !interpBraces.isEmpty, interpBraces[interpBraces.count - 1] > 0 {
                interpBraces[interpBraces.count - 1] -= 1
            }
            if c == ")" || c == "]" { emitCode(c); sawValue(c); i += 1; continue }
            emitCode(c); sawCode(c); i += 1
        }
        return String(out)
    }

    // MARK: - CSS

    /// A dependency-free re-indenter for minified CSS — a simpler sibling of
    /// `prettyPrintJS`. CSS has no regex, no template literals and no line
    /// comments, so the only lexical state to track is string (`"…"` / `'…'`)
    /// and block comment (`/* … */`); a bare `/` is just a value character
    /// (`font: 12px/1.4`, `url(http://…)`), NOT a comment unless followed by
    /// `*`. It re-indents around `{`, `}`, declaration-ending `;` and
    /// top-level selector-list `,` (commas inside `()` value lists / `rgb(…)`
    /// and inside a rule body are left inline).
    ///
    /// Same correctness guarantee as the JS twin: only whitespace OUTSIDE
    /// string/comment literals is rewritten, so it can never change meaning.
    /// `.scss`/`.less` are excluded at `detect` (their `//` line comments and
    /// nesting aren't modelled). Pinned by the `cssSignificantContent`
    /// differential test.
    private static func prettyPrintCSS(_ content: String) -> String {
        let chars = Array(content)
        let n = chars.count
        guard n > 0 else { return content }

        var out = ""
        out.reserveCapacity(n + n / 4)
        var indent = 0
        var atLineStart = true
        var pendingSpace = false
        var parenDepth = 0
        var braceDepth = 0

        func flush() {
            if atLineStart {
                for _ in 0..<max(0, indent) { out += jsIndentUnit }
                atLineStart = false
                pendingSpace = false
            } else if pendingSpace {
                out.append(" ")
                pendingSpace = false
            }
        }
        func emit(_ c: Character) { flush(); out.append(c) }
        func emitVerbatim(_ s: String) { flush(); out += s }
        func newline() {
            pendingSpace = false
            if !atLineStart { out.append("\n"); atLineStart = true }
        }

        var i = 0
        while i < n {
            let c = chars[i]
            if c == " " || c == "\t" || c == "\n" || c == "\r" {
                if !atLineStart { pendingSpace = true }
                i += 1; continue
            }
            // Block comment.
            if c == "/", i + 1 < n, chars[i + 1] == "*" {
                var j = i + 2; var lit = "/*"
                while j < n {
                    if chars[j] == "*", j + 1 < n, chars[j + 1] == "/" { lit += "*/"; j += 2; break }
                    lit.append(chars[j]); j += 1
                }
                emitVerbatim(lit); i = j; continue
            }
            // String literal.
            if c == "\"" || c == "'" {
                let q = c; var j = i + 1; var lit = String(c)
                while j < n {
                    let s = chars[j]; lit.append(s)
                    if s == "\\", j + 1 < n { lit.append(chars[j + 1]); j += 2; continue }
                    if s == q { j += 1; break }
                    j += 1
                }
                emitVerbatim(lit); i = j; continue
            }
            // Block open.
            if c == "{" {
                emit("{"); braceDepth += 1; indent += 1; newline(); i += 1; continue
            }
            // Block close.
            if c == "}" {
                indent -= 1; braceDepth = max(0, braceDepth - 1)
                newline(); emit("}"); newline()
                i += 1; continue
            }
            // Declaration end.
            if c == ";" {
                emit(";")
                if parenDepth == 0 { newline() }
                i += 1; continue
            }
            // Selector-list comma (only between top-level selectors).
            if c == "," {
                emit(",")
                if braceDepth == 0, parenDepth == 0 { newline() }
                i += 1; continue
            }
            if c == "(" { emit("("); parenDepth += 1; i += 1; continue }
            if c == ")" { emit(")"); parenDepth = max(0, parenDepth - 1); i += 1; continue }
            emit(c); i += 1
        }
        while out.hasSuffix("\n") { out.removeLast() }
        return out
    }

    /// Independent CSS lexer for tests — projects a source down to its
    /// significant content (everything except whitespace OUTSIDE string /
    /// block-comment literals, with such whitespace collapsed to a single
    /// space only between two identifier characters). `prettyPrintCSS` must
    /// preserve this projection exactly.
    static func cssSignificantContent(_ content: String) -> String {
        let chars = Array(content)
        let n = chars.count
        var out: [Character] = []
        out.reserveCapacity(n)

        func isW(_ c: Character) -> Bool {
            c == "_" || c == "-" || c.isLetter || c.isNumber
        }
        var prevWasWord = false
        var pendingSpace = false
        func emitCode(_ c: Character) {
            let w = isW(c)
            if pendingSpace { if prevWasWord && w { out.append(" ") }; pendingSpace = false }
            out.append(c); prevWasWord = w
        }
        func emitVerbatim(_ s: [Character]) {
            pendingSpace = false
            out += s
            prevWasWord = false
        }

        var i = 0
        while i < n {
            let c = chars[i]
            if c == " " || c == "\t" || c == "\n" || c == "\r" { pendingSpace = true; i += 1; continue }
            if c == "/", i + 1 < n, chars[i + 1] == "*" {
                var j = i + 2; var lit: [Character] = ["/", "*"]
                while j < n {
                    if chars[j] == "*", j + 1 < n, chars[j + 1] == "/" { lit += ["*", "/"]; j += 2; break }
                    lit.append(chars[j]); j += 1
                }
                emitVerbatim(lit); i = j; continue
            }
            if c == "\"" || c == "'" {
                let q = c; var j = i + 1; var lit: [Character] = [c]
                while j < n {
                    let s = chars[j]; lit.append(s)
                    if s == "\\", j + 1 < n { lit.append(chars[j + 1]); j += 2; continue }
                    if s == q { j += 1; break }
                    j += 1
                }
                emitVerbatim(lit); i = j; continue
            }
            emitCode(c); i += 1
        }
        return String(out)
    }

    // MARK: - Markdown (TSK-350)

    /// Re-align GFM pipe tables in `content`; everything else is returned
    /// byte-for-byte. Conservative on purpose — markdown prose has no single
    /// "correct" reflow, but a ragged pipe table is unambiguous to align:
    ///
    ///   - Only a header row immediately followed by a valid delimiter row
    ///     (`---`, `:--`, `:-:`, `--:`) starts a table; body rows continue
    ///     until a non-pipe / blank line.
    ///   - Column widths = the widest cell per column (min 3, so delimiters stay
    ///     valid); per-column alignment is read from the delimiter colons and
    ///     re-emitted (left `:--`, center `:-:`, right `--:`, none `---`).
    ///   - Escaped pipes (`\|`) inside a cell are NOT separators.
    ///   - Fenced code blocks (``` / ~~~) are skipped wholesale — a `|` inside a
    ///     fence is code, not a table.
    static func prettyPrintMarkdown(_ content: String) -> String {
        var lines = content.components(separatedBy: "\n")
        var i = 0
        var inFence = false
        var fence = ""
        while i < lines.count {
            let trimmed = lines[i].trimmingCharacters(in: .whitespaces)
            if inFence {
                if trimmed.hasPrefix(fence) { inFence = false }
                i += 1; continue
            }
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                inFence = true
                fence = String(trimmed.prefix(3))
                i += 1; continue
            }
            // A table = a pipe row directly followed by a delimiter row.
            if i + 1 < lines.count,
               mdIsTableRow(lines[i]), mdIsDelimiterRow(lines[i + 1]) {
                var end = i + 2
                while end < lines.count, mdIsTableRow(lines[end]) { end += 1 }
                let aligned = mdAlignTable(Array(lines[i..<end]))
                lines.replaceSubrange(i..<end, with: aligned)
                i += aligned.count
                continue
            }
            i += 1
        }
        return lines.joined(separator: "\n")
    }

    /// A line that carries at least one UNescaped `|` (a table-row candidate).
    static func mdIsTableRow(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return false }
        var prev: Character = " "
        for c in t {
            if c == "|" && prev != "\\" { return true }
            prev = c
        }
        return false
    }

    /// Every cell matches `:?-+:?` (a GFM delimiter row).
    static func mdIsDelimiterRow(_ line: String) -> Bool {
        let cells = mdSplitCells(line)
        guard !cells.isEmpty else { return false }
        for cell in cells {
            let c = cell.trimmingCharacters(in: .whitespaces)
            guard !c.isEmpty else { return false }
            var body = Substring(c)
            if body.first == ":" { body = body.dropFirst() }
            if body.last == ":" { body = body.dropLast() }
            guard !body.isEmpty, body.allSatisfy({ $0 == "-" }) else { return false }
        }
        return true
    }

    private enum MDAlign { case none, left, center, right }

    /// Split a pipe row into trimmed cells, honoring `\|` escapes and dropping
    /// the empty cells produced by an optional leading/trailing `|`.
    static func mdSplitCells(_ line: String) -> [String] {
        let t = line.trimmingCharacters(in: .whitespaces)
        var cells: [String] = []
        var cur = ""
        var prev: Character = " "
        for c in t {
            if c == "|" && prev != "\\" {
                cells.append(cur)
                cur = ""
            } else {
                cur.append(c)
            }
            prev = c
        }
        cells.append(cur)
        // Drop the leading/trailing empties from outer pipes.
        if let first = cells.first, first.trimmingCharacters(in: .whitespaces).isEmpty {
            cells.removeFirst()
        }
        if let last = cells.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
            cells.removeLast()
        }
        return cells.map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private static func mdAlign(of delimiterCell: String) -> MDAlign {
        let c = delimiterCell.trimmingCharacters(in: .whitespaces)
        let l = c.hasPrefix(":"), r = c.hasSuffix(":")
        if l && r { return .center }
        if r { return .right }
        if l { return .left }
        return .none
    }

    private static func mdPad(_ s: String, to width: Int, _ align: MDAlign) -> String {
        let pad = max(0, width - s.count)
        switch align {
        case .right:  return String(repeating: " ", count: pad) + s
        case .center: let l = pad / 2; return String(repeating: " ", count: l) + s
                                         + String(repeating: " ", count: pad - l)
        case .none, .left: return s + String(repeating: " ", count: pad)
        }
    }

    private static func mdDelimiter(width: Int, _ align: MDAlign) -> String {
        let w = max(width, 3)
        switch align {
        case .none:   return String(repeating: "-", count: w)
        case .left:   return ":" + String(repeating: "-", count: w - 1)
        case .right:  return String(repeating: "-", count: w - 1) + ":"
        case .center: return ":" + String(repeating: "-", count: w - 2) + ":"
        }
    }

    /// Re-emit a confirmed table block (header, delimiter, body…) with padded,
    /// aligned columns. Column count is fixed by the header; short rows get
    /// empty cells, long rows keep their overflow cells (GFM-ish, lossless).
    static func mdAlignTable(_ block: [String]) -> [String] {
        guard block.count >= 2 else { return block }
        let header = mdSplitCells(block[0])
        let delims = mdSplitCells(block[1])
        let bodyRows = block[2...].map { mdSplitCells($0) }
        let colCount = max(header.count, delims.count)

        var aligns = [MDAlign](repeating: .none, count: colCount)
        for (i, d) in delims.enumerated() where i < colCount { aligns[i] = mdAlign(of: d) }

        // Column widths: widest content cell per column (header + body), min 3.
        var widths = [Int](repeating: 3, count: colCount)
        func measure(_ cells: [String]) {
            for (i, c) in cells.enumerated() where i < colCount {
                widths[i] = max(widths[i], c.count)
            }
        }
        measure(header)
        for r in bodyRows { measure(r) }

        func render(_ cells: [String]) -> String {
            var out = "|"
            for col in 0..<colCount {
                let cell = col < cells.count ? cells[col] : ""
                out += " " + mdPad(cell, to: widths[col], aligns[col]) + " |"
            }
            return out
        }

        var result = [render(header)]
        var delimRow = "|"
        for col in 0..<colCount { delimRow += " " + mdDelimiter(width: widths[col], aligns[col]) + " |" }
        result.append(delimRow)
        for r in bodyRows { result.append(render(r)) }
        return result
    }
}
