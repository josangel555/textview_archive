import Foundation

/// A single recent entry to surface alongside the native `NSOpenPanel`
/// (TSK-746). `NSOpenPanel` exposes almost no recents customization, so
/// the high-value slice is presenting OUR recents (an accessory sidebar /
/// list) so the user picks a recent without re-navigating the system file
/// browser.
///
/// `displayName` is the last path component; `parentLabel` (optional) is a
/// short, IntelliJ-style folder hint that disambiguates same-named files
/// (mirrors `HistoryEntry.parentFolderLabel`).
public struct OpenPanelRecentEntry: Equatable, Sendable, Identifiable {
    public var id: String { path }
    /// Absolute filesystem path (already expanded/standardized).
    public let path: String
    /// `URL` form for handing straight to the open flow.
    public var url: URL { URL(fileURLWithPath: path) }
    /// Last path component, for the primary label.
    public let displayName: String
    /// `~`, the immediate parent folder name, or `/` at the fs root;
    /// `nil` when there's no meaningful parent (a bare name).
    public let parentLabel: String?
    /// True iff the path resolves to a directory (drives the icon).
    public let isDirectory: Bool

    public init(path: String, isDirectory: Bool) {
        self.path = path
        self.isDirectory = isDirectory
        self.displayName = (path as NSString).lastPathComponent
        self.parentLabel = Self.parentLabel(for: path)
    }

    /// Short parent-folder hint. `~` for the home dir, the parent's
    /// last component otherwise, `/` at the filesystem root, `nil` for
    /// a bare relative name. Pure string logic — no filesystem touch.
    static func parentLabel(for path: String) -> String? {
        let ns = path as NSString
        let parent = ns.deletingLastPathComponent
        if parent.isEmpty { return nil }
        let home = NSHomeDirectory()
        if !home.isEmpty,
           (parent as NSString).standardizingPath == (home as NSString).standardizingPath {
            return "~"
        }
        if parent == "/" { return "/" }
        let name = (parent as NSString).lastPathComponent
        if name.isEmpty || name == "." { return nil }
        return name
    }
}

/// Builds the ordered, de-duplicated, existence-filtered, capped recents
/// list that the Open-dialog accessory presents (TSK-746).
///
/// The derivation is intentionally a pure function over newest-first path
/// lists plus an injectable existence probe, so it is fully host-testable
/// in `ViewerCoreTests` without a real `NSOpenPanel` or live filesystem.
/// The two app sources — `GoToPathHistoryStore.recent()` (typed Go-to
/// paths) and `HistoryStore.recent()` (opened files/folders) — are merged
/// caller-side into a single newest-first list and handed in here.
public enum OpenPanelRecents {
    /// Default cap on how many recents the accessory surfaces. Kept small —
    /// the accessory is a quick-pick shortcut, not a full history browser.
    public static let defaultLimit = 12

    /// The result of probing one candidate path for the recents list.
    public enum Existence: Equatable, Sendable {
        case file
        case directory
        case missing
    }

    /// Derive the recents list.
    ///
    /// - Parameters:
    ///   - paths: candidate absolute paths, NEWEST-FIRST. Callers merge
    ///     their sources (Go-to history ahead of file history, say) before
    ///     calling; ordering is preserved as given.
    ///   - limit: maximum entries to return (after de-dup + existence
    ///     filtering). Defaults to `defaultLimit`.
    ///   - probe: existence check for a path. Injectable for host tests;
    ///     defaults to a `FileManager`-backed probe.
    /// - Returns: ordered (input order), de-duplicated by standardized
    ///   path, missing paths dropped, capped at `limit`.
    public static func derive(
        from paths: [String],
        limit: Int = defaultLimit,
        probe: (String) -> Existence = Self.fileSystemProbe
    ) -> [OpenPanelRecentEntry] {
        guard limit > 0 else { return [] }
        var seen = Set<String>()
        var out: [OpenPanelRecentEntry] = []
        for raw in paths {
            let path = (raw as NSString).standardizingPath
            if path.isEmpty { continue }
            // De-dup on the standardized form so `/a` and `/a/` (or a
            // re-typed tilde-vs-absolute) collapse to one entry; the FIRST
            // (newest) occurrence wins its slot.
            guard seen.insert(path).inserted else { continue }
            switch probe(path) {
            case .missing:
                continue
            case .file:
                out.append(OpenPanelRecentEntry(path: path, isDirectory: false))
            case .directory:
                out.append(OpenPanelRecentEntry(path: path, isDirectory: true))
            }
            if out.count >= limit { break }
        }
        return out
    }

    /// Prepend a just-opened path to the head of a recents list, de-duping
    /// any prior occurrence and re-capping — the "add-on-open updates the
    /// head" behavior. The underlying stores persist independently; this
    /// keeps an already-derived in-memory list fresh without a re-derive.
    public static func addingOnOpen(
        _ openedPath: String,
        to list: [OpenPanelRecentEntry],
        isDirectory: Bool,
        limit: Int = defaultLimit
    ) -> [OpenPanelRecentEntry] {
        guard limit > 0 else { return [] }
        let path = (openedPath as NSString).standardizingPath
        guard !path.isEmpty else { return Array(list.prefix(limit)) }
        let head = OpenPanelRecentEntry(path: path, isDirectory: isDirectory)
        var out = [head]
        for entry in list where entry.path != path {
            out.append(entry)
            if out.count >= limit { break }
        }
        return Array(out.prefix(limit))
    }

    /// `FileManager`-backed existence probe (the production default).
    public static func fileSystemProbe(_ path: String) -> Existence {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else {
            return .missing
        }
        return isDir.boolValue ? .directory : .file
    }
}
