import Foundation

// TSK-1254 slice 4 — the agent-drivable ADDRESSING CONTRACT.
//
// The app carries ~300 `mdv.*` accessibilityIdentifiers, but most are
// incidental or dynamic (per-row ids minted from data). This catalog is the
// CURATED subset of stable, long-lived, top-level controls that the
// out-of-process AX driver (AXDriverCore) and the element-reference tooling
// (TSK-1256) address — the surface an agent journey relies on. It is the AX/
// native-chrome sibling of `ScriptVerbCatalog` (the action-verb surface).
//
// A drift guard (AXIdentifierCatalogTests) asserts every catalogued id STILL
// EXISTS in the ViewerUI source, so renaming or deleting a critical control
// breaks the contract loudly instead of silently un-addressing it.

public enum AXIdentifierCatalog {

    /// Broad UI surface an addressable control belongs to (for grouping /
    /// agent affordances).
    public enum Surface: String, CaseIterable, Comparable, Sendable {
        case chrome      // window/toolbar/breadcrumb/tabs
        case content     // the main document view
        case editor      // CM6 editor surface
        case find        // find / filter / search bars
        case data        // csv / diff / hex viewers
        case nav         // sidebar / bookmarks / archive / empty-state
        case tools       // command palette, folder-stats, monitors
        case media       // audio editor

        public static func < (a: Surface, b: Surface) -> Bool {
            a.rawValue < b.rawValue
        }
    }

    public struct Entry: Equatable, Sendable {
        /// The accessibilityIdentifier literal, e.g. `"mdv.hexView"`.
        public let id: String
        public let surface: Surface
        /// One-line human/agent description of the control.
        public let summary: String
        public init(_ id: String, _ surface: Surface, _ summary: String) {
            self.id = id; self.surface = surface; self.summary = summary
        }
    }

