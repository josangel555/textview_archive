import Foundation
import RustCore
import ViewerKit

/// Routes syntax tokenisation through the Rust core (engine port TSK-660)
/// when the `.highlight` gate is on, falling back to the Swift
/// `TreeSitterEngine` otherwise — the single place the two engines meet.
///
/// Fail-safe by construction (`RustCoreFallback`): gate off → Swift; any
/// bridge fault → Swift. One EXPECTED routine fallback: the core build
/// covers a SUBSET of the Swift grammar set until the stage-3 coverage
/// parity lands, and signals `supported == false` in-band — the adapter
/// converts that to the Swift path (full language coverage is preserved
/// throughout the migration).
///
/// Deliberate behavior gain on the Rust path (documented, not a bug):
/// `tree-sitter-highlight` EVALUATES `#match?`/`#eq?` query predicates that
/// the Swift engine ignores — the TS/JS identifier mis-coloring class
/// (TSK-410) is structurally absent on the Rust side.
public enum RustHighlightAdapter {

    /// Tokenise `text`, routing per the `.highlight` gate. Mirrors
    /// `TreeSitterEngine.tokenize`'s contract: best-effort decoration,
    /// empty on failure, never throws.
    public static func tokenize(
        _ text: String, language: HighlightLanguage
    ) -> [HighlightRun] {
        outcome(text, language: language).value
    }

    /// Same, but also reporting which engine produced the result
    /// (A/B / diagnostics / tests).
    public static func outcome(
        _ text: String,
        language: HighlightLanguage,
        defaults: UserDefaults = .standard,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> CoreOutcome<[HighlightRun]> {
        RustCoreFallback.run(
            .highlight, defaults: defaults, environment: environment,
            rust: {
                guard let runs = try mdvCoreHighlightRuns(
                    text: text, lang: language.rawValue)
                else {
                    // No grammar in this core build — routine fallback,
                    // not a fault (stage-3 closes the coverage gap).
                    throw CoreError.decode("no core grammar for '\(language.rawValue)'")
                }
                return runs.compactMap { run in
                    // Unknown kind strings drop (forward-compat: a newer
                    // core may speak kinds this build's theme lacks).
                    TokenKind(rawValue: run.kind).map {
                        HighlightRun(
                            range: NSRange(location: run.start, length: run.len),
                            kind: $0)
                    }
                }
            },
            swift: { TreeSitterEngine.shared.tokenize(text, language: language) }
        )
    }
}
