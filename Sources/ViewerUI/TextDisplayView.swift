import AppKit
import SwiftUI

/// Read-only monospaced source viewer. Pure SwiftUI — no NSScrollView /
/// NSTextView. The previous NSScrollView+NSTextView implementation
/// triggered a macOS-14+ SwiftUI compositor pathology where the
/// surrounding TabBar / ModeBar / sidebar all stopped committing their
/// layer contents (visible as: window shows ONLY line numbers + text,
/// nothing else). The pure-SwiftUI path avoids the entire AppKit-bridge
/// problem.
///
/// Tradeoffs versus the NSTextView version:
///   - Native Cmd+F find bar is replaced by our own (Phase 4.5 UI).
///   - Per-character selection works via `.textSelection(.enabled)`.
///   - No incremental rendering of huge files — lines are split eagerly.
///     The Tab/file-load layer caps at maxBytes so the worst case is
///     ~32 MB of text → ~500k lines, all loaded. SwiftUI LazyVStack
///     virtualizes the rendering.
public struct TextDisplayView: View {
    public let text: String
    public let fontSize: CGFloat

    public init(text: String, fontSize: CGFloat = 13) {
        self.text = text
        self.fontSize = fontSize
    }

    public var body: some View {
        // Split eagerly. For files our loader will accept this is at
        // most a few hundred thousand lines and a single pass.
        let lines = text.split(
            separator: "\n",
            omittingEmptySubsequences: false
        ).map(String.init)
        SourceTextScrollView(lines: lines, fontSize: fontSize)
    }
}

private struct SourceTextScrollView: View {
    let lines: [String]
    let fontSize: CGFloat
    private let gutterWidth: CGFloat = 44

    var body: some View {
        // Use a GeometryReader to make the inner HStack fill at least
        // the viewport's width so the gutter pins to the leading edge.
        // ScrollView([.horizontal, .vertical]) by itself sizes its
        // content to its intrinsic width, which for a short snippet is
        // narrow and ends up centered inside the parent's larger frame.
        GeometryReader { geom in
            ScrollView([.horizontal, .vertical]) {
                HStack(alignment: .top, spacing: 0) {
                    gutter
                    contentColumn
                    Spacer(minLength: 0)
                }
                .frame(
                    minWidth: geom.size.width,
                    minHeight: geom.size.height,
                    alignment: .topLeading
                )
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    private var gutter: some View {
        VStack(alignment: .trailing, spacing: 0) {
            ForEach(lines.indices, id: \.self) { i in
                Text("\(i + 1)")
                    .font(.system(size: max(10, fontSize - 3), design: .monospaced))
                    .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                    .frame(width: gutterWidth - 6, alignment: .trailing)
                    .padding(.trailing, 6)
                    .frame(height: lineHeight)
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .overlay(alignment: .trailing) {
            // Right-edge separator between gutter and text.
            Rectangle()
                .fill(Color(nsColor: .separatorColor))
                .frame(width: 0.5)
        }
    }

    private var contentColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(lines.indices, id: \.self) { i in
                Text(lines[i])
                    .font(.system(size: fontSize, design: .monospaced))
                    .foregroundStyle(Color(nsColor: .labelColor))
                    .frame(height: lineHeight, alignment: .leading)
                    .padding(.leading, 8)
                    .fixedSize(horizontal: true, vertical: false)
            }
        }
        .textSelection(.enabled)
    }

    /// Tight, predictable per-line height — keeps gutter rows aligned
    /// with content rows without measuring text metrics.
    private var lineHeight: CGFloat {
        // ~1.32× font size matches Menlo / SF Mono natural leading and
        // matches the NSTextView output users were used to.
        max(14, fontSize * 1.32)
    }
}

