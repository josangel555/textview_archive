import SwiftUI
import ViewerCore

// MARK: - SidebarPanelProtocol conformances
//
// One-liner conformances for every existing sidebar section view.
// Lives in a single file (rather than next to each view) so the seam
// is easy to audit: every panel-kind enum case should appear here.
//
// Per the activity-bar groundwork: the views themselves are NOT
// rewritten. They keep their own headers, expand/collapse state,
// scroll bodies. The protocol exists so the future activity-bar UI
// can enumerate panels by `kind` and look up display metadata
// without an out-of-band registry.
//
// Access-level note: `static var kind` matches the host type's
// access level (internal for the file-local sections, public for the
// LSP panels that are exported from ViewerUI). The protocol itself
// is public; SwiftUI extensions satisfy public requirements with
// less-than-public witnesses as long as the conformance scope is
// the same module — which is the case here (ViewerUI).

extension BookmarksSection: SidebarPanelProtocol {
    static var kind: SidebarPanelKind { .bookmarks }
}

extension SearchAnywhereSection: SidebarPanelProtocol {
    static var kind: SidebarPanelKind { .searchAnywhere }
}

extension GitPanelSection: SidebarPanelProtocol {
    static var kind: SidebarPanelKind { .git }
}

extension ClaudeTimelineSection: SidebarPanelProtocol {
    static var kind: SidebarPanelKind { .claudeTimeline }
}

extension LSPOutlineSection: SidebarPanelProtocol {
    public static var kind: SidebarPanelKind { .lspOutline }
}

extension MarkdownOutlineSection: SidebarPanelProtocol {
    static var kind: SidebarPanelKind { .markdownOutline }
}

extension LSPNavigationPanel: SidebarPanelProtocol {
    public static var kind: SidebarPanelKind { .lspNavigation }
}

extension LSPProblemsPanel: SidebarPanelProtocol {
    public static var kind: SidebarPanelKind { .lspProblems }
}

extension PluginSidebarSections: SidebarPanelProtocol {
    static var kind: SidebarPanelKind { .pluginSections }
}

// FILES is rendered inline in `SidebarView` (it's the tree, not a
// stand-alone section view), so it doesn't have a dedicated View
// struct to conform here. Its kind (`SidebarPanelKind.files`) is
// the registry entry the future activity-bar UI will use; the body
// is supplied by `SidebarView` directly.
