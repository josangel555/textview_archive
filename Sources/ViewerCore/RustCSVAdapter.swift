import Foundation
import RustCore

/// Bridges the Rust core's CSV parse into the app's existing
/// `CSVParser.Result` shape, so the CSV viewer can swap parser implementations
/// behind `RustCSVGate` without any change to its rendering / filtering code.
///
/// The Rust path runs ONLY when the gate is on; this adapter is the single
/// place the two implementations meet. It is intentionally fail-safe: if the
/// Rust bridge throws for any reason (decode error, panic caught at the FFI
/// boundary, a future status the Swift side doesn't know), the adapter falls
/// back to the Swift `CSVParser` so a bridge fault degrades to today's behavior
/// rather than breaking CSV viewing. The fallback is reported via `usedRust`
/// so callers / tests can tell which path produced the result.
public enum RustCSVAdapter {

    /// The result of a routed parse: the `CSVParser.Result` plus which engine
    /// produced it (Rust when the gate is on AND the bridge succeeded; Swift
    /// otherwise).
    public struct Outcome: Sendable {
        public let result: CSVParser.Result
        /// `true` iff the Rust core produced this result. `false` means the
        /// Swift `CSVParser` did — either the gate was off, or the Rust bridge
        /// threw and we fell back.
        public let usedRust: Bool
    }

    /// Parse `text`, routing through the Rust core when `RustCSVGate` is on.
    /// Falls back to the Swift `CSVParser` when the gate is off or the bridge
    /// throws. Returns the parsed `CSVParser.Result` only (drops the engine
    /// tag) — the drop-in replacement for `CSVParser.parse(_:)`.
    public static func parse(_ text: String) -> CSVParser.Result {
        parseDetailed(text).result
    }

    /// Same as `parse(_:)` but returns which engine produced the result.
    /// Exposed for the A/B harness and any diagnostics that want to know
    /// whether the Rust path actually ran.
    public static func parseDetailed(_ text: String) -> Outcome {
        guard RustCSVGate.isEnabled() else {
            return Outcome(result: CSVParser.parse(text), usedRust: false)
        }
        do {
            let table = try rustParse(text)
            return Outcome(result: table, usedRust: true)
        } catch {
            // Bridge fault → fall back to the proven Swift path. A CSV view
            // should never go blank because the experimental engine hiccuped.
            return Outcome(result: CSVParser.parse(text), usedRust: false)
        }
    }

    /// Drive the Rust core to parse `text` and map its `Table` onto a
    /// `CSVParser.Result`, bypassing the gate. Throws on any bridge error
    /// (caller decides fallback). Public so the A/B harness and diagnostics can
    /// force the Rust path regardless of the live flag.
    public static func rustParse(_ text: String) throws -> CSVParser.Result {
        let session = try CsvSession(bytes: [UInt8](text.utf8))
        let table = try session.table()
        // The core returns the delimiter as a one-grapheme String; the Swift
        // Result wants a Character. An empty-table parse can return "" — match
        // the Swift parser, which carries the *detected* delimiter even for an
        // empty body, so we fall back to "," only when the core gives nothing.
        let delimiter: Character = table.delimiter.first ?? ","
        return CSVParser.Result(
            delimiter: delimiter,
            header: table.header,
            rows: table.rows,
            truncated: table.truncated
        )
    }
}
