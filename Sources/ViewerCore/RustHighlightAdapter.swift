import Foundation
import RustCore
import ViewerKit

/// Routes syntax tokenisation through the Rust core (engine port TSK-660).
/// As of TSK-854 (Swift highlight-twin deletion) this is the ONLY
/// highlighter for the viewer + rendered-MD code fences — the Rust core
/// covers every language the app marks highlightable, so there is no Swift
/// `TreeSitterEngine` fallback on the highlight path anymore. (The Swift
/// engine survives ONLY for code-FOLDS + structural search, which have no
/// Rust port yet — see `TreeSitterEngine+Folds.swift`.)
///
/// Fail-safe by construction (`RustCoreFallback`): the gate stays in place
/// so an env/Settings off-switch or a bridge fault degrades to EMPTY runs
/// (plain text) rather than crashing — highlighting is best-effort
/// decoration. The previous Swift-engine fallback is gone: it would have
/// required carrying the per-grammar dylibs purely as a highlight backstop,
/// the ~16 MB double-carry TSK-854 reclaims.
///
/// Deliberate behavior gain on the Rust path (documented, not a bug):
/// `tree-sitter-highlight` EVALUATES `#match?`/`#eq?` query predicates that
/// the old Swift engine ignored — the TS/JS identifier mis-coloring class
/// (TSK-410) is structurally absent.
public enum RustHighlightAdapter {

    /// Tokenise `text` through the Rust core. Best-effort decoration:
    /// empty on a gate-off / bridge fault, never throws.
    public static func tokenize(
        _ text: String, language: HighlightLanguage
    ) -> [HighlightRun] {
        outcome(text, language: language).value
    }

    /// Same, but also reporting provenance (A/B / diagnostics / tests).
    /// With the Swift twin gone the source is `.rust` on success and
    /// `.swiftFallback`/`.swiftBecauseGateOff` map to "no highlighting"
    /// (an empty run array) — the gate's only remaining role is the
    /// off-switch.
    public static func outcome(
        _ text: String,
        language: HighlightLanguage,
        defaults: UserDefaults = .standard,
        environment: [String: String]? = nil
    ) -> CoreOutcome<[HighlightRun]> {
        RustCoreFallback.run(
            .highlight, defaults: defaults, environment: environment,
            rust: {
                guard let runs = try mdvCoreHighlightRuns(
                    text: text, lang: language.rawValue)
                else {
                    // No grammar in this core build for this language —
                    // degrade to plain (empty runs), same as a gate-off.
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
            // The Swift highlight engine is gone (TSK-854). Off-switch /
            // bridge fault → no highlighting (plain text), not a crash.
            swift: { [] }
        )
    }

    /// Pre-compile the per-language Rust highlight config (the TSK-545
    /// `config_cache`) off the user's first-open critical path. Highlighting
    /// routes exclusively through the Rust core now (TSK-854), so the warm
    /// heats the only engine that paints (TSK-853).
    ///
    /// Two-phase: `prioritizing` languages — markdown drives the rendered-MD
    /// fence path, which tokenizes on the main actor — compile first/serially;
    /// the rest compile concurrently across cores (`config_cache` builds
    /// outside its lock, so distinct languages parallelise). A one-space probe
    /// clears `tokenize`'s plainText/max-byte guards and reaches the config
    /// compile while emitting ~no runs.
    public static func warm(
        _ languages: [HighlightLanguage],
        prioritizing first: [HighlightLanguage] = [],
        defaults: UserDefaults = .standard,
        environment: [String: String]? = nil
    ) {
        let probe = " "
        var prioritized = Set<HighlightLanguage>()
        for lang in first where lang != .plainText {
            _ = outcome(probe, language: lang, defaults: defaults, environment: environment)
            prioritized.insert(lang)
        }
        let rest = languages.filter { $0 != .plainText && !prioritized.contains($0) }
        guard !rest.isEmpty else { return }
        DispatchQueue.concurrentPerform(iterations: rest.count) { i in
            _ = outcome(probe, language: rest[i], defaults: defaults, environment: environment)
        }
    }
}
