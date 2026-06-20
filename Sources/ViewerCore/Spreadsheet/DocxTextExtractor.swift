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
