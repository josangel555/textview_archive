import Foundation

/// Coarse grouping for a command, used to section the palette / a future
/// keybindings settings pane. Low-cardinality and stable.
public enum CommandCategory: String, Sendable, CaseIterable, Comparable {
    case file
    case view
    case edit
    case navigation
    case tabs
    case sessions
    case git
    case lsp
    case find
    case window
    case debug

    /// Human label for the category header.
    public var title: String {
        switch self {
        case .file:       return "File"
        case .view:       return "View"
        case .edit:       return "Edit"
        case .navigation: return "Navigation"
        case .tabs:       return "Tabs"
        case .sessions:   return "Sessions"
        case .git:        return "Git"
        case .lsp:        return "Language"
        case .find:       return "Find"
        case .window:     return "Window"
        case .debug:      return "Debug"
        }
    }

    public static func < (lhs: CommandCategory, rhs: CommandCategory) -> Bool {
        // Order by declaration order in `allCases`.
        let order = CommandCategory.allCases
        return order.firstIndex(of: lhs)! < order.firstIndex(of: rhs)!
    }
}

/// Whether a command is safe to capture into a recorded macro and re-dispatch
/// later without a live pointer / selection / interactive prompt (TSK-957,
/// app-wide command macros).
///
/// A macro is a deterministic, headless re-run of a *command sequence*. Many
/// commands are not deterministic out of their original interaction context:
///
///   - **pointer/selection-dependent** — they resolve against the live caret
///     or mouse (LSP go-to-at-cursor, sidebar select-next/prev), so replaying
///     them later lands somewhere unrelated;
///   - **interactive-prompt** — they only open a panel/sheet that needs the
///     user to type or pick (Open…, Find…, Rename Symbol…, Go to Line…), so a
///     replay would either stall waiting for input or do nothing useful.
///
/// Everything else — text-edit transforms, pure view/state toggles, clipboard
/// text tools, tab/zoom/session navigation that resolves against model state —
/// is `.replayable`: re-dispatching it through the registry reproduces the
/// recorded effect.
public enum CommandReplayability: String, Sendable, Hashable, CaseIterable {
    /// Safe to capture + re-dispatch headlessly; reproduces the recorded effect.
    case replayable
    /// Pointer/selection-dependent or interactive-prompt — excluded from macros.
    case excluded
}

/// One user-invokable action.
///
/// **Why `scriptVerb` is the canonical invoker.** The app already has a
/// pure, headless dispatch surface — `ScriptVerb.apply(verb:to:sessions:)`
/// — that drives a `(DocumentModel, SessionsAppCoordinator)` pair without
/// any window or `NSApp`. Rather than invent a *second* closure-based
/// invoker that would duplicate that switch (and couple this catalog to
/// `@MainActor` model state, dragging it out of pure ViewerCore), a
/// command records the script-verb *line* it maps to. The palette / menu
/// layer feeds that line straight through `ScriptVerb.apply`. Commands
/// that have no pure verb yet — the genuinely window/`NSApp`-coupled ones
/// (open-panels, the find router, zoom-via-menu, the debug tool windows)
/// — carry `scriptVerb == nil` and are listed in the GAP report; the menu
/// still binds them the old way and the palette skips invoking them until
/// a verb exists.
///
/// Pure value type: `id`, `title`, `category`, an optional
/// `defaultShortcut`, and the optional verb token. No closures, no
/// `@MainActor`, no AppKit — so the whole catalog is constructable and
/// assertable from a host-side unit test.
public struct CommandDescriptor: Sendable, Hashable, Identifiable {
    /// Stable, dot-namespaced identifier. This is the key users write in
    /// `keybinding.json`; NEVER renamed once shipped (it's a config
    /// contract), even if the title changes.
    public let id: String
    /// Human-readable title shown in the palette.
    public let title: String
    public let category: CommandCategory
    /// Built-in shortcut, or `nil` if the command has no default binding.
    public let defaultShortcut: Shortcut?
    /// `ScriptVerb` line this command dispatches to, or `nil` if the
    /// command is still window/`NSApp`-coupled (see the type doc + GAP
    /// report). When the verb takes an argument the descriptor stores the
    /// invariant prefix only; the invoker appends the runtime arg.
    public let scriptVerb: String?
    /// Whether this command is safe to capture into a recorded macro and
    /// re-dispatch later (TSK-957). Defaults to `.replayable` for commands
    /// that have a pure script verb (those are headlessly dispatchable) and
    /// `.excluded` for the window/`NSApp`-coupled `scriptVerb == nil`
    /// commands. The built-in catalog overrides this for the handful of
    /// verb-backed commands that are still pointer/selection-dependent or
    /// open an interactive prompt (LSP go-to-at-cursor, sidebar select,
    /// Go-to / Rename / Code-Actions panels) — see `CommandRegistry+BuiltIn`.
    public let replayability: CommandReplayability

