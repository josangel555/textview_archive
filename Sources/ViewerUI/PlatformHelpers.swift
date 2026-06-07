import AppKit

/// Small AppKit helpers used by context menus / actions. Centralized here so
/// we don't open-code `NSPasteboard.general.clearContents();
/// setString(...)` and `NSWorkspace.shared.activateFileViewerSelecting(...)`
/// every place we need them.
enum Pasteboard {
    /// Replace the pasteboard's contents with `string`. `pasteboard` is
    /// injectable so callers with a test seam (e.g. ReviewExport) can route
    /// through the same canonical write instead of open-coding it.
    static func copy(_ string: String, to pasteboard: NSPasteboard = .general) {
        pasteboard.clearContents()
        pasteboard.setString(string, forType: .string)
    }
}

enum Finder {
    static func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}
