import AppKit
import SwiftUI
import ViewerCore

/// LSP "Code Actions…" picker (TSK-640) — the interactive entry to the
/// host-tested applyCodeAction path. Fetches actions at the active editor
/// cursor (async, via DocumentModel.showCodeActionPicker), lists them, and
/// applies the pick (`pickCodeAction`). Command-only actions (empty `edit`)
/// are listed but disabled — this viewer applies edits, never executes server
/// commands. Mirrors GoToPathPrompt / LSPRenamePrompt chrome.
///
/// # Accessibility identifiers (for VM UI tests)
///   - `mdv.codeActions.panel`   — the overlay container
///   - `mdv.codeActions.loading` — the fetching spinner
///   - `mdv.codeActions.row`     — one action row (button)
///   - `mdv.codeActions.cancelButton`
struct CodeActionPicker: View {
    @ObservedObject var model: DocumentModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "lightbulb")
                    .foregroundStyle(.secondary)
                Text("Code Actions")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Button(action: { model.dismissCodeActionPicker() }) {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("mdv.codeActions.cancelButton")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Divider()

            content
                .padding(.horizontal, 8)
                .padding(.vertical, 8)
        }
        .frame(width: 460)
        .background(Palette.windowBackground)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
        )
        .shadow(radius: 24)
        .accessibilityIdentifier("mdv.codeActions.panel")
    }

    @ViewBuilder
    private var content: some View {
        switch model.codeActionPicker {
        case .hidden:
            EmptyView()
        case .loading:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Finding code actions…")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .accessibilityIdentifier("mdv.codeActions.loading")
        case .presenting(let actions):
            VStack(alignment: .leading, spacing: 1) {
                ForEach(Array(actions.enumerated()), id: \.offset) { _, action in
                    let applicable = !action.edit.isEmpty
                    Button(action: {
                        if !model.pickCodeAction(action) { NSSound.beep() }
                    }) {
                        HStack(spacing: 6) {
                            Image(systemName: action.isPreferred ? "star.fill" : "wrench.and.screwdriver")
                                .font(.caption)
                                .foregroundStyle(applicable ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.tertiary))
                                .frame(width: 16)
                            Text(action.title)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .foregroundStyle(applicable ? .primary : .secondary)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(!applicable)   // command-only: listable, not applicable
                    .help(applicable ? action.title : "\(action.title) — not applicable here (command-only)")
                    .accessibilityIdentifier("mdv.codeActions.row")
                }
            }
        }
    }
}
