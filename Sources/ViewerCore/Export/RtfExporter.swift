import Foundation

/// A styled text run for RTF export (TSK-680).
public struct RtfRun: Equatable, Sendable {
    public var text: String
    public var bold: Bool
    public var italic: Bool
    public var mono: Bool   // inline code
    public init(_ text: String, bold: Bool = false, italic: Bool = false, mono: Bool = false) {
        self.text = text; self.bold = bold; self.italic = italic; self.mono = mono
    }
}

/// A block-level element for RTF export.
public enum RtfBlock: Equatable, Sendable {
    case paragraph([RtfRun])
    case heading(level: Int, [RtfRun])
    case codeBlock(String)
}

/// Emits RTF (Rich Text Format) from a structured block/run model — TSK-680
/// (rich-text export, the `.rtf` slice). Pure string generation, host-testable.
///
/// Deliberately consumes a STRUCTURED model rather than raw markdown: the
/// markdown→blocks step reuses the rust-core markdown parser (a later slice), so
/// this layer never reinvents parsing. `.rtfd`/`.docx`/`.doc` are separate tails.
public enum RtfExporter {

    /// RTF-escape a string: the three RTF metacharacters, tab/newline control
    /// words, and any non-ASCII scalar as `\uN?` (signed 16-bit, RTF's spec),
    /// with astral scalars emitted as a UTF-16 surrogate pair.
    public static func escape(_ s: String) -> String {
        var out = ""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\\": out += "\\\\"
            case "{":  out += "\\{"
            case "}":  out += "\\}"
            case "\n": out += "\\line "
            case "\t": out += "\\tab "
            default:
                let v = scalar.value
                if v < 0x80 {
                    out.unicodeScalars.append(scalar)
                } else if v <= 0xFFFF {
                    out += "\\u\(Int16(truncatingIfNeeded: v))?"
                } else {
                    let u = v - 0x10000
                    let hi = 0xD800 + (u >> 10)
                    let lo = 0xDC00 + (u & 0x3FF)
                    out += "\\u\(Int16(truncatingIfNeeded: hi))?\\u\(Int16(truncatingIfNeeded: lo))?"
                }
            }
        }
        return out
    }

    /// Heading font size in half-points (RTF `\fsN`): h1=36 (18pt) → floor 24 (12pt).
    static func headingHalfPoints(_ level: Int) -> Int {
        max(24, 36 - (max(1, level) - 1) * 4)
    }

    private static func runRtf(_ r: RtfRun) -> String {
        var s = escape(r.text)
        if r.mono   { s = "{\\f1 \(s)}" }       // monospace font group
        if r.italic { s = "\\i \(s)\\i0 " }
        if r.bold   { s = "\\b \(s)\\b0 " }
        return s
    }

    /// Render `blocks` to a complete RTF document.
    public static func export(_ blocks: [RtfBlock]) -> String {
        var body = ""
        for block in blocks {
            switch block {
            case let .heading(level, runs):
                body += "{\\b\\fs\(headingHalfPoints(level)) " + runs.map(runRtf).joined() + "}\\par\n"
            case let .paragraph(runs):
                body += runs.map(runRtf).joined() + "\\par\n"
            case let .codeBlock(code):
                body += "{\\f1 " + escape(code) + "}\\par\n"
            }
        }
        return "{\\rtf1\\ansi\\deff0{\\fonttbl{\\f0 Helvetica;}{\\f1 Menlo;}}\n" + body + "}"
    }
}
