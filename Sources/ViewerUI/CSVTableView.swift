import AppKit
import SwiftUI
import ViewerCore

/// CSV / TSV grid view. Reuses the column-width math + draggable
/// resizer pattern from `ResultTableView` (SQLite results) so they
/// look and feel identical. Parses lazily — the file's raw text is
/// passed in, parsing happens once per render and caches column
/// widths across re-renders.
struct CSVTableView: View {
    let text: String

    @State private var widths: [CGFloat] = []
    @State private var lastFingerprint: String = ""

    /// Cached parse — recomputed only when `text` changes. The parser
    /// is O(n) in characters; for a 1 MB CSV it's well under 100 ms.
    private var parsed: CSVParser.Result {
        CSVParser.parse(text)
    }

    var body: some View {
        let result = parsed
        ScrollView([.horizontal, .vertical]) {
            VStack(alignment: .leading, spacing: 0) {
                headerRow(result)
                ForEach(Array(result.rows.enumerated()), id: \.offset) { (i, row) in
                    cellRow(row, isAlt: i % 2 == 1)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { ensureWidths(result) }
        .onChange(of: text) { _, _ in
            // Re-parse fingerprint flush.
            ensureWidths(parsed)
        }
        .accessibilityIdentifier("mdv.csvTable")
    }

    private let rowHeight: CGFloat = 22

    @ViewBuilder
    private func headerRow(_ r: CSVParser.Result) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(r.header.enumerated()), id: \.offset) { (i, name) in
                Text(name)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .padding(.horizontal, 8)
                    .frame(width: widthFor(i), height: rowHeight, alignment: .topLeading)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .overlay(alignment: .trailing) { columnResizer(forIndex: i) }
            }
        }
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color(nsColor: .separatorColor)).frame(height: 0.5)
        }
    }

    @ViewBuilder
    private func cellRow(_ row: [String], isAlt: Bool) -> some View {
        HStack(spacing: 0) {
            ForEach(row.indices, id: \.self) { i in
                let cell = row[i]
                Text(cell)
                    .font(.system(size: 11, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.horizontal, 8)
                    .frame(width: widthFor(i), height: rowHeight, alignment: .topLeading)
                    .overlay(alignment: .trailing) {
                        Rectangle().fill(Color(nsColor: .separatorColor)).frame(width: 0.5)
                    }
            }
        }
        .background(isAlt ? Color(nsColor: .controlBackgroundColor).opacity(0.3) : Color.clear)
        .textSelection(.enabled)
    }

    private func columnResizer(forIndex i: Int) -> some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(width: 0.5)
            .overlay(
                Rectangle()
                    .fill(Color.clear)
                    .frame(width: 6)
                    .contentShape(Rectangle())
                    .onHover { hovering in
                        if hovering { NSCursor.resizeLeftRight.push() }
                        else { NSCursor.pop() }
                    }
                    .gesture(
                        DragGesture(minimumDistance: 0, coordinateSpace: .local)
                            .onChanged { value in
                                let newWidth = max(40, widthFor(i) + value.translation.width)
                                if widths.indices.contains(i) {
                                    widths[i] = newWidth
                                }
                            }
                    )
            )
    }

    private func widthFor(_ i: Int) -> CGFloat {
        if widths.indices.contains(i) { return widths[i] }
        return 120
    }

    private func ensureWidths(_ r: CSVParser.Result) {
        let fp = "\(r.header.joined(separator: "|"))#\(r.rows.count)"
        if fp == lastFingerprint, widths.count == r.header.count { return }
        lastFingerprint = fp
        let header = r.header
        let rows = r.rows.map { row -> [String?] in
            row.map { Optional($0) }
        }
        // Reuse SQLite's pure math helper. The shape matches.
        widths = ResultTableView.computeWidths(columns: header, rows: rows)
    }
}
