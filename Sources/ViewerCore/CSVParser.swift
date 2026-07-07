import Foundation

/// Minimal RFC 4180-ish CSV parser. Handles:
///   - comma / tab / semicolon / pipe delimiters (auto-detected)
///   - double-quoted fields with embedded delimiters / newlines
///   - escaped quotes inside quoted fields (`""`)
///   - CRLF or LF line endings
///   - trailing empty fields
///
/// Does NOT handle:
///   - per-column type inference (everything is String)
///   - locale-specific number / date parsing
///   - alternative quote characters (single quotes, etc.)
///   - BOM stripping (caller normalizes input encoding)
///
/// Output: `(header: [String], rows: [[String]])`. If the input is
/// header-less the first row is still treated as the header — the
/// table view shows it as bold and the user can hover to see "Row 1".
public enum CSVParser {

    public struct Result: Equatable, Sendable {
        public let delimiter: Character
        public let header: [String]
        public let rows: [[String]]
        /// `true` when one of the `Limits` caps fired and the table was
        /// truncated / a cell was clamped. UI can surface a "malformed
        /// or oversized CSV — showing a partial view" banner (PARSE-04).
        public let truncated: Bool
        public init(delimiter: Character, header: [String], rows: [[String]],
                    truncated: Bool = false) {
            self.delimiter = delimiter
            self.header = header
            self.rows = rows
            self.truncated = truncated
        }
    }

    /// STAGE-B DELETED TWIN (TSK-649, 2026-07-07): the Swift CSV parsing
    /// ALGORITHM (RFC-4180 tokenizer, delimiter sniff, resource caps) that
    /// lived here was deleted — the engine is rust-core's `csv.rs` (grammar,
    /// caps and sniffing pinned there), and every caller routes through
    /// `RustCSVAdapter` (`parse` for sniffed, `parseWith` for forced-
    /// delimiter, e.g. the clipboard TSV path). Only the `Result` contract
    /// type above remains.
}
