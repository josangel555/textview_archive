import Foundation

/// TSK-1144 — export a `RichTextDocument` to a Word `.docx` (Office Open XML).
/// A `.docx` is a ZIP of three XML parts; we write a STORE-only (uncompressed)
/// ZIP by hand so there is NO dependency (Foundation has no archive writer) and
/// the whole thing stays host-testable — store entries appear verbatim in the
/// output bytes, so a test can assert on the embedded XML directly.
///
/// Covered: headings (built-in `HeadingN` styles), paragraphs, bullet/ordered
/// lists (rendered as prefixed paragraphs — Word list numbering needs a
/// numbering part, deferred), blockquote lines, and bold/italic/strike runs.
public enum DocxExporter {

    public static func export(_ doc: RichTextDocument) -> Data {
        var zip = StoreZip()
        zip.add(name: "[Content_Types].xml", utf8: contentTypesXML)
        zip.add(name: "_rels/.rels", utf8: relsXML)
        zip.add(name: "word/document.xml", utf8: documentXML(doc))
        return zip.finalize()
    }

    // MARK: - OOXML parts

    private static let contentTypesXML = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">\
    <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>\
    <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>\
    </Types>
    """

    private static let relsXML = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
    <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>\
    </Relationships>
    """

    static func documentXML(_ doc: RichTextDocument) -> String {
        var body = ""
        for block in doc.blocks {
            switch block {
            case let .heading(level, inlines):
                body += paragraph(style: "Heading\(min(max(level, 1), 6))", inlines)
            case let .paragraph(inlines):
                body += paragraph(style: nil, inlines)
            case let .bulletList(items):
                for item in items { body += paragraph(style: nil, item.inlines, prefix: "•\u{00A0}") }
            case let .orderedList(start, items):
                for (i, item) in items.enumerated() {
                    body += paragraph(style: nil, item.inlines, prefix: "\(start + i).\u{00A0}")
                }
            case let .blockquote(lines):
                for line in lines { body += paragraph(style: "Quote", line) }
            case let .codeBlock(code):
                // No DOCX markdown fence; one paragraph per code line, text preserved.
                for line in code.split(separator: "\n", omittingEmptySubsequences: false) {
                    body += paragraph(style: nil, [.text(String(line))])
                }
            case let .table(header, rows):
                // No DOCX table model here; one tab-separated paragraph per row.
                for r in [header] + rows {
                    var inl: [RichInline] = []
                    for (idx, c) in r.enumerated() {
                        if idx > 0 { inl.append(.text("\t")) }
                        inl.append(contentsOf: c)
                    }
                    body += paragraph(style: nil, inl)
                }
            }
        }
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">\
        <w:body>\(body)</w:body></w:document>
        """
    }

    // MARK: - Block / run emission

    private struct Run { let text: String; let bold: Bool; let italic: Bool; let strike: Bool }

    private static func paragraph(style: String?, _ inlines: [RichInline], prefix: String = "") -> String {
        let pPr = style.map { "<w:pPr><w:pStyle w:val=\"\($0)\"/></w:pPr>" } ?? ""
        var runs = ""
        if !prefix.isEmpty {
            runs += runXML(Run(text: prefix, bold: false, italic: false, strike: false))
        }
        runs += flatten(inlines).map(runXML).joined()
        return "<w:p>\(pPr)\(runs)</w:p>"
    }

    /// Flatten the restricted-inline tree into flat runs, accumulating the
    /// active bold/italic/strike emphasis down each branch.
    private static func flatten(
        _ inlines: [RichInline], bold: Bool = false, italic: Bool = false, strike: Bool = false
    ) -> [Run] {
        var out: [Run] = []
        for inline in inlines {
            switch inline {
            case let .text(s):
                out.append(Run(text: s, bold: bold, italic: italic, strike: strike))
            case let .bold(inner):
                out += flatten(inner, bold: true, italic: italic, strike: strike)
            case let .italic(inner):
                out += flatten(inner, bold: bold, italic: true, strike: strike)
            case let .strike(inner):
                out += flatten(inner, bold: bold, italic: italic, strike: true)
            case let .code(s):
                out.append(Run(text: s, bold: bold, italic: italic, strike: strike))
            case let .link(text, _):
                out += flatten(text, bold: bold, italic: italic, strike: strike)
            }
        }
        return out
    }

    private static func runXML(_ r: Run) -> String {
        var rPr = ""
        if r.bold { rPr += "<w:b/>" }
        if r.italic { rPr += "<w:i/>" }
        if r.strike { rPr += "<w:strike/>" }
        let pr = rPr.isEmpty ? "" : "<w:rPr>\(rPr)</w:rPr>"
        return "<w:r>\(pr)<w:t xml:space=\"preserve\">\(escapeXML(r.text))</w:t></w:r>"
    }

    private static func escapeXML(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
}

/// Minimal STORE-only (method 0, uncompressed) ZIP writer — no dependency, no
/// compression. Sufficient for `.docx`/`.xlsx`-style OOXML packages; entries are
/// stored verbatim so the payload is byte-recoverable without an inflater.
struct StoreZip {
    private struct Entry { let name: [UInt8]; let crc: UInt32; let size: UInt32; let offset: UInt32 }
    private var output: [UInt8] = []
    private var entries: [Entry] = []

    mutating func add(name: String, utf8: String) {
        let nameBytes = Array(name.utf8)
        let data = Array(utf8.utf8)
        let crc = StoreZip.crc32(data)
        let offset = UInt32(output.count)
        // Local file header.
        append32(0x0403_4b50)
        append16(20)            // version needed
        append16(0)             // flags
        append16(0)             // method 0 = store
        append16(0); append16(0)  // mod time / date
        append32(crc)
        append32(UInt32(data.count))   // compressed size == size (store)
        append32(UInt32(data.count))   // uncompressed size
        append16(UInt16(nameBytes.count))
        append16(0)             // extra len
        output += nameBytes
        output += data
        entries.append(Entry(name: nameBytes, crc: crc, size: UInt32(data.count), offset: offset))
    }

    mutating func finalize() -> Data {
        let cdStart = UInt32(output.count)
        for e in entries {
            append32(0x0201_4b50)
            append16(20); append16(20)  // version made by / needed
            append16(0); append16(0)    // flags / method
            append16(0); append16(0)    // mod time / date
            append32(e.crc)
            append32(e.size); append32(e.size)
            append16(UInt16(e.name.count))
            append16(0); append16(0)    // extra / comment len
            append16(0); append16(0)    // disk start / internal attrs
            append32(0)                 // external attrs
            append32(e.offset)
            output += e.name
        }
        let cdSize = UInt32(output.count) - cdStart
        append32(0x0605_4b50)           // EOCD
        append16(0); append16(0)        // disk numbers
        append16(UInt16(entries.count)); append16(UInt16(entries.count))
        append32(cdSize)
        append32(cdStart)
        append16(0)                     // comment len
        return Data(output)
    }

    private mutating func append16(_ v: UInt16) { output.append(UInt8(v & 0xFF)); output.append(UInt8(v >> 8)) }
    private mutating func append32(_ v: UInt32) {
        output.append(UInt8(v & 0xFF)); output.append(UInt8((v >> 8) & 0xFF))
        output.append(UInt8((v >> 16) & 0xFF)); output.append(UInt8((v >> 24) & 0xFF))
    }

    private static let crcTable: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 { c = (c & 1) != 0 ? (0xEDB8_8320 ^ (c >> 1)) : (c >> 1) }
        return c
    }
    static func crc32(_ bytes: [UInt8]) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        for b in bytes { c = crcTable[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
        return c ^ 0xFFFF_FFFF
    }
}
