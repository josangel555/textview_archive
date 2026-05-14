import AppKit

/// Small AppKit helpers used by context menus / actions. Centralized here so
/// we don't open-code `NSPasteboard.general.clearContents();
/// setString(...)` and `NSWorkspace.shared.activateFileViewerSelecting(...)`
/// every place we need them.
enum Pasteboard {
    static func copy(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }
}

enum Finder {
    static func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}
