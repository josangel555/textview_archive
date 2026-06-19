import Foundation

/// Parsers for the two XLSX container-index parts that map a workbook to its
/// worksheet parts (TSK-682):
///   - `xl/workbook.xml` — declares each `<sheet name="…" r:id="rIdN"/>`.
///   - `xl/_rels/workbook.xml.rels` — maps each `Id="rIdN"` to a `Target`
///     (the worksheet part path, relative to `xl/`).
///
/// Both are pure XML string parsers (host-testable, no file I/O). ``XLSXDocument``
/// composes them with the on-disk unzip to locate and load each sheet.
public enum XLSXWorkbookParts {
    /// One sheet declaration from `xl/workbook.xml`.
    public struct SheetRef: Equatable, Sendable {
        public let name: String
        /// The relationship id (`r:id`), used to resolve the part path via the
        /// rels file. May be empty for a malformed declaration.
        public let relationshipID: String
        public init(name: String, relationshipID: String) {
            self.name = name
            self.relationshipID = relationshipID
        }
    }

    /// Parse `xl/workbook.xml` into its ordered sheet declarations.
    public static func parseWorkbook(_ xml: String) -> [SheetRef] {
        guard let data = xml.data(using: .utf8) else { return [] }
        let parser = XMLParser(data: data)
        // Namespace-aware so `r:id` resolves regardless of the prefix the file
        // uses; XMLParser reports the local name "id" with the relationships
        // namespace URI when this is on.
        parser.shouldProcessNamespaces = true
        let delegate = WorkbookDelegate()
        parser.delegate = delegate
        parser.parse()
        return delegate.sheets
    }

    /// Parse `xl/_rels/workbook.xml.rels` into an `Id` → `Target` map.
    public static func parseRels(_ xml: String) -> [String: String] {
        guard let data = xml.data(using: .utf8) else { return [:] }
        let parser = XMLParser(data: data)
        let delegate = RelsDelegate()
        parser.delegate = delegate
        parser.parse()
        return delegate.map
    }

    private final class WorkbookDelegate: NSObject, XMLParserDelegate {
        var sheets: [SheetRef] = []
        func parser(_ parser: XMLParser, didStartElement elementName: String,
                    namespaceURI: String?, qualifiedName qName: String?,
                    attributes attributeDict: [String: String]) {
            guard elementName == "sheet" else { return }
            let name = attributeDict["name"] ?? ""
            // With namespaces on, the relationship id arrives as local "id";
            // tolerate a raw "r:id" too (namespaces-off / odd producers).
            let rid = attributeDict["id"] ?? attributeDict["r:id"] ?? ""
            sheets.append(SheetRef(name: name, relationshipID: rid))
        }
    }

    private final class RelsDelegate: NSObject, XMLParserDelegate {
        var map: [String: String] = [:]
        func parser(_ parser: XMLParser, didStartElement elementName: String,
                    namespaceURI: String?, qualifiedName qName: String?,
                    attributes attributeDict: [String: String]) {
            guard elementName == "Relationship",
                  let id = attributeDict["Id"],
                  let target = attributeDict["Target"] else { return }
            map[id] = target
        }
    }
}
