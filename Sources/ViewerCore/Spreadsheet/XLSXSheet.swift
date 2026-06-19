import Foundation

/// Pure tabular model for a parsed XLSX worksheet (TSK-682 foundation slice —
/// the XLSX format of the RTF/DOCX/PDF/XLSX multi-format viewer epic).
///
/// This is the closed, dependency-free output of ``XLSXWorksheet`` /
/// ``XLSXWorkbook``: a dense grid of string-rendered cell values, mirroring the
/// shape `CSVTableView` already consumes so a later UI slice can render it
/// through the existing table lens. The model carries no styling, formulae, or
/// merged-cell geometry — those are downgraded to their displayed string value,
/// matching the "view, don't edit" intent of the epic.
///
/// All parsing is host-testable on raw XML strings (no file I/O) — see
/// ``XLSXWorksheet/parse(sheetXML:sharedStrings:)`` and
/// ``XLSXSharedStrings/parse(_:)``. The `.xlsx`-on-disk orchestration lives in
/// ``XLSXDocument`` (filesystem + the existing `ArchiveCatalog` unzip path).
public struct XLSXSheet: Equatable, Sendable {
    /// The sheet's display name (from `xl/workbook.xml`); empty when unknown.
    public let name: String
    /// Dense row-major grid of displayed cell values. Every row has exactly
    /// ``columnCount`` columns (short rows are right-padded with "") so the
    /// grid is rectangular for a table renderer.
    public let rows: [[String]]

    public init(name: String = "", rows: [[String]] = []) {
        self.name = name
        self.rows = rows
    }

    /// Column count of the rectangular grid (0 for an empty sheet).
    public var columnCount: Int { rows.first?.count ?? 0 }

    /// Row count.
    public var rowCount: Int { rows.count }

    public var isEmpty: Bool { rows.isEmpty }
}

/// A parsed workbook: its ordered sheets. v1 of the slice parses a single
/// (first) sheet, but the container is plural so a later slice can surface a
/// sheet tab strip without a model change.
public struct XLSXWorkbook: Equatable, Sendable {
    public let sheets: [XLSXSheet]
    public init(sheets: [XLSXSheet] = []) { self.sheets = sheets }

    public var firstSheet: XLSXSheet? { sheets.first }
}

// MARK: - A1-style cell-reference math

/// Conversions between spreadsheet A1 cell references and zero-based
/// (row, column) indices. Pure + total; host-testable in isolation.
public enum XLSXCellRef {
    /// Parse the leading column letters of an A1 ref (e.g. "AB12" → column 27,
    /// row 11, both zero-based). Returns nil for a malformed ref. The column
    /// is bijective base-26 ("A"=0, "Z"=25, "AA"=26, "AB"=27, …).
    public static func parse(_ ref: String) -> (row: Int, col: Int)? {
        var col = 0
        var sawLetter = false
        var idx = ref.startIndex
        while idx < ref.endIndex {
            let ch = ref[idx]
            guard let ascii = ch.asciiValue else { return nil }
            if ascii >= 65 && ascii <= 90 {            // 'A'...'Z'
                col = col * 26 + Int(ascii - 65) + 1
                sawLetter = true
                idx = ref.index(after: idx)
            } else if ascii >= 97 && ascii <= 122 {    // 'a'...'z' (tolerant)
                col = col * 26 + Int(ascii - 97) + 1
                sawLetter = true
                idx = ref.index(after: idx)
            } else {
                break
            }
        }
        guard sawLetter else { return nil }
        let rowStr = ref[idx...]
        guard !rowStr.isEmpty, let row1 = Int(rowStr), row1 >= 1 else { return nil }
        return (row: row1 - 1, col: col - 1)
    }
}
