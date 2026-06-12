import Foundation

/// Per-capability feature gates for routing a slice of work through the Rust
/// core instead of its Swift incumbent. This is the generalization of the
/// CSV-specific `RustCSVGate` to the N slices of the migration
/// (`docs/RUST_MIGRATION_PLAN_2026-06-04.md`): ONE precedence rule, one entry
/// per capability, so the host, adapters, tests, and the Settings view all
/// consult a single predicate.
///
/// Precedence (highest first):
///   1. env var (`MDV_RUST_<CAP>=1`) — per-run override for A/B / CI; wins even
///      over a persisted toggle, and an env `0` pins the Swift A-side.
///   2. persisted `UserDefaults` toggle (the Settings switch) — an EXPLICIT
///      user choice in either direction survives a shipped-default change.
///   3. the capability's `defaultEnabled` (TSK-649 stage A: the soak set
///      ships ON; everything else stays OFF until soaked).
///
/// SwiftUI-free (lives in ViewerCore) so pure routing code can gate without the
/// UI layer.
public enum RustCoreCapability: String, CaseIterable, Sendable {
    /// CSV/TSV parse + filter session. The shipped beachhead.
    case csv
    // Planned Phase-A slices (no new deps) — gates exist ahead of the adapters
    // so a slice's gate name is stable from day one.
    case cmEdit
    case diff
    case hex
    case hexSearch
    case fuzzy
    case indent
    /// Whole-document find (TSK-645; engine port TSK-630).
    case find
    /// Claude transcript event projection (TSK-647; engine port TSK-632).
    case transcript
    /// Markdown→HTML structural render (TSK-648; engine port TSK-631).
    case markdown

    /// Persisted UserDefaults key. `csv` keeps its original key for
    /// back-compat with any already-persisted preference / the Settings toggle.
    public var defaultsKey: String {
        switch self {
        case .csv: return "MarkdownViewer.experimental.rustCSV"
        default:   return "MarkdownViewer.experimental.rust.\(rawValue)"
        }
    }

    /// Per-run env override. `csv` keeps `MDV_RUST_CSV`; others follow
    /// `MDV_RUST_<UPPERCASED-RAWVALUE>`.
    public var envVar: String {
        switch self {
        case .csv: return "MDV_RUST_CSV"
        default:   return "MDV_RUST_\(rawValue.uppercased())"
        }
    }

    /// The shipped default (TSK-649 stage A). The SOAK SET — engines whose
    /// adapters are consumed in app paths, A/B-parity-validated, and
    /// longest-proven — ships ON; the rest stays OFF until their soak round.
    /// Off-switch at any time: `MDV_RUST_<CAP>=0` env, or the persisted
    /// Settings toggle (an explicit toggle beats this default).
    public var defaultEnabled: Bool {
        switch self {
        // Round 1 (2026-06-12): the longest-proven trio.
        case .csv, .indent, .diff: return true
        // Round 2 (2026-06-12, round 1 quiet): the hex family — consumed
        // since A0, A/B suites long green, engines ported in the first wave.
        case .hex, .hexSearch: return true
        // Round 3 (2026-06-12, rounds 1-2 quiet): the wave-1 engines —
        // fresh ports with cross-language A/B parity + adapter routing
        // tests, all fail-safe behind RustCoreFallback.
        case .fuzzy, .find, .transcript, .markdown: return true
        // cmEdit flips LAST and alone (the keystroke hot path).
        case .cmEdit: return false
        }
    }
}

public enum RustCoreGates {

    /// Is `capability` routed through the Rust core for this run? Env override
    /// first (a hard `1`/`true` ON, anything else — incl. `0` — OFF), else the
    /// EXPLICIT persisted toggle (either direction), else the capability's
    /// shipped default.
    public static func isEnabled(
        _ capability: RustCoreCapability,
        defaults: UserDefaults = .standard,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        if let raw = environment[capability.envVar] {
            return raw == "1" || raw.lowercased() == "true"
        }
        // `object(forKey:)` distinguishes "never touched" from an explicit
        // false — a user who toggled a slice OFF must stay OFF even after
        // the shipped default flips ON (TSK-649 stage A).
        if defaults.object(forKey: capability.defaultsKey) != nil {
            return defaults.bool(forKey: capability.defaultsKey)
        }
        return capability.defaultEnabled
    }
}
