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

    // Filter state. All three CSVFilter scopes are exposed:
    //   1. Global substring across all columns.
    //   2. Global substring constrained to one column (scope picker).
    //   3. Per-column expressions with operator prefixes (`>`, `<=`,
    //      `!=`, `=`, …) revealed via the "Per-column" toggle.
    @State private var globalQuery: String = ""
    @State private var globalScope: Int? = nil    // nil = all columns
    @State private var perColumn: [Int: String] = [:]
    @State private var advancedShown: Bool = false

    /// Cached parse. CSV parsing is O(n) per call and (more importantly)
    /// allocates one `String` per cell — for a 1 MB CSV with ~50K rows
    /// × 10 cols that's 500K Swift strings + temporary scalar arrays
    /// per parse. The original `var parsed: CSVParser.Result { … }`
    /// computed property re-parsed on every body re-eval, which after
    /// adding the filter UI fired on every keystroke — visible as
    /// heap churn and dropped frames. Cached on @State, recomputed
    /// only when `text` changes (via `.onChange`).
    @State private var parsedCache: CSVParser.Result =
        CSVParser.Result(delimiter: ",", header: [], rows: [])

    private var currentFilter: CSVFilter {
        CSVFilter(
            globalQuery: globalQuery,
            globalScope: globalScope.map { .column($0) } ?? .all,
            perColumn: perColumn
        )
    }

    var body: some View {
        let result = parsedCache
        let filtered = currentFilter.apply(to: result)
        VStack(spacing: 0) {
            filterBar(result: result, filteredCount: filtered.rows.count)
            Divider()
            // Single shared horizontal+vertical ScrollView so the
            // per-column filter row, header, and data rows all share
            // the same x-origin and scroll together horizontally. This
            // is what keeps the filter inputs visually aligned to the
            // columns they filter.
            ScrollView([.horizontal, .vertical]) {
                VStack(alignment: .leading, spacing: 0) {
                    if advancedShown {
                        perColumnRow(result: result)
                    }
                    headerRow(result)
                    ForEach(Array(filtered.rows.enumerated()), id: \.offset) { (i, row) in
                        cellRow(row, isAlt: i % 2 == 1)
                    }
                }
            }
        }
        .onAppear {
            reparse()
        }
        .onChange(of: text) { _, _ in
            reparse()
        }
        .accessibilityIdentifier("mdv.csvTable")
    }

    private func reparse() {
        let result = CSVParser.parse(text)
        parsedCache = result
        ensureWidths(result)
        let cols = result.header.count
        perColumn = perColumn.filter { $0.key < cols }
        if let s = globalScope, s >= cols { globalScope = nil }
    }

    private let rowHeight: CGFloat = 22

    @ViewBuilder
    private func filterBar(result: CSVParser.Result, filteredCount: Int) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .font(.system(size: 11))
            TextField("Filter rows…", text: $globalQuery)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .frame(maxWidth: 280)
                .accessibilityIdentifier("mdv.csvFilter.global")

            Menu {
                Button("All columns") { globalScope = nil }
                ForEach(Array(result.header.enumerated()), id: \.offset) { (i, name) in
                    Button(name.isEmpty ? "Column \(i + 1)" : name) {
                        globalScope = i
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(scopeLabel(result: result))
                        .font(.system(size: 11))
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9))
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .accessibilityIdentifier("mdv.csvFilter.scope")

            Button {
                advancedShown.toggle()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: advancedShown
                          ? "chevron.down.square" : "chevron.right.square")
                    Text("Per-column")
                }
                .font(.system(size: 11))
            }
            .buttonStyle(.borderless)
            .help("Show per-column filter row (supports >, <, >=, <=, =, !=)")

            Spacer()

            if !currentFilter.isEmpty {
                Button {
                    globalQuery = ""
                    globalScope = nil
                    perColumn.removeAll()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.borderless)
                .help("Clear all filters")
                .accessibilityIdentifier("mdv.csvFilter.clear")
            }

            Text(rowCountLabel(total: result.rows.count, shown: filteredCount))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("mdv.csvFilter.count")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    @ViewBuilder
    private func perColumnRow(result: CSVParser.Result) -> some View {
        // Sits inside the shared ScrollView (see body). Each filter
        // cell is exactly `widthFor(i)` wide so it aligns with the
        // header / data cell above and below.
        HStack(spacing: 0) {
            ForEach(Array(result.header.enumerated()), id: \.offset) { (i, _) in
                TextField("filter…", text: Binding(
                    get: { perColumn[i] ?? "" },
                    set: { newValue in
                        if newValue.isEmpty {
                            perColumn.removeValue(forKey: i)
                        } else {
                            perColumn[i] = newValue
                        }
                    }
                ))
                .textFieldStyle(.plain)
                .controlSize(.small)
                .font(.system(size: 11, design: .monospaced))
                .padding(.horizontal, 6)
                .frame(width: widthFor(i), height: rowHeight, alignment: .leading)
                .background(Color(nsColor: .windowBackgroundColor))
                .overlay(alignment: .trailing) {
                    Rectangle().fill(Color(nsColor: .separatorColor)).frame(width: 0.5)
                }
                .accessibilityIdentifier("mdv.csvFilter.col\(i)")
            }
        }
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color(nsColor: .separatorColor)).frame(height: 0.5)
        }
    }

    private func scopeLabel(result: CSVParser.Result) -> String {
        guard let i = globalScope, i >= 0, i < result.header.count else {
            return "All columns"
        }
        let name = result.header[i]
        return "in: " + (name.isEmpty ? "Column \(i + 1)" : name)
    }

    private func rowCountLabel(total: Int, shown: Int) -> String {
        if shown == total { return "\(total) rows" }
        return "\(shown) / \(total) rows"
    }

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
