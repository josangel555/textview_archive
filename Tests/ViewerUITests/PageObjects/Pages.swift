import Foundation

/// One-stop accessor that bundles every Page Object for a single
/// step dump. Tests use this as a single parameter so adding a new
/// Page Object doesn't churn callers.
///
/// All page objects are constructed lazily on access; they're tiny
/// (a single dictionary capture) and the JIT eliminates the dispatch
/// noise.
struct Pages {
    let dump: [String: Any]

    init(dump: [String: Any]) { self.dump = dump }

    var tabBar:        TabBarPage          { TabBarPage(dump: dump) }
    var sidebar:       SidebarPage         { SidebarPage(dump: dump) }
    var modeBar:       ModeBarPage         { ModeBarPage(dump: dump) }
    var statusBar:     StatusBarPage       { StatusBarPage(dump: dump) }
    var content:       RenderedContentPage { RenderedContentPage(dump: dump) }
    var sessionTabBar: SessionTabBarPage   { SessionTabBarPage(dump: dump) }
    var goToPath:      GoToPathPage        { GoToPathPage(dump: dump) }

    /// Convenience: get the same generic dump page (window title,
    /// zoom, node walks) without picking a specific surface.
    var generic: GenericDumpPage { GenericDumpPage(dump: dump) }
}

/// Concrete `DumpPage` for "I just want windowTitle / zoom / node
/// walks without scoping to a surface".
struct GenericDumpPage: DumpPage {
    let dump: [String: Any]
}
