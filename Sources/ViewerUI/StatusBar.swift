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
                    if metrics.lineCount > 0 {
                        // Ln/Col only meaningful for text files. Hide
                        // for media previews where everything is 0.
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
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .frame(height: 22)
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.65))
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

    private var currentMetrics: Metrics? {
        guard let tab = model.tabs.selected else { return nil }
        switch tab.state {
        case .loaded(let f):
            return Metrics(
                lineCount: lineCount(in: f.contents),
                charCount: (f.contents as NSString).length,
                byteCount: f.byteCount,
                lineEndings: detectLineEndings(in: f.contents),
                encodingShort: encodingShort(f.encoding),
                indent: IndentDetector.detect(in: f.contents)
            )
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
            let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
            let size = (attrs?[.size] as? Int) ?? 0
            return Metrics(
                lineCount: 0,
                charCount: 0,
                byteCount: size,
                lineEndings: "—",
                encodingShort: cat.rawValue,
                indent: ""
            )
        case .empty, .error:
            return nil
        }
    }

    private func lineCount(in s: String) -> Int {
        // Each \n bumps the line count; trailing-newline / empty cases
        // handled so "abc" → 1, "abc\n" → 1, "abc\ndef" → 2.
        if s.isEmpty { return 0 }
        var n = 1
        for c in s.utf8 where c == 0x0A { n += 1 }
        if s.utf8.last == 0x0A { n -= 1 }
        return n
    }

    private func detectLineEndings(in s: String) -> String {
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

    private func encodingShort(_ enc: String.Encoding) -> String {
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
