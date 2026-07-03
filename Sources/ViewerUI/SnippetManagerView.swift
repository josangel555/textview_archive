import SwiftUI
import ViewerCore

/// Snippet management UI (TSK-705, UX pass TSK-1461): search every snippet,
/// preview what it expands to, insert it into the active editor with one
/// keystroke, and add / edit / delete user snippets (overriding built-ins by
/// id). A thin SwiftUI shell over `SnippetManagerModel` — filtering, the
/// insert-candidate pick, preview text, and create / edit / delete / validate
/// BEHAVIOUR all live in that host-tested model; this view only renders + binds.
///
/// Interaction model:
///   - type in the search field to filter by name / id / body;
///   - single-click a row to select it (loads the form + preview);
///   - double-click a row — or press Return (the Insert default action) —
///     to insert it into the active editor (tab-stop session included);
///   - ⌘S saves the form; built-ins are read-only unless overridden by id.
///
/// Presented as a retained tool window from Edit → Manage Snippets…. The
/// left column is search + list + Insert; the right column is the editing
/// form with a live expansion preview.
public struct SnippetManagerView: View {

    private let model: SnippetManagerModel
    private let onInsert: ((Snippet) -> Void)?
    private let onDismiss: () -> Void

    /// Forces a re-read of the store after a save / delete (the store is a
    /// reference type with no `@Published` surface).
    @State private var tick: Int = 0
    /// The id of the user snippet currently being edited in place; nil while
    /// composing a brand-new snippet.
    @State private var editingID: String? = nil
    @State private var formID: String = ""
    @State private var formName: String = ""
    @State private var formBody: String = ""
    /// Live name/id/body filter (TSK-1461).
    @State private var searchText: String = ""

    public init(
        model: SnippetManagerModel,
        onInsert: ((Snippet) -> Void)? = nil,
        onDismiss: @escaping () -> Void
    ) {
        self.model = model
        self.onInsert = onInsert
        self.onDismiss = onDismiss
    }

    private var validation: SnippetManagerModel.Validation {
        model.validate(id: formID, name: formName, body: formBody, editingID: editingID)
    }

    private var filteredSnippets: [Snippet] {
        model.filtered(query: searchText)
    }

    /// What Return / the Insert button inserts: the selected row when it
    /// survives the filter, else the first filtered match (model-decided).
    private var insertCandidate: Snippet? {
        model.insertCandidate(query: searchText, selectedID: editingID)
    }

    public var body: some View {
        HSplitView {
            listColumn
                .frame(minWidth: 230, idealWidth: 250)
            formColumn
                .frame(minWidth: 320)
        }
        .frame(width: 680, height: 540)
        .id(tick)
    }

    // MARK: - List column

