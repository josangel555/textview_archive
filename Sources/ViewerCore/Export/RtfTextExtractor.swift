import Foundation

/// Extract text from RTF (Rich Text Format) — the read counterpart to
/// ``RtfExporter`` (TextEdit/Word `.rtf`). Pure parsing, host-testable.
///
/// Handles the load-bearing RTF subtleties: control words vs control symbols,
/// nested `{}` groups (state inherits into a subgroup, restores on close),
/// ignorable DESTINATIONS (`\*` and `\fonttbl`/`\colortbl`/`\stylesheet`/`\info`/
/// `\pict`… — their text is dropped), `\uN` Unicode with the `\ucN`
/// fallback-skip, `\'XX` hex bytes, and `\par`/`\line`/`\tab` + `\\ \{ \}`
/// escapes. `plainText` discards styling; `markdown`/`richTextDocument` (TSK-1338)
/// preserve bold/italic + paragraphs so a `.rtf` RENDERS instead of showing flat.
public enum RtfTextExtractor {

    private struct GroupState { var uc = 1; var skip = false; var bold = false; var italic = false }

    /// Destinations whose contents are metadata, not document text.
    private static let ignoredDestinations: Set<String> = [
        "fonttbl", "colortbl", "stylesheet", "info", "pict", "header", "footer",
        "headerl", "headerr", "footerl", "footerr", "footnote", "field", "object",
        "themedata", "colorschememapping", "latentstyles", "datastore", "generator",
    ]

    /// Run-level formatting passed to the scanner's text sink.
    struct RunFormat: Equatable { var bold = false; var italic = false }

    /// Single tokenizer core. Calls `onText(text, format)` for document text
    /// (with the active bold/italic) and `onParagraph()` at `\par`/`\line`/`\sect`.
    /// Both `plainText` and `richTextDocument` consume this — one parser, no dup.
    private static func scan(
        _ rtf: String,
        onText: (String, RunFormat) -> Void,
        onParagraph: () -> Void
    ) {
        let s = Array(rtf.unicodeScalars)
        let n = s.count
        var i = 0
        var stack = [GroupState()]
        var pendingHigh: Int? = nil

        func isLetter(_ c: Unicode.Scalar) -> Bool { (c >= "a" && c <= "z") || (c >= "A" && c <= "Z") }
        func isDigit(_ c: Unicode.Scalar) -> Bool { c >= "0" && c <= "9" }
        func emit(_ str: String) {
            let top = stack[stack.count - 1]
            if top.skip { return }
            onText(str, RunFormat(bold: top.bold, italic: top.italic))
        }

        while i < n {
            let c = s[i]
            if c == "{" {
                stack.append(stack[stack.count - 1]); i += 1
            } else if c == "}" {
                if stack.count > 1 { stack.removeLast() }; i += 1
            } else if c == "\\" {
                i += 1
                guard i < n else { break }
                let cc = s[i]
                if isLetter(cc) {
                    var word = String.UnicodeScalarView()
                    while i < n && isLetter(s[i]) { word.append(s[i]); i += 1 }
                    var neg = false
                    if i < n && s[i] == "-" { neg = true; i += 1 }
                    var num = 0; var hasNum = false
                    while i < n && isDigit(s[i]) { hasNum = true; num = num * 10 + Int(s[i].value - 48); i += 1 }
                    if i < n && s[i] == " " { i += 1 }   // consume the single-space delimiter
                    let w = String(word)
                    let param = neg ? -num : num
                    switch w {
                    case "par", "line", "sect": onParagraph()
                    case "tab": emit("\t")
                    case "uc": stack[stack.count - 1].uc = hasNum ? num : 1
                    // TSK-1338: run-level bold/italic. `\b`/`\i` (no arg) → ON;
                    // `\b0`/`\i0` → OFF. Group-scoped (inherits/restores via stack).
                    case "b":  stack[stack.count - 1].bold = hasNum ? (param != 0) : true
                    case "i":  stack[stack.count - 1].italic = hasNum ? (param != 0) : true
                    case "plain": stack[stack.count - 1].bold = false; stack[stack.count - 1].italic = false
                    case "u":
                        var cp = param
                        if cp < 0 { cp += 0x10000 }   // signed 16-bit → code point
                        if (0xD800...0xDBFF).contains(cp) {
                            pendingHigh = cp                      // hold the high surrogate
                        } else if (0xDC00...0xDFFF).contains(cp), let hi = pendingHigh {
                            let astral = 0x10000 + ((hi - 0xD800) << 10) + (cp - 0xDC00)
                            if let scalar = Unicode.Scalar(astral) { emit(String(scalar)) }
                            pendingHigh = nil
                        } else {
                            pendingHigh = nil                     // a stray pending high is dropped
                            if let scalar = Unicode.Scalar(cp) { emit(String(scalar)) }
                        }
                        // skip the \uc fallback tokens that follow \uN.
                        var toSkip = stack[stack.count - 1].uc
                        while toSkip > 0 && i < n {
                            if s[i] == "\\" {
                                if i + 1 < n && s[i + 1] == "'" {
                                    i += 2                       // past \'
                                    if i + 1 < n { i += 2 }      // past the two hex digits
                                    toSkip -= 1
                                    continue
                                }
                                break                            // other control fallback — stop
                            }
                            if s[i] == "{" || s[i] == "}" { break }
                            i += 1; toSkip -= 1
                        }
                    default:
                        if ignoredDestinations.contains(w) { stack[stack.count - 1].skip = true }
                        // other control words = formatting → ignored
                    }
                } else {
                    // control symbol
                    switch cc {
                    case "\\", "{", "}": emit(String(cc)); i += 1
                    case "*": stack[stack.count - 1].skip = true; i += 1   // ignorable destination
                    case "~": emit("\u{00A0}"); i += 1                     // non-breaking space
                    case "_": emit("\u{2011}"); i += 1                     // non-breaking hyphen
                    case "-": i += 1                                       // optional hyphen → drop
                    case "\n", "\r": onParagraph(); i += 1                 // escaped newline → break
                    case "'":
                        i += 1
                        if i + 1 < n, let hi = hexVal(s[i]), let lo = hexVal(s[i + 1]) {
                            let byte = hi * 16 + lo
                            if let scalar = Unicode.Scalar(byte) { emit(String(scalar)) }
                            i += 2
                        }
                    default: i += 1
                    }
                }
            } else if c == "\n" || c == "\r" {
                i += 1   // raw line breaks in the RTF stream are not document text
            } else {
                emit(String(c)); i += 1
            }
        }
    }

