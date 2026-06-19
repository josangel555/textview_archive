import SwiftUI
import ViewerCore

/// Snippet management UI (TSK-705): list every snippet, add a new user snippet,
/// edit / delete user snippets, and override a built-in by id. A thin SwiftUI
/// shell over `SnippetManagerModel` — all the create / edit / delete / validate
/// BEHAVIOUR lives in that host-tested model; this view only renders + binds.
///
/// Presented as a sheet from the Edit menu (Edit → Manage Snippets…). The
/// left column lists snippets; the right column is the editing form.
public struct SnippetManagerView: View {

    private let model: SnippetManagerModel
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

    public init(model: SnippetManagerModel, onDismiss: @escaping () -> Void) {
        self.model = model
        self.onDismiss = onDismiss
    }

    private var validation: SnippetManagerModel.Validation {
        model.validate(id: formID, name: formName, body: formBody, editingID: editingID)
    }

    public var body: some View {
        HSplitView {
            listColumn
                .frame(minWidth: 220, idealWidth: 240)
            formColumn
                .frame(minWidth: 300)
        }
        .frame(width: 660, height: 460)
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
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(model.allSnippets, id: \.id) { snip in
                        snippetRow(snip)
                    }
                }
                .padding(.vertical, 4)
            }
        }
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
                .frame(minHeight: 140)
                .overlay(RoundedRectangle(cornerRadius: 4)
                    .stroke(Color.secondary.opacity(0.3)))
                .accessibilityIdentifier("mdv.snippetManager.body")

            Text("Use $1, $2, … for tab stops, ${1:default} for a placeholder, $0 for the final caret.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)

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
                .keyboardShortcut(.defaultAction)
                .disabled(!validation.isValid)
                .accessibilityIdentifier("mdv.snippetManager.save")
            }
        }
        .padding(16)
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
