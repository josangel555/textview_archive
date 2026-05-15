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

private struct ResultTableView: View {
    let result: SQLiteReader.QueryResult

    var body: some View {
        // SwiftUI's `Table` API isn't a great fit for dynamic-column
        // arbitrary-SQL results; we hand-roll a grid. ScrollView in
        // both axes so wide schemas don't get clipped.
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
        }
    }

    private var headerRow: some View {
        HStack(spacing: 0) {
            ForEach(result.columns, id: \.self) { name in
                Text(name)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .frame(minWidth: 80, alignment: .leading)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .overlay(alignment: .trailing) {
                        Rectangle().fill(Color(nsColor: .separatorColor))
                            .frame(width: 0.5)
                    }
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
                    .padding(.vertical, 3)
                    .frame(minWidth: 80, alignment: .leading)
                    .overlay(alignment: .trailing) {
                        Rectangle().fill(Color(nsColor: .separatorColor))
                            .frame(width: 0.5)
                    }
            }
        }
        .background(isAlt ? Color(nsColor: .controlBackgroundColor).opacity(0.3) : Color.clear)
        .textSelection(.enabled)
    }
}