    public static func plainText(_ rtf: String) -> String {
        var out = String.UnicodeScalarView()
        scan(rtf,
             onText: { text, _ in out.append(contentsOf: text.unicodeScalars) },
             onParagraph: { out.append("\n") })
        return String(out)
    }

    // MARK: - Structured (Markdown) extraction (TSK-1338)

    /// Parse RTF into the restricted `RichTextDocument` IR — paragraphs of
    /// bold/italic inline runs (RTF has no semantic headings/lists, so those are
    /// out of scope). Reuses the escaping `RichTextSerializer` so body text never
    /// becomes accidental Markdown.
    public static func richTextDocument(_ rtf: String) -> RichTextDocument {
        var blocks: [RichBlock] = []
        var paraInlines: [RichInline] = []
        var runText = ""
        var runFormat = RunFormat()

        func flushRun() {
            guard !runText.isEmpty else { return }
            var node: RichInline = .text(runText)
            if runFormat.italic { node = .italic([node]) }
            if runFormat.bold { node = .bold([node]) }
            paraInlines.append(node)
            runText = ""
        }
        func endParagraph() {
            flushRun()
            if !paraInlines.isEmpty { blocks.append(.paragraph(paraInlines)); paraInlines = [] }
        }

        scan(rtf,
             onText: { text, fmt in
                 if fmt != runFormat { flushRun(); runFormat = fmt }
                 runText += text
             },
             onParagraph: { endParagraph() })
        endParagraph()   // flush the trailing paragraph
        return RichTextNormalizer.normalize(RichTextDocument(blocks))
    }

    /// The document as canonical (restricted) Markdown — bold/italic preserved.
    public static func markdown(_ rtf: String) -> String {
        RichTextSerializer.serialize(richTextDocument(rtf))
    }

    private static func hexVal(_ c: Unicode.Scalar) -> Int? {
        switch c {
        case "0"..."9": return Int(c.value - 48)
        case "a"..."f": return Int(c.value - 87)
        case "A"..."F": return Int(c.value - 55)
        default: return nil
        }
    }
}
