import Foundation

/// Extract plain text from RTF (Rich Text Format) — the read counterpart to
/// ``RtfExporter`` (TextEdit/Word `.rtf`). Pure parsing, host-testable.
///
/// Handles the load-bearing RTF subtleties: control words vs control symbols,
/// nested `{}` groups (state inherits into a subgroup, restores on close),
/// ignorable DESTINATIONS (`\*` and `\fonttbl`/`\colortbl`/`\stylesheet`/`\info`/
/// `\pict`… — their text is dropped), `\uN` Unicode with the `\ucN`
/// fallback-skip, `\'XX` hex bytes, and `\par`/`\line`/`\tab` + `\\ \{ \}`
/// escapes. Styling is discarded (text only).
public enum RtfTextExtractor {

    private struct GroupState { var uc = 1; var skip = false }

    /// Destinations whose contents are metadata, not document text.
    private static let ignoredDestinations: Set<String> = [
        "fonttbl", "colortbl", "stylesheet", "info", "pict", "header", "footer",
        "headerl", "headerr", "footerl", "footerr", "footnote", "field", "object",
        "themedata", "colorschememapping", "latentstyles", "datastore", "generator",
    ]

    public static func plainText(_ rtf: String) -> String {
        let s = Array(rtf.unicodeScalars)
        let n = s.count
        var i = 0
        var stack = [GroupState()]
        var out = String.UnicodeScalarView()

        func isLetter(_ c: Unicode.Scalar) -> Bool { (c >= "a" && c <= "z") || (c >= "A" && c <= "Z") }
        func isDigit(_ c: Unicode.Scalar) -> Bool { c >= "0" && c <= "9" }
        func emit(_ str: String) { if !stack[stack.count - 1].skip { out.append(contentsOf: str.unicodeScalars) } }

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
                    case "par", "line", "sect": emit("\n")
                    case "tab": emit("\t")
                    case "uc": stack[stack.count - 1].uc = hasNum ? num : 1
                    case "u":
                        var cp = param
                        if cp < 0 { cp += 0x10000 }   // signed 16-bit → code point
                        if let scalar = Unicode.Scalar(cp) { emit(String(scalar)) }
                        // skip the \uc fallback scalars that follow
                        var toSkip = stack[stack.count - 1].uc
                        while toSkip > 0 && i < n {
                            if s[i] == "\\" || s[i] == "{" || s[i] == "}" { break }
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
                    case "\n", "\r": emit("\n"); i += 1                    // escaped newline → break
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
        return String(out)
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
