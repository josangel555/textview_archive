import Foundation
import RustCore

/// Routes whole-document find through the Rust core (TSK-645; engine port
/// TSK-630) when the `.find` gate is on, falling back to the Swift
/// `FindEngine` otherwise — the single place the two implementations meet.
///
/// Fail-safe by construction (`RustCoreFallback`): gate off → Swift; any
/// Rust bridge fault → Swift. Default-OFF. Two faults are EXPECTED routine
/// fallbacks, not errors:
///   • `.invalidPattern` for ICU-only constructs (lookaround, backrefs,
///     non-ASCII case folding) — the Swift/ICU engine CAN run those, so
///     the fallback restores full expressiveness;
///   • a truly-invalid pattern — both engines reject it; the Swift arm
///     mirrors the consumer's historical `(try? …) ?? []` contract, so the
///     adapter yields `[]` rather than throwing.
///
/// Two deliberate behavior gains on the Rust path (documented, not bugs):
/// the PikeVM is worst-case linear, so patterns the Swift-side
/// `RegexComplexityGuard` would REJECT as ReDoS-shaped run fine, and no
/// wall-clock truncation exists (`timedOut` is structurally false).
public enum RustFindAdapter {

    /// Search `text`, routing per the `.find` gate. Invalid patterns yield
    /// `[]` (the consumer contract automationFind has always had).
    public static func search(in text: String, query: FindQuery) -> [FindMatch] {
        outcome(in: text, query: query).value
    }

    /// Same, but also reporting which engine produced the result
    /// (A/B / diagnostics / tests).
    public static func outcome(
        in text: String,
        query: FindQuery,
        defaults: UserDefaults = .standard,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> CoreOutcome<[FindMatch]> {
        RustCoreFallback.run(
            .find, defaults: defaults, environment: environment,
            rust: {
                try mdvCoreFindSearch(
                    text: text,
                    pattern: query.pattern,
                    kind: query.kind == .literal ? "literal" : "regex",
                    caseSensitive: query.caseSensitive,
                    wholeWord: query.wholeWord
                ).map {
                    FindMatch(
                        range: NSRange(location: $0.location, length: $0.length),
                        line: $0.line,
                        column: $0.column)
                }
            },
            swift: { (try? FindEngine().search(in: text, query: query)) ?? [] }
        )
    }
}
