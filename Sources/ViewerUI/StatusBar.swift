import SwiftUI
import ViewerCore
import ViewerKit

/// Bottom status bar: file path on the left; document metrics on the
/// right. Mirrors what code editors expose so the user can read state
/// at a glance without right-clicking or opening a menu.
///
/// Fields shown today (light-weight, no I/O on the body path):
///   • File path (abbreviated to ~) — moved here from ModeBar
///   • Language badge (also still shown in ModeBar for emphasis)
///   • Line count
///   • Character count
///   • File size (KB / MB)
///   • Line endings (LF / CRLF)
///   • Encoding (UTF-8 / Latin-1 / UTF-16 LE/BE)
///
/// Deferred (need plumbing or filesystem stat):
///   • Cursor position — requires NSTextView delegate → model
///   • git +/-, last commit, file age — Phase 7 git module
///   • Spaces vs tabs — Phase 8.5 polish
struct StatusBar: View {
    @ObservedObject var model: DocumentModel
    /// Tabs + per-tab caches (incl. live editor buffers). Observed
    /// DIRECTLY — same severed path as the TabBar's dirty-dot — because
    /// an editor save rewrites `tab.state` via `tabCoordinator.replace`,
    /// which fires `tabCoordinator.objectWillChange`, NOT
    /// `DocumentModel`'s; and every editor keystroke mutates
    /// `editorBuffers`. Without this observation the editor-mode metrics
    /// never re-body — they'd stay pinned to the on-disk-at-open values
    /// while the buffer is dirty AND after save. See `currentMetrics` for
    /// the editor-buffer-vs-loaded-TextFile choice.
    @ObservedObject var tabCoordinator: TabCoordinator
    /// Caret/selection channel. Observed DIRECTLY (not via `model`) so the
    /// "Ln X, Col Y" readout updates on caret move WITHOUT republishing
    /// DocumentModel — a caret tick re-bodies only this bar + the source
    /// subtree, never the sidebar / content tree. See `SourceViewChannel`.
    @ObservedObject var sourceView: SourceViewChannel
    /// Hover-description sink (0c). Defaults to the process-wide shared sink
    /// that the `.helpInfo(_:)` modifier feeds — `StatusBar(model:)` keeps
    /// working without a new injection at the (out-of-scope) ContentView root.
    @ObservedObject var helpSink: HelpSink = .shared

