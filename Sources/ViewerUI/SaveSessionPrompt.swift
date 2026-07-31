import AppKit

/// "Save Session As…" name prompt (owner ask 2026-07-29: *"Can we have a
/// Save and retrieve session option?"*) — the same light NSAlert +
/// text-field idiom as `NewFilePrompt` / rename / Go-to-Line.
///
/// Names are display labels for save points, not filenames — no
/// filesystem constraints; the only rule is non-empty (re-prompts).
/// Returns the trimmed name, or nil on cancel.
@MainActor
enum SaveSessionPrompt {

    static func run(currentName: String, now: Date = Date()) -> String? {
        var prefill = defaultName(for: currentName, now: now)
        var problem: String?

        while true {
            let alert = NSAlert()
            alert.messageText = "Save Session As"
            alert.informativeText = problem
                ?? "Name this save point. Restoring it later opens a new "
                + "session with these tabs and this layout."
            if problem != nil { alert.alertStyle = .warning }
            alert.addButton(withTitle: "Save")
            alert.addButton(withTitle: "Cancel")

            let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 22))
            field.stringValue = prefill
            alert.accessoryView = field
            alert.window.initialFirstResponder = field
            field.selectText(nil)

            guard alert.runModal() == .alertFirstButtonReturn else { return nil }

            let entered = field.stringValue
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if entered.isEmpty {
                problem = "The name can\u{2019}t be empty."
                prefill = field.stringValue
                continue
            }
            return entered
        }
    }

    /// "<session> — Jul 31" so a plain Return still yields a useful label.
    /// Split out for the host test (the modal itself is AX-lane).
    static func defaultName(for sessionName: String, now: Date = Date()) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "MMM d"
        return "\(sessionName) \u{2014} \(fmt.string(from: now))"
    }
}
