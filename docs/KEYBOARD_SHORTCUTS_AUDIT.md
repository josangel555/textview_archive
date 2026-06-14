# Keyboard-shortcut audit (TSK-757) — 2026-06-14

Catalog of the app's default keyboard shortcuts vs. the macOS / VS Code / Xcode
conventions, plus the gaps. Source of truth: `Sources/ViewerCore/Commands/
CommandRegistry+BuiltIn.swift` (the `defaultShortcut` on each `CommandDescriptor`;
the in-app **Help ▸ Keyboard Shortcuts** reference renders the live, override-aware
view). The registry is the single place to add a binding — `applyShortcut(id, to:)`
in `main.swift` pulls it onto the matching menu item automatically.

## Current bindings (by category)

| Command | Chord | Standard it matches |
|---|---|---|
| New Tab | ⌘T | macOS standard |
| Open… | ⌘O | macOS standard |
| Open Folder… | ⇧⌘O | — (VS Code uses ⌘O for both) |
| Go to File or Folder… | ⇧⌘G | VS Code ⌘P-ish / Sublime ⌘P |
| Close Tab | ⌘W | macOS standard |
| Save | ⌘S | macOS standard |
| Reload | ⌘R | browser standard |
| Toggle Rendered / Source | ⇧⌘R | app-specific |
| Toggle Sidebar | ⌃⌘S | (VS Code ⌘B — see gaps) |
| Wrap Long Lines | ⌥⌘W | app-specific |
| Show Invisibles | ⌥⌘I | app-specific |
| Fold All / Unfold All | ⌥⌘[ / ⌥⌘] | (VS Code ⌘K ⌘0 / ⌘K ⌘J) |
| Go to Line… | ⌘L | VS Code ⌃G / Xcode ⌘L ✓ |
| Quick Open (palette) | ⌘K | app palette |
| Command Palette | ⇧⌘P | VS Code ✓ (TSK-720) |
| Zoom In / Out / Actual Size | ⌘= / ⌘- / ⌘0 | macOS standard |
| Pretty-Print (format-as-view) | ⌥⌘F | app-specific |
| Apply jq Filter… | ⌥⌘J | app-specific |
| Bookmark / Bookmark Line | ⌘D / ⌥⌘D | app-specific |
| Toggle Split / Swap Split | ⌘\ / ⇧⌘\ | app-specific |
| Toggle Folder Stats | ⌃⌘I | app-specific |
| Undo / Redo | ⌘Z / ⇧⌘Z | macOS standard |
| Find | ⌘F | macOS standard |
| Find and Replace | ⌥⌘F | (VS Code ⌥⌘F ✓) |
| Find in Folder | ⇧⌘F | VS Code ✓ |
| Find Next / Previous | ⌘G / ⌥⌘G | macOS standard |
| Next / Previous Tab | ⇧⌘] / ⇧⌘[ | Safari/Terminal ✓ (TSK-328) |
| Move Tab Left / Right | ⌥⌘[ / ⌥⌘] | app-specific (mode-disambiguated vs Fold All) |
| **Format Document** | **⇧⌥F** | **VS Code ✓ (TSK-757, this change)** |
| Show Git Panel / File History / Repo History | ⌥⇧⌘B / ⌥⇧⌘H / ⌥⇧⌘L | app-specific |
| New Session | ⇧⌘N | app-specific |
| Next / Previous Session | ⌃Tab / ⌃⇧Tab | browser tab-group standard |
| Close Session | ⇧⌘W | macOS window-close-ish |
| Minimize | ⌘M | macOS standard |

## Gap-filled this pass

- **Format Document → ⇧⌥F** — VS Code's universal "Format Document" chord. `⌥⌘F`
  was already Find-and-Replace; `⇧⌥F` is free and is exactly what VS Code-for-Mac
  binds, so muscle memory transfers. Auto-wired to the Edit-menu item via the
  registry (`applyShortcut("lsp.format", …)`). Test:
  `CommandRegistryTests.test_formatDocument_shiftOptF_routesToLspFormat_noCollision`.

## Candidate gaps — left for an owner pick (cross-app divergent / conflicting)

These commands have NO default chord and a *plausible* standard, but the standard
differs across apps OR the obvious chord is taken — so they're a taste/preference
call, not an unambiguous fill. Listed for the owner to choose; not imposed.

| Command | VS Code | Xcode | Note |
|---|---|---|---|
| Go to Definition (`lsp.gotoDefinition`) | F12 | ⌃⌘J | Diverges; ⌘-click + Navigate menu already work. F-key vs ⌃⌘J is a preference. |
| Rename Symbol (`lsp.rename`) | F2 | — | **F2 is already the sidebar file-rename** (TSK-283) → conflict. Needs a different chord (e.g. ⌥⌘R? — taste). |
| Code Actions (`lsp.codeActions`) | ⌘. | — | ⌘. is the old macOS *Cancel* convention; overriding it is a judgment call. |
| Toggle Sidebar (`view.toggleSidebar`) | ⌘B | — | App already binds ⌃⌘S; VS Code users expect ⌘B. Rebinding established UX = owner call. |
| Toggle Comment | ⌘/ | ⌘/ | No comment-toggle command exists yet (CM6 feature un-surfaced); file the command first. |

## Method / how to extend

- Add `defaultShortcut:` to the `CommandDescriptor` in `CommandRegistry+BuiltIn.swift`.
  The Edit/View/etc. menu item picks it up via `applyShortcut(id, to:)` — no menu
  edit needed for commands already wired that way.
- Pin it with a test in `CommandRegistryTests` asserting `shortcutMap()[chord] == id`
  (proves no later command stole the keystroke via last-wins).
- Conflicts are surfaced by `shortcutMap`'s collision callback; keep new chords off
  the table above.