    var body: some View {
        HStack(spacing: 12) {
            Text(model.currentFilePath ?? "—")
                .font(.system(size: model.uiSize(11)))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.head)
                // The path is the LEAST critical field — it already
                // head-truncates. Give it the lowest layout priority so
                // SwiftUI shrinks IT (not the live metric chips) first
                // under width pressure. Without this, a normal-width
                // footer with the WAVE1 date chips appended distributed
                // truncation across every chip ("Col…", "50.…") instead
                // of collapsing the path.
                .layoutPriority(-1)
                .help(model.currentURL?.path ?? "")
                .accessibilityIdentifier("mdv.statusBar.path")

            // 0c: hover-description slot. Shows the longer `description` of
            // whatever element the pointer is over (fed by `.helpInfo`).
            // Empty when nothing is hovered. Truncates so it never pushes the
            // metrics off-screen.
            if let desc = helpSink.hovered?.description, !desc.isEmpty {
                Text(desc)
                    .font(.system(size: model.uiSize(11)))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(-1)
                    .accessibilityIdentifier("mdv.statusBar.helpDescription")
            }

            Spacer(minLength: 8)

            // Trailing block: live metrics first, then the WAVE1 date
            // chips. `ViewThatFits` tries the full layout (metrics +
            // dates) and falls back to metrics-only when the row is too
            // narrow — so the date chips DROP CLEANLY under width
            // pressure instead of clipping the live metrics. Combined
            // with the path's `.layoutPriority(-1)` and the per-chip
            // `.fixedSize()`, the live line/cursor/size/encoding chips
            // are guaranteed to render whole or not at all (never the
            // "Col…" / "50.…" half-truncation the date chips introduced).
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    metricsGroup
                    dateChips
                }
                metricsGroup
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .frame(height: 22)
        .background(Palette.windowBackground.opacity(0.65))
        .overlay(alignment: .top) { Divider() }
        .accessibilityIdentifier("mdv.statusBar")
    }

    /// Live document metrics (line/cursor, lines, chars, size, indent,
    /// EOL, encoding). These are the HIGH-priority chips — never dropped,
    /// each `.fixedSize()` so it renders whole. The trailing date chips
    /// (`dateChips`) drop ahead of these via `ViewThatFits`.
    @ViewBuilder
    private var metricsGroup: some View {
        if let metrics = currentMetrics {
            HStack(spacing: 12) {
                if model.currentViewMode.hasTextCaret,
                   metrics.lineCount > 0, sourceView.sourceSelection.line > 0 {
                    // Ln/Col only meaningful for the caret-backed text
                    // lenses (Source / Editor). Hidden in Rendered (no
                    // caret in the WKWebView — VM-01), Preview / Hex /
                    // Formatted / Table / Diff (no caret either), for
                    // media previews where everything is 0, and for
                    // large read-only files where the source view
                    // publishes a `line == 0` sentinel (it skips the
                    // O(N) newline-index build that would otherwise
                    // resolve precise line:col).
                    metric("Ln",
                        "\(sourceView.sourceSelection.line)" +
                        ", Col \(sourceView.sourceSelection.column)")
                }
                // Lines/Chars only apply to a text-backed document. For
                // media/binary previews (image/audio/video/PDF/sqlite)
                // they're a meaningless 0 — hide them rather than render
                // "Lines 0 / Chars 0", which reads as an empty 0-line doc
                // (PV-08). Size + category encoding still show.
                if metrics.hasTextMetrics {
                    metric("Lines", "\(metrics.lineCount)")
                    metric("Chars", formatNumber(metrics.charCount))
                }
                metric("Size",  formatBytes(metrics.byteCount))
                if !metrics.indent.isEmpty {
                    metric("Indent", metrics.indent)
                }
                metric("EOL",   metrics.lineEndings)
                metric("Enc",   metrics.encodingShort)
            }
            // A11Y-16: collapse the per-metric label/value pairs into
            // a single VoiceOver element so the rotor surfaces one
            // "Lines 42, Chars 1.2k, …" element instead of a dozen
            // fragments. `.combine` concatenates each metric's own
            // accessibility label (set in `metric(_:_:)`).
            .accessibilityElement(children: .combine)
        }
    }

    /// item7/0d: Created / Modified dates. "Modified" turns RED when
    /// the active tab's disk-staleness signal says the on-disk file
    /// changed since we loaded it (consumes Tab.diskState). Dates are
    /// today-relative (time-only when the date is today) and cached so
    /// the body hot path doesn't stat on every re-eval. LOW priority —
    /// the `ViewThatFits` in `body` drops this whole block when the row
    /// is too narrow rather than truncating the live metrics.
    @ViewBuilder
    private var dateChips: some View {
        if let dates = currentFileDates {
            HStack(spacing: 12) {
                if let created = dates.created {
                    metric("Created", Self.formatDate(created))
                }
                if let modified = dates.modified {
                    modifiedMetric(Self.formatDate(modified), stale: isActiveTabStale)
                }
            }
        }
    }

    /// True when the active tab's loaded copy is stale vs disk (or deleted).
    private var isActiveTabStale: Bool {
        switch model.tabs.selected?.diskState {
        case .staleVsDisk, .deleted: return true
        default: return false
        }
    }

    /// "Modified" chip that renders red on staleness. Mirrors `metric(_:_:)`
    /// but with a conditional value color + a "(on disk changed)" a11y hint.
    @ViewBuilder
    private func modifiedMetric(_ value: String, stale: Bool) -> some View {
        HStack(spacing: 3) {
            Text("Modified")
                .font(.system(size: model.uiSize(10), weight: .medium))
                .foregroundStyle(stale ? Color.red : Color.secondary)
            Text(value)
                .font(.system(size: model.uiSize(10), design: .monospaced))
                .foregroundStyle(stale ? Color.red : Color.primary)
        }
        // Render whole or not at all — never a half-truncated "Mod… 6:12…".
        // The whole date block is dropped by `ViewThatFits` when too narrow.
        .fixedSize()
        .help(stale ? "Modified: \(value) — the file changed on disk since it was loaded"
                    : "Modified: \(value)")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(stale ? "Modified \(value), changed on disk" : "Modified: \(value)")
        .accessibilityIdentifier("mdv.statusBar.modified")
    }

    @ViewBuilder
    private func metric(_ label: String, _ value: String) -> some View {
        HStack(spacing: 3) {
            Text(label)
                .font(.system(size: model.uiSize(10), weight: .medium))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: model.uiSize(10), design: .monospaced))
                .foregroundStyle(.primary)
        }
        // A status-bar chip must render whole — `.fixedSize()` stops
        // SwiftUI from compressing "Col 1" → "Col…" or "50.0k" → "50.…"
        // under width pressure. The path (lowest layout priority) absorbs
        // the shrink; the trailing date chips drop via `ViewThatFits`.
        .fixedSize()
        .help("\(label): \(value)")
        // One combined element per metric so the parent's
        // `.accessibilityElement(children: .combine)` (A11Y-16) reads
        // "Lines: 42" as a unit rather than two separate fragments.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label): \(value)")
    }

    /// Lightweight per-render stats from the in-memory TextFile.
    private struct Metrics {
        let lineCount: Int
        let charCount: Int
        let byteCount: Int
        let lineEndings: String  // "LF" / "CRLF" / "—"
        let encodingShort: String
        let indent: String       // "Tabs" / "Spaces (2)" / "—"
        /// True only for text-backed documents (`.loaded`). Media/binary
        /// previews leave line/char at 0; this flag drives hiding the
        /// Lines/Chars chips for them so they don't read as an empty
        /// 0-line document (PV-08).
        var hasTextMetrics: Bool = true
    }

    /// `body` re-evals every `@Published` mutation (typing, scroll,
    /// selection move). Without memoization, every keystroke re-runs
    /// `lineCount`, `IndentDetector.detect`, `(contents as NSString).length`
    /// across the full file. For a 1 MB source, that's ~5-15 ms of
    /// pure waste per keystroke. Cache keyed by URL + utf8 length so a
    /// file-watcher reload (different length) invalidates automatically.
    private var currentMetrics: Metrics? {
        guard let tab = model.tabs.selected else { return nil }
        switch tab.state {
        case .loaded(let f):
            // In editor mode the on-disk-at-open `TextFile` is stale the
            // moment the user types — the live edits live in the editor
            // buffer, and the post-save bytes land there too (`markSaved`
            // sets `originalText = text`). Read metrics off the buffer so
            // Lines/Chars/Size track the buffer live AND reflect the saved
            // content after a save, instead of freezing at the load-time
            // values. `byteCount` is recomputed from the buffer text in
            // the buffer's own encoding so it matches what a save writes.
            // Falls back to the loaded TextFile in non-editor modes (where
            // the on-disk copy IS the source of truth) and whenever no
            // buffer has been materialized yet.
            if tab.viewMode == .editor,
               let buf = tabCoordinator.editorBuffer(forTabID: tab.id) {
                let bytes = buf.text.data(using: buf.encoding)?.count
                    ?? f.byteCount
                let bufferFile = TextFile(
                    url: buf.url,
                    contents: buf.text,
                    encoding: buf.encoding,
                    byteCount: bytes,
                    modifiedTime: f.modifiedTime
                )
                return Self.metrics(for: bufferFile)
            }
            return Self.metrics(for: f)
        case .binary(let b):
            return Metrics(
                lineCount: 0,
                charCount: 0,
                byteCount: b.totalByteCount,
                lineEndings: "—",
                encodingShort: "binary",
                indent: "",
                hasTextMetrics: false
            )
        case .preview(let url, let cat):
            return Metrics(
                lineCount: 0,
                charCount: 0,
                byteCount: Self.cachedFileSize(for: url),
                lineEndings: "—",
                encodingShort: cat.rawValue,
                indent: "",
                hasTextMetrics: false
            )
        case .empty, .error, .loading, .hostedView:
            return nil
        }
    }

    /// Cache of (url, length) → Metrics for loaded text files.
    nonisolated(unsafe) private static var metricsCache:
        (key: AnyHashable, value: Metrics)? = nil
    private static let metricsLock = NSLock()

    private static func metrics(for f: TextFile) -> Metrics {
        struct Key: Hashable { let url: URL; let bytes: Int }
        let key = Key(url: f.url, bytes: f.byteCount)
        metricsLock.lock()
        if let hit = metricsCache, hit.key == AnyHashable(key) {
            metricsLock.unlock()
            return hit.value
        }
        metricsLock.unlock()
        // .utf16.count without NSString bridge — String.UTF16View.count
        // is O(1) on UTF-8 storage post-first-access (Swift caches).
        let m = Metrics(
            lineCount: lineCount(in: f.contents),
            charCount: f.contents.utf16.count,
            byteCount: f.byteCount,
            lineEndings: detectLineEndings(in: f.contents),
            encodingShort: encodingShort(f.encoding),
            indent: IndentDetector.detect(in: f.contents)
        )
        metricsLock.lock()
        metricsCache = (AnyHashable(key), m)
        metricsLock.unlock()
        return m
    }

    /// Cache of (url, mtime) → byte size for the preview state. Reads
    /// `attributesOfItem` once per (url, mtime); without this, every
    /// body re-eval did a fresh stat syscall.
    nonisolated(unsafe) private static var previewSizeCache:
        (url: URL, size: Int, sampledAt: TimeInterval)? = nil
    nonisolated(unsafe) private static let previewLock = NSLock()
    private static let previewCacheTTL: TimeInterval = 1.0

    private static func cachedFileSize(for url: URL) -> Int {
        let now = Date().timeIntervalSinceReferenceDate
        previewLock.lock()
        if let hit = previewSizeCache,
           hit.url == url,
           now - hit.sampledAt < previewCacheTTL {
            previewLock.unlock()
            return hit.size
        }
        previewLock.unlock()
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attrs?[.size] as? Int) ?? 0
        previewLock.lock()
        previewSizeCache = (url, size, now)
        previewLock.unlock()
        return size
    }

    // MARK: - File dates (Created / Modified)

    /// Creation + modification dates for the active tab's file. Cached by
    /// (url, mtime, size) so the body hot path doesn't `stat` on every
    /// re-eval. Reuses the same TTL-window discipline as the preview-size
    /// cache. `nil` for tabs with no file (empty / error / loading).
    private var currentFileDates: (created: Date?, modified: Date?)? {
        guard let tab = model.tabs.selected, let url = tab.url else { return nil }
        switch tab.state {
        case .empty, .error, .loading: return nil
        default: return Self.cachedFileDates(for: url)
        }
    }

    nonisolated(unsafe) private static var datesCache:
        (url: URL, created: Date?, modified: Date?, sampledAt: TimeInterval)? = nil
    nonisolated(unsafe) private static let datesLock = NSLock()
    private static let datesCacheTTL: TimeInterval = 1.0

    private static func cachedFileDates(for url: URL) -> (created: Date?, modified: Date?) {
        let now = Date().timeIntervalSinceReferenceDate
        datesLock.lock()
        if let hit = datesCache, hit.url == url, now - hit.sampledAt < datesCacheTTL {
            datesLock.unlock()
            return (hit.created, hit.modified)
        }
        datesLock.unlock()
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let created = attrs?[.creationDate] as? Date
        let modified = attrs?[.modificationDate] as? Date
        datesLock.lock()
        datesCache = (url, created, modified, now)
        datesLock.unlock()
        return (created, modified)
    }

    /// File created/modified chip: standardized `yyyy-MM-dd HH:mm` (24h)
    /// via the shared ``DisplayDateFormatter``. `now` / `calendar` are kept
    /// for call-site/test compatibility but no longer branch the format.
    static func formatDate(_ date: Date, now: Date = Date(),
                           calendar: Calendar = .current) -> String {
        DisplayDateFormatter.string(from: date)
    }

    private static func lineCount(in s: String) -> Int {
        // Each \n bumps the line count; trailing-newline / empty cases
        // handled so "abc" → 1, "abc\n" → 1, "abc\ndef" → 2.
        if s.isEmpty { return 0 }
        var n = 1
        for c in s.utf8 where c == 0x0A { n += 1 }
        if s.utf8.last == 0x0A { n -= 1 }
        return n
    }

    private static func detectLineEndings(in s: String) -> String {
        // Sample the first ~4 KB rather than the whole file — saves
        // O(N) on the body hot path for multi-MB files.
        let bytes = s.utf8
        var sawCR = false
        var sawLF = false
        var checked = 0
        for b in bytes {
            if b == 0x0D { sawCR = true }
            if b == 0x0A { sawLF = true }
            checked += 1
            if checked >= 4096 { break }
        }
        if sawCR && sawLF { return "CRLF" }
        if sawLF { return "LF" }
        if sawCR { return "CR" }
        return "—"
    }

    private static func encodingShort(_ enc: String.Encoding) -> String {
        switch enc {
        case .utf8:             return "UTF-8"
        case .utf16LittleEndian: return "UTF-16 LE"
        case .utf16BigEndian:    return "UTF-16 BE"
        case .utf16:            return "UTF-16"
        case .isoLatin1:        return "Latin-1"
        case .ascii:            return "ASCII"
        default:                return "?"
        }
    }

    private func formatNumber(_ n: Int) -> String {
        // Compact: 12,345 → "12.3k", 1,234,567 → "1.2M". The status bar
        // can't afford much width for "Chars".
        if n < 1_000 { return "\(n)" }
        if n < 1_000_000 {
            return String(format: "%.1fk", Double(n) / 1_000)
        }
        return String(format: "%.1fM", Double(n) / 1_000_000)
    }

    private func formatBytes(_ n: Int) -> String {
        if n < 1_024 { return "\(n) B" }
        if n < 1_024 * 1_024 { return String(format: "%.1f KB", Double(n) / 1_024) }
        return String(format: "%.1f MB", Double(n) / (1_024 * 1_024))
    }
}
