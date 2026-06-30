import Foundation

/// Plain-text extraction from a Word `.docx` `word/document.xml` — part of the
/// multi-format viewer family (sibling to ``XLSXDocument`` / ``ODSContentParser``;
/// `.docx` is an OOXML ZIP, so the caller extracts `document.xml` via the
/// hardened `ArchiveCatalog.zipEntryBytes` `unzip -p` pipe — zero new deps).
///
/// Reads the body's paragraphs (`w:p`), concatenating run text (`w:t`) and
/// honoring intra-paragraph `w:tab` / `w:br` / `w:cr` breaks. Tables and styling
/// are out of scope for this slice (the viewer renders extracted text). Unlike
/// `.ods`, `.docx` has no repeat-count expansion, so no OOM guard is needed.
public enum DocxTextExtractor {

    /// Extract the document body as an ordered list of paragraph strings.
    public static func paragraphs(documentXML: String) -> [String] {
        guard let data = documentXML.data(using: .utf8) else { return [] }
        let delegate = Delegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        return delegate.paragraphs
    }

    /// Convenience: the whole document as text (paragraphs joined by `\n`).
    public static func plainText(documentXML: String) -> String {
        paragraphs(documentXML: documentXML).joined(separator: "\n")
    }

    // MARK: - Structured (Markdown) extraction (TSK-1338)

    /// Parse the body into the restricted `RichTextDocument` IR, preserving
    /// STRUCTURE the flat `paragraphs` path drops: heading paragraphs
    /// (`w:pStyle` Heading1-N / Title), bullet/numbered list items (`w:numPr`),
    /// and run-level bold/italic (`w:rPr` `w:b`/`w:i`). Reuses the same IR + the
    /// (escaping, in-vocabulary) `RichTextSerializer` as the HTML-paste path, so
    /// body text never accidentally becomes Markdown syntax.
    public static func richTextDocument(documentXML: String) -> RichTextDocument {
        guard let data = documentXML.data(using: .utf8) else { return RichTextDocument() }
        let delegate = RichDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        delegate.flushPendingList()
        return RichTextNormalizer.normalize(RichTextDocument(delegate.blocks))
    }

    /// The document as canonical (restricted) Markdown — headings → `#`, lists →
    /// `-`, bold/italic preserved. The structured counterpart of `plainText`.
    public static func markdown(documentXML: String) -> String {
        RichTextSerializer.serialize(richTextDocument(documentXML: documentXML))
    }

    /// Builds `RichBlock`s from the OOXML body. Tracks per-paragraph style/list
    /// state + per-run bold/italic, coalescing consecutive list paragraphs into
    /// one bullet list.
    final class RichDelegate: NSObject, XMLParserDelegate {
        var blocks: [RichBlock] = []
        private var pendingListItems: [RichListItem] = []
        private var paraInlines: [RichInline] = []
        private var paraStyle: String?
        private var paraIsList = false
        private var inParagraph = false
        private var inRun = false
        private var runBold = false
        private var runItalic = false
        private var runText = ""
        private var inText = false

        func parser(_ parser: XMLParser, didStartElement element: String,
                    namespaceURI: String?, qualifiedName qName: String?,
                    attributes attrs: [String: String]) {
            switch element {
            case "w:p":
                inParagraph = true; paraInlines = []; paraStyle = nil; paraIsList = false
            case "w:pStyle":
                if inParagraph, paraStyle == nil { paraStyle = attrs["w:val"] }
            case "w:numPr":
                if inParagraph { paraIsList = true }
            case "w:r":
                inRun = true; runBold = false; runItalic = false; runText = ""
            case "w:b":  if inRun { runBold = Self.boolAttr(attrs["w:val"]) }
            case "w:i":  if inRun { runItalic = Self.boolAttr(attrs["w:val"]) }
            case "w:t":  inText = true
            case "w:tab": if inRun { runText += "\t" }
            case "w:br", "w:cr": if inRun { runText += " " }   // soft break → space (IR has no line break)
            default: break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if inText { runText += string }
        }

        func parser(_ parser: XMLParser, didEndElement element: String,
                    namespaceURI: String?, qualifiedName qName: String?) {
            switch element {
            case "w:t": inText = false
            case "w:r":
                inRun = false
                if !runText.isEmpty {
                    paraInlines.append(Self.inline(runText, bold: runBold, italic: runItalic))
                }
            case "w:p":
                inParagraph = false
                endParagraph()
            default: break
            }
        }

        private func endParagraph() {
            if paraIsList {
                pendingListItems.append(RichListItem(paraInlines.isEmpty ? [.text("")] : paraInlines))
                return
            }
            flushPendingList()
            guard !paraInlines.isEmpty else { return }   // drop empty paragraphs
            if let level = Self.headingLevel(paraStyle) {
                blocks.append(.heading(level: level, inlines: paraInlines))
            } else {
                blocks.append(.paragraph(paraInlines))
            }
        }

        /// Emit any accumulated consecutive list paragraphs as one bullet list.
        func flushPendingList() {
            guard !pendingListItems.isEmpty else { return }
            blocks.append(.bulletList(pendingListItems))
            pendingListItems = []
        }

        /// `<w:b/>` with no `w:val` means ON; `w:val="false"/"0"/"off"` means OFF.
        static func boolAttr(_ value: String?) -> Bool {
            guard let value else { return true }
            return !(value == "false" || value == "0" || value == "off")
        }

        static func inline(_ text: String, bold: Bool, italic: Bool) -> RichInline {
            var node: RichInline = .text(text)
            if italic { node = .italic([node]) }
            if bold { node = .bold([node]) }
            return node
        }

        /// Heading level from a paragraph style val: "Heading1".."HeadingN" →
        /// clamped 1...3, "Title" → 1; anything else → nil (a normal paragraph).
        static func headingLevel(_ style: String?) -> Int? {
            guard let s = style?.lowercased() else { return nil }
            if s == "title" { return 1 }
            if s.hasPrefix("heading") {
                let suffix = s.dropFirst("heading".count).trimmingCharacters(in: .whitespaces)
                let n = Int(suffix) ?? 1
                return min(max(n, 1), 3)
            }
            return nil
        }
    }

    private final class Delegate: NSObject, XMLParserDelegate {
        var paragraphs: [String] = []
        private var current = ""
        private var inParagraph = false
        private var inText = false

        func parser(_ parser: XMLParser, didStartElement element: String,
                    namespaceURI: String?, qualifiedName qName: String?,
                    attributes attrs: [String: String]) {
            switch element {
            case "w:p":   inParagraph = true; current = ""
            case "w:t":   inText = true
            case "w:tab": if inParagraph { current += "\t" }
            case "w:br", "w:cr": if inParagraph { current += "\n" }
            default: break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if inText { current += string }
        }

        func parser(_ parser: XMLParser, didEndElement element: String,
                    namespaceURI: String?, qualifiedName qName: String?) {
            switch element {
            case "w:t": inText = false
            case "w:p":
                if inParagraph { paragraphs.append(current); inParagraph = false }
            default: break
            }
        }
    }
}
