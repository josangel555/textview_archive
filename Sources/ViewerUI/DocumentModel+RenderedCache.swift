import Foundation
import SwiftUI
import ViewerCore

// Rendered-markdown HTML cache (TSK-1110 SRP slice) — the memoized
// HTMLRenderer.renderPage output, the cache-only body read, the off-main render
// request, and the mounted-aware LRU eviction. The cache storage
// (renderedHTMLCache / renderedHTMLCacheOrder / renderedHTMLInFlight /
// renderedHTMLCacheMax) and the RenderedHTMLKey struct stay on DocumentModel
// (extensions can't add stored properties). All host logic — renderPage composes
// an HTML string; the live WKWebView is in the view, driven by @Published.
// Behavior-preserving move out of DocumentModel.swift.
extension DocumentModel {

    /// Returns the rendered HTML for `file` in `tabID`, building+caching
    /// on miss. Call from a SwiftUI body — it's main-thread, sync, and
    /// the cached path is just a dict lookup so re-renders are fast.
    ///
    /// Cache key is `(tabID, file.byteCount, file.modifiedTime)`. The
    /// caller passes `contents` separately because the mermaid host
    /// wraps the raw file in a fence (`"```mermaid\n…```\n"`) — the
    /// cache key intentionally ignores the wrapper since each tab only
    /// ever renders one shape (mermaid vs raw md), so a tabID match
    /// guarantees the same wrapping.
    public func renderedHTML(
        forTabID tabID: UUID,
        file: TextFile,
        contents: String,
        renderer: HTMLRenderer,
        stylesheet: String
    ) -> String {
        let key = RenderedHTMLKey(
            tabID: tabID,
            byteCount: file.byteCount,
            modifiedTime: file.modifiedTime
        )
        if let hit = renderedHTMLCache[key] { return hit }
        // Mermaid CSS rides along on every rendered markdown page. It's
        // tiny (~1 KB) and inlining it unconditionally avoids the flash
        // of unstyled mermaid hosts during initial render. The JS runtime
        // is injected separately by `MarkdownRenderedView.makeNSView` via
        // `WKUserScript`.
        let html = renderer.renderPage(
            contents,
            stylesheet: stylesheet,
            extraStylesheet: themedExtraStylesheet
        )
        storeRenderedHTML(key: key, html: html)
        return html
    }

    /// Cache-only read for SwiftUI bodies: a dict lookup, never a render.
    /// `nil` means "not rendered yet" — the body shows a placeholder and
    /// kicks `requestRenderedHTML` instead of rendering inline (TSK-611:
    /// the inline cold render — markdown→HTML plus the per-language
    /// TreeSitter `ts_query_new` compile for code fences — blocked the
    /// main thread for ~927ms inside a layout pass at file open).
    public func renderedHTMLIfCached(forTabID tabID: UUID, file: TextFile) -> String? {
        renderedHTMLCache[RenderedHTMLKey(
            tabID: tabID,
            byteCount: file.byteCount,
            modifiedTime: file.modifiedTime
        )]
    }

    /// Kick a background render for `key` unless cached or already in
    /// flight. The render (and any cold TreeSitter grammar query compile
    /// it triggers) runs off-main; the result lands on the MainActor,
    /// fills the cache, and republishes so bodies re-evaluate onto the
    /// cached HTML. Returns the task for tests; `nil` when nothing was
    /// kicked (cache hit or duplicate).
    ///
    /// A result whose tab has been closed by the time it lands is
    /// dropped — `purgeCaches(forTabID:)` already evicted that tab and a
    /// late store would resurrect a dead entry.
    @discardableResult
    public func requestRenderedHTML(
        forTabID tabID: UUID,
        file: TextFile,
        contents: String,
        renderer: HTMLRenderer,
        stylesheet: String
    ) -> Task<Void, Never>? {
        let key = RenderedHTMLKey(
            tabID: tabID,
            byteCount: file.byteCount,
            modifiedTime: file.modifiedTime
        )
        guard renderedHTMLCache[key] == nil,
              !renderedHTMLInFlight.contains(key) else { return nil }
        renderedHTMLInFlight.insert(key)
        // Capture the themed stylesheet on the main actor BEFORE the
        // detached hop (it reads the live theme selection).
        let extraStylesheet = themedExtraStylesheet
        return Task.detached(priority: .userInitiated) { [weak self] in
            let html = renderer.renderPage(
                contents,
                stylesheet: stylesheet,
                extraStylesheet: extraStylesheet
            )
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.renderedHTMLInFlight.remove(key)
                guard self.tabs.tabs.contains(where: { $0.id == tabID }) else { return }
                self.storeRenderedHTML(key: key, html: html)
                self.objectWillChange.send()
            }
        }
    }

    /// Shared insert + S2-G insertion-order eviction for the rendered-HTML
    /// cache (sync body path and async request path).
    ///
    /// MOUNTED-AWARE eviction (TSK-621): since TSK-611 the rendered body
    /// READS this cache only — evicting an entry whose tab is still in
    /// `MountedPanesLRU` flips that pane's branch webview→spinner, which
    /// DISMANTLES a retained WKWebView and re-renders it (the exact
    /// reload churn TSK-108's pane retention removed; the 5th markdown
    /// open used to tear down 2 retained panes). So: never evict a
    /// mounted tab's entry; evict the oldest NON-mounted first, and only
    /// down to capacity (the old drop-to-2/3 hysteresis amplified the
    /// over-eviction and is pointless now that eviction is rare). The
    /// cache may transiently exceed the cap by the mounted count — that
    /// is bounded by the pane LRU's own capacity (4).
    func storeRenderedHTML(key: RenderedHTMLKey, html: String) {
        if renderedHTMLCache[key] == nil {
            renderedHTMLCacheOrder.append(key)
        }
        renderedHTMLCache[key] = html
        guard renderedHTMLCache.count > Self.renderedHTMLCacheMax else { return }
        let mounted = Set(mountedPanes.ids)
        var overflow = renderedHTMLCache.count - Self.renderedHTMLCacheMax
        var keep: [RenderedHTMLKey] = []
        keep.reserveCapacity(renderedHTMLCacheOrder.count)
        for k in renderedHTMLCacheOrder {
            if overflow > 0, !mounted.contains(k.tabID) {
                renderedHTMLCache.removeValue(forKey: k)
                overflow -= 1
            } else {
                keep.append(k)
            }
        }
        renderedHTMLCacheOrder = keep
    }
}
