import SwiftUI
import ViewerCore

/// Status-bar indicator that a command macro is recording (TSK-1162, vm slice).
/// Empty (and absent) when not recording — mirrors the vim-mode chip's
/// "show only when relevant" pattern. Observes the `MacroController` directly so
/// it appears/disappears reactively as recording toggles (the controller's
/// `isRecording` is `@Published`).
struct MacroRecordingChip: View {
    @ObservedObject var macros: MacroController

    var body: some View {
        if macros.isRecording {
            HStack(spacing: 4) {
                Image(systemName: "record.circle.fill")
                    .foregroundStyle(.red)
                Text("Recording Macro")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .fixedSize()
            .help("A command macro is recording. Run “Stop Recording Macro” to finish, then “Replay Last Macro” to play it back (⌘K).")
            .accessibilityIdentifier("mdv.statusBar.macroRecording")
        }
    }
}
