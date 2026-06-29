import Foundation
import ViewerKit
import ViewerCore

// "Open As…" universal viewer menu (TSK-1110 SRP slice; WAVE 2b item 6) — the
// viewer list for any file, force-open in a chosen category, the per-tab category
// override, the per-category default-view-mode pin, and the magic-byte auto-hint
// sniff. Behavior-preserving move out of DocumentModel.swift.
extension DocumentModel {

    /// The viewers offered by the universal "Open As…" menu for `url`.
    /// Every applicable category for ANY file, including binaries — the
    /// user can force a `.db` open as CSV, a `.png` as HEX, etc. Optional
    /// magic-byte sniff promotes a likely-real category to the top (an
    /// auto-hint, not a restriction).
    public func openAsCategories(for url: URL) -> [FileCategory] {
        // The full UNIVERSAL menu of viewers. Order = the menu order. Now
        // the complete viewer set (every FileCategory that maps to a real
        // viewer), so "Open As" is genuinely "open any file as any viewer":
        // text-shaped lenses (Source / Plain / Markdown / Mermaid / HTML),
        // native previews (Image / Audio / Video / PDF / SQLite), and HEX
        // (.binary) for raw bytes. `.unknown` is omitted — it's the
        // not-a-viewer sentinel, not a lens. (2026-06-01: folded the former
        // context-menu Open-As capability into this one chip; added the
        // media + mermaid lenses that were previously unreachable here.)
        var cats: [FileCategory] = [
            .code, .plainText, .markdown, .mermaid, .html,
            .image, .audio, .video, .pdf, .sqlite, .binary
        ]
        // Magic-byte hint: if the bytes look like a known type the
        // extension didn't reveal (e.g. `mydb.db.bak` → SQLite), float
        // that category to the front so it's the obvious first pick.
        if let hint = Self.sniffCategory(url: url),
           let idx = cats.firstIndex(of: hint) {
            cats.remove(at: idx)
            cats.insert(hint, at: 0)
        }
        return cats
    }

    /// Open `url` in a NEW tab forced to `category` (WAVE 2b item 6).
    /// Used by the sidebar file context menu's "Open As…" submenu, where
    /// the target file may not be the current tab. Loads through the
    /// chosen lens and selects the new tab.
    public func openAs(url: URL, category: FileCategory) {
        let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
        let state = controller.open(url: resolved, forcedCategory: category)
        let mode = ViewModeOptions.defaultMode(for: resolved, forcedCategory: category)
        tabCoordinator.append(Tab(
            url: resolved, state: state, viewMode: mode, categoryOverride: category))
        updateDerived()
        recordOpenedFile(state: state, resolved: resolved)
        startWatchingCurrentFile()
    }

    /// Set (or clear, with `nil`) the current tab's "Open As…" category
    /// override and re-open the tab through that lens. Re-runs the loader
    /// with the forced category (so a binary can be decoded as text /
    /// rendered as a SQLite preview / shown in HEX) and resets the view
    /// mode to that viewer's natural default.
    public func setCurrentCategoryOverride(_ category: FileCategory?) {
        guard let i = tabs.selectedIndex, tabs.tabs.indices.contains(i),
              let url = tabs.tabs[i].url else { return }
        let tabID = tabs.tabs[i].id
        // Recompute the load + the default mode under the override.
        let state = controller.open(url: url, forcedCategory: category)
        let mode = ViewModeOptions.defaultMode(for: url, forcedCategory: category)
        var t = tabs.tabs[i]
        t.categoryOverride = category
        t.state = state
        t.viewMode = mode
        tabCoordinator.replace(at: i, with: t)
        // Drop derived caches keyed on the old rendering so the new
        // viewer doesn't show stale rendered HTML / highlight runs.
        purgeCaches(forURL: url, tabID: tabID)
        updateDerived()
    }

    /// The user's pinned default view mode for `category` (TSK-671), or `nil`
    /// when that category uses its built-in default. Read by the bottom
    /// type-control menu's "Default view" section.
    public func defaultViewMode(for category: FileCategory) -> ViewMode? {
        preferences.viewModeDefault(for: category)
    }

    /// Pin (`mode`) or clear (`nil`) the default view mode for `category`.
    /// Affects FUTURE opens of that category — open tabs keep their mode.
    /// Publishes so the menu's checkmark moves immediately on selection.
    public func setDefaultViewMode(_ mode: ViewMode?, for category: FileCategory) {
        preferences.setViewModeDefault(mode, for: category)
        objectWillChange.send()
    }

    /// Best-effort magic-byte category sniff for the "Open As…" auto-hint.
    /// Reads only the file's header — cheap, never the whole file. Returns
    /// `nil` when nothing recognizable matches (then the menu just uses
    /// its default order). This is a HINT, never a gate.
    nonisolated static func sniffCategory(url: URL) -> FileCategory? {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? fh.close() }
        guard let head = try? fh.read(upToCount: 16), !head.isEmpty else { return nil }
        let b = [UInt8](head)
        // SQLite: "SQLite format 3\0".
        let sqliteMagic: [UInt8] = Array("SQLite format 3".utf8)
        if b.count >= sqliteMagic.count, Array(b.prefix(sqliteMagic.count)) == sqliteMagic {
            return .sqlite
        }
        // PNG.
        if b.count >= 8, Array(b.prefix(8)) == [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] {
            return .image
        }
        // JPEG.
        if b.count >= 3, b[0] == 0xFF, b[1] == 0xD8, b[2] == 0xFF { return .image }
        // GIF.
        if b.count >= 6, Array(b.prefix(3)) == Array("GIF".utf8) { return .image }
        // PDF — "%PDF".
        if b.count >= 4, Array(b.prefix(4)) == Array("%PDF".utf8) { return .pdf }
        return nil
    }
}
