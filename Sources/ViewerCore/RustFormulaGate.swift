import Foundation

/// Feature gate for routing spreadsheet formula evaluation through the Rust core
/// (TSK-1213). A thin wrapper over the central `RustCoreGates` registry
/// (`.formula`), mirroring `RustCSVGate`. Ships OFF — the Swift `FormulaEngine`
/// stays the default — until cross-language parity is soaked; flip per-run with
/// `MDV_RUST_FORMULA=1` (or `0` to pin Swift) or the persisted Settings toggle.
public enum RustFormulaGate {
    public static func isEnabled(
        defaults: UserDefaults = .standard,
        environment: [String: String]? = nil
    ) -> Bool {
        RustCoreGates.isEnabled(.formula, defaults: defaults, environment: environment)
    }
}
