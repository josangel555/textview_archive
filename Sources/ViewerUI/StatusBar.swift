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

    var body: some View {
        HStack(spacing: 12) {
            Text(model.currentFilePath ?? "—")
                .font(.system(size: model.uiSize(11)))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.head)
                .help(model.currentURL?.path ?? "")
                .accessibilityIdentifier("mdv.statusBar.path")

            Spacer(minLength: 8)

            if let metrics = currentMetrics {
                Group {
                    if metrics.lineCount > 0, model.sourceSelection.line > 0 {
                        // Ln/Col only meaningful for text files. Hide
                        // for media previews where everything is 0, and
                        // for large read-only files where the source
                        // view publishes a `line == 0` sentinel (it
                        // skips the O(N) newline-index build that would
                        // otherwise resolve precise line:col).
                        metric("Ln",
                            "\(model.sourceSelection.line)" +
                            ", Col \(model.sourceSelection.column)")
                    }
                    metric("Lines", "\(metrics.lineCount)")
                    metric("Chars", formatNumber(metrics.charCount))
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
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .frame(height: 22)
        .background(Palette.windowBackground.opacity(0.65))
        .overlay(alignment: .top) { Divider() }
        .accessibilityIdentifier("mdv.statusBar")
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
            return Self.metrics(for: f)
        case .binary(let b):
            return Metrics(
                lineCount: 0,
                charCount: 0,
                byteCount: b.totalByteCount,
                lineEndings: "—",
                encodingShort: "binary",
                indent: ""
            )
        case .preview(let url, let cat):
            return Metrics(
                lineCount: 0,
                charCount: 0,
                byteCount: Self.cachedFileSize(for: url),
                lineEndings: "—",
                encodingShort: cat.rawValue,
                indent: ""
            )
        case .empty, .error, .loading:
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
