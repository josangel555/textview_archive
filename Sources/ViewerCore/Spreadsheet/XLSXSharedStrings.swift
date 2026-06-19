import Foundation

/// Parser for an XLSX shared-string table (`xl/sharedStrings.xml`), TSK-682.
///
/// In the OOXML spreadsheet format, string cell values are not stored inline by
/// default: a cell with `t="s"` holds an *index* into this shared table. The
/// table is a `<sst>` of `<si>` items; each `<si>` is either a single `<t>` run
/// or several `<r><t>…</t></r>` rich-text runs which must be concatenated into
/// one logical string.
///
/// Pure + dependency-free: parses a raw XML string via Foundation's
/// `XMLParser`, returns the ordered string array. Host-testable on literal XML
/// (no file I/O). Malformed XML yields whatever prefix parsed before the error
/// rather than throwing — a corrupt table degrades to fewer strings, never a
/// crash (cells that reference a missing index resolve to "").
public enum XLSXSharedStrings {
    /// Parse the `<sst>` document into its ordered list of strings.
    public static func parse(_ xml: String) -> [String] {
        guard let data = xml.data(using: .utf8) else { return [] }
        let parser = XMLParser(data: data)
        let delegate = SharedStringsDelegate()
        parser.delegate = delegate
        parser.parse()
        delegate.finishPending()
        return delegate.strings
    }

    private final class SharedStringsDelegate: NSObject, XMLParserDelegate {
        var strings: [String] = []
        /// Accumulated text for the `<si>` currently being parsed; nil when
        /// outside an `<si>`.
        private var current: String?
        /// True while inside a `<t>` (the only element whose chars we keep).
        private var inText = false

        func parser(_ parser: XMLParser, didStartElement elementName: String,
                    namespaceURI: String?, qualifiedName qName: String?,
                    attributes attributeDict: [String: String]) {
            switch elementName {
            case "si":
                current = ""
            case "t":
                inText = true
            default:
                break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            guard inText, current != nil else { return }
            current?.append(string)
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String,
                    namespaceURI: String?, qualifiedName qName: String?) {
            switch elementName {
            case "t":
                inText = false
            case "si":
                strings.append(current ?? "")
                current = nil
            default:
                break
            }
        }

        /// If a malformed document ended mid-`<si>` (the close element never
        /// arrived), flush the partial string so the table isn't silently short
        /// by one entry.
        func finishPending() {
            if let c = current {
                strings.append(c)
                current = nil
            }
        }
    }
}