    private var listColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Snippets")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Button {
                    startNewSnippet()
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .help("Add a new snippet")
                .accessibilityIdentifier("mdv.snippetManager.add")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            searchField
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            Divider()
            if filteredSnippets.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(filteredSnippets, id: \.id) { snip in
                            snippetRow(snip)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            Spacer(minLength: 0)
            Divider()
            insertBar
        }
    }

    private var searchField: some View {
        HStack(spacing: 4) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            TextField("Search name, id, or body", text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .accessibilityIdentifier("mdv.snippetManager.search")
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .accessibilityIdentifier("mdv.snippetManager.searchClear")
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 6)
            .fill(Color.secondary.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 6)
            .stroke(Color.secondary.opacity(0.25)))
    }

    /// TSK-1461 — the list is empty either because the store is (first run
    /// after deleting everything) or because the search matched nothing.
    @ViewBuilder
    private var emptyState: some View {
        Spacer(minLength: 0)
        if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            HostedEmptyStateView(EmptyStateCatalog.snippetManager) {
                startNewSnippet()
            }
            .frame(maxWidth: .infinity)
        } else {
            HostedEmptyStateView(EmptyStateCatalog.snippetManagerNoMatches) {
                searchText = ""
            }
            .frame(maxWidth: .infinity)
        }
    }

    /// The one-keystroke insert affordance: Return (default action) or the
    /// button. Disabled when nothing matches or no insert sink is wired.
    private var insertBar: some View {
        HStack(spacing: 6) {
            if let candidate = insertCandidate {
                Text(candidate.name)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            Button("Insert") {
                if let candidate = insertCandidate { onInsert?(candidate) }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(insertCandidate == nil || onInsert == nil)
            .help("Insert into the active editor (Return)")
            .accessibilityIdentifier("mdv.snippetManager.insert")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func snippetRow(_ snip: Snippet) -> some View {
        let builtIn = model.isBuiltIn(snip.id)
        let overridden = builtIn && model.userSnippets.contains { $0.id == snip.id }
        return HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 1) {
                Text(snip.name)
                    .font(.system(size: 12))
                Text(snip.id)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            if builtIn {
                Text(overridden ? "OVERRIDDEN" : "BUILT-IN")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Color.secondary.opacity(0.15))
                    .cornerRadius(3)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .background(editingID == snip.id ? Color.accentColor.opacity(0.15) : Color.clear)
        // Double-click inserts (TSK-1461); registered BEFORE the single-tap so
        // it wins the gesture arbitration. Single click selects + loads the form.
        .onTapGesture(count: 2) { onInsert?(snip) }
        .onTapGesture { beginEditing(snip) }
        .accessibilityIdentifier("mdv.snippetManager.row.\(snip.id)")
    }

    // MARK: - Form column

    private var formColumn: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(editingID == nil ? "New snippet" : "Edit snippet")
                .font(.system(size: 12, weight: .semibold))

            field("Id", text: $formID, placeholder: "my.snippet", mono: true)
            field("Name", text: $formName, placeholder: "Menu label")

            Text("Body")
                .font(.system(size: 11, weight: .medium))
            TextEditor(text: $formBody)
                .font(.system(size: 12, design: .monospaced))
                .frame(minHeight: 110)
                .overlay(RoundedRectangle(cornerRadius: 4)
                    .stroke(Color.secondary.opacity(0.3)))
                .accessibilityIdentifier("mdv.snippetManager.body")

            Text("Use $1, $2, … for tab stops, ${1:default} for a placeholder, $0 for the final caret.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)

            previewSection

            if let msg = validation.message {
                Text(msg)
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
            }

            Spacer(minLength: 0)

            HStack {
                if let editingID, !model.isBuiltIn(editingID) {
                    Button("Delete", role: .destructive) {
                        _ = model.delete(id: editingID)
                        resetForm()
                        bump()
                    }
                    .accessibilityIdentifier("mdv.snippetManager.delete")
                }
                Spacer()
                Button("Close") { onDismiss() }
                Button("Save") {
                    if model.save(id: formID, name: formName, body: formBody,
                                  editingID: editingID).isValid {
                        editingID = formID.trimmingCharacters(in: .whitespacesAndNewlines)
                        bump()
                    }
                }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(!validation.isValid)
                .help("Save the snippet (⌘S)")
                .accessibilityIdentifier("mdv.snippetManager.save")
            }
        }
        .padding(16)
    }

    /// TSK-1461 — live preview of what the body INSERTS (placeholder markup
    /// stripped, defaults kept), captioned with the tab-stop walk. Uses the
    /// same parse the real insert path uses, so preview and insert can't drift.
    @ViewBuilder
    private var previewSection: some View {
        if !formBody.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text("Preview")
                        .font(.system(size: 11, weight: .medium))
                    Spacer()
                    Text(SnippetManagerModel.tabStopSummary(body: formBody))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("mdv.snippetManager.previewSummary")
                }
                ScrollView {
                    Text(SnippetManagerModel.previewText(body: formBody))
                        .font(.system(size: 12, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(6)
                        .textSelection(.enabled)
                }
                .frame(minHeight: 48, maxHeight: 96)
                .background(Color.secondary.opacity(0.06))
                .overlay(RoundedRectangle(cornerRadius: 4)
                    .stroke(Color.secondary.opacity(0.2)))
                .accessibilityIdentifier("mdv.snippetManager.preview")
            }
        }
    }

    private func field(
        _ label: String, text: Binding<String>, placeholder: String, mono: Bool = false
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
            TextField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, design: mono ? .monospaced : .default))
                .accessibilityIdentifier("mdv.snippetManager.field.\(label.lowercased())")
        }
    }

    // MARK: - Actions

    private func startNewSnippet() {
        resetForm()
    }

    private func beginEditing(_ snip: Snippet) {
        editingID = snip.id
        formID = snip.id
        formName = snip.name
        formBody = snip.body
    }

    private func resetForm() {
        editingID = nil
        formID = ""
        formName = ""
        formBody = ""
    }

    private func bump() { tick += 1 }
}
