import Foundation
import RustCore

/// The CodeMirror edit-apply reducer over the rust-core engine.
///
/// STAGE-B (TSK-649, 2026-07-07): the Swift twin (`CMEditApplier`) is
/// DELETED — rust is the only engine, routed via
/// `RustCoreFallback.runRustOnly`. A *rejected* batch (`nil`) is a valid
/// agreed result, not a fault — the engine returns `nil` to signal
/// "resync", and a BRIDGE fault degrades to the same `nil` (observable via
/// the runRustOnly log), so the caller's full-resync path handles both.
public enum RustCMEditAdapter {

    /// Apply `edits` to `base`. Returns the applied text or `nil`
    /// (rejected/degraded → caller full-resyncs).
    public static func apply(_ edits: [CMEdit], to base: String) -> String? {
        outcome(edits, to: base).value
    }

    /// Same, but also reporting the result's provenance.
    public static func outcome(
        _ edits: [CMEdit],
        to base: String
    ) -> CoreOutcome<String?> {
        RustCoreFallback.runRustOnly(
            .cmEdit,
            rust: {
                try mdvCoreApplyCMEdits(
                    base: base,
                    edits: edits.map { (from: $0.from, to: $0.to, insert: $0.insert) }
                )
            },
            degraded: nil
        )
    }
}
