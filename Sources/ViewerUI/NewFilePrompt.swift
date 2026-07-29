import AppKit
import ViewerCore

/// TSK-1605 — the "New File" name prompt (owner 2026-07-25: *"New file should
/// first ask the filename. Do not create Untitled.txt."*).
///
/// Every New-File entry point now collects the name UP FRONT and creates the
/// file with it, so the create → rename dance (and its bugs) is off the happy
/// path entirely. Same light `NSAlert` + text-field idiom as the rename and
/// Go-to-Line prompts.
///
/// The field is pre-filled with the type's default (`untitled.md`, …) and the
/// STEM is pre-selected, so typing replaces the name while keeping the
/// extension — and a user who just hits Return still gets a working file.
/// Invalid / colliding names re-prompt with the reason rather than silently
/// falling back to a generated name.
@MainActor
public enum NewFilePrompt {

    /// Ask for a file name for `type` in `directory`. Returns the validated
    /// name, or nil if the user cancelled.
    public static func run(
        in directory: URL,
        type: NewFileType,
        suggestion: String? = nil
    ) -> String? {
        var prefill = suggestion ?? NewFileNameValidator.suggestion(for: type)
        var problem: String?

        while true {
            let alert = NSAlert()
            alert.messageText = "New File"
            alert.informativeText = problem
                ?? "Name the new file in \u{201C}\(directory.lastPathComponent)\u{201D}."
            if problem != nil { alert.alertStyle = .warning }
            alert.addButton(withTitle: "Create")
            alert.addButton(withTitle: "Cancel")

            let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 22))
            field.stringValue = prefill
            field.placeholderString = NewFileNameValidator.suggestion(for: type)
            alert.accessoryView = field
            alert.window.initialFirstResponder = field
            // Select the STEM only, so typing replaces the name but keeps the
            // extension the user picked from the New ▸ menu.
            field.selectText(nil)
            if let editor = field.currentEditor() {
                let ns = prefill as NSString
                let dot = ns.range(of: ".", options: .backwards)
                editor.selectedRange = dot.location == NSNotFound
                    ? NSRange(location: 0, length: ns.length)
                    : NSRange(location: 0, length: dot.location)
            }

            guard alert.runModal() == .alertFirstButtonReturn else { return nil }

            let entered = field.stringValue
            switch NewFileNameValidator.validate(entered, in: directory) {
            case .ok(let name):
                return name
            case let verdict:
                // Re-prompt with the reason, keeping what they typed.
                problem = NewFileNameValidator.message(for: verdict)
                prefill = entered
            }
        }
    }
}
