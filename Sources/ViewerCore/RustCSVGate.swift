import Foundation

/// Feature gate for routing CSV/TSV parsing through the Rust core instead of
/// the incumbent Swift `CSVParser`. **Default OFF** — the shipping default is
/// the existing Swift path, byte-for-byte identical to today's behavior.
///
/// Two independent opt-ins (either flips it ON):
///   1. `UserDefaults` key `MarkdownViewer.experimental.rustCSV == true`
///      (the Settings toggle, persisted; survives relaunch).
///   2. env var `MDV_RUST_CSV=1` (per-run override for A/B testing / CI; wins
///      even if the default is false, and is how the cross-language tests and
///      `swift run` smoke flip it without touching the prefs DB).
///
/// Mirrors `DiagnosticGate`'s shape so the host, the adapter, and the Settings
/// view all consult ONE predicate. Lives in ViewerCore (SwiftUI-free) so the
/// pure CSV-routing code can gate without importing the UI layer.
public enum RustCSVGate {

    /// Persisted UserDefaults key for the Settings toggle.
    public static let defaultsKey = "MarkdownViewer.experimental.rustCSV"

    /// Per-run env override (A/B / CI). `MDV_RUST_CSV=1` forces ON.
    public static let envVar = "MDV_RUST_CSV"

    /// Is CSV parsing routed through the Rust core for this run?
    ///
    /// The env var is checked first as a hard override so an A/B run can force
    /// the Rust path regardless of the persisted pref. Absent the env var, the
    /// persisted UserDefaults toggle decides; absent both, the answer is `false`
    /// (the safe Swift default).
    public static func isEnabled(
        defaults: UserDefaults = .standard,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        if let raw = environment[envVar] {
            // Explicit env override: "1"/"true" → ON, anything else (incl. "0")
            // → OFF. An env var set to "0" deliberately forces the Swift path
            // even if the persisted toggle is on (useful to pin the A-side).
            return raw == "1" || raw.lowercased() == "true"
        }
        return defaults.bool(forKey: defaultsKey)
    }
}
