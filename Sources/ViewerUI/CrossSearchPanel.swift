import SwiftUI
import ViewerCore

/// Cross-file search overlay. Mirrors the command palette's visual
/// style but lists grep-style results — file groups with line-number
/// hits. Activation: Cmd+Shift+F. Click a row to open the file.
struct CrossSearchPanel: View {
    @ObservedObject var model: DocumentModel
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search across folder…", text: $model.crossSearchQuery)
                    .textFieldStyle(.plain)
                    .font(.system(size: 16))
                    .focused($fieldFocused)
                    .onSubmit { model.runCrossSearch() }
                Toggle(isOn: $model.crossSearchCaseSensitive) {
                    Text("Aa").font(.system(size: 11, weight: .medium))
                }
                .toggleStyle(.button)
                .controlSize(.small)
                .help("Match case")
                if model.crossSearchIsRunning {
                    ProgressView().controlSize(.small)
                }
                Button {
                    model.dismissCrossSearch()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.escape, modifiers: [])
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)

            Divider()

            if model.crossSearchQuery.isEmpty {
                placeholder
            } else if model.crossSearchResults.isEmpty {
                Text(model.crossSearchIsRunning ? "Searching…" : "No matches")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 24)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(model.crossSearchResults) { group in
                            CrossSearchFileGroupView(group: group, model: model)
                        }
                    }
                    .padding(.vertical, 6)
                }
            }
        }
        .frame(maxWidth: 760, maxHeight: 520)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Palette.separator, lineWidth: 1)
        )
        .shadow(color: Color.primary.opacity(0.25), radius: 20, y: 8)
        .onAppear {
            fieldFocused = true
            if !model.crossSearchQuery.isEmpty { model.runCrossSearch() }
        }
        .onChange(of: model.crossSearchQuery) { _, _ in
            model.runCrossSearch()
        }
        .onChange(of: model.crossSearchCaseSensitive) { _, _ in
            model.runCrossSearch()
        }
        .accessibilityIdentifier("mdv.crossSearchPanel")
    }

    private var placeholder: some View {
        VStack(spacing: 8) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
            Text(model.sidebar.rootURL == nil
                 ? "Open a folder to search across files."
                 : "Type to search the folder.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}

private struct CrossSearchFileGroupView: View {
    let group: CrossFileSearch.FileMatches
    @ObservedObject var model: DocumentModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                model.openPath(group.url)
                model.dismissCrossSearch()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "doc.text")
                        .foregroundStyle(.secondary)
                    Text(group.url.lastPathComponent)
                        .font(.system(.body, design: .default).weight(.medium))
                    Text("(\(group.matches.count))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(group.url.deletingLastPathComponent().path)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 4)
            }
            .buttonStyle(.plain)

            ForEach(group.matches.prefix(8), id: \.lineNumber) { m in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("\(m.lineNumber)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(width: 36, alignment: .trailing)
                    Text(m.line)
                        .font(.system(.body, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .padding(.leading, 30)
                .padding(.trailing, 14)
                .padding(.vertical, 1)
            }
            if group.matches.count > 8 {
                Text("+ \(group.matches.count - 8) more")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 66)
            }
            Divider().padding(.vertical, 4)
        }
    }
}