    public init(
        id: String,
        title: String,
        category: CommandCategory,
        defaultShortcut: Shortcut? = nil,
        scriptVerb: String? = nil,
        replayability: CommandReplayability? = nil
    ) {
        self.id = id
        self.title = title
        self.category = category
        self.defaultShortcut = defaultShortcut
        self.scriptVerb = scriptVerb
        // Default: a command with a pure verb is replayable; a
        // window/`NSApp`-coupled one (no verb) cannot be re-dispatched
        // headlessly, so it is excluded. Explicit values override.
        self.replayability = replayability ?? (scriptVerb != nil ? .replayable : .excluded)
    }

    /// `true` when this command can be invoked via the pure
    /// `ScriptVerb.apply` path (and thus by the palette headlessly).
    public var isPaletteInvokable: Bool { scriptVerb != nil }

    /// `true` when this command may be captured into / replayed from a macro
    /// (TSK-957). A convenience over `replayability == .replayable`.
    public var isMacroReplayable: Bool { replayability == .replayable }
}

/// The one canonical catalog of every user action.
///
/// Populated from three existing surfaces, deduplicated into a single
/// list:
///   1. The `ScriptVerb` vocabulary (`ScriptVerbDispatch.swift`) — the
///      bulk of the action surface; these all become palette-invokable.
///   2. The menu commands (`main.swift` `buildMenu`) — their default
///      shortcuts are mirrored here so the menu can resolve its key
///      equivalent from the registry instead of hard-coding it.
///   3. The recents-finder commands the palette already had.
///
/// `CommandRegistry` is the *built-in* catalog plus, once
/// `applying(overrides:)` is called, the user's keybinding overrides.
/// Both are pure value computations — no I/O happens in this type;
/// loading the JSON is `KeybindingConfig`'s job, and the registry merely
/// folds the parsed overrides over its defaults.
public struct CommandRegistry: Sendable {

    /// All commands, in a stable order (category, then declaration).
    public let commands: [CommandDescriptor]

    /// Index by id for O(1) lookup + override application.
    private let byID: [String: Int]

    public init(commands: [CommandDescriptor]) {
        self.commands = commands
        var idx: [String: Int] = [:]
        idx.reserveCapacity(commands.count)
        for (i, c) in commands.enumerated() { idx[c.id] = i }
        self.byID = idx
    }

    public func command(id: String) -> CommandDescriptor? {
        byID[id].map { commands[$0] }
    }

    /// Commands the palette can actually invoke today (have a script
    /// verb). The palette lists ALL commands but only these dispatch; the
    /// rest are surfaced as menu-only.
    public var paletteInvokable: [CommandDescriptor] {
        commands.filter(\.isPaletteInvokable)
    }

    // MARK: - Override merge

    /// Return a new registry where each command's `defaultShortcut` is
    /// replaced by the user override when one exists for its id.
    ///
    /// Precedence: **user > default** — an entry in `keybinding.json`
    /// always wins over the built-in. An override id that matches no
    /// known command is ignored (the caller logs it). This is a pure fold
    /// — call it once with the parsed `KeybindingConfig.bindings`.
    public func applying(overrides: [String: Shortcut]) -> CommandRegistry {
        guard !overrides.isEmpty else { return self }
        let merged = commands.map { cmd -> CommandDescriptor in
            guard let override = overrides[cmd.id] else { return cmd }
            return CommandDescriptor(
                id: cmd.id,
                title: cmd.title,
                category: cmd.category,
                defaultShortcut: override,
                scriptVerb: cmd.scriptVerb,
                replayability: cmd.replayability
            )
        }
        return CommandRegistry(commands: merged)
    }

    /// The effective shortcut → command-id map after a merge, with
    /// last-wins conflict resolution. If two commands resolve to the same
    /// keystroke, the LATER one in declaration order keeps it and the
    /// collision is reported via `onConflict` (the caller logs it). This
    /// is what the key-handling layer consults to route a keystroke.
    public func shortcutMap(
        onConflict: (_ shortcut: Shortcut, _ losingID: String, _ winningID: String) -> Void = { _, _, _ in }
    ) -> [Shortcut: String] {
        var map: [Shortcut: String] = [:]
        for cmd in commands {
            guard let sc = cmd.defaultShortcut else { continue }
            if let prior = map[sc] {
                onConflict(sc, prior, cmd.id)
            }
            map[sc] = cmd.id  // last-wins
        }
        return map
    }
}
