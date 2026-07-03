import SwiftUI

/// Footer toggle chips for the two per-keystroke editor assists — spell-check
/// (whole-doc NSSpellChecker pass per debounced edit) and autocomplete (LSP /
/// whole-buffer word scan per completion request). On large txt files or a
/// loaded machine these are the felt typing cost, so the user can flip them
/// off right where they watch the editor state.
///
/// Its OWN view observing EditorCoordinator directly (StatusBarMemoryChip
/// precedent): editor publishes re-body ONLY these chips, never the StatusBar —
/// preserving the bar's severed-path design (no re-body per keystroke/caret).
struct EditorAssistChips: View {
    @ObservedObject var editor: EditorCoordinator
    let fontSize: CGFloat

    var body: some View {
        HStack(spacing: 8) {
            chip(on: editor.spellCheckEnabled,
                 systemImage: "textformat.abc",
                 help: editor.spellCheckEnabled ? "Spell check: on — click to disable"
                                                : "Spell check: off — click to enable",
                 id: "mdv.statusbar.spellToggle") {
                editor.spellCheckEnabled.toggle()
            }
            chip(on: editor.autocompleteEnabled,
                 systemImage: "character.cursor.ibeam",
                 help: editor.autocompleteEnabled ? "Autocomplete: on — click to disable"
                                                  : "Autocomplete: off — click to enable",
                 id: "mdv.statusbar.autocompleteToggle") {
                editor.autocompleteEnabled.toggle()
            }
        }
    }

    @ViewBuilder
    private func chip(on: Bool, systemImage: String, help: String,
                      id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: fontSize))
                .foregroundStyle(on ? Color.primary : Color.secondary.opacity(0.45))
                .overlay(alignment: .center) {
                    if !on {
                        Rectangle()
                            .fill(Color.secondary)
                            .frame(height: 1)
                            .rotationEffect(.degrees(-20))
                    }
                }
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityIdentifier(id)
    }
}
