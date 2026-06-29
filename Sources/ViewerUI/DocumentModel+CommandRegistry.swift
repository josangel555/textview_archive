import Foundation
import Combine
import ViewerCore

// Command registry (TSK-1110 SRP slice; UX-M / #232) — keybinding load/reload,
// the partial-failure diagnostics, and palette command dispatch. The
// `commandRegistry` / `macros` / `sessionsCoordinator` stored properties stay on
// DocumentModel (extensions can't add storage); only the logic lives here.
// Behavior-preserving move out of DocumentModel.swift.
extension DocumentModel {

    /// Reload the keybinding config from disk (e.g. after the user edits
    /// the file or a settings UI rewrites it). Re-validates ids, re-folds
    /// overrides, re-logs partial failures. Triggers an objectWillChange
    /// so palette / menu observers refresh.
    public func loadKeybindings(directory: URL = KeybindingConfig.defaultDirectory) {
        let result = KeybindingConfig.load(directory: directory)
        logKeybindingResult(result)
        objectWillChange.send()
        commandRegistry = CommandRegistry.builtIn.applying(
            overrides: result.config.bindings)
    }

    /// Emit the partial-failure diagnostics from a keybinding parse to the
    /// observability sink (unknown ids, malformed values, bad file) so a
    /// user mis-edit is visible in the Logs view / stderr instead of
    /// silently dropped.
    func logKeybindingResult(_ result: KeybindingConfig.ParseResult) {
        if result.malformedFile {
            Obs.shared.emit(.warn, "keybinding",
                "keybinding.json is not a JSON object of strings — ignored")
        }
        for (id, raw) in result.invalidValues {
            Obs.shared.emit(.warn, "keybinding",
                "unparseable shortcut '\(raw)' for '\(id)' — ignored",
                fields: ["id": id, "value": raw])
        }
        for id in result.unknownIDs {
            Obs.shared.emit(.warn, "keybinding",
                "unknown command id '\(id)' in keybinding.json — ignored",
                fields: ["id": id])
        }
        // Surface effective-shortcut collisions (built-in or user-caused)
        // so a rebind that shadows another command is noticed.
        _ = CommandRegistry.builtIn
            .applying(overrides: result.config.bindings)
            .shortcutMap { shortcut, losing, winning in
                Obs.shared.emit(.info, "keybinding",
                    "shortcut '\(shortcut.displayString)' bound to both '\(losing)' and '\(winning)' — last wins (\(winning))",
                    fields: ["shortcut": shortcut.displayString,
                             "losing": losing, "winning": winning])
            }
    }

    /// Invoke a registered command by id from the palette.
    ///
    /// Routes through `ScriptVerb.apply` when the command has a
    /// `scriptVerb` (the pure, headless-tested dispatch path). Commands
    /// without a verb (window/`NSApp`-coupled — see the GAP list) are
    /// no-ops here and remain menu-only; the palette greys them out.
    /// Returns `true` if a verb was dispatched.
    @discardableResult
    public func invokeCommand(id: String) -> Bool {
        guard let cmd = commandRegistry.command(id: id),
              let verb = cmd.scriptVerb else { return false }
        guard let sessions = sessionsCoordinator else {
            // No coordinator wired (previews / some tests). The model-only
            // verbs would still apply, but ScriptVerb.apply needs the pair;
            // without it we can't dispatch safely.
            Obs.shared.emit(.warn, "command",
                "invokeCommand('\(id)') skipped: no sessions coordinator wired")
            return false
        }
        return ScriptVerb.apply(verb: verb, to: self, sessions: sessions)
    }
}
