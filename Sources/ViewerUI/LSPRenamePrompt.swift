import AppKit
import SwiftUI
import ViewerCore

/// "Rename Symbol…" prompt (TSK-640) — the interactive entry to the
/// host-tested LSP rename engine. Type a new name, hit Return, and the
/// symbol at the active editor cursor is renamed across the open tabs
/// (`DocumentModel.submitLSPRename` → `renameActiveEditorSymbolViaLSP`).
/// Mirrors `GoToPathPrompt`'s scrim + centered-panel chrome.
///
/// # Accessibility identifiers (for VM UI tests)
///   - `mdv.lspRename.panel`   — the overlay container
///   - `mdv.lspRename.field`   — the new-name text field (autofocus)
///   - `mdv.lspRename.renameButton` — primary Rename button (⏎)
///   - `mdv.lspRename.cancelButton` — dismiss without renaming (⎋)
struct LSPRenamePrompt: View {
    @ObservedObject var model: DocumentModel
    @State private var name: String = ""
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "character.cursor.ibeam")
                    .foregroundStyle(.secondary)
                Text("Rename Symbol")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Divider()

            TextField("New name", text: $name)
                .textFieldStyle(.plain)
                .font(.system(size: 14, design: .monospaced))
                .focused($fieldFocused)
                .onSubmit { submit() }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Color.primary.opacity(0.18), lineWidth: 0.5)
                )
                .accessibilityIdentifier("mdv.lspRename.field")
                .padding(.horizontal, 14)
                .padding(.vertical, 12)

            Divider()

            HStack(spacing: 12) {
                Button(action: { submit() }) {
                    Label("Rename", systemImage: "return").labelStyle(.titleAndIcon)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                .accessibilityIdentifier("mdv.lspRename.renameButton")

                Spacer()

                Text("⎋ cancel")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                Button(action: { model.dismissLSPRenamePrompt() }) {
                    Text("Cancel")
                }
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("mdv.lspRename.cancelButton")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .frame(width: 420)
        .background(Palette.windowBackground)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
        )
        .shadow(radius: 24)
        .accessibilityIdentifier("mdv.lspRename.panel")
        .onAppear {
            if name.isEmpty { name = model.lspRenamePrefill }
            fieldFocused = true
        }
    }

    private func submit() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        if !model.submitLSPRename(trimmed) { NSSound.beep() }
        name = ""
    }
}
