import Foundation
import RustCore
import ViewerKit

/// Bridges the Rust core's fold engine (TSK-1202) into the app's `FoldRegion`.
///
/// STAGE-B (TSK-649, 2026-07-07): the Swift fold twin (`TreeSitterEngine`'s
/// fold queries + computeFolds) is DELETED — rust is the only engine; its
/// language coverage is a strict superset of the deleted `.scm` set. A bridge
/// fault degrades to NO folds for the pass (observable via the runRustOnly
/// log), never a crash — the next text change retries.
public enum RustFoldAdapter {

    /// Map a RustCore `CoreFoldRegion` onto the app's `FoldRegion`. Returns `nil`
    /// for a kind rawValue the app doesn't know (forward-compat: a newer Rust
    /// kind a stale app build can't represent).
    public static func mapRegion(_ core: CoreFoldRegion) -> FoldRegion? {
        guard let kind = FoldRegion.Kind(rawValue: core.kind) else { return nil }
        return FoldRegion(startLine: core.startLine, endLine: core.endLine, kind: kind)
    }

    /// Force the Rust path: fold regions for `text` in `language`. Throws on a
    /// bridge fault (incl. an unsupported language) — for parity tests and
    /// callers that want the error.
    public static func rustFolds(
        _ text: String, language: HighlightLanguage
    ) throws -> [FoldRegion] {
        try mdvCoreFoldRegions(text: text, lang: language.rawValue).compactMap(mapRegion)
    }

    /// TSK-1609 (owner 2026-07-26, reported log line:
    /// `fold DEGRADED (twin deleted): decode("fold_regions: unsupported
    /// language 'plain'")`) — languages that have NO syntax folds at all.
    ///
    /// Plain text can't have fold regions by definition, so asking the core
    /// for them was never a fault — but the core answers `supported: false`,
    /// the client turns that into a thrown `decode` error, and the production
    /// adapter logged it as a DEGRADED bridge fault. That fired on every fold
    /// pass in any plain-text buffer: a false alarm that also buried real
    /// bridge faults in noise, plus a pointless FFI round-trip per text change.
    public static func hasNoFoldSupport(_ language: HighlightLanguage) -> Bool {
        language == .plainText
    }

    /// True when `error` is the core's "this language has no fold support"
    /// answer rather than a real bridge fault. Matched on the client's own
    /// message (one hop away, and pinned by a test) because widening
    /// `RustCore.CoreError` with a new case would re-lay-out a cross-module
    /// enum — the SwiftPM staleness trap CLAUDE.md documents.
    public static func isUnsupportedLanguage(_ error: Error) -> Bool {
        String(describing: error).contains("fold_regions: unsupported language")
    }

    /// The production entry: fold regions for `text`, degrading to `[]` on a
    /// bridge fault (empty gutter for this pass, observable log).
    ///
    /// A language with no fold support returns `[]` QUIETLY — it is a normal
    /// answer, not a degradation, so it must not trip the DEGRADED alarm.
    public static func foldRegions(
        _ text: String, language: HighlightLanguage
    ) -> [FoldRegion] {
        // Cheap client-side skip: no FFI call at all for a language that
        // cannot fold.
        guard !hasNoFoldSupport(language) else { return [] }
        do {
            return try rustFolds(text, language: language)
        } catch where isUnsupportedLanguage(error) {
            // The core says this language has no fold engine. Empty gutter,
            // no alarm — same outcome the guard above short-circuits.
            return []
        } catch {
            // A REAL bridge fault still degrades loudly through the shared
            // path (so the runRustOnly log/telemetry keeps its teeth).
            return RustCoreFallback.runRustOnly(
                .fold,
                rust: { throw error },
                degraded: []
            ).value
        }
    }
}
