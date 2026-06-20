import Foundation

/// Parser for the first table in an OpenDocument Spreadsheet (`.ods`)
/// `content.xml` — TSK-674. Sibling to ``XLSXDocument`` (both are ZIP
/// containers; the caller extracts `content.xml` via the hardened
/// `ArchiveCatalog.zipEntryBytes` `unzip -p` pipe — zero new dependencies).
///
/// The load-bearing subtlety is `table:number-columns-repeated` /
/// `table:number-rows-repeated`: real `.ods` files pad every row and the sheet
/// tail with HUGE repeat counts (e.g. an empty cell repeated 1000×, then a row
/// repeated 1,048,575×). A naive expansion OOMs. So TRAILING empty cells/rows
/// are NEVER materialized — empties are deferred and only flushed when a
/// non-empty cell/row follows.
public enum ODSContentParser {

    /// Parse the first `table:table` into a row-major grid of cell display
    /// strings. `maxCells` is a hard backstop against a pathological file.
    public static func parseFirstTableGrid(contentXML: String, maxCells: Int = 5_000_000) -> [[String]] {
        guard let data = contentXML.data(using: .utf8) else { return [] }
        let delegate = Delegate(maxCells: maxCells)
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        return delegate.grid
    }

    private final class Delegate: NSObject, XMLParserDelegate {
        let maxCells: Int
        var grid: [[String]] = []
        private var doneFirstTable = false
        private var inTable = false

        // Row state
        private var rowCells: [String] = []
        private var deferredEmptyCols = 0          // trailing empty cells, not yet materialized
        private var deferredEmptyRows = 0          // trailing empty rows, not yet materialized
        private var lastRowWidth = 1

        // Cell state
        private var inCell = false
        private var inParagraph = false
        private var cellText = ""
        private var cellRepeat = 1
        private var rowRepeat = 1
        private var cellHadContent = false
        private var cellCount = 0

        init(maxCells: Int) { self.maxCells = maxCells }

        func parser(_ parser: XMLParser, didStartElement element: String,
                    namespaceURI: String?, qualifiedName qName: String?,
                    attributes attrs: [String: String]) {
            switch element {
            case "table:table":
                if doneFirstTable { break }
                inTable = true
            case "table:table-row" where inTable:
                rowCells = []; deferredEmptyCols = 0
                rowRepeat = intAttr(attrs["table:number-rows-repeated"]) ?? 1
            case "table:table-cell", "table:covered-table-cell":
                guard inTable else { break }
                inCell = true; cellText = ""; cellHadContent = false
                cellRepeat = intAttr(attrs["table:number-columns-repeated"]) ?? 1
            case "text:p":
                inParagraph = true   // capture text only INSIDE a paragraph (skip structural whitespace)
            case "text:span", "text:a":
                break  // inline children of text:p — inParagraph is already true
            default:
                break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if inCell && inParagraph { cellText += string; if !string.isEmpty { cellHadContent = true } }
        }

        func parser(_ parser: XMLParser, didEndElement element: String,
                    namespaceURI: String?, qualifiedName qName: String?) {
            switch element {
            case "text:p":
                inParagraph = false
            case "table:table-cell", "table:covered-table-cell":
                guard inCell else { break }
                inCell = false
                let value = cellHadContent ? cellText : ""
                if value.isEmpty {
                    deferredEmptyCols += cellRepeat        // defer — don't materialize trailing empties
                } else {
                    if deferredEmptyCols > 0 {              // flush the gap before a real value
                        rowCells.append(contentsOf: Array(repeating: "", count: deferredEmptyCols))
                        deferredEmptyCols = 0
                    }
                    rowCells.append(contentsOf: Array(repeating: value, count: cellRepeat))
                }
                cellCount += cellRepeat
            case "table:table-row":
                guard inTable else { break }
                if rowCells.isEmpty {
                    deferredEmptyRows += rowRepeat          // defer trailing empty rows
                } else {
                    if deferredEmptyRows > 0 {              // flush blank rows before a real one
                        let blank = [String](repeating: "", count: lastRowWidth)
                        for _ in 0..<deferredEmptyRows { grid.append(blank) }
                        deferredEmptyRows = 0
                    }
                    lastRowWidth = rowCells.count
                    for _ in 0..<rowRepeat { grid.append(rowCells) }
                }
            case "table:table":
                if inTable { inTable = false; doneFirstTable = true }
            default:
                break
            }
            if cellCount > maxCells { parser.abortParsing() }   // backstop a pathological file
        }

        private func intAttr(_ s: String?) -> Int? {
            guard let s, let n = Int(s), n > 0 else { return nil }
            return n
        }
    }
}
