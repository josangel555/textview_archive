import AppKit
import SwiftUI
import ViewerCore
import ViewerKit

/// Read-only SQLite browser. Three panes: schema sidebar (tables /
/// views / indexes / triggers), SQL editor + results panel, schema
/// inspector for the selected table. Wraps `SQLiteReader`.
///
/// The whole thing is read-only by construction — `SQLiteReader`
/// opens with `SQLITE_OPEN_READONLY` so attempts to INSERT/UPDATE
/// fail at the SQLite level, not at the UI level.
public struct SQLiteBrowserView: View {
    public let url: URL
    /// Unified zoom multiplier (`DocumentModel.zoom`, 1.0 = default).
    /// Every font/row/size literal below is multiplied by this so the
    /// browser tracks the same Cmd++/Cmd+− / Settings slider as the rest
    /// of the app — matching CSVTableView's `model.zoom` scaling.
    public let uiScale: CGFloat
    @StateObject private var model: SQLiteBrowserModel

    public init(url: URL, uiScale: CGFloat = 1.0) {
        self.url = url
        self.uiScale = uiScale
        self._model = StateObject(wrappedValue: SQLiteBrowserModel(url: url))
    }

    public var body: some View {
        Group {
            if let err = model.openError {
                errorView(err)
            } else {
                HSplitView {
                    sidebar
                        .frame(minWidth: 180, idealWidth: 220, maxWidth: 320)
                    rightPane
                        .frame(minWidth: 360)
                }
            }
        }
        .onAppear { model.load() }
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle")
                .resizable().scaledToFit().frame(width: 44, height: 44)
                .foregroundStyle(.secondary)
            Text("Couldn't open database")
            Text(message)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            Text(url.path)
                .font(.caption2.monospaced())
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var sidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                schemaGroup("Tables",   items: model.tables,   icon: "tablecells")
                schemaGroup("Views",    items: model.views,    icon: "rectangle.stack")
                schemaGroup("Indexes",  items: model.indexes,  icon: "list.number")
                schemaGroup("Triggers", items: model.triggers, icon: "bolt.horizontal")
            }
            .padding(.vertical, 4)
        }
        .background(Palette.textBackground)
    }

    @ViewBuilder
    private func schemaGroup(_ title: String, items: [String], icon: String) -> some View {
        if !items.isEmpty {
            Text(title.uppercased())
                .font(.system(size: 10 * uiScale, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.top, 8)
                .padding(.bottom, 2)
            ForEach(items, id: \.self) { name in
                Button(action: { model.select(name: name) }) {
                    HStack(spacing: 6) {
                        Image(systemName: icon)
                            .font(.system(size: 10 * uiScale))
                            .foregroundStyle(.secondary)
                            .frame(width: 14 * uiScale)
                        Text(name)
                            .font(.system(size: 12 * uiScale, weight: model.selectedName == name ? .semibold : .regular))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 22 * uiScale)
                    .contentShape(Rectangle())
                    .background(model.selectedName == name
                        ? Color.accentColor.opacity(0.20)
                        : Color.clear)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var rightPane: some View {
        VStack(spacing: 0) {
            queryEditor
            Divider()
            resultsArea
        }
    }

    private var queryEditor: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Query")
                    .font(.system(size: 11 * uiScale, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                // SQL-01/SQL-03: while a query runs off-main, swap Run
                // for a Cancel button so a runaway query (cross join,
                // recursive CTE) can be interrupted instead of freezing
                // the UI. `model.cancelQuery()` flips the reader's
                // cancel flag → SQLITE_INTERRUPT on the next step.
                // TSK-1439: export the current result grid (CSV / Markdown /
                // JSON) — copy to clipboard or save to a file. Disabled until a
                // query has produced a result. Reuses `SQLiteResultExport` +
                // `CsvConvert` so the browser, CSV viewer, and future grids share
                // one serializer.
                exportMenu
                if model.isRunning {
                    ProgressView()
                        .controlSize(.small)
                        .padding(.trailing, 4)
                    Button("Cancel") { model.cancelQuery() }
                        .keyboardShortcut(".", modifiers: [.command])
                } else {
                    Button("Run") { model.runQuery() }
                        .keyboardShortcut(.return, modifiers: [.command])
                        .disabled(model.query.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            TextEditor(text: $model.query)
                .font(.system(size: 12 * uiScale, design: .monospaced))
                .frame(height: 110 * uiScale)
                .padding(.horizontal, 4)
        }
        .background(Palette.windowBackground)
    }

    /// TSK-1439: Export ▾ menu — copy the result grid to the clipboard in any of
    /// the three formats, or save it to a file. Disabled until a query has run.
    private var exportMenu: some View {
        Menu {
            ForEach(SQLiteResultExport.Format.allCases, id: \.self) { format in
                Button("Copy as \(format.menuLabel)") { model.copyResult(format) }
            }
            Divider()
            ForEach(SQLiteResultExport.Format.allCases, id: \.self) { format in
                Button("Save as \(format.menuLabel)…") { saveResult(format) }
            }
        } label: {
            Label("Export", systemImage: "square.and.arrow.up")
                .font(.system(size: 11 * uiScale))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(!model.canExport)
        .help("Export the query result as CSV, a Markdown table, or JSON")
        .accessibilityIdentifier("mdv.sqlite.export")
    }

    /// Present a save panel and write the serialized result. Save-panel plumbing
    /// is UI-only (VM/UAT lane); the serialization it writes is the host-tested
    /// `model.exportedText(_:)`.
    private func saveResult(_ format: SQLiteResultExport.Format) {
        guard let text = model.exportedText(format) else {
            ToastCenter.shared.postError("Nothing to export", reason: "Run a query first.")
            return
        }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(url.deletingPathExtension().lastPathComponent)-export.\(format.fileExtension)"
        panel.canCreateDirectories = true
        panel.begin { response in
            guard response == .OK, let dest = panel.url else { return }
            do {
                try text.write(to: dest, atomically: true, encoding: .utf8)
                ToastCenter.shared.post(.success, "Saved \(dest.lastPathComponent)")
            } catch {
                ToastCenter.shared.postError("Couldn't save export", reason: "\(error.localizedDescription)")
            }
        }
    }

    @ViewBuilder
    private var resultsArea: some View {
        if model.isRunning {
            // SQL-01/SQL-03: explicit loading state while the query runs
            // off the main actor. Keeps the UI responsive (and the
            // Cancel button live) instead of a synchronous freeze.
            VStack(spacing: 10) {
                ProgressView()
                Text("Running query…")
                    .font(.system(size: 11 * uiScale))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let err = model.queryError {
            VStack(spacing: 8) {
                Text("Query error")
                    .font(.system(size: 12 * uiScale, weight: .semibold))
                    .foregroundStyle(.red)
                Text(err)
                    .font(.system(size: 11 * uiScale, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 20)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let result = model.queryResult {
            ResultTableView(result: result, uiScale: uiScale)
        } else {
            // TSK-1435: purposeful empty state (what this tool is + both ways
            // to get a first result) instead of the bare hint line.
            HostedEmptyStateView(EmptyStateCatalog.sqliteBrowser)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// Internal (not file-private) so host tests can drive `exportedText(_:)` and the
// select/seed behavior directly (TSK-1439). Still a view-owned model — nothing
// outside this file constructs it in the app.
@MainActor
final class SQLiteBrowserModel: ObservableObject {
    let url: URL
    @Published var openError: String?
    @Published var tables: [String] = []
    @Published var views: [String] = []
    @Published var indexes: [String] = []
    @Published var triggers: [String] = []
    @Published var selectedName: String?
    @Published var query: String = ""
    @Published var queryResult: SQLiteReader.QueryResult?
    @Published var queryError: String?
    /// SQL-01: true while a query runs on `dbQueue`. Drives the
    /// loading state + Cancel button.
    @Published var isRunning: Bool = false

    /// SQL-01/PARSE-02: the connection is confined to a dedicated
    /// serial queue and NEVER touched from `@MainActor`. `SQLiteReader`
    /// isn't `Sendable`, so we only ever read/query it from `dbQueue`;
    /// `cancel()` is the one method that's lock-safe to call from main.
    /// `nonisolated(unsafe)` is sound here precisely because every
    /// access except the thread-safe `cancel()` is serialized on
    /// `dbQueue`.
    nonisolated(unsafe) private var reader: SQLiteReader?
    private let dbQueue = DispatchQueue(label: "SQLiteBrowser.db", qos: .userInitiated)
    /// Monotonic token so a result from a superseded/cancelled query
    /// can't clobber a newer one (user hits Run again before the old
    /// query is interrupted).
    private var runToken: UInt64 = 0

    init(url: URL) { self.url = url }

    func load() {
        dbQueue.async { [weak self] in
            guard let self else { return }
            do {
                let r = try SQLiteReader(url: self.url)
                // Let a post-open enumeration failure THROW into the catch
                // below rather than collapsing to `[]`. The old
                // `(try? …) ?? []` hid a DB that OPENS but can't enumerate
                // its schema (corrupt sqlite_master, a locked/contended
                // file, a malformed-but-openable header): the user got an
                // empty browser with zero signal, indistinguishable from a
                // genuinely empty DB. Surface it as an open error instead.
                let tables   = try r.tableNames()
                let views    = try r.viewNames()
                let indexes  = try r.indexNames()
                let triggers = try r.triggerNames()
                self.reader = r
                Task { @MainActor in
                    self.tables = tables
                    self.views = views
                    self.indexes = indexes
                    self.triggers = triggers
                }
            } catch {
                let msg = "\(error)"
                Task { @MainActor in self.openError = msg }
            }
        }
    }

    func select(name: String) {
        selectedName = name
        // Bonus: seed the query editor with a sensible SELECT when
        // the user picks a table.
        if tables.contains(name) {
            let escaped = name.replacingOccurrences(of: "\"", with: "\"\"")
            query = "SELECT * FROM \"\(escaped)\" LIMIT 100;"
            runQuery()
        }
    }

    func runQuery() {
        queryError = nil
        runToken &+= 1
        let token = runToken
        let sql = query
        isRunning = true
        dbQueue.async { [weak self] in
            guard let self else { return }
            guard let reader = self.reader else {
                Task { @MainActor in self.isRunning = false }
                return
            }
            do {
                let result = try reader.query(sql)
                Task { @MainActor in
                    // Drop the result if a newer query has superseded
                    // this one.
                    guard token == self.runToken else { return }
                    self.queryResult = result
                    self.isRunning = false
                }
            } catch {
                let msg = "\(error)"
                Task { @MainActor in
                    guard token == self.runToken else { return }
                    self.queryResult = nil
                    self.queryError = msg
                    self.isRunning = false
                }
            }
        }
    }

    /// SQL-01: interrupt the in-flight query. The flag is observed by
    /// the reader's progress handler on its next poll, aborting the
    /// step loop with `SQLITE_INTERRUPT` (surfaced as a "Cancelled"
    /// error). Bumping `runToken` also makes a late result a no-op.
    func cancelQuery() {
        runToken &+= 1
        reader?.cancel()
    }

    // MARK: - Export (TSK-1439)

    /// True when there's a materialized result to export.
    var canExport: Bool { queryResult != nil }

    /// Serialize the current result in `format`, or nil when there's nothing to
    /// export. Pure delegation to `SQLiteResultExport` — the meaningful logic is
    /// host-tested there; this is the exact string an Export menu item copies.
    func exportedText(_ format: SQLiteResultExport.Format) -> String? {
        guard let result = queryResult else { return nil }
        return SQLiteResultExport.serialize(result, as: format)
    }

    /// Copy the current result to the pasteboard in `format` and post a toast.
    /// No-op (with an error toast) when there's no result. The pasteboard is
    /// injectable so the copy path is host-testable end-to-end.
    func copyResult(_ format: SQLiteResultExport.Format,
                    to pasteboard: NSPasteboard = .general) {
        guard let text = exportedText(format) else {
            ToastCenter.shared.postError("Nothing to export", reason: "Run a query first.")
            return
        }
        Pasteboard.copy(text, to: pasteboard)
        let rowCount = queryResult?.rows.count ?? 0
        ToastCenter.shared.post(.success,
            "Copied \(rowCount) row\(rowCount == 1 ? "" : "s") as \(format.menuLabel)")
    }
}

internal struct ResultTableView: View {
    let result: SQLiteReader.QueryResult
    /// Unified zoom multiplier (`DocumentModel.zoom`, 1.0 = default).
    /// Defaults to 1.0 so CSVTableView's reuse of the pure width helpers
    /// (which pass no scale) and any test constructing the view bare
    /// keep the original 1.0 metrics.
    var uiScale: CGFloat = 1.0

    /// Per-column widths (one entry per column index). Auto-sized at
    /// first render from header + sample of cell widths; user can drag
    /// the separator next to a column header to override.
    @State private var columnWidths: [CGFloat] = []
    /// Column-resize drag base — same fix as CSVTableView.columnDrag
    /// (the 2026-08-01 resize-lag class: moving-space + live-base drags).
    @State private var columnDrag: (index: Int, start: CGFloat)?
    /// Track the result identity so the widths re-compute when a new
    /// query lands (different column set).
    @State private var fingerprint: String = ""

    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            // LazyVStack virtualizes vertical row materialization even
            // inside a 2-axis ScrollView. SQLite query results capped
            // at 1K rows × N cols × ~5 Text views per cell = up to
            // 50K SwiftUI nodes if eager-VStack'd. Header pinned via
            // `Section`/`pinnedViews` stays visible while scrolling.
            LazyVStack(alignment: .leading, spacing: 0,
                       pinnedViews: [.sectionHeaders]) {
                Section {
                    ForEach(result.rows.indices, id: \.self) { i in
                        cellRow(result.rows[i], isAlt: i % 2 == 1)
                    }
                    if result.truncated {
                        Text("Output truncated at \(result.rows.count) rows.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .padding(8)
                    }
                } header: {
                    headerRow
                }
            }
            // Pin content to the top-left of the scroll area. Without
            // this the table sat centered when its content was narrower
            // than the viewport, which looked broken.
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear(perform: ensureWidths)
        .onChange(of: result.columns) { _, _ in recomputeWidths() }
        // TSK-604: fonts and row height read `uiScale` live, but the
        // widths are @State computed once — a zoom change while a table
        // is open grew the text into stale, clipping columns. Rescale
        // proportionally so user-dragged widths keep their ratio.
        .onChange(of: uiScale) { old, new in
            columnWidths = Self.rescaledWidths(columnWidths, from: old, to: new)
        }
    }

    /// Bump font height to a stable line height across header + cells
    /// (NSAttributedString's intrinsic height fluctuates with content;
    /// fixing it here keeps every row the same vertical size). Scales
    /// with `uiScale` to track the cell font growth.
    private var rowHeight: CGFloat { 22 * uiScale }

    private var headerRow: some View {
        HStack(spacing: 0) {
            ForEach(Array(result.columns.enumerated()), id: \.offset) { (i, name) in
                Text(name)
                    .font(.system(size: 11 * uiScale, weight: .semibold, design: .monospaced))
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

    /// SQL-03: hard cap on the characters we hand to a `Text` cell. A
    /// query like `SELECT zeroblob(50000000)` or a multi-MB JSON/TEXT
    /// column yields a single giant string; even with `lineLimit(1)`,
    /// SwiftUI/TextKit measures and stores the whole NSAttributedString
    /// per cell, which spikes memory + main-thread layout time. We only
    /// ever show one truncated line, so clamp the source string.
    private static let maxCellChars = 2_000

    private func displayText(_ cell: String?) -> String {
        guard let cell else { return "NULL" }
        if cell.count <= Self.maxCellChars { return cell }
        let head = cell.prefix(Self.maxCellChars)
        return "\(head)… (\(cell.count) chars)"
    }

    private func cellRow(_ row: [String?], isAlt: Bool) -> some View {
        HStack(spacing: 0) {
            ForEach(row.indices, id: \.self) { i in
                let cell = row[i]
                Text(displayText(cell))
                    .font(.system(size: 11 * uiScale, design: .monospaced))
                    .foregroundStyle(cell == nil ? .tertiary : .primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.horizontal, 8)
                    .frame(width: widthFor(i), height: rowHeight, alignment: .topLeading)
                    .overlay(alignment: .trailing) {
                        Rectangle().fill(Palette.separator)
                            .frame(width: 0.5)
                    }
            }
        }
        .background(isAlt ? Palette.controlBackground.opacity(0.3) : Color.clear)
        .textSelection(.enabled)
    }

    /// Draggable handle on the right edge of each header cell. The
    /// hit zone is wider than the visible 0.5-pt rule so it's actually
    /// catchable by the cursor.
    private func columnResizer(forIndex i: Int) -> some View {
        Rectangle()
            .fill(Palette.separator)
            .frame(width: 0.5)
            .overlay(
                Rectangle()
                    .fill(Color.clear)
                    .frame(width: 6)
                    .contentShape(Rectangle())
                    .resizePointer(vertical: false)   // 2026-08-22: off the leaky NSCursor stack
                    .gesture(
                        // .global + drag-start base (see the columnDrag doc).
                        DragGesture(minimumDistance: 0, coordinateSpace: .global)
                            .onChanged { value in
                                let start: CGFloat
                                if let d = columnDrag, d.index == i {
                                    start = d.start
                                } else {
                                    start = widthFor(i)
                                    columnDrag = (i, start)
                                }
                                if columnWidths.indices.contains(i) {
                                    columnWidths[i] = max(40 * uiScale, start + value.translation.width)
                                }
                            }
                            .onEnded { _ in columnDrag = nil }
                    )
            )
    }

    private func widthFor(_ i: Int) -> CGFloat {
        if columnWidths.indices.contains(i) { return columnWidths[i] }
        return 120 * uiScale
    }

    /// Compute widths from a sample of rows. Avoids touching every cell
    /// of a result with thousands of rows — first 200 is plenty.
    private func ensureWidths() {
        let fp = fingerprint(for: result)
        if fingerprint == fp, columnWidths.count == result.columns.count { return }
        fingerprint = fp
        recomputeWidths()
    }

    private func recomputeWidths() {
        columnWidths = Self.computeWidths(columns: result.columns,
                                          rows: result.rows,
                                          uiScale: uiScale)
    }

    private func fingerprint(for r: SQLiteReader.QueryResult) -> String {
        r.columns.joined(separator: "|") + "#\(r.rows.count)"
    }

    /// Width sampling math, extracted as pure for testing. Header
    /// width + max of the first `sampleRows` cell widths per column,
    /// each clamped to keep one giant cell from making the column
    /// hundreds of points wide.
    ///
    /// Pure: `uiScale` is an explicit parameter (default 1.0), never a
    /// global read, so the metric constants (`+24` padding, the
    /// `80/220/320` clamps) and the per-char estimate all scale in
    /// lockstep with the cell font and the result stays unit-testable.
    /// CSVTableView reuses this at the default 1.0.
    internal static func computeWidths(columns: [String], rows: [[String?]],
                                        sampleRows: Int = 200,
                                        uiScale: CGFloat = 1.0) -> [CGFloat] {
        let pad: CGFloat = 24 * uiScale
        let floor: CGFloat = 80 * uiScale
        let headerCap: CGFloat = 220 * uiScale
        let cellCap: CGFloat = 320 * uiScale
        return columns.enumerated().map { (i, name) -> CGFloat in
            let headerW = approxTextWidth(name, uiScale: uiScale)
            let cellW = rows.prefix(sampleRows).reduce(CGFloat(0)) { acc, row in
                guard row.indices.contains(i), let cell = row[i] else { return acc }
                return max(acc, min(approxTextWidth(cell, uiScale: uiScale), cellCap))
            }
            return max(floor, min(headerW + pad, headerCap), min(cellW + pad, cellCap))
        }
    }

    /// Cheap monospaced-width estimate. 7 pt per char @ 11 pt mono is
    /// close enough for column sizing; users can drag to refine. The
    /// per-char estimate scales with `uiScale` (default 1.0) so wider
    /// columns track the larger font.
    internal static func approxTextWidth(_ s: String, uiScale: CGFloat = 1.0) -> CGFloat {
        CGFloat(s.count) * 7 * uiScale
    }

    /// Proportional width rescale for a zoom change (TSK-604). Keeps
    /// user-dragged column ratios instead of recomputing from samples.
    /// Degenerate scales (zero/negative/unchanged) return the input
    /// untouched so a transient bad value can't wipe the widths.
    internal static func rescaledWidths(
        _ widths: [CGFloat], from old: CGFloat, to new: CGFloat
    ) -> [CGFloat] {
        guard old > 0, new > 0, old != new, !widths.isEmpty else { return widths }
        let ratio = new / old
        return widths.map { $0 * ratio }
    }
}
