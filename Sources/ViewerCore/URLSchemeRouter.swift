import Foundation

/// Parses `markdownviewer://` URLs into typed routes (TSK-317).
///
/// Extracted from the AppDelegate so the VERB routing is headless-testable
/// — previously only the path policy had tests while the dispatch lived
/// untested in `handleCustomURLScheme`. Every path funnels through
/// `URLSchemePolicy.containedPath` (the S1.1 hardening): home/temp only,
/// `~` expanded, anything else dropped at this boundary.
public enum URLSchemeRoute: Equatable, Sendable {
    /// `markdownviewer://open?path=…` — open a file.
    case open(URL)
    /// `markdownviewer://search?root=…&q=…` — set the root and/or run a
    /// cross-file search. Either part may be absent.
    case search(root: URL?, query: String?)
    /// `markdownviewer://walkthrough?path=…` — start a walkthrough script.
    /// CALLERS MUST CONFIRM with the user before starting: a walkthrough
    /// executes UI automation, which is a bigger grant than opening a
    /// file — a drive-by web link must not auto-drive the app (the local
    /// `--walkthrough` CLI flag is the unprompted dev path).
    case walkthrough(URL)
}

public enum URLSchemeRouter {

    /// The custom URL schemes the app answers to. `textview` is the current
    /// scheme (TSK-928); `markdownviewer` is kept as a back-compat alias so
    /// existing links keep working. Must match `CFBundleURLSchemes` in
    /// `scripts/Info.plist`.
    public static let schemes: Set<String> = ["textview", "markdownviewer"]

    /// Route a custom-scheme URL, or nil for unknown hosts / rejected
    /// paths / non-scheme URLs. A `search` with neither a contained root
    /// nor a query routes to nil rather than an empty action.
    public static func route(_ url: URL) -> URLSchemeRoute? {
        guard let scheme = url.scheme, schemes.contains(scheme), let host = url.host else { return nil }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems ?? []
        func q(_ key: String) -> String? {
            items.first(where: { $0.name == key })?.value
        }
        switch host {
        case "open":
            guard let raw = q("path"),
                  let safe = URLSchemePolicy.containedPath(raw) else { return nil }
            return .open(safe)
        case "search":
            let root = q("root").flatMap(URLSchemePolicy.containedPath)
            let query = q("q")
            guard root != nil || query != nil else { return nil }
            return .search(root: root, query: query)
        case "walkthrough":
            guard let raw = q("path"),
                  let safe = URLSchemePolicy.containedPath(raw) else { return nil }
            return .walkthrough(safe)
        default:
            return nil
        }
    }
}
