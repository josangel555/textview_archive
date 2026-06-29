import Foundation
import ViewerCore

// Active-file data-format conversions (TSK-1110 SRP slice; TSK-901/675) — CSV ⇄
// JSON ⇄ Markdown-table conversions + summary/profile of the active file, with the
// content-sniffing helpers (TSK-901: a misnamed `.txt`-holding-JSON / `.dat`-
// holding-CSV still gets the matching tools, under a size cap). Reads through the
// public `activeFileText` seam + the now-internal `activeTextWithEncoding` /
// `applyTextTransformToActiveFile` write-through seam (both stay on DocumentModel).
// Behavior-preserving move out of DocumentModel.swift.
extension DocumentModel {

    /// True when the CSV conversions can act — an active `.csv`/`.tsv` text file.
    /// Size cap for content-sniffing the active file in the menu gates (TSK-901).
    /// The sniff scans/parses the in-memory text on each menu-validate, so cap it
    /// — beyond this we trust the extension only (a huge misnamed data file is
    /// rare and the validate path must stay cheap).
    private static let contentSniffByteCap = 1 * 1024 * 1024

    /// The active file's CONTENT-sniffed kind (TSK-901) — only for files whose
    /// extension didn't already classify them, and only under the size cap.
    /// Lets a misnamed file (`.txt` holding JSON / `.dat` holding CSV) still use
    /// the matching tools. Conservative: prose returns nil.
    private func sniffedActiveContentKind() -> ContentTypeSniffer.Kind? {
        guard let text = activeFileText, text.utf8.count <= Self.contentSniffByteCap else { return nil }
        return ContentTypeSniffer.detect(text)
    }

    public var canConvertActiveCSV: Bool {
        guard let tab = tabs.selected, let url = tab.url, activeFileText != nil else { return false }
        if ["csv", "tsv"].contains(url.pathExtension.lowercased()) { return true }
        return sniffedActiveContentKind() == .csv   // TSK-901: misnamed CSV
    }

    /// The active CSV rendered as a Markdown pipe table, or nil when no CSV is active.
    public func activeCSVAsMarkdownTable() -> String? {
        guard canConvertActiveCSV, let text = activeFileText else { return nil }
        let r = RustCSVAdapter.parse(text)
        return CsvConvert.toMarkdownTable(header: r.header, rows: r.rows)
    }

    /// The active CSV rendered as a JSON array of objects, or nil when no CSV is active.
    public func activeCSVAsJSON() -> String? {
        guard canConvertActiveCSV, let text = activeFileText else { return nil }
        let r = RustCSVAdapter.parse(text)
        return CsvConvert.toJSON(header: r.header, rows: r.rows)
    }

    /// A plain-text profile (row/column counts + per-column type & numeric
    /// min/max/mean) of the active CSV, or nil when no CSV is active.
    public func activeCSVSummary() -> String? {
        guard canConvertActiveCSV, let text = activeFileText else { return nil }
        let r = RustCSVAdapter.parse(text)
        return CsvSummary.report(header: r.header, rows: r.rows)
    }

    /// True when "Minify JSON" can act — an active `.json` text file, or (TSK-901)
    /// a misnamed text file whose content actually parses as JSON.
    public var canMinifyActiveJSON: Bool {
        guard let tab = tabs.selected, let url = tab.url, activeTextWithEncoding != nil else { return false }
        if url.pathExtension.lowercased() == "json" { return true }
        return sniffedActiveContentKind() == .json   // TSK-901: misnamed JSON
    }

    /// TSK — compact the active JSON file (whitespace-strip, order + values
    /// preserved). No-op on invalid JSON. Encoding/line-endings preserved.
    @discardableResult
    public func minifyActiveJSON() -> Bool {
        applyTextTransformToActiveFile(Formatter.minifyJSON)
    }

    /// The active JSON rendered as CSV (array-of-objects → table), or nil when no
    /// JSON is active OR the content isn't a JSON array of objects.
    public func activeJSONAsCSV() -> String? {
        guard canMinifyActiveJSON, let text = activeFileText else { return nil }
        return JsonConvert.toCSV(text)
    }
}
