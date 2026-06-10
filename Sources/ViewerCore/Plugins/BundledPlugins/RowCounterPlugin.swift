import Foundation

/// Trivial bundled plugin — sidebar section that lists open files with
/// their line counts. Pure-logic, no external deps, no IO of its own:
/// it consumes the snapshot the host hands it.
///
/// Lives in `Sources/ViewerCore/Plugins/BundledPlugins/` to make the
/// "first-party plugins are Swift inside the bundle" pattern obvious.
/// Third-party authors get the Tier A JSON path (and, in v2, Tier B
/// subprocess); they do NOT get to drop in compiled Swift.
public enum RowCounterPlugin {
    public static let id = "com.markdownviewer.builtin.rowcounter"

    /// Synthesised manifest. We could also ship this as JSON inside
    /// the app bundle and parse it at launch (truer to the design),
    /// but for the bundled-Swift path a Swift literal is cheaper and
    /// keeps the plugin self-contained as a single file.
    public static let manifest = PluginManifest(
        id: id,
        name: "Row Counter",
        version: "0.1.0",
        author: PluginManifest.Author(name: "MarkdownViewer", url: nil, email: nil),
        homepage: nil,
        license: "MIT",
        hostVersion: ">=0.0.0",
        manifestVersion: 1,
        capabilities: [.uiSidebar],
        contributes: []  // Bundled plugin registers contributions directly; the JSON `contributes` list is unused for in-process Swift plugins.
    )

    /// Register the plugin's one contribution with the host. Called
    /// at app launch from `applicationDidFinishLaunching`.
    @MainActor
    public static func register(into registry: PluginRegistry = .shared) {
        let entry = SidebarSectionRegistry.Entry(
            pluginID: id,
            sectionID: "row-counts",
            title: "ROW COUNTS",
            icon: "number.square",
            order: 500,
            collapsedByDefault: false,
            provider: rows(for:)
        )
        registry.registerBundledSidebarSection(manifest: manifest, entry: entry)
    }

    /// Public for unit-testing. The function is the entire plugin —
    /// counting lines is the kind of pure transformation that should
    /// be unit-testable without spinning up the host.
    ///
    /// PERF (TSK-612, measured on the TSK-603 nav-sweep capture): this
    /// provider runs inside `PluginSidebarSections`' SwiftUI body, so it
    /// fires on EVERY sidebar re-evaluation (tab switch, panel toggle,
    /// …). Recounting every open file each time burned ~256ms/sweep of
    /// main-thread grapheme iteration. Counts are now memoized per URL
    /// keyed by the contents string: an unchanged tab keeps its CoW
    /// storage, so the `==` hits the identical-buffer fast path and the
    /// hot path is O(open tabs), not O(total bytes).
    @MainActor
    public static func rows(for snapshot: SidebarSectionRegistry.Snapshot) -> [SidebarSectionRegistry.Row] {
        // Sort by URL path for deterministic display. (The snapshot
        // is a dictionary; iteration order is unstable.)
        let sorted = snapshot.openFileContents.sorted { $0.key.path < $1.key.path }
        var newCache: [URL: (contents: String, count: Int)] = [:]
        newCache.reserveCapacity(sorted.count)
        let result = sorted.map { url, contents -> SidebarSectionRegistry.Row in
            let count: Int
            if let hit = countCache[url], hit.contents == contents {
                count = hit.count
            } else {
                count = lineCount(of: contents)
                coldCountComputations += 1
            }
            newCache[url] = (contents, count)
            return SidebarSectionRegistry.Row(
                id: url.path,
                label: url.lastPathComponent,
                detail: "\(count) lines"
            )
        }
        // Replace wholesale so closed tabs don't pin their contents.
        countCache = newCache
        return result
    }

    /// Memoized counts for the CURRENTLY open snapshot. Holding the
    /// contents string is free (CoW reference shared with the tab) and
    /// gives an O(1) staleness check via the identical-storage `==`
    /// fast path.
    @MainActor
    private static var countCache: [URL: (contents: String, count: Int)] = [:]

    /// Test seam: number of actual (non-memoized) line counts performed.
    @MainActor
    internal static var coldCountComputations = 0

    /// Counts lines the way `wc -l`-style intuition wants: every
    /// newline marks the end of a line, and a trailing partial line
    /// (no terminating newline) also counts. Empty string → 0.
    ///
    /// Scans UTF-8 bytes for 0x0A instead of iterating `Character`s:
    /// ~10-30x faster (no grapheme segmentation), and it FIXES CRLF
    /// files — the old loop compared each grapheme to "\n", and the
    /// "\r\n" grapheme is NOT equal to "\n", so a CRLF file counted as
    /// ONE line. A byte scan can't miss the 0x0A inside CRLF.
    static func lineCount(of text: String) -> Int {
        if text.isEmpty { return 0 }
        var count = 0
        var lastByteWasNewline = false
        for byte in text.utf8 {
            if byte == 0x0A {
                count += 1
                lastByteWasNewline = true
            } else {
                lastByteWasNewline = false
            }
        }
        if !lastByteWasNewline { count += 1 }
        return count
    }
}

// `PluginManifest` is a public struct with no explicit init, which
// gives it an internal-visibility synthesized memberwise init reachable
// from in-process bundled-plugin code above. No extension needed.
