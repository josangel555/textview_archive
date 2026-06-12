import Foundation

/// Per-capability feature gates for routing a slice of work through the Rust
/// core instead of its Swift incumbent. This is the generalization of the
/// CSV-specific `RustCSVGate` to the N slices of the migration
/// (`docs/RUST_MIGRATION_PLAN_2026-06-04.md`): ONE precedence rule, one entry
/// per capability, so the host, adapters, tests, and the Settings view all
/// consult a single predicate.
///
/// **Default OFF for every capability.** A slice only runs through Rust when
/// explicitly opted in. Precedence (highest first):
///   1. env var (`MDV_RUST_<CAP>=1`) — per-run override for A/B / CI; wins even
///      over a persisted toggle, and an env `0` pins the Swift A-side.
///   2. persisted `UserDefaults` toggle (the Settings switch).
///   3. otherwise `false` (the safe Swift path).
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
}

public enum RustCoreGates {

    /// Is `capability` routed through the Rust core for this run? Env override
    /// first (a hard `1`/`true` ON, anything else — incl. `0` — OFF), else the
    /// persisted toggle, else `false`.
    public static func isEnabled(
        _ capability: RustCoreCapability,
        defaults: UserDefaults = .standard,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        if let raw = environment[capability.envVar] {
            return raw == "1" || raw.lowercased() == "true"
        }
        return defaults.bool(forKey: capability.defaultsKey)
    }
}
