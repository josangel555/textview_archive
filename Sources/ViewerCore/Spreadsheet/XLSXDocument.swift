import Foundation

/// On-disk loader for an `.xlsx` workbook (TSK-682 foundation slice). Composes
/// the pure part-parsers (``XLSXWorkbookParts`` / ``XLSXSharedStrings`` /
/// ``XLSXWorksheet``) with the existing read-only ZIP extraction
/// (``ArchiveCatalog``) — `.xlsx` is an OOXML ZIP container, so we lean on the
/// already-vetted system `unzip -p` path: zero new dependencies and the same
/// zip-slip safety (entry names never drive filesystem paths).
///
/// v1 of the slice parses ALL declared sheets (each resolved through the
/// workbook→rels indirection, with a conventional `xl/worksheets/sheetN.xml`
/// fallback), sharing one shared-string table. The result is a pure
/// ``XLSXWorkbook`` the existing table lens can render in a later UI slice.
///
/// The pure parsers are unit-tested on raw XML strings; this orchestrator is the
/// thin filesystem seam (best-effort, returns `nil`/empty on any extraction or
/// parse failure so a corrupt/foreign file degrades quietly rather than throwing
/// into the open path).
public enum XLSXDocument {
    public enum LoadError: Error, Equatable {
        case notXLSX
        case unreadable
        case noSheets
    }

    /// True when the URL is an `.xlsx` (or the macro-enabled `.xlsm`) workbook
    /// by extension. (`.xlsb` is a binary-part variant we do not parse.)
    public static func isXLSX(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return ext == "xlsx" || ext == "xlsm"
    }

    /// Load and parse the workbook at `url`. Throws ``LoadError`` for a
    /// non-xlsx URL or a file with no parseable sheet.
    public static func load(_ url: URL) throws -> XLSXWorkbook {
        guard isXLSX(url) else { throw LoadError.notXLSX }
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            throw LoadError.unreadable
        }

        let shared = extractString(url, entry: "xl/sharedStrings.xml")
            .map(XLSXSharedStrings.parse) ?? []

        let refs = extractString(url, entry: "xl/workbook.xml")
            .map(XLSXWorkbookParts.parseWorkbook) ?? []
        let rels = extractString(url, entry: "xl/_rels/workbook.xml.rels")
            .map(XLSXWorkbookParts.parseRels) ?? [:]

        var sheets: [XLSXSheet] = []
        if refs.isEmpty {
            // No workbook index — try the conventional first-sheet path.
            if let xml = extractString(url, entry: "xl/worksheets/sheet1.xml") {
                sheets.append(XLSXWorksheet.parse(
                    sheetXML: xml, sharedStrings: shared, name: "Sheet1"))
            }
        } else {
            for (i, ref) in refs.enumerated() {
                let part = sheetPartPath(for: ref, rels: rels, index: i)
                guard let xml = extractString(url, entry: part) else { continue }
                sheets.append(XLSXWorksheet.parse(
                    sheetXML: xml, sharedStrings: shared, name: ref.name))
            }
        }

        guard !sheets.isEmpty else { throw LoadError.noSheets }
        return XLSXWorkbook(sheets: sheets)
    }

    /// Resolve the worksheet part path (relative to the archive root) for a
    /// sheet declaration. Prefers the rels `Target`; falls back to the
    /// conventional `xl/worksheets/sheet<N>.xml`.
    static func sheetPartPath(
        for ref: XLSXWorkbookParts.SheetRef,
        rels: [String: String], index: Int
    ) -> String {
        if let target = rels[ref.relationshipID], !target.isEmpty {
            return normalizeTarget(target)
        }
        return "xl/worksheets/sheet\(index + 1).xml"
    }

    /// Rels `Target`s are relative to the rels file's base (`xl/`), and may be
    /// absolute (`/xl/...`). Normalize to an archive-root-relative path.
    static func normalizeTarget(_ target: String) -> String {
        if target.hasPrefix("/") { return String(target.dropFirst()) }
        if target.hasPrefix("xl/") { return target }
        return "xl/" + target
    }

    /// Extract one entry's bytes as a UTF-8 string, or nil on any failure
    /// (entry absent, not a zip, decode failure). `.xlsx` is a ZIP container, so
    /// we reuse `ArchiveCatalog`'s hardened `unzip -p` pipe via the
    /// extension-agnostic `zipEntryBytes` seam.
    private static func extractString(_ url: URL, entry: String) -> String? {
        guard let data = try? ArchiveCatalog.zipEntryBytes(named: entry, fromZipAt: url) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }
}
