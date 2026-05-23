import Foundation

/// User-selectable scope for the unified search panel. Pure value type
/// so the resolver is testable without spinning up a DocumentModel or
/// a SwiftUI view.
///
/// The panel keeps one `SearchScope` in `@State`. Each engine call
/// resolves it against the live "active file" and "active folder" to
/// get a concrete URL. The resolver intentionally tolerates missing
/// active context (e.g. no file open) — callers decide whether `nil`
/// means "fall back" or "show empty state".
public enum SearchScope: Equatable, Sendable {
    /// Use the currently-focused tab's URL.
    case activeFile
    /// Use the sidebar's root folder URL.
    case activeFolder
    /// User explicitly picked a specific file via NSOpenPanel.
    case pickedFile(URL)
    /// User explicitly picked a specific folder via NSOpenPanel.
    case pickedFolder(URL)

    /// True if this scope resolves to a folder (vs a single file). The
    /// panel uses this to decide which engines are runnable in the
    /// current mode (e.g. jq / CSS / XPath need a single file).
    public var isFolder: Bool {
        switch self {
        case .activeFolder, .pickedFolder: return true
        case .activeFile, .pickedFile:     return false
        }
    }
}

/// Pure resolver. Maps a `SearchScope` against ambient context
/// (`activeFile`, `activeFolder`) to the concrete URL the engine
/// should run against.
///
/// Resolution rules:
///   - `.activeFile`  → `activeFile` (nil if no file open).
///   - `.activeFolder`→ `activeFolder` (nil if no folder open).
///   - `.pickedFile`  → the picked URL, verbatim.
///   - `.pickedFolder`→ the picked URL, verbatim.
///
/// The resolver never validates that the URL exists on disk — callers
/// do that at run time (engines surface FileManager errors anyway).
public enum SearchScopeResolver {
    public static func resolve(
        _ scope: SearchScope,
        activeFile: URL?,
        activeFolder: URL?
    ) -> URL? {
        switch scope {
        case .activeFile:           return activeFile
        case .activeFolder:         return activeFolder
        case .pickedFile(let url):  return url
        case .pickedFolder(let url): return url
        }
    }

    /// Returns `true` when `scope` is "file-shaped" but the requested
    /// search mode requires a folder (e.g. cross-file text search
    /// where searching inside one file is nonsensical). The panel
    /// uses this to auto-collapse to `.activeFolder` and grey the
    /// file-scope buttons.
    public static func needsFolderFallback(
        scope: SearchScope,
        modeRequiresFolder: Bool
    ) -> Bool {
        modeRequiresFolder && !scope.isFolder
    }
}