    /// The curated contract. Keep entries STABLE — agents and the driver
    /// address by these. Add a row when a new top-level control becomes part of
    /// the agent-drivable surface; never silently drop one (the drift guard will
    /// catch a source removal, but update the catalog deliberately).
    public static let critical: [Entry] = [
        // chrome
        Entry("mdv.contentToolbar", .chrome, "The main content toolbar host."),
        Entry("mdv.breadcrumb", .chrome, "Path breadcrumb bar above the content."),
        Entry("mdv.tab.overflowMenu", .chrome, "Tab-strip overflow menu button."),
        Entry("mdv.tabbar", .chrome, "The document tab strip."),
        Entry("mdv.sessionTabBar", .chrome, "The session tab bar."),
        Entry("mdv.split", .chrome, "The split-view container."),
        // chrome — status bar: the app's observable STATE surface (agents READ
        // these to assert file/git/mode/recording state in a journey/eval).
        Entry("mdv.statusBar", .chrome, "The bottom status bar (app state surface)."),
        Entry("mdv.statusBar.git", .chrome, "Status bar: git repo/branch chip."),
        Entry("mdv.statusBar.vimMode", .chrome, "Status bar: vim mode indicator (NORMAL/INSERT/VISUAL…)."),
        Entry("mdv.statusBar.dates", .chrome,
              "Status bar: Created/Modified dates — click toggles absolute ↔ relative."),
        Entry("mdv.statusBar.macroRecording", .chrome, "Status bar: macro recording indicator (TSK-1162)."),
        Entry("mdv.statusBar.memory", .chrome, "Status bar: process memory-usage readout."),
        // content
        Entry("mdv.content", .content, "The main content region (active document view)."),
        Entry("mdv.htmlRendered", .content, "The rendered Markdown/HTML document view."),
        Entry("mdv.markdownOverview", .content, "The Markdown overview / minimap."),
        // editor
        Entry("mdv.editor", .editor, "The CM6 code editor surface."),
        // find / filter / search
        Entry("mdv.renderedFindBar", .find, "Find bar over the rendered-markdown view."),
        Entry("mdv.editorFindBar", .find, "Find bar over the CM6 editor."),
        Entry("mdv.sourceFindBar", .find, "Find bar over the plain source view."),
        Entry("mdv.crossSearchPanel", .find, "Cross-file search panel."),
        Entry("mdv.searchAnywhere", .find, "The global 'search anywhere' surface."),
        Entry("mdv.findMatchList", .find, "The find match-list results view."),
        // data viewers
        Entry("mdv.csvTable", .data, "The CSV/sheet table view."),
        Entry("mdv.csvFind.field", .data, "CSV find query field."),
        Entry("mdv.csvFilter.global", .data, "CSV global filter field."),
        Entry("mdv.hexView", .data, "The hex viewer."),
        Entry("mdv.hex.search.field", .data, "Hex viewer search field."),
        Entry("mdv.diff.findField", .data, "Diff viewer find field."),
        Entry("mdv.diff.summaryHeader", .data, "Diff viewer summary header (the diff content surface)."),
        // nav
        Entry("mdv.sidebar", .nav, "The file-navigator sidebar surface."),
        Entry("mdv.bookmarks", .nav, "Bookmarks sidebar section."),
        Entry("mdv.archive.browser", .nav, "Archive (zip/tar) browser."),
        Entry("mdv.lspOutline", .nav, "The LSP code-outline (symbol navigator)."),
        Entry("mdv.emptyState.newFile", .nav, "Empty-state 'New File' action."),
        Entry("mdv.emptyState.recents", .nav, "Empty-state recents list."),
        Entry("mdv.recentlyOpened", .nav, "The recently-opened tool window."),
        // tools
        Entry("mdv.commandPaletteButton", .tools, "Command-palette toolbar button."),
        // 2026-08-01 AX rollout: the palette + session-strip controls the AX
        // tier drives (AXChromeInteractionTests proves each end-to-end).
        Entry("mdv.palette.panel", .tools, "Command palette panel (container)."),
        Entry("mdv.palette.field", .tools, "Command palette search field."),
        Entry("mdv.sessionTab.new", .chrome, "Session strip + (new session) button."),
        Entry("mdv.sessionTab.omni", .chrome, "Session strip command-palette button."),
        Entry("mdv.sessionTab.settings", .chrome, "Session strip Settings button."),
        Entry("mdv.sessionTab.search", .chrome, "Session strip cross-file-search button."),
        Entry("mdv.sessionTab.saveAs", .chrome, "Session context menu: Save Session As…"),
        Entry("mdv.tab.closeButton", .chrome,
              "Tab close button (AX frame = parent tab's — drivers derive the × position)."),
        Entry("mdv.goto.panel", .nav, "Go-to-path prompt panel."),
        Entry("mdv.folderStats.showTreemap", .tools, "Folder-stats treemap toggle."),
        Entry("mdv.claudeMonitor", .tools, "Claude session monitor window."),
        Entry("mdv.gitPanel", .tools, "Git panel (log / diff / status tool window)."),
        Entry("mdv.gitLog.searchField", .tools, "Git log search field."),
        Entry("mdv.git.openModeToggle", .tools,
              "Git Status header: Diff | Source open-mode toggle (I-05, 2026-08-01)."),
        Entry("mdv.terminal.pane", .tools, "Terminal pane (PTY tool window) surface."),
        Entry("mdv.settings.languages", .tools,
              "Help ▸ Supported Languages list (id predates the 2026-08-05 move out of Settings)."),
        Entry("mdv.review.composer", .tools, "Code-review comment composer."),
        // TSK-1462: the old minimal local-history list (mdv.localHistory.list)
        // was replaced by the unified version viewer for ALL entry points.
        Entry("mdv.history.versionList", .tools, "Version-history timeline list (Local History + git)."),
        Entry("mdv.history.restore", .tools, "Version-history Restore button."),
        Entry("mdv.history.mergePick", .tools,
              "Version-history Merge into Current… (per-hunk picker, I-08)."),
        Entry("mdv.history.copyVersion", .tools,
              "Version-history Copy Version button (I-08)."),
        Entry("mdv.packageExplorer.list", .tools, "Dependency-package explorer list."),
        Entry("mdv.walkthrough.player", .tools, "The walkthrough player surface."),
        Entry("mdv.walkthroughs.browser", .tools, "The walkthrough catalog/browser."),
        Entry("mdv.actionHistory", .tools, "The action-history (reversible-actions) view."),
        Entry("mdv.problems", .tools, "The problems / diagnostics panel."),
        Entry("mdv.claudeTimeline", .tools, "The Claude session timeline view."),
        Entry("mdv.instrumentation", .tools, "The instrumentation (observability) window."),
        Entry("mdv.logs", .tools, "The system logs window."),
        Entry("mdv.metrics", .tools, "The system metrics window."),
        // media
        Entry("mdv.audioEditor", .media, "The audio editor surface."),
        Entry("mdv.imageEditor", .media, "The image editor surface."),
        Entry("mdv.imagePreview", .media, "The image preview / viewer surface."),
        Entry("mdv.audioPreview", .media, "The audio preview / player surface."),
    ]

    /// All catalogued ids.
    public static var ids: Set<String> { Set(critical.map(\.id)) }

    /// Lookup by id.
    public static func entry(_ id: String) -> Entry? {
        critical.first { $0.id == id }
    }

    /// Entries grouped by surface, surfaces in declaration (sorted) order.
    public static func grouped() -> [(surface: Surface, entries: [Entry])] {
        Surface.allCases.sorted().compactMap { surface in
            let entries = critical.filter { $0.surface == surface }
            return entries.isEmpty ? nil : (surface, entries)
        }
    }
}
