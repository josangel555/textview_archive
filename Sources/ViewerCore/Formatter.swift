import Foundation

/// Pretty-printing for structured text formats.
///
/// Supported: JSON, XML, JS. Future: YAML, TOML, CSS (CSS would slot into
/// the same brace re-indenter as JS).
///
/// Each format degrades gracefully — if parsing fails, the original
/// content is returned (so a malformed JSON file doesn't become empty).
/// JS uses a dependency-free lexical re-indenter (see `prettyPrintJS`) that
/// only ever rewrites whitespace OUTSIDE string/template/comment/regex
/// literals, so it can never alter code meaning.
public enum Formatter {

    public enum SupportedFormat: String, CaseIterable, Sendable {
        case json
        case xml
        case js

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
}
