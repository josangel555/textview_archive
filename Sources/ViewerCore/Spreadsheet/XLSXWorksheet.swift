import Foundation

/// Parser for an XLSX worksheet part (`xl/worksheets/sheet*.xml`), TSK-682.
///
/// Walks `<sheetData>` → `<row>` → `<c>` cells and resolves each cell to its
/// *displayed string value*, then lays the cells into a dense rectangular grid
/// keyed by their A1 references (so gaps, sparse cells, and out-of-order rows
/// all land in the right column). The output ``XLSXSheet`` mirrors the shape the
/// existing CSV table lens consumes.
///
/// ## Cell-type handling (the `t` attribute)
///   - `t="s"`  — shared string: `<v>` is an index into the shared-string table.
///   - `t="str"` — formula string result: `<v>` is the literal string.
///   - `t="inlineStr"` — inline string: text lives in `<is><t>…</t></is>`,
///     not `<v>`.
///   - `t="b"`  — boolean: `<v>` is "0"/"1", rendered as "FALSE"/"TRUE".
///   - `t="e"`  — error: `<v>` is the literal error token (e.g. "#DIV/0!").
///   - no `t` / `t="n"` — number: `<v>` is the numeric literal, rendered as-is.
///     (Number-format styling — dates, currency — is a later slice; v1 shows the
///     raw stored value, which is the lossless, non-misleading default.)
///
/// Pure + dependency-free (Foundation `XMLParser`); host-testable on raw XML
/// with an in-memory shared-string array — no file I/O. A malformed cell
/// degrades to "" rather than aborting the parse.
public enum XLSXWorksheet {
    /// Parse a worksheet XML part into a dense ``XLSXSheet``. `sharedStrings`
    /// resolves `t="s"` cells; pass `[]` if the sheet has none.
    public static func parse(
        sheetXML: String, sharedStrings: [String], name: String = ""
    ) -> XLSXSheet {
        guard let data = sheetXML.data(using: .utf8) else {
            return XLSXSheet(name: name)
        }
        let parser = XMLParser(data: data)
        let delegate = WorksheetDelegate(sharedStrings: sharedStrings)
        parser.delegate = delegate
        parser.parse()
        return XLSXSheet(name: name, rows: delegate.buildGrid())
    }

    private final class WorksheetDelegate: NSObject, XMLParserDelegate {
        private let sharedStrings: [String]

        /// Sparse cell store: (row, col) → displayed string.
        private var cells: [Int: [Int: String]] = [:]
        private var maxRow = -1
        private var maxCol = -1

        // Per-cell parse state.
        private var curRow = -1
        private var curCol = -1
        private var curType = ""        // the `t` attribute
        private var inValue = false     // inside <v>
        private var inInlineText = false // inside <is>…<t>
        private var valueBuffer = ""
        /// Tracks an implicit column cursor for `<c>` cells with no `r=` ref,
        /// reset at each row start.
        private var implicitCol = 0

        init(sharedStrings: [String]) { self.sharedStrings = sharedStrings }

        func parser(_ parser: XMLParser, didStartElement elementName: String,
                    namespaceURI: String?, qualifiedName qName: String?,
                    attributes attributeDict: [String: String]) {
            switch elementName {
            case "row":
                implicitCol = 0
                // A row may declare its 1-based number via r=; otherwise we
                // advance from the previous max row.
                if let r = attributeDict["r"], let n = Int(r), n >= 1 {
                    curRow = n - 1
                } else {
                    curRow = maxRow + 1
                }
            case "c":
                curType = attributeDict["t"] ?? ""
                if let ref = attributeDict["r"], let pos = XLSXCellRef.parse(ref) {
                    curRow = pos.row
                    curCol = pos.col
                } else {
                    curCol = implicitCol
                }
                implicitCol = curCol + 1
                valueBuffer = ""
            case "v":
                inValue = true
                valueBuffer = ""
            case "t":
                // <t> appears inside <is> for inline strings; only capture it
                // when we're in that context (not the worksheet's other <t>s).
                inInlineText = true
                valueBuffer = ""
            default:
                break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if inValue || inInlineText { valueBuffer.append(string) }
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String,
                    namespaceURI: String?, qualifiedName qName: String?) {
            switch elementName {
            case "v":
                inValue = false
                if curType != "inlineStr" {
                    store(resolve(value: valueBuffer, type: curType))
                }
            case "t":
                inInlineText = false
                if curType == "inlineStr" {
                    store(valueBuffer)
                }
            case "c":
                curType = ""
            default:
                break
            }
        }

        /// Map a raw `<v>` payload to its displayed string per the cell type.
        private func resolve(value raw: String, type: String) -> String {
            switch type {
            case "s":
                guard let idx = Int(raw), idx >= 0, idx < sharedStrings.count else {
                    return ""
                }
                return sharedStrings[idx]
            case "b":
                return raw == "1" ? "TRUE" : "FALSE"
            case "str", "e":
                return raw
            default: // "", "n" (number)
                return raw
            }
        }

        private func store(_ value: String) {
            guard curRow >= 0, curCol >= 0 else { return }
            cells[curRow, default: [:]][curCol] = value
            maxRow = max(maxRow, curRow)
            maxCol = max(maxCol, curCol)
        }

        /// Materialize the sparse cell store into a dense, rectangular,
        /// row-major grid. Empty cells become "".
        func buildGrid() -> [[String]] {
            guard maxRow >= 0, maxCol >= 0 else { return [] }
            let width = maxCol + 1
            var grid = [[String]](
                repeating: [String](repeating: "", count: width),
                count: maxRow + 1)
            for (r, cols) in cells {
                for (c, v) in cols where r < grid.count && c < width {
                    grid[r][c] = v
                }
            }
            return grid
        }
    }
}
