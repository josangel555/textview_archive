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
    @StateObject private var model: SQLiteBrowserModel

    public init(url: URL) {
        self.url = url
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
        .background(Color(nsColor: .textBackgroundColor))
    }

    @ViewBuilder
    private func schemaGroup(_ title: String, items: [String], icon: String) -> some View {
        if !items.isEmpty {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.top, 8)
                .padding(.bottom, 2)
            ForEach(items, id: \.self) { name in
                Button(action: { model.select(name: name) }) {
                    HStack(spacing: 6) {
                        Image(systemName: icon)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .frame(width: 14)
                        Text(name)
                            .font(.system(size: 12, weight: model.selectedName == name ? .semibold : .regular))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 22)
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
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Run") { model.runQuery() }
                    .keyboardShortcut(.return, modifiers: [.command])
                    .disabled(model.query.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            TextEditor(text: $model.query)
                .font(.system(size: 12, design: .monospaced))
                .frame(height: 110)
                .padding(.horizontal, 4)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    @ViewBuilder
    private var resultsArea: some View {
        if let err = model.queryError {
            VStack(spacing: 8) {
                Text("Query error")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.red)
                Text(err)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 20)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let result = model.queryResult {
            ResultTableView(result: result)
        } else {
            VStack(spacing: 8) {
                Text("Click a table or write a SELECT, then ⌘↵ to run.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

@MainActor
private final class SQLiteBrowserModel: ObservableObject {
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

    private var reader: SQLiteReader?

    init(url: URL) { self.url = url }

    func load() {
        do {
            reader = try SQLiteReader(url: url)
            tables   = (try? reader?.tableNames())   ?? []
            views    = (try? reader?.viewNames())    ?? []
            indexes  = (try? reader?.indexNames())   ?? []
            triggers = (try? reader?.triggerNames()) ?? []
        } catch {
            openError = "\(error)"
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
        guard let reader else { return }
        do {
            queryResult = try reader.query(query)
        } catch {
            queryResult = nil
            queryError = "\(error)"
        }
    }
}

internal struct ResultTableView: View {
    let result: SQLiteReader.QueryResult

    /// Per-column widths (one entry per column index). Auto-sized at
    /// first render from header + sample of cell widths; user can drag
    /// the separator next to a column header to override.
    @State private var columnWidths: [CGFloat] = []
    /// Track the result identity so the widths re-compute when a new
    /// query lands (different column set).
    @State private var fingerprint: String = ""

    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            VStack(alignment: .leading, spacing: 0) {
                headerRow
                ForEach(Array(result.rows.enumerated()), id: \.offset) { (i, row) in
                    cellRow(row, isAlt: i % 2 == 1)
                }
                if result.truncated {
                    Text("Output truncated at \(result.rows.count) rows.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(8)
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
    }

    /// Bump font height to a stable line height across header + cells
    /// (NSAttributedString's intrinsic height fluctuates with content;
    /// fixing it here keeps every row the same vertical size).
    private let rowHeight: CGFloat = 22

    private var headerRow: some View {
        HStack(spacing: 0) {
            ForEach(Array(result.columns.enumerated()), id: \.offset) { (i, name) in
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

    private func cellRow(_ row: [String?], isAlt: Bool) -> some View {
        HStack(spacing: 0) {
            ForEach(row.indices, id: \.self) { i in
                let cell = row[i]
                Text(cell ?? "NULL")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(cell == nil ? .tertiary : .primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.horizontal, 8)
                    .frame(width: widthFor(i), height: rowHeight, alignment: .topLeading)
                    .overlay(alignment: .trailing) {
                        Rectangle().fill(Color(nsColor: .separatorColor))
                            .frame(width: 0.5)
                    }
            }
        }
        .background(isAlt ? Color(nsColor: .controlBackgroundColor).opacity(0.3) : Color.clear)
        .textSelection(.enabled)
    }

    /// Draggable handle on the right edge of each header cell. The
    /// hit zone is wider than the visible 0.5-pt rule so it's actually
    /// catchable by the cursor.
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
                                if columnWidths.indices.contains(i) {
                                    columnWidths[i] = newWidth
                                }
                            }
                    )
            )
    }

    private func widthFor(_ i: Int) -> CGFloat {
        if columnWidths.indices.contains(i) { return columnWidths[i] }
        return 120
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
        columnWidths = Self.computeWidths(columns: result.columns, rows: result.rows)
    }

    private func fingerprint(for r: SQLiteReader.QueryResult) -> String {
        r.columns.joined(separator: "|") + "#\(r.rows.count)"
    }

    /// Width sampling math, extracted as pure for testing. Header
    /// width + max of the first `sampleRows` cell widths per column,
    /// each clamped to keep one giant cell from making the column
    /// hundreds of points wide.
    internal static func computeWidths(columns: [String], rows: [[String?]],
                                        sampleRows: Int = 200) -> [CGFloat] {
        columns.enumerated().map { (i, name) -> CGFloat in
            let headerW = approxTextWidth(name)
            let cellW = rows.prefix(sampleRows).reduce(CGFloat(0)) { acc, row in
                guard row.indices.contains(i), let cell = row[i] else { return acc }
                return max(acc, min(approxTextWidth(cell), 320))
            }
            return max(80, min(headerW + 24, 220), min(cellW + 24, 320))
        }
    }

    /// Cheap monospaced-width estimate. 7 pt per char @ 11 pt mono is
    /// close enough for column sizing; users can drag to refine.
    internal static func approxTextWidth(_ s: String) -> CGFloat {
        CGFloat(s.count) * 7
    }
}
