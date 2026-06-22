import Foundation
import RustCore
import ViewerKit

/// Bridges the Rust core's fold engine (TSK-1202) into the app's `FoldRegion`,
/// so `DocumentModel.refreshEditorFolds` can route through Rust behind the
/// `.fold` gate without changing the gutter. Mirrors `RustFormulaAdapter`:
/// fail-safe — any bridge throw (decode error, unsupported language, caught FFI
/// panic) falls back to the Swift `TreeSitterEngine`, so a fault degrades to
/// today's behavior rather than blanking the fold gutter.
public enum RustFoldAdapter {

    /// Map a RustCore `CoreFoldRegion` onto the app's `FoldRegion`. Returns `nil`
    /// for a kind rawValue the app doesn't know (forward-compat: a newer Rust
    /// kind a stale app build can't represent).
    public static func mapRegion(_ core: CoreFoldRegion) -> FoldRegion? {
        guard let kind = FoldRegion.Kind(rawValue: core.kind) else { return nil }
        return FoldRegion(startLine: core.startLine, endLine: core.endLine, kind: kind)
    }

    /// Force the Rust path: fold regions for `text` in `language`. Throws on a
    /// bridge fault (incl. an unsupported language). Bypasses the gate — for the
    /// A/B harness and parity tests.
    public static func rustFolds(
        _ text: String, language: HighlightLanguage
    ) throws -> [FoldRegion] {
        try mdvCoreFoldRegions(text: text, lang: language.rawValue).compactMap(mapRegion)
    }

    /// Gated: route through the Rust core when `.fold` is on AND the bridge
    /// succeeds; otherwise run `swiftFolds` (the incumbent `TreeSitterEngine`
    /// path). Fail-safe — a bridge throw falls back rather than blanking folds.
    public static func foldRegions(
        _ text: String, language: HighlightLanguage,
        environment: [String: String]? = nil,
        swiftFolds: () -> [FoldRegion]
    ) -> [FoldRegion] {
        guard RustCoreGates.isEnabled(.fold, environment: environment) else { return swiftFolds() }
        do {
            return try rustFolds(text, language: language)
        } catch {
            return swiftFolds()
        }
    }
}
