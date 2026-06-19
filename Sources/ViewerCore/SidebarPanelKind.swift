import Foundation
import CoreGraphics

/// Canonical identity for every panel that can appear in the sidebar
/// (accordion today; activity-bar in the future).
///
/// One enum, one source of truth. The accordion UI reads the ordered
/// list out of `SidebarPanelRegistry.defaultOrder` and renders each
/// panel that's visible. The (forthcoming) activity-bar UI will read
/// the same list to render its icon column and pick which single panel
/// to show.
///
/// Persistence keys for per-panel state (heights, etc.) are pinned to
/// `appStorageKey` so the raw-value of a case can be evolved (e.g.
/// `gitPanel` → `git`) without invalidating user defaults.
public enum SidebarPanelKind: String, CaseIterable, Sendable, Codable, Identifiable {
    case files
    case bookmarks
    case searchAnywhere
    case git
    case claudeTimeline
    case lspOutline
    /// References / workspace-symbol panel (LSP Phase B).
    case lspNavigation
    /// "Problems" panel — server-pushed LSP diagnostics (LSP Phase E).
    case lspProblems
    /// Recently-opened files (global, newest-first) — reads `model.recents`.
    case recentlyOpened
    case pluginSections

    public var id: String { rawValue }

    /// `@AppStorage` key for the panel's persisted body height.
    ///
    /// Pinned per-case (not derived from `rawValue`) so the case names
    /// can evolve without throwing away the user's stored layout.
    /// The string contract here is pinned by
    /// `SidebarPanelKindTests.test_appStorageKeys_are_stable`.
    public var appStorageKey: String {
        switch self {
        case .files:          return "MarkdownViewer.sidebar.files.height"
        case .bookmarks:      return "MarkdownViewer.sidebar.bookmarks.height"
        case .searchAnywhere: return "MarkdownViewer.sidebar.searchAnywhere.height"
        case .git:            return "MarkdownViewer.sidebar.gitPanel.height"
        case .claudeTimeline: return "MarkdownViewer.sidebar.claudeTimeline.height"
        case .lspOutline:     return "MarkdownViewer.sidebar.lspOutline.height"
        case .lspNavigation:  return "MarkdownViewer.sidebar.lspNavigation.height"
        case .lspProblems:    return "MarkdownViewer.sidebar.lspProblems.height"
        // Fresh, stable key (pinned by SidebarPanelHeightsTests). Derived
        // names are forbidden here — pick the key once and never change it.
        case .recentlyOpened: return "MarkdownViewer.sidebar.recentlyOpened.height"
        case .pluginSections: return "MarkdownViewer.sidebar.pluginSections.height"
        }
    }

    /// `UserDefaults` key for the section's expanded/collapsed disclosure
    /// state. The rail toggle writes `true` here when it flips a panel ON
    /// (TSK-609): several sections (Git, Claude) keep their own collapse
    /// state, so "show the panel" used to mount only a thin collapsed
    /// header — which read as the rail button doing nothing. Sections that
    /// persist their disclosure read the SAME key via `@AppStorage`.
    ///
    /// `git` reuses its pre-existing legacy key so stored layouts survive.
    /// Pinned by test — never derive-and-change.
    public var expandedStateKey: String {
        switch self {
        case .git: return "MarkdownViewer.sidebar.gitExpanded"
        default:   return "MarkdownViewer.sidebar.\(rawValue).expanded"
        }
    }

    /// Whether this panel can become a free-standing tool window docked
    /// to a non-`.left` shoulder (right / bottom), and therefore whether
    /// it is a legal drag/redock target.
    ///
    /// SINGLE SOURCE OF TRUTH for the "FILES is never a free-standing tool
    /// window" rule that was previously open-coded as `kind == .files`
    /// checks scattered across `ShoulderRailView` (drag source + redock
    /// menu) and `DockResolution`. The FILES tree is the accordion's
    /// flex-fill panel — it has no fixed-size tool-window form — so it is
    /// pinned to the left accordion and rejected by `PanelPlacement`'s
    /// validator for any non-`.left` edge.
    ///
    /// Every other panel is dockable. Pinned by
    /// `PanelPlacementTests` so a new panel defaults to dockable unless it
    /// is explicitly opted out here.
    public var isDockable: Bool {
        switch self {
        case .files: return false
        default:     return true
        }
    }

    /// Default uncollapsed height for the panel's scrollable body.
    /// Matches the previous fixed `SidebarConstants.sectionBodyHeight`
    /// (220) for parity with the pre-resize layout.
    ///
    /// `files` doesn't use this — the FILES tree is the flex-fill
    /// panel and ignores per-panel heights. The constant is still
    /// defined for it so callers don't have to special-case.
    public var defaultHeight: CGFloat { 220 }

    /// Human-readable label for the future activity-bar tooltip /
    /// menu listing. Kept short — these end up in 1-line UI.
    public var displayName: String {
        switch self {
        case .files:          return "Files"
        case .bookmarks:      return "Bookmarks"
        case .searchAnywhere: return "Search"
        case .git:            return "Git"
        case .claudeTimeline: return "Claude"
        case .lspOutline:     return "Outline"
        case .lspNavigation:  return "References"
        case .lspProblems:    return "Problems"
        case .recentlyOpened: return "Recent"
        case .pluginSections: return "Plugins"
        }
    }

    /// SF Symbol used in the future activity-bar icon column. Today
    /// only the protocol surface reads this; the accordion UI uses
    /// each section's own header chrome.
    public var systemImage: String {
        switch self {
        case .files:          return "folder"
        case .bookmarks:      return "star"
        case .searchAnywhere: return "magnifyingglass"
        case .git:            return "arrow.triangle.branch"
        case .claudeTimeline: return "sparkles"
        case .lspOutline:     return "list.bullet.indent"
        case .lspNavigation:  return "arrow.triangle.turn.up.right.circle"
        case .lspProblems:    return "exclamationmark.triangle"
        case .recentlyOpened: return "clock.arrow.circlepath"
        case .pluginSections: return "puzzlepiece.extension"
        }
    }
}

/// Backwards-compatible alias.
///
/// The pre-refactor enum was named `SidebarPanel` (without the `Kind`
/// suffix). Existing call sites — and the `SidebarPanelHeights`
/// helpers in particular — continue to spell it that way. The alias
/// lets the rename land without an across-the-codebase sweep.
public typealias SidebarPanel = SidebarPanelKind

public extension SidebarPanelKind {
    /// Legacy spelling of `.git`. Pre-refactor the case was named
    /// `gitPanel` (mirroring `GitPanelSection`). The new canonical
    /// spelling is `.git` — shorter, matches the rest of the cases.
    /// Kept as a static alias so older call sites + tests compile.
    static var gitPanel: SidebarPanelKind { .git }
}
