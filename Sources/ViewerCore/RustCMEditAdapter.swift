import Foundation
import RustCore

/// Routes the CodeMirror edit-apply reducer through the Rust core (migration
/// slice #2) when the `.cmEdit` gate is on, falling back to the Swift
/// `CMEditApplier` otherwise — the single place the two implementations meet.
///
/// Fail-safe by construction (`RustCoreFallback`): gate off → Swift; Rust bridge
/// fault → Swift. A *rejected* batch (`nil`) is a valid agreed result, not a
/// fault — both impls return `nil` to signal "resync". Default-OFF; the editor
/// path is byte-identical to today until the gate is flipped.
public enum RustCMEditAdapter {

    /// Apply `edits` to `base`, routing per the `.cmEdit` gate. Returns the
    /// applied text or `nil` (rejected → caller full-resyncs).
    public static func apply(_ edits: [CMEdit], to base: String) -> String? {
        outcome(edits, to: base).value
    }

    /// Same, but also reporting which engine produced the result (A/B / diag).
    public static func outcome(
        _ edits: [CMEdit],
        to base: String,
        defaults: UserDefaults = .standard,
        environment: [String: String]? = nil
    ) -> CoreOutcome<String?> {
        RustCoreFallback.run(
            .cmEdit, defaults: defaults, environment: environment,
            rust: {
                try mdvCoreApplyCMEdits(
                    base: base,
                    edits: edits.map { (from: $0.from, to: $0.to, insert: $0.insert) }
                )
            },
            swift: { CMEditApplier.apply(edits, to: base) }
        )
    }
}
