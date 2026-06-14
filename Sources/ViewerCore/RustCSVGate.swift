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

    /// Persisted UserDefaults key for the Settings toggle. Sourced from the
    /// `.csv` capability so the (legacy) key has a single source of truth.
    public static let defaultsKey = RustCoreCapability.csv.defaultsKey

    /// Per-run env override (A/B / CI). `MDV_RUST_CSV=1` forces ON.
    public static let envVar = RustCoreCapability.csv.envVar

    /// Is CSV parsing routed through the Rust core for this run? Thin shim over
    /// the generalized `RustCoreGates` (identical precedence: env override →
    /// persisted toggle → false). Kept as the named entry point the existing
    /// CSV call sites / Settings view use.
    public static func isEnabled(
        defaults: UserDefaults = .standard,
        environment: [String: String]? = nil
    ) -> Bool {
        RustCoreGates.isEnabled(.csv, defaults: defaults, environment: environment)
    }
}
