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
    @ObservedObject var model: DocumentModel
    let tabID: UUID

    @State private var widths: [CGFloat] = []
    @State private var lastFingerprint: String = ""

    // Filter state lives on DocumentModel keyed by tab id so it
    // survives tab switches. These computed properties bridge the
    // SwiftUI Binding API to the model's `csvFilterState(forTabID:)`
    // / `setCsvFilterState(_:forTabID:)` accessors.
    private var globalQuery: Binding<String> {
        Binding(
            get: { model.csvFilterState(forTabID: tabID).globalQuery },
            set: { newValue in
                var s = model.csvFilterState(forTabID: tabID)
                s.globalQuery = newValue
                model.setCsvFilterState(s, forTabID: tabID)
            }
        )
    }
    private var globalScope: Int? {
        get { model.csvFilterState(forTabID: tabID).globalScope }
    }
    private func setGlobalScope(_ v: Int?) {
        var s = model.csvFilterState(forTabID: tabID)
        s.globalScope = v
        model.setCsvFilterState(s, forTabID: tabID)
    }
    private var perColumn: [Int: String] {
        get { model.csvFilterState(forTabID: tabID).perColumn }
    }
    private func setPerColumn(_ map: [Int: String]) {
        var s = model.csvFilterState(forTabID: tabID)
        s.perColumn = map
        model.setCsvFilterState(s, forTabID: tabID)
    }
    private var advancedShown: Bool {
        get { model.csvFilterState(forTabID: tabID).advancedShown }
    }
    private func setAdvancedShown(_ v: Bool) {
        var s = model.csvFilterState(forTabID: tabID)
        s.advancedShown = v
        model.setCsvFilterState(s, forTabID: tabID)
    }

    /// Debounced filter — separate from the typing buffer so each
    /// keystroke doesn't immediately reapply the filter over the full
    /// row set. ~200 ms debounce balances responsiveness vs work.
    @State private var debouncedFilter: CSVFilter = CSVFilter()
    @State private var debounceTask: Task<Void, Never>?

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

    /// Parallel-to-`parsedCache.rows`, pre-lowercased. Populated once on
    /// every `reparse()`. The global-query contains-match used to call
    /// `String.lowercased()` per cell per row per keystroke; on a 1 MB
    /// CSV that's hundreds of thousands of allocations per character
    /// typed. With the cache, typing only does `String.contains`
    /// against the pre-lowercased buffer. ~3-10× faster filter typing
    /// on multi-MB CSVs.
    @State private var lowercasedRowsCache: [[String]] = []

    private var currentFilter: CSVFilter {
        let state = model.csvFilterState(forTabID: tabID)
        return CSVFilter(
            globalQuery: state.globalQuery,
            globalScope: state.globalScope.map { .column($0) } ?? .all,
            perColumn: state.perColumn
        )
    }

    var body: some View {
        let result = parsedCache
        let filtered = debouncedFilter.apply(
            to: result,
            lowercasedRows: lowercasedRowsCache
        )
        VStack(spacing: 0) {
            filterBar(result: result, filteredCount: filtered.rows.count)
            Divider()
            // Single shared horizontal+vertical ScrollView so the
            // per-column filter row, header, and data rows all share
            // the same x-origin and scroll together horizontally.
            // LazyVStack virtualizes the vertical axis even inside a
            // 2-axis ScrollView — only ~30 visible rows live at any
            // time. ForEach uses Int range directly rather than
            // Array(rows.enumerated()), which allocated a fresh
            // tuple-array on every body re-eval.
            ScrollView([.horizontal, .vertical]) {
                LazyVStack(alignment: .leading, spacing: 0,
                           pinnedViews: [.sectionHeaders]) {
                    if advancedShown {
                        perColumnRow(result: result)
                    }
                    Section {
                        ForEach(filtered.rows.indices, id: \.self) { i in
                            cellRow(filtered.rows[i], isAlt: i % 2 == 1)
                        }
                    } header: {
                        headerRow(result)
                    }
                }
            }
        }
        .onAppear {
            reparse()
            debouncedFilter = currentFilter
        }
        .onChange(of: text) { _, _ in
            reparse()
        }
        .onChange(of: currentFilter) { _, newFilter in
            scheduleFilterCommit(newFilter)
        }
        .accessibilityIdentifier("mdv.csvTable")
    }

    /// 200 ms debounce on filter commits — typing into the global
    /// query or a per-column field stays responsive while heavy
    /// filter work (lowercased compares, regex-shaped expressions)
    /// happens only after the user pauses.
    private func scheduleFilterCommit(_ filter: CSVFilter) {
        debounceTask?.cancel()
        // If the filter cleared completely, commit immediately so the
        // clear button feels instant. Drop the cancelled handle too,
        // otherwise a previously-scheduled non-empty filter could fire
        // after the clear and briefly re-apply it.
        if filter.isEmpty {
            debouncedFilter = filter
            debounceTask = nil
            return
        }
        debounceTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 200_000_000)
            if Task.isCancelled { return }
            debouncedFilter = filter
        }
    }

    private func reparse() {
        let result = CSVParser.parse(text)
        parsedCache = result
        // O(rows × cols) one-time lowercase. Pays for itself after the
        // first ~3 keystrokes vs the previous per-keystroke approach.
        // But for small CSVs the cache costs more than it saves and
        // doubles peak memory unnecessarily — only build it once the
        // file size justifies the cost. 256 KB threshold matches the
        // crossover point where typing latency starts to matter; below
        // that, live `.lowercased()` is fast enough.
        if text.utf8.count >= 256 * 1024 {
            lowercasedRowsCache = result.rows.map { row in
                row.map { $0.lowercased() }
            }
        } else {
            // Drop any stale cache from a previous larger file.
            lowercasedRowsCache = []
        }
        ensureWidths(result)
        // After re-parse, drop stale per-column entries (file shape
        // may have changed) and stale scope picks.
        let cols = result.header.count
        let pruned = perColumn.filter { $0.key < cols }
        if pruned != perColumn { setPerColumn(pruned) }
        if let s = globalScope, s >= cols { setGlobalScope(nil) }
    }

    /// Row height scales with the user's font-zoom + ui-scale prefs.
    /// Was a fixed 22 pt; that's the baseline (zoom 1.0 × uiScale 1.0).
    private var rowHeight: CGFloat { 22 * model.zoom * model.uiScale }
    private var cellFontSize: CGFloat { 11 * model.zoom * model.uiScale }
    private var headerFontSize: CGFloat { 11 * model.zoom * model.uiScale }

    @ViewBuilder
    private func filterBar(result: CSVParser.Result, filteredCount: Int) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .font(.system(size: cellFontSize))
            TextField("Filter rows…", text: globalQuery)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .frame(maxWidth: 280)
                .accessibilityIdentifier("mdv.csvFilter.global")

            Menu {
                Button("All columns") { setGlobalScope(nil) }
                ForEach(Array(result.header.enumerated()), id: \.offset) { (i, name) in
                    Button(name.isEmpty ? "Column \(i + 1)" : name) {
                        setGlobalScope(i)
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(scopeLabel(result: result))
                        .font(.system(size: cellFontSize))
                    Image(systemName: "chevron.down")
                        .font(.system(size: cellFontSize * 0.82))
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .accessibilityIdentifier("mdv.csvFilter.scope")

            Button {
                setAdvancedShown(!advancedShown)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: advancedShown
                          ? "chevron.down.square" : "chevron.right.square")
                    Text("Per-column")
                }
                .font(.system(size: cellFontSize))
            }
            .buttonStyle(.borderless)
            .help("Show per-column filter row (supports >, <, >=, <=, =, !=)")

            Spacer()

            if !currentFilter.isEmpty {
                Button {
                    model.setCsvFilterState(DocumentModel.CSVFilterState(),
                                            forTabID: tabID)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.borderless)
                .help("Clear all filters")
                .accessibilityIdentifier("mdv.csvFilter.clear")
            }

            Text(rowCountLabel(total: result.rows.count, shown: filteredCount))
                .font(.system(size: cellFontSize, design: .monospaced))
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("mdv.csvFilter.count")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Palette.controlBackground)
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
                        var map = perColumn
                        if newValue.isEmpty {
                            map.removeValue(forKey: i)
                        } else {
                            map[i] = newValue
                        }
                        setPerColumn(map)
                    }
                ))
                .textFieldStyle(.plain)
                .controlSize(.small)
                .font(.system(size: cellFontSize, design: .monospaced))
                .padding(.horizontal, 6)
                .frame(width: widthFor(i), height: rowHeight, alignment: .leading)
                .background(Palette.windowBackground)
                .overlay(alignment: .trailing) {
                    Rectangle().fill(Palette.separator).frame(width: 0.5)
                }
                .accessibilityIdentifier("mdv.csvFilter.col\(i)")
            }
        }
        .overlay(alignment: .bottom) {
            Rectangle().fill(Palette.separator).frame(height: 0.5)
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
                    .font(.system(size: headerFontSize, weight: .semibold, design: .monospaced))
                    .padding(.horizontal, 8)
                    .frame(width: widthFor(i), height: rowHeight, alignment: .topLeading)
                    .background(Palette.controlBackground)
                    .overlay(alignment: .trailing) { columnResizer(forIndex: i) }
            }
        }
        .overlay(alignment: .bottom) {
            Rectangle().fill(Palette.separator).frame(height: 0.5)
        }
    }

    @ViewBuilder
    private func cellRow(_ row: [String], isAlt: Bool) -> some View {
        HStack(spacing: 0) {
            ForEach(row.indices, id: \.self) { i in
                let cell = row[i]
                Text(cell)
                    .font(.system(size: cellFontSize, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.horizontal, 8)
                    .frame(width: widthFor(i), height: rowHeight, alignment: .topLeading)
                    .overlay(alignment: .trailing) {
                        Rectangle().fill(Palette.separator).frame(width: 0.5)
                    }
                    .contextMenu {
                        Button("Copy Cell") { Pasteboard.copy(cell) }
                    }
            }
        }
        .background(isAlt ? Palette.controlBackground.opacity(0.3) : Color.clear)
        .textSelection(.enabled)
    }

    private func columnResizer(forIndex i: Int) -> some View {
        Rectangle()
            .fill(Palette.separator)
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
