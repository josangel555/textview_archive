import AppKit
import Foundation
import ViewerCore

/// TSK-698 slice 3b — the Script Console's DocumentModel wiring: open the panel seeded
/// from the active buffer, and apply its output to a new tab. The @Published flag +
/// view-model live on `DocumentModel` (stored props can't be in an extension); these are
/// the open/apply methods. The presentation (`.sheet` in ContentView) + a menu trigger
/// are the view-side companions; this layer is host-testable.
extension DocumentModel {

    /// Open the Script Console, seeded with the active buffer's live content and a default
    /// input format inferred from its file extension (.csv→CSV, .log/.txt→Lines, else JSON).
    public func openScriptConsole() {
        let tab = tabs.selected
        let content: String
        if let id = tab?.id, let text = editorBuffer(forTabID: id)?.text {
            content = text
        } else if let url = tab?.url, let text = try? String(contentsOf: url, encoding: .utf8) {
            content = text
        } else {
            content = ""
        }
        let vm = ScriptConsoleViewModel(inputContent: content)
        vm.inputFormat = ScriptConsoleViewModel.defaultInputFormat(forURL: tab?.url)
        scriptConsoleVM = vm
        showScriptConsole = true
    }

    /// Apply the console's output: write it to a per-user temp `.json` file and open it in
    /// a new tab (the output is JSON.stringify'd). No-op + beep on empty / write failure.
    public func applyScriptConsoleOutput(_ output: String) {
        guard !output.isEmpty, let data = output.data(using: .utf8) else { NSSound.beep(); return }
        let name = "ScriptOutput-\(UUID().uuidString.prefix(8)).json"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        do {
            try data.write(to: url)
            openInNewTab(url)
        } catch {
            NSSound.beep()
        }
    }
}
