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

    // TSK-1019: in-place cell editing, wired to the host-tested
    // `EditableCSVModel`. Ships DARK behind `CSVEditingGate` (default OFF) —
    // when the gate is off, NONE of this state is populated and the read-only
    // Text path below is rendered verbatim (zero behaviour change). When the
    // gate is on, a double-click on a cell begins editing; the editing cell
    // swaps its read-only `Text` for an inline `TextField` whose `onCommit`
    // folds the new value into `editModel`.
    //
    // `editModel` is built ONLY when the gate is on (see `reparse()`), so a
    // gate-off run pays nothing — no extra grid copy, no overlay map.
    @State private var editModel: EditableCSVModel?
    /// The cell currently being edited (FULL-grid coords: header is row 0,
    /// body rows are `1...`), or nil when not editing.
    @State private var editingCell: EditableCSVModel.Cell?
    /// Live buffer for the inline `TextField` while a cell is being edited.
    @State private var editingText: String = ""
    // TSK-925: click a column header to sort by it (toggles asc/desc; a third
    // click is just another toggle). nil = original file order.
    @State private var sortColumn: Int?
    @State private var sortAscending: Bool = true

    // TSK-303: find-in-table. Find is DISTINCT from the row FILTER above —
    // filter REMOVES non-matching rows; find KEEPS every row and highlights
    // matching CELLS, stepping a cursor through them (prev/next). State is
    // view-local @State (not on DocumentModel): find is an ephemeral,
    // per-view-instance interaction (no need to survive a tab switch), so we
    // keep it self-contained rather than threading new per-tab model storage.
    @State private var findVisible: Bool = false
    @State private var findQuery: String = ""
    /// Cursor into `findMatches` — nil = nothing selected yet. Drives which
    /// match gets the strong "current" highlight + the scroll target.
    @State private var findCurrent: Int?
    /// Cached match list, recomputed (debounced) when the query or the
    /// displayed rows change. Coordinates index the DISPLAYED rows.
    @State private var findMatches: [CSVFind.Match] = []
    @State private var findDebounceTask: Task<Void, Never>?
    @FocusState private var findFieldFocused: Bool

    // TSK-1102: keyboard cell cursor for the default browse state. Stored as
    // plain row/col Ints and rebuilt into a clamped `CSVCellCursor` per keypress
    // so it tracks the dynamically filtered/sorted `displayRows`. Active only
    // when not editing and not finding (those own the keyboard); the focus ring
    // shows only while the grid is focused. ⌘C copies the focused cell.
    @State private var cursorRow = 0
    @State private var cursorCol = 0
    @FocusState private var gridFocused: Bool

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
    /// TSK-925: header click → sort by that column (toggles asc/desc on the
    /// active one). Pure transition in `CsvSort.nextState`.
    private func toggleSort(column: Int) {
        let next = CsvSort.nextState(
            current: sortColumn.map { ($0, sortAscending) }, tapped: column)
        sortColumn = next.column
        sortAscending = next.ascending
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
        // TSK-925: apply the active column sort to the (already-filtered) rows.
        let displayRows: [[String]] = sortColumn.map {
            CsvSort.sorted(rows: filtered.rows, column: $0, ascending: sortAscending)
        } ?? filtered.rows
        VStack(spacing: 0) {
            filterBar(result: result, filteredCount: filtered.rows.count)
            if findVisible {
                Divider()
                findBar(header: result.header)
            }
            Divider()
            // Single shared horizontal+vertical ScrollView so the
            // per-column filter row, header, and data rows all share
            // the same x-origin and scroll together horizontally.
            // LazyVStack virtualizes the vertical axis even inside a
            // 2-axis ScrollView — only ~30 visible rows live at any
            // time. ForEach uses Int range directly rather than
            // Array(rows.enumerated()), which allocated a fresh
            // tuple-array on every body re-eval.
            //
            // TSK-303: ScrollViewReader so the find cursor can scroll the
            // current match's row into view. Each data row is `.id`'d by its
            // display index; jumping calls `proxy.scrollTo(rowIndex)`.
            ScrollViewReader { proxy in
                ScrollView([.horizontal, .vertical]) {
                    LazyVStack(alignment: .leading, spacing: 0,
                               pinnedViews: [.sectionHeaders]) {
                        if advancedShown {
                            perColumnRow(result: result)
                        }
                        Section {
                            ForEach(displayRows.indices, id: \.self) { i in
                                cellRow(displayRows[i], isAlt: i % 2 == 1,
                                        header: result.header, allRows: displayRows,
                                        rowIndex: i)
                                    .id(i)
                            }
                        } header: {
                            headerRow(result)
                        }
                    }
                }
                .onChange(of: findCurrent) { _, _ in
                    scrollToCurrentMatch(proxy)
                }
                // TSK-1102: keyboard cell cursor — arrows move the focused cell,
                // ⌘C copies it. Active only in the default browse state (not while
                // editing a cell or in find), so it never steals those keys.
                .focusable()
                .focused($gridFocused)
                .onKeyPress { press in
                    guard editingCell == nil, !findVisible else { return .ignored }
                    let rowCount = displayRows.count
                    let colCount = result.header.count
                    guard rowCount > 0, colCount > 0 else { return .ignored }
                    var cur = CSVCellCursor(
                        rowCount: rowCount, columnCount: colCount,
                        row: cursorRow, column: cursorCol)
                    switch press.key {
                    case .upArrow:    cur.moveUp()
                    case .downArrow:  cur.moveDown()
                    case .leftArrow:  cur.moveLeft()
                    case .rightArrow: cur.moveRight()
                    default:
                        if press.key == KeyEquivalent("c"),
                           press.modifiers.contains(.command) {
                            if let text = cur.copyText(from: displayRows) {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(text, forType: .string)
                            }
                            return .handled
                        }
                        return .ignored
                    }
                    cursorRow = cur.row
                    cursorCol = cur.column
                    proxy.scrollTo(cur.row)
                    return .handled
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
        // TSK-303: recompute matches when the query, the displayed rows
        // (filter/sort change), or the underlying parse change. Search the
        // DISPLAYED rows so coordinates map to on-screen cells.
        .onChange(of: findQuery) { _, _ in
            scheduleFindCommit(header: result.header, rows: displayRows)
        }
        .onChange(of: displayRows) { _, newRows in
            recomputeFind(header: result.header, rows: newRows)
        }
        .accessibilityIdentifier("mdv.csvTable")
    }

    /// Toggle the find bar (Cmd-F-style entry point — wired to a button in the
    /// filter bar). Showing it focuses the field; hiding it clears the query so
    /// highlights disappear and the next open starts clean.
    private func toggleFind() {
        if findVisible {
            closeFind()
        } else {
            findVisible = true
            findFieldFocused = true
        }
    }

    private func closeFind() {
        findVisible = false
        findQuery = ""
        findMatches = []
        findCurrent = nil
        findDebounceTask?.cancel()
        findDebounceTask = nil
    }

    /// 150 ms debounce on find recompute — keystrokes stay responsive while
    /// the O(cells) sweep runs only after the user pauses. An empty query
    /// commits immediately so clearing the field feels instant.
    private func scheduleFindCommit(header: [String], rows: [[String]]) {
        findDebounceTask?.cancel()
        if findQuery.isEmpty {
            recomputeFind(header: header, rows: rows)
            findDebounceTask = nil
            return
        }
        findDebounceTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 150_000_000)
            if Task.isCancelled { return }
            recomputeFind(header: header, rows: rows)
        }
    }

    /// Re-run the matcher over the DISPLAYED rows and reset the cursor to the
    /// first match (or nil when there are none). Keeping the cursor pinned to
    /// "first" on every recompute is the conventional find-bar behavior: a new
    /// query starts you at the top of its results.
    private func recomputeFind(header: [String], rows: [[String]]) {
        let finder = CSVFind(query: findQuery)
        findMatches = finder.matches(header: header, rows: rows)
        findCurrent = findMatches.isEmpty ? nil : 0
    }

    private func findStep(forward: Bool) {
        findCurrent = CSVFind.step(count: findMatches.count,
                                   from: findCurrent, forward: forward)
    }

    /// Scroll the row owning the current match into view. Header matches
    /// (`row == headerRow`) need no scroll — the header is pinned.
    private func scrollToCurrentMatch(_ proxy: ScrollViewProxy) {
        guard let cur = findCurrent, findMatches.indices.contains(cur) else { return }
        let match = findMatches[cur]
        guard match.row != CSVFind.headerRow else { return }
        withAnimation(.easeInOut(duration: 0.12)) {
            proxy.scrollTo(match.row, anchor: .center)
        }
    }

    /// Per-cell find verdict — thin lookup over `CSVFind.highlight`. `row`
    /// uses display indices; pass `CSVFind.headerRow` for header cells.
    private func findHighlight(row: Int, column: Int) -> CSVFind.Highlight {
        CSVFind.highlight(row: row, column: column,
                          matches: findMatches, current: findCurrent)
    }

    /// SwiftUI fill for a find highlight state, or nil for `.none`. Reuses the
    /// shared find-highlight palette so CSV find reads like the editor/source
    /// find highlights.
    private func findHighlightColor(_ state: CSVFind.Highlight) -> Color? {
        switch state {
        case .none: return nil
        case .match: return Color(nsColor: Palette.findHighlightInactive)
        case .current: return Color(nsColor: Palette.findHighlightCurrent)
        }
    }

    // MARK: - TSK-1019: in-place cell editing

    /// Is editing offered for the CURRENTLY-DISPLAYED grid? Editing is allowed
    /// ONLY when the file is shown in its on-disk order — `sortColumn == nil`
    /// AND no active filter — because an edit addresses the FULL grid by row,
    /// so the displayed row index must map 1:1 to the grid row (display index
    /// `i` ⇒ grid row `i + 1`, with the header as row 0). A sort or filter
    /// reorders/removes rows, breaking that mapping; rather than maintain a
    /// reverse index (a later slice), editing simply isn't offered until the
    /// view is back in file order. The pure decision lives in the static
    /// `editingAvailable(...)` so the host gate can pin it without a window.
    private var editingAvailable: Bool {
        Self.editingAvailable(
            gateEnabled: CSVEditingGate.isEnabled(),
            sortColumn: sortColumn,
            filterIsEmpty: debouncedFilter.isEmpty
        )
    }

    /// Pure gating decision (no UI state): editing is on iff the gate is on
    /// AND the grid is in file order (no sort, no filter). `internal static`
    /// so `CSVEditingWiringTests` can exercise every branch host-side.
    static func editingAvailable(gateEnabled: Bool,
                                 sortColumn: Int?,
                                 filterIsEmpty: Bool) -> Bool {
        gateEnabled && sortColumn == nil && filterIsEmpty
    }

    /// Map a DISPLAYED-row index to its FULL-grid row. Row 0 of the grid is the
    /// header, so the first displayed body row (`displayIndex == 0`) is grid
    /// row 1. Only meaningful when `editingAvailable` holds (file order). Pure
    /// + `internal static` for the host gate.
    static func gridRow(forDisplayIndex displayIndex: Int) -> Int {
        displayIndex + 1
    }

    /// Begin editing the cell at displayed `(rowIndex, column)` — seeds the
    /// inline `TextField` with the cell's CURRENT value (overlay if already
    /// edited, else base) and marks it as the active editing cell. No-op when
    /// editing isn't available or the model isn't built.
    private func beginEditing(rowIndex: Int, column: Int) {
        guard editingAvailable, let model = editModel else { return }
        let gridR = Self.gridRow(forDisplayIndex: rowIndex)
        editingText = model.getCell(row: gridR, column: column) ?? ""
        editingCell = EditableCSVModel.Cell(row: gridR, column: column)
    }

    /// Commit the in-progress edit into `editModel` and end editing. Folds the
    /// `editingText` buffer into the model via `setCell` (a no-op write — same
    /// value — is dropped by the model's coalescing). Clears `editingCell`
    /// regardless so the inline field always closes on commit.
    private func commitEditing() {
        defer { editingCell = nil }
        guard let cell = editingCell, editModel != nil else { return }
        editModel?.setCell(row: cell.row, column: cell.column, to: editingText)
    }

    /// Cancel the in-progress edit WITHOUT writing — drops the buffer and
    /// closes the inline field, leaving the model untouched.
    private func cancelEditing() {
        editingCell = nil
    }

    /// `true` when `(rowIndex, column)` (display coords) is the cell currently
    /// being edited. Used by `cellRow` to swap in the inline `TextField`.
    private func isEditingCell(rowIndex: Int, column: Int) -> Bool {
        guard let cell = editingCell else { return false }
        return cell.row == Self.gridRow(forDisplayIndex: rowIndex)
            && cell.column == column
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
        // Routed parse: Rust core when RustCSVGate is on (UserDefaults toggle
        // or MDV_RUST_CSV=1), else the incumbent Swift CSVParser. The adapter
        // is fail-safe — a Rust bridge fault falls back to Swift, so a CSV view
        // never goes blank because the experimental engine hiccuped.
        let result = RustCSVAdapter.parse(text)
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
        // TSK-1019: build the editable model ONLY when the edit gate is on, so
        // a gate-off run pays nothing (no extra grid copy / overlay map). Any
        // in-progress edit is abandoned across a re-parse (the underlying text
        // changed out from under it). Drop the model entirely when the gate is
        // off so we never carry stale editable state into a read-only run.
        if CSVEditingGate.isEnabled() {
            editModel = EditableCSVModel(result)
        } else {
            editModel = nil
        }
        editingCell = nil
        // After re-parse, drop stale per-column entries (file shape
        // may have changed) and stale scope picks.
        let cols = result.header.count
        let pruned = perColumn.filter { $0.key < cols }
        if pruned != perColumn { setPerColumn(pruned) }
        if let s = globalScope, s >= cols { setGlobalScope(nil) }
    }

    /// Row height scales with the user's unified zoom pref. Was a
    /// fixed 22 pt; that's the baseline (zoom 1.0). Previously also
    /// multiplied by a separate `uiScale`; that knob was collapsed
    /// onto `zoom` so a single slider drives both content + chrome.
    private var rowHeight: CGFloat { 22 * model.zoom }
    private var cellFontSize: CGFloat { 11 * model.zoom }
    private var headerFontSize: CGFloat { 11 * model.zoom }

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
            .helpInfo(title: "Per-column filter",
                      description: "Show the per-column filter row (supports >, <, >=, <=, =, !=)")

            // TSK-303: open/close the find bar. Distinct from the row filter:
            // find highlights matching cells and steps through them.
            Button {
                toggleFind()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "text.magnifyingglass")
                    Text("Find")
                }
                .font(.system(size: cellFontSize))
            }
            .buttonStyle(.borderless)
            .keyboardShortcut("f", modifiers: [.command])
            .helpInfo(title: "Find in table",
                      description: "Highlight matching cells and step through them (Cmd-F)")
            .accessibilityIdentifier("mdv.csvFind.toggle")

            Spacer()

            if !currentFilter.isEmpty {
                Button {
                    model.setCsvFilterState(DocumentModel.CSVFilterState(),
                                            forTabID: tabID)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.borderless)
                .helpInfo(title: "Clear filters", description: "Remove all column filters")
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

    /// TSK-303: find-in-table bar. Query field + "n of N" / "No results" count
    /// + prev/next stepper + Done. Mirrors the native find-bar layout used by
    /// the rendered/source/editor `FindBar` (we don't reuse that view because
    /// it's bound to `FindCoordinator`; this is the lightweight grid variant).
    @ViewBuilder
    private func findBar(header: [String]) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "text.magnifyingglass")
                .foregroundStyle(.secondary)
                .font(.system(size: cellFontSize))

            TextField("Find in table…", text: $findQuery)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .frame(maxWidth: 280)
                .focused($findFieldFocused)
                .onSubmit { findStep(forward: true) }
                .accessibilityIdentifier("mdv.csvFind.field")

            Text(findCountLabel)
                .font(.system(size: cellFontSize, design: .monospaced))
                .foregroundStyle(findMatches.isEmpty && !findQuery.isEmpty
                                 ? Color(nsColor: .systemOrange) : .secondary)
                .accessibilityIdentifier("mdv.csvFind.count")

            HStack(spacing: 0) {
                Button { findStep(forward: false) } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: cellFontSize, weight: .semibold))
                        .frame(minWidth: 22)
                }
                .keyboardShortcut(.return, modifiers: [.shift])
                .helpInfo(title: "Previous match",
                          description: "Jump to the previous match (Shift+Return)")
                .accessibilityIdentifier("mdv.csvFind.prev")

                Divider().frame(height: 14)

                Button { findStep(forward: true) } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: cellFontSize, weight: .semibold))
                        .frame(minWidth: 22)
                }
                .helpInfo(title: "Next match",
                          description: "Jump to the next match (Return)")
                .accessibilityIdentifier("mdv.csvFind.next")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(findMatches.isEmpty)

            Spacer()

            Button("Done") { closeFind() }
                .controlSize(.small)
                .keyboardShortcut(.escape, modifiers: [])
                .helpInfo(title: "Done", description: "Close the find bar (Esc)")
                .accessibilityIdentifier("mdv.csvFind.done")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Palette.controlBackground)
    }

    /// "n of N" when a match is selected, "N matches" before stepping, "No
    /// results" for a non-empty query with no hits, empty for an empty query.
    /// `internal` so `CSVFindLabelTests` can pin the pure label math.
    static func findCountLabel(matchCount: Int, current: Int?, query: String) -> String {
        if query.isEmpty { return "" }
        if matchCount == 0 { return "No results" }
        if let cur = current, cur >= 0, cur < matchCount {
            return "\(cur + 1) of \(matchCount)"
        }
        return matchCount == 1 ? "1 match" : "\(matchCount) matches"
    }

    private var findCountLabel: String {
        Self.findCountLabel(matchCount: findMatches.count,
                            current: findCurrent, query: findQuery)
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
                HStack(spacing: 2) {
                    Text(name)
                        .font(.system(size: headerFontSize, weight: .semibold, design: .monospaced))
                    if sortColumn == i {
                        // TSK-925: sort-direction indicator on the active column.
                        Image(systemName: sortAscending ? "chevron.up" : "chevron.down")
                            .font(.system(size: headerFontSize - 2, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                }
                    .padding(.horizontal, 8)
                    .frame(width: widthFor(i), height: rowHeight, alignment: .topLeading)
                    .background(Palette.controlBackground)
                    // TSK-303: find highlight overlays the opaque header
                    // background (translucent wash, so the title stays legible).
                    .overlay {
                        if let c = findHighlightColor(
                            findHighlight(row: CSVFind.headerRow, column: i)) {
                            c
                        }
                    }
                    .contentShape(Rectangle())
                    // TSK-925: click toggles sort by this column (asc → desc → asc).
                    .onTapGesture { toggleSort(column: i) }
                    .overlay(alignment: .trailing) { columnResizer(forIndex: i) }
                    // A11Y-01: mark header cells with the header trait so
                    // VoiceOver's table navigation announces column titles.
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityLabel(Self.columnName(name, index: i))
            }
        }
        .overlay(alignment: .bottom) {
            Rectangle().fill(Palette.separator).frame(height: 0.5)
        }
    }

    @ViewBuilder
    private func cellRow(_ row: [String], isAlt: Bool, header: [String],
                         allRows: [[String]], rowIndex: Int) -> some View {
        HStack(spacing: 0) {
            ForEach(row.indices, id: \.self) { i in
                cell(value: row[i], row: row, allRows: allRows,
                     header: header, rowIndex: rowIndex, column: i)
            }
        }
        .background(isAlt ? Palette.controlBackground.opacity(0.3) : Color.clear)
        .textSelection(.enabled)
        // A11Y-01: group the cells under a single row container so the
        // grid reads as rows-of-cells in VoiceOver's table rotor.
        .accessibilityElement(children: .contain)
    }

    /// A single data cell. When this exact cell is being edited (gate on,
    /// double-clicked, file order) it renders an inline `TextField`; otherwise
    /// it renders the read-only `Text` path UNCHANGED — same find highlight
    /// (TSK-303), Copy Cell/Row/Column context menu (TSK-924), and per-cell
    /// VoiceOver label (A11Y-01) as before. A double-click begins editing only
    /// when `editingAvailable`; with the gate off it's a no-op overlay (the
    /// read-only behaviour is byte-identical to pre-TSK-1019).
    @ViewBuilder
    private func cell(value: String, row: [String], allRows: [[String]],
                      header: [String], rowIndex: Int, column i: Int) -> some View {
        if isEditingCell(rowIndex: rowIndex, column: i) {
            // TSK-1019: inline editor for the active cell. onCommit/onSubmit
            // folds the buffer into the model; Esc cancels without writing.
            TextField("", text: $editingText, onCommit: { commitEditing() })
                .textFieldStyle(.plain)
                .font(.system(size: cellFontSize, design: .monospaced))
                .padding(.horizontal, 8)
                .frame(width: widthFor(i), height: rowHeight, alignment: .topLeading)
                .background(Palette.windowBackground)
                .overlay(alignment: .trailing) {
                    Rectangle().fill(Palette.separator).frame(width: 0.5)
                }
                .onExitCommand { cancelEditing() }
                .accessibilityIdentifier("mdv.csvCell.edit.\(rowIndex).\(i)")
        } else {
            readOnlyCell(value: value, row: row, allRows: allRows,
                         header: header, rowIndex: rowIndex, column: i)
        }
    }

    /// The read-only data cell. When editing is NOT available (the gate is OFF,
    /// or the grid is sorted/filtered) this is BYTE-IDENTICAL to the
    /// pre-TSK-1019 render — no extra gesture is attached, so single-click
    /// selection / Copy menu / find behave exactly as before. When editing IS
    /// available, a double-click recognizer is layered on to begin editing.
    @ViewBuilder
    private func readOnlyCell(value cell: String, row: [String], allRows: [[String]],
                              header: [String], rowIndex: Int, column i: Int) -> some View {
        Text(cell)
            .font(.system(size: cellFontSize, design: .monospaced))
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.horizontal, 8)
            .frame(width: widthFor(i), height: rowHeight, alignment: .topLeading)
            // TSK-303: per-cell find highlight (display-row coords).
            .background(findHighlightColor(findHighlight(row: rowIndex, column: i))
                        ?? Color.clear)
            .overlay(alignment: .trailing) {
                Rectangle().fill(Palette.separator).frame(width: 0.5)
            }
            // TSK-1102: focus ring on the keyboard-cursor cell, shown only while
            // the grid is focused (the browse-state cell cursor).
            .overlay {
                if gridFocused, rowIndex == cursorRow, i == cursorCol {
                    Rectangle().strokeBorder(Color.accentColor, lineWidth: 2)
                }
            }
            // TSK-1019: attach double-click-to-edit ONLY when editing is
            // available, so the gate-off path keeps the exact original gesture
            // surface (no recognizer competing with text selection).
            .modifier(DoubleClickToEdit(enabled: editingAvailable) {
                beginEditing(rowIndex: rowIndex, column: i)
            })
            .contextMenu {
                Button("Copy Cell") { Pasteboard.copy(cell) }
                // TSK-924: multi-cell copy — the whole row (TSV) or the
                // whole column (newline-joined), pasteable into a sheet.
                Button("Copy Row") { Pasteboard.copy(CSVCopy.rowTSV(row)) }
                Button("Copy Column") { Pasteboard.copy(CSVCopy.columnText(i, in: allRows)) }
            }
            // A11Y-01: per-cell VoiceOver label "<column>: <value>"
            // so each cell announces which column it belongs to
            // rather than reading a bare value out of context.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Self.cellLabel(column: i, header: header, value: cell))
    }

    /// Column title for VoiceOver — falls back to "Column N" for blank
    /// header cells, matching the visible scope-picker label. `internal
    /// static` so `CSVAccessibilityLabelTests` can exercise the pure
    /// label math without a window.
    static func columnName(_ name: String, index: Int) -> String {
        name.isEmpty ? "Column \(index + 1)" : name
    }

    /// "<column>: <value>" per-cell accessibility label. Tolerates a
    /// ragged row (more cells than header columns) by falling back to
    /// the positional "Column N" name.
    static func cellLabel(column: Int, header: [String], value: String) -> String {
        let name = column < header.count ? columnName(header[column], index: column)
                                         : "Column \(column + 1)"
        return "\(name): \(value)"
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

/// TSK-1019: conditionally layer a double-click recognizer onto a cell. When
/// `enabled` is false the view is returned untouched (no `simultaneousGesture`,
/// no `onTapGesture`) so the gate-off read-only path keeps its EXACT original
/// gesture surface — single-click selection and the context menu are unchanged.
/// `simultaneousGesture` (rather than `onTapGesture`) so the double-click
/// coexists with the cell's `textSelection`/copy affordances when editing is on.
private struct DoubleClickToEdit: ViewModifier {
    let enabled: Bool
    let action: () -> Void

    func body(content: Content) -> some View {
        if enabled {
            content.simultaneousGesture(
                TapGesture(count: 2).onEnded { action() }
            )
        } else {
            content
        }
    }
}
