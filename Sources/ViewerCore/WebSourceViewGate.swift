import Foundation

/// TSK-1530 (WEB-MIGRATE M6) — gate for rendering the READ-ONLY source lens
/// with the CM6 WebView (read-only state, virtualized, rust highlights)
/// instead of the NSTextView-based `TextDisplayView` (the "chokes at 1MB"
/// pain). Ships OFF: flipping is a render-behavior swap that needs its VM
/// slice green first (TSK-1550 gates the lane). Flip per-run with
/// `MDV_WEB_SOURCE=1` or the persisted default.
///
/// v1 scope note (documented on the ticket): the web route uses CM6's own
/// line numbers, folding and find; the AppKit `SourceGutterView` extras
/// (bookmark pins, diff marks) and the source find-bar wire up in the M6
/// follow-on slices before the default can flip.
public enum WebSourceViewGate {
    public static let defaultsKey = "mdv.webSourceView"
    static let envKey = "MDV_WEB_SOURCE"

    public static func isEnabled(
        defaults: UserDefaults = .standard,
        environment: [String: String]? = nil
    ) -> Bool {
        let env = environment ?? ProcessInfo.processInfo.environment
        if let v = env[envKey] { return v == "1" }
        if defaults.object(forKey: defaultsKey) != nil {
            return defaults.bool(forKey: defaultsKey)
        }
        return false   // ships OFF until the VM render slice validates the swap
    }
}
