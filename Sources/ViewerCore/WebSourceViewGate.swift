import Foundation

/// TSK-1530 (WEB-MIGRATE M6) — gate for rendering the READ-ONLY source lens
/// with the CM6 WebView (read-only state, virtualized, rust highlights)
/// instead of the NSTextView-based `TextDisplayView` (the "chokes at 1MB"
/// pain).
///
/// SHIPS ON since 2026-07-17 (owner directive: retire NSTextView from the
/// source lens). Kill per-run with `MDV_WEB_SOURCE=0` or persist an opt-out
/// via the default.
///
/// NSTextView survives ONLY as the large-file fallback: CM6 has no
/// large-file guard (the whole document marshals through the JS bridge into
/// CM6's in-memory model), while `TextDisplayView` opens up to
/// `TextFileLoader.readableMaxBytes` (512 MiB). `shouldUseWebSource`
/// size-gates the route at `maxBytes` (default 16 MiB, tunable via
/// `mdv.webSourceMaxBytes`) so a 300 MB log still opens. The fallback dies
/// for good once the windowed/virtualized CM6 feed lands (the rust
/// windowed-snapshot path, TSK-1527 pattern).
///
/// v1 residual (tracked on the ticket): the AppKit `SourceGutterView`
/// extras (bookmark pins, diff marks) have no CM6 twin yet; the source
/// find-bar IS wired (drives CM6's search via the find nonce channels).
public enum WebSourceViewGate {
    public static let defaultsKey = "mdv.webSourceView"
    static let envKey = "MDV_WEB_SOURCE"

    /// Large-file fallback threshold for the web route. Above this byte
    /// length the source lens stays on the NSTextView stack.
    public static let maxBytesDefaultsKey = "mdv.webSourceMaxBytes"
    public static let defaultMaxBytes = 16 * 1024 * 1024

    public static func isEnabled(
        defaults: UserDefaults = .standard,
        environment: [String: String]? = nil
    ) -> Bool {
        let env = environment ?? ProcessInfo.processInfo.environment
        if let v = env[envKey] { return v == "1" }
        if defaults.object(forKey: defaultsKey) != nil {
            return defaults.bool(forKey: defaultsKey)
        }
        return true   // ships ON (owner 2026-07-17); NSTextView = large-file fallback only
    }

    /// Effective large-file threshold (bytes) for the web route.
    public static func maxBytes(defaults: UserDefaults = .standard) -> Int {
        let v = defaults.integer(forKey: maxBytesDefaultsKey)
        return v > 0 ? v : defaultMaxBytes
    }

    /// The actual routing decision for a source pane: web route iff the gate
    /// is enabled AND the document fits under the large-file threshold.
    public static func shouldUseWebSource(
        byteLength: Int,
        defaults: UserDefaults = .standard,
        environment: [String: String]? = nil
    ) -> Bool {
        guard isEnabled(defaults: defaults, environment: environment) else { return false }
        return byteLength <= maxBytes(defaults: defaults)
    }
}
