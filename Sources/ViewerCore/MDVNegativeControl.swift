import Foundation

/// TSK-1134 — the codified negative-control (teeth) switch.
///
/// A pixel/visual guard proves it has teeth only if it can be shown to go RED on
/// a broken build. The pattern: gate a *deliberate* break behind
/// `MDV_ENABLE_BROKEN_<NAME>=1`, and have a T5 pixel test spawn the app with that
/// env set + assert the guard fails — demonstrating the green is not a false
/// green. (The first instance was `MDV_ENABLE_BROKEN_RULER`, in TextDisplayView /
/// SourceViewVisualRegressionTests.)
///
/// Use this single helper for every such switch so the env-key shape stays
/// consistent and greppable. Pure + host-testable (env injectable).
public enum MDVNegativeControl {
    /// True when `MDV_ENABLE_BROKEN_<name>` is `"1"`. `name` is the upper-snake
    /// control id (e.g. `"RULER"`); the `MDV_ENABLE_BROKEN_` prefix is added here.
    public static func isBroken(
        _ name: String,
        env: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        env["MDV_ENABLE_BROKEN_\(name)"] == "1"
    }
}
