# Keybindings & the Command Registry (UX-M / #232, action catalog / #223)

TextView keeps **one canonical catalog** of every user action — the
`CommandRegistry` (`Sources/ViewerCore/Commands/`). Each action has a
stable id, a human title, a category, a built-in default shortcut, and
(where one exists) the pure script-verb it dispatches through. The
command palette lists this catalog; the menu bar resolves its shortcuts
from it; and the user can override any shortcut via
`~/.textview/keybinding.json`.

## Files

| File | Role |
|------|------|
| `Sources/ViewerCore/Commands/Shortcut.swift` | `Shortcut` value type + `"cmd+shift+f"` string parser. Pure, no AppKit. |
| `Sources/ViewerCore/Commands/CommandRegistry.swift` | `CommandDescriptor`, `CommandRegistry`, override merge + conflict resolution. |
| `Sources/ViewerCore/Commands/CommandRegistry+BuiltIn.swift` | THE canonical built-in command list. |
| `Sources/ViewerCore/Commands/KeybindingConfig.swift` | Loader + parser for `~/.textview/keybinding.json`. Totally safe (never throws/crashes). |

## Config location

`~/.textview/keybinding.json`

The `~/.textview/` directory is created on launch if it doesn't exist.
If the file is absent, TextView uses the built-in defaults — no error.

## Schema

A flat JSON object mapping **command id → shortcut string**:

```json
{
  "view.toggleSidebar": "cmd+shift+e",
  "view.quickOpen":     "cmd+p",
  "file.save":          "cmd+s",
  "find.inFolder":      "cmd+shift+f",
  "tabs.next":          "ctrl+tab",
  "session.next":       "cmd+alt+right"
}
```

- **Keys** are `CommandDescriptor.id` values (the dot-namespaced ids in
  `CommandRegistry+BuiltIn.swift`, e.g. `view.toggleSidebar`,
  `file.save`). An unknown id is parsed but has no effect (there's no
  command to bind) — it's logged and ignored.
- **Values** are shortcut strings: zero or more `+`-joined modifiers
  followed by a base key.
  - Modifier tokens (case-insensitive, aliases accepted):
    `cmd` / `command` / `meta`, `shift`, `alt` / `opt` / `option`,
    `ctrl` / `control`.
  - Base key: a single character (`f`, `=`, `0`, …) **or** a symbolic
    name: `left`, `right`, `up`, `down`, `tab`, `space`, `escape`,
    `return`, `delete`, `backslash`, `home`, `end`, `pageup`, `pagedown`.
  - Literal `+` as a base key is written `cmd++`.
  - Examples: `"cmd+s"`, `"cmd+shift+f"`, `"alt+cmd+left"`, `"ctrl+tab"`,
    `"cmd+backslash"`.

## Precedence

**User > default.** Any binding in `keybinding.json` *replaces* the
built-in `defaultShortcut` for that command. It is total replacement, not
addition — to rebind a command, set its value to the new keystroke.

## Conflicts

If two commands resolve to the same keystroke (whether a built-in
collision or one introduced by an override), the effective shortcut map
is **last-wins**: the command later in catalog declaration order keeps
the key. The shadowed binding is reported via
`CommandRegistry.shortcutMap(onConflict:)` and logged through the
observability sink (visible in the Logs view / stderr, subsystem
`keybinding`).

Note that a few built-in defaults already collide by design and are
disambiguated at runtime by the AppKit responder chain / current view
mode rather than by the registry — e.g. `view.foldAll` (`⌥⌘[`) vs
`tabs.moveLeft` (`⌥⌘[`): fold-all is only enabled in editor mode, move-
tab only when multiple tabs exist.

## Robustness

`KeybindingConfig.load(directory:)` is total — it never throws to the
caller and never crashes:

| Situation | Result |
|-----------|--------|
| `~/.textview/` missing | created (best-effort); defaults used |
| `keybinding.json` missing | defaults used (the common case) |
| File unreadable | defaults used |
| Top-level JSON not an object of strings | whole file ignored, defaults used, warning logged |
| One value fails to parse | that entry dropped, others applied, warning logged |
| One key is an unknown command id | that entry dropped, others applied, warning logged |

## Palette invocation

The command palette (`⌘K`) is a dual-mode finder:

- **File mode** (default): type a filename to fuzzy-search recents +
  bookmarks (unchanged behaviour).
- **Command mode**: prefix the query with `>` (VS Code convention) to
  list **every** registered command, fuzzy-filtered by title, each
  showing its category and effective shortcut. `↵` runs the selected
  command.

Commands invoke through `DocumentModel.invokeCommand(id:)`, which routes
to `ScriptVerb.apply(verb:to:sessions:)` — the same pure, headless-tested
dispatch surface the `--script` runner and the in-process test harness
use. Commands whose `scriptVerb` is `nil` (still window/`NSApp`-coupled)
render dimmed and non-actionable in the palette and remain menu-only —
see the GAP list below.

## GAP list — commands not yet palette-invokable

These are in the catalog (so the palette lists them and the menu can
resolve their shortcut) but have `scriptVerb == nil` because they depend
on a real window, `NSApp`, an `NSOpenPanel`, or a modal that the pure
`(model, sessions)` dispatch surface can't drive yet:

- `file.open`, `file.openFolder` — `NSOpenPanel`.
- `file.reload`, `file.clearRecents` — AppDelegate-coupled (reload reads
  the live file; clearRecents shows a confirm `NSAlert`).
- `view.toggleWordWrap`, `view.toggleInvisibles` — model toggles exist
  but no script verb yet; trivial to add (`toggle-word-wrap`,
  `toggle-invisibles`).
- `view.foldAll`, `view.unfoldAll`, `view.goToLine` — drive the live
  CodeMirror WebView / show an `NSAlert`.
- `view.applyJQ` — `NSAlert` prompt + jq subprocess.
- `view.toggleLineBookmark` — needs the live editor cursor line.
- `view.toggleSplit`, `view.swapSplit` — model methods exist; no verb
  yet (easy add).
- `edit.undo`, `edit.redo`, `find.find`, `find.replace` — responder-
  chain / mode-routing coupled (the `⌘F` router picks bar by view mode).
- `tabs.moveLeft`, `tabs.moveRight` — model methods exist; no verb yet.
- `git.showPanel`, `git.fileHistory`, `git.repoHistory` — model methods
  exist; no verb yet (would be `show-git-panel <tab>`, `file-history`
  already exists as a verb — `git.fileHistory` could be wired).
- `session.new` — `NSOpenPanel`.
- `window.minimize`, `window.zoom` — `NSWindow` actions.
- `debug.diagnosticWindow`, `debug.instrumentation` — gated tool windows.

The straightforward next step is to add the missing pure verbs
(`toggle-word-wrap`, `toggle-invisibles`, `toggle-split`, `swap-split`,
`move-tab-left`/`-right`, `show-git-panel`) to `ScriptVerbDispatch.swift`
and point these descriptors at them; the genuinely window/panel-coupled
ones stay menu-only.
```
