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

    /// The production entry: fold regions for `text`, degrading to `[]` on a
    /// bridge fault (empty gutter for this pass, observable log).
    public static func foldRegions(
        _ text: String, language: HighlightLanguage
    ) -> [FoldRegion] {
        RustCoreFallback.runRustOnly(
            .fold,
            rust: { try rustFolds(text, language: language) },
            degraded: []
        ).value
    }
}
