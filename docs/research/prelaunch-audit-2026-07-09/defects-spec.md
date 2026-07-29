# Pre-Launch Product Review — Spec / Behavior Mismatches

**Dimension:** Where docs, code comments, UI text, or menu labels promise behavior the code does not deliver (and vice versa).
**Repo:** `/Users/me/Documents/workspaces/claude/markdown_viewer`
**Date:** 2026-07-10
**Reviewer:** automated static review (read-only)

---

## Executive summary

The codebase is unusually disciplined about honesty: almost no `TODO`/`FIXME` in
shipping Swift, a self-checking test that keeps the MCP script-verb catalog and its
dispatch switch in sync, and a shipped `CAPABILITIES.md` Help page that candidly marks
features `⚠️ backend built but not surfaced`. Most user-facing capability claims I
spot-verified were **accurate** (URL-scheme routes, LSP idle-reap timing, `--script`
verb list, vim-mode-in-bundle, capabilities-doc bundling).

The real defects in this dimension cluster around **keyboard shortcuts** and **one
dead menu item**:

1. **Three keyboard-shortcut chords are double-bound** (`⌥⌘F`, `⌥⌘[`, `⌥⌘]`). Each
   chord is advertised on two different menu items; the app's two dispatch paths
   (AppKit `performKeyEquivalent` menu-order vs. the registry's *last-wins*
   `shortcutMap`) resolve the same chord to **opposite commands**. At least one menu
   label is a lie in every case; for `⌥⌘[` / `⌥⌘]` both commands are commonly enabled
   at once, so the key actively does the wrong thing. **[P2]**
2. **`Help ▸ TextView Help` (⌘?) has no help book** — no `CFBundleHelpBookName` in
   `Info.plist`, no `.help` bundle in Resources → macOS shows the system
   *"Help isn't available for TextView"* alert. **[P2]**
3. **`MacroRecordingChip` tooltip tells the user `⌘K` replays a macro** — `⌘K` is
   unbound app-wide (a code comment even says so); Replay Last Macro carries no
   shortcut. **[P3]**
4. **The shipped `CAPABILITIES.md` Help page understates the app** — it still lists
   *Find References* as `⚠️ no results-panel UI yet`, but that feature was surfaced
   (Navigate menu + palette + a real results panel). **[P3]**

Net: 4 findings. No P0/P1 — nothing here causes data loss or a crash, but the
shortcut collisions are table-stakes UX polish a native Mac app is expected to get
right, and the Help-menu dead-end is a first-thing-a-user-clicks miss.

---

## Methodology

**What I examined (static analysis, read-only):**

- **Menu + shortcut layer:** `Sources/MarkdownViewer/main.swift` (4,435 LOC — the full
  `NSMenu` construction), `Sources/ViewerCore/Commands/CommandRegistry+BuiltIn.swift`
  (the `defaultShortcut` source of truth), `Sources/ViewerCore/Commands/Shortcut.swift`,
  and the `applyShortcut(_:to:)` bridge. Cross-checked every duplicated `keyEquivalent`
  / `defaultShortcut`.
- **UI text / tooltips:** grepped `.help(...)` strings across `Sources/ViewerUI`,
  `SettingsView.swift` help captions, `MacroRecordingChip.swift`, walkthrough player
  labels; verified each cited shortcut against the actual binding.
- **Shipped docs vs. code:** `docs/CAPABILITIES.md` (bundled into the app as the
  `Help ▸ Capabilities` page) — diffed its `✅ / ⚠️ / 📐` claims against the registry,
  the `--script` runner (`Sources/MarkdownViewer/ScriptRunner.swift`), the MCP verb
  catalog (`ScriptVerbCatalog.swift`), and the URL router (`URLSchemeRouter.swift`).
- **Bundle metadata:** `scripts/Info.plist` + `scripts/build-app.sh` (help-book keys,
  URL schemes, capabilities-doc copy step).
- **Conflict guards:** `Tests/ViewerCoreTests/CommandRegistryTests.swift` (the existing
  `shortcutMap` last-wins / conflict tests) to understand what is *and isn't* guarded.

**How much:** targeted, evidence-driven. Every finding below is reproducible from a
`grep`/`sed` on the cited lines. I did **not** run the app or any UI test (constraint),
so the AppKit-vs-registry dispatch resolution is reasoned from the code paths, not
observed on screen — flagged where it matters.

---

## Findings

### 1. Three keyboard-shortcut chords are double-bound; menu labels advertise a shortcut the app resolves to a *different* command — **[P2]**

**Files:**
- `Sources/ViewerCore/Commands/CommandRegistry+BuiltIn.swift:158-166, 198-200, 360-361, 396-403`
- `Sources/MarkdownViewer/main.swift:1553-1567 (Move Tab L/R), 2208-2227 (Fold/Unfold All), 2305-2311 (Pretty-Print), 2609-2614 (Find and Replace)`
- `Tests/ViewerCoreTests/CommandRegistryTests.swift:397-419` (documents the last-wins behavior)

**Evidence — three chords, each on two commands:**

| Chord  | Command A (declared first)                  | Command B (declared later)                   |
|--------|---------------------------------------------|----------------------------------------------|
| `⌥⌘F`  | `view.prettyPrint` "Pretty-Print" (line 198)| `find.replace` "Find and Replace…" (line 360)|
| `⌥⌘[`  | `view.foldAll` "Fold All" (line 158)        | `tabs.moveLeft` "Move Tab Left" (line 396)   |
| `⌥⌘]`  | `view.unfoldAll` "Unfold All" (line 165)    | `tabs.moveRight` "Move Tab Right" (line 403) |

A `grep` for duplicate `defaultShortcut` values returns **exactly** these three
(`⌥⌘F`, `⌥⌘[`, `⌥⌘]` each appear twice; everything else is unique). Each of the six
commands binds its chord onto a real `NSMenuItem`: Fold/Unfold/Pretty-Print via
`applyShortcut("view.foldAll" / "view.unfoldAll" / "view.prettyPrint", to:)`
(main.swift:2218/2227/2311), Move Tab L/R and Find-and-Replace via explicit
`keyEquivalentModifierMask = [.command, .option]` (main.swift:1557/1565/2614).

**Why it's a real mismatch (two dispatch paths disagree):**

- The registry's `shortcutMap` is **last-wins** (`CommandRegistryTests.swift:397`
  `test_shortcutMap_reportsConflict_lastWins` proves the later-declared command takes
  the map entry and the earlier one is silently overridden). So the registry resolves
  `⌥⌘F → find.replace`, `⌥⌘[ → tabs.moveLeft`, `⌥⌘] → tabs.moveRight`.
- AppKit `performKeyEquivalent:` traverses menus in **menu-bar order** (App, File,
  Edit, View, Session, Window, Help) and fires the *first enabled* match. View comes
  before Window, so `⌥⌘[` → **Fold All** wins there; but Edit's Find submenu comes
  before View, so `⌥⌘F` → **Find and Replace** wins.
- These two resolutions are **opposite** for `⌥⌘[` / `⌥⌘]` (registry says Move-Tab,
  AppKit says Fold). Whichever path handles the keystroke for the focused surface,
  the *other* menu item is displaying a shortcut that does nothing — or does the
  wrong thing.

**Impact:** The `⌥⌘[` / `⌥⌘]` pair is the worst: Fold All is enabled "in any FOLDABLE
lens" (main.swift:2208 comment) and Move Tab Left/Right is enabled whenever ≥2 tabs
are open — a code file with folds in a multi-tab window has **both** enabled, so
`⌥⌘[` is ambiguous and a user reaching for "fold everything" may instead reorder their
tabs. `⌥⌘F` is a HIG-standard chord users expect for Find-and-Replace, yet the View
menu also stamps it on Pretty-Print. The existing conflict test only *reports* the
collision; the *guarded* set (`test_dailyDriverCommands_carryConflictFreeShortcuts`,
`test_addedDefaultShortcuts_arePresentAndConflictFree`) covers Check-Links / Align /
Insert-TOC / Copy-Reference / git-history — **not** Fold/Unfold/Pretty-Print, so these
three slipped through.

**Suggested fix:** Give each command a distinct chord (e.g. Fold/Unfold All → `⌥⌘-` /
`⌥⌘=` or `⇧⌘[` / `⇧⌘]`; Pretty-Print → `⌃⌥⌘F` or move off the Find namespace), OR make
the `shortcutMap` builder **fail the test on any duplicate** (extend the guard to
assert zero conflicts across the whole registry) so the collision can't ship. The
latter is the durable fix — it converts every future duplicate into a red gate.

**Fix size:** S (pick new chords) · **Fix risk:** careful (changing a shipped keybinding
is a muscle-memory contract; the registry comment at line 197 calls `view.prettyPrint`
"a shipped keybinding contract" — coordinate with whatever the Keyboard-Shortcuts help
window, TSK-678, advertises).

---

### 2. `Help ▸ TextView Help` (⌘?) opens nothing — no help book is bundled — **[P2]**

**Files:**
- `Sources/MarkdownViewer/main.swift:2838-2843` (`title: "TextView Help"`,
  `action: #selector(NSApplication.showHelp(_:))`, `keyEquivalent: "?"`)
- `scripts/Info.plist` (no `CFBundleHelpBookName` / `CFBundleHelpBookFolder`)
- `scripts/build-app.sh` (no `.help` bundle copied into `Contents/Resources`)

**Evidence:** The menu item's action is the stock `NSApplication.showHelp(_:)`, which
asks `NSHelpManager` to open the app's registered help book. But:
- `grep '<key>' scripts/Info.plist` lists every key — there is **no**
  `CFBundleHelpBookName` and no `CFBundleHelpBookFolder`.
- `find Sources -iname '*.help' -o -iname '*.helpindex'` → nothing.
- No custom `showHelp(_:)` override anywhere (`grep -rn "showHelp" Sources` → only the
  `#selector` line above).

With no registered help book, `showHelp(_:)` triggers the macOS system alert
**"Help isn't available for TextView."**

**Impact:** The first, most discoverable help affordance (⌘? and the standard Help
menu) dead-ends with a system error. Every other Help-menu item is real (Keyboard
Shortcuts, Open Sample Document, Capabilities, Install CLI), which makes the broken one
stand out more, not less. HIG expects Help to work.

**Suggested fix:** Cheapest correct fix — repoint the item to the existing rendered
Help content the app already ships: reuse `openCapabilities(_:)` (main.swift:3894, which
opens the bundled `CAPABILITIES.md`) as "TextView Help", or open the Sample Document.
Alternatively author a minimal `.help` bundle + add `CFBundleHelpBookName`. Do **not**
leave the stock `showHelp:` wired with no book.

**Fix size:** S · **Fix risk:** safe.

---

### 3. `MacroRecordingChip` tooltip tells the user `⌘K` replays a macro; `⌘K` is unbound — **[P3]**

**Files:**
- `Sources/ViewerUI/MacroRecordingChip.swift:22` — tooltip:
  *"…Run "Stop Recording Macro" to finish, then "Replay Last Macro" to play it back (⌘K)."*
- `Sources/ViewerCore/Commands/CommandRegistry+BuiltIn.swift:333-335` — `macro.replayLast`
  has **no** `defaultShortcut`.
- `Sources/ViewerCore/Commands/CommandRegistry+BuiltIn.swift:522-524` — the *only*
  `key: "k"` binding is `file.checkLinks` at `⇧⌘K`; its comment literally states
  *"k is unbound app-wide"*.
- `Sources/MarkdownViewer/main.swift:2446-2449` — the sole `⌘…K` menu item is Check
  Links, explicitly masked to `⇧⌘K`. Plain `⌘K` is bound to nothing (grep for
  `keyboardShortcut("k"` / `keyEquivalent: "k"` returns only that `⇧⌘K` item).

**Evidence:** `macro.replayLast` carries only a `scriptVerb` (`macro-replay-last`) — no
shortcut. There is no `⌘K` anywhere in the menu tree or SwiftUI `keyboardShortcut`
modifiers. So the tooltip's "(⌘K)" is simply wrong: pressing `⌘K` does nothing, and the
user must run "Replay Last Macro" from the palette/menu.

**Impact:** Low blast radius (only visible while a macro is recording, in a small chip
tooltip), but it's a direct false instruction — a user follows it and the key does
nothing.

**Suggested fix:** Either (a) drop "(⌘K)" from the tooltip, or (b) actually bind
`macro.replayLast` to a free chord (⌘K is available per the registry's own comment) and
update the menu/help window to match. (b) is the better product outcome since replay is
a hot loop.

**Fix size:** S · **Fix risk:** safe.

---

### 4. Shipped `CAPABILITIES.md` Help page understates the app: *Find References* is marked "no results-panel UI yet" but is fully surfaced — **[P3]**

**Files:**
- `docs/CAPABILITIES.md:112` — table row: *"**Find References** | backend exists, no
  results-panel UI yet (use ⌘⇧F cross-search meanwhile) | ⚠️"* (this file is bundled
  into the app as the `Help ▸ Capabilities` page — `scripts/build-app.sh:253-258`).
- Contradicting code:
  - `Sources/MarkdownViewer/main.swift:2900-2908` — TSK-950 added a **Navigate ▸ Find
    References** menu item + palette command (`lsp.findReferences`).
  - `Sources/ViewerUI/DocumentModel+LSPEditorCommands.swift:21-46` —
    `findReferencesAtCursor()` populates the `lspNavigation` store (a real multi-result
    references panel — "the SAME store the source-view hover menu's Find References
    populates").
  - `CommandRegistry+BuiltIn.swift:443-444` — `lsp.findReferences` is a first-class
    command.

**Evidence:** The doc claims the feature has no surfaced UI and steers users to ⌘⇧F
cross-search as a workaround, yet the results panel, the Navigate menu entry, and the
palette command all exist. The `⚠️` legend ("backend built but not surfaced") is stale
for this row.

**Impact:** A shipped Help page that *understates* capability — a user who reads it
won't discover a working feature and will fall back to a worse workaround. Lower harm
than overstating (no broken promise, just a hidden feature), hence P3, but it's a
user-facing doc inaccuracy in the bundle.

**Suggested fix:** Update the `CAPABILITIES.md` row to `✅` and describe the Navigate ▸
Find References flow + the references panel. While there, re-audit the other `⚠️` rows
(e.g. Workspace Symbols, line 113) against current code so the shipped Help page
reflects reality at launch.

**Fix size:** S · **Fix risk:** safe.

---

## Positive observations

Verified claims that **do** match behavior (good hygiene worth noting):

- **URL scheme is honest.** `CAPABILITIES.md` advertises
  `markdownviewer://open|search|walkthrough|session`; `Info.plist` registers both
  `textview` and `markdownviewer` schemes, and `URLSchemeRouter.route(_:)`
  (`URLSchemeRouter.swift:39-60`) implements every advertised host.
- **`--script` verb list is accurate.** Every verb the doc lists (`find`, `ui-click`,
  `resize`, `goto-line`, `zoom-*`, `select-tab`, `snapshot`, …) is handled in
  `ScriptRunner.swift` (`case "find"`, `case "ui-click"`, `case "resize"`, etc.).
- **MCP verb catalog can't drift.** `ScriptVerbCatalog.swift` carries a self-check
  contract asserting the catalog set equals the dispatch switch's `case` labels, so a
  documented-but-unhandled MCP verb is a compile/test failure by construction.
- **LSP idle-reap claim is exact.** SettingsView says servers "reap after 5 minutes
  idle"; `LSPPool` default `idleTimeout = .seconds(5 * 60)` (LSPPool.swift:34).
- **Vim mode really is in the bundle.** Settings/View menu offer Vim Mode; the
  `codemirror.js` bundle exports `vim:()=>JX`, so the `"vim mode unavailable in this
  codemirror.js bundle"` error path (codemirror.html:734) is unreachable dead-code, not
  a broken promise.
- **`Reset window state` help text is accurate.** It claims to reset zoom, sidebar
  width, and window position; `PreferencesStore.resetWindowState()` clears exactly
  those three keys (+ AppKit's frame autosave).
- **Capabilities doc is bundled with an embedded fallback**, so `Help ▸ Capabilities`
  never shows an empty page (`CapabilitiesDocument.swift`, `build-app.sh:253-258`).

---

## Coverage gaps (what I did NOT examine)

- **Runtime resolution of the shortcut collisions.** I reasoned the AppKit-vs-registry
  divergence from code paths; I did not run the app to observe which command actually
  fires for `⌥⌘[` in each focus context (constraint: no UI/window tests). The
  *collision* is certain; the exact per-context winner is inferred.
- **The full `CAPABILITIES.md` ✅/⚠️/📐 matrix.** I diffed a sample (URL scheme, script
  verbs, MCP, Find References). I did not verify every one of the ~40 rows — other
  `⚠️`/`📐` rows may likewise be stale in either direction.
- **Deep semantic claims in doc-comments across the ~88K-LOC ViewerCore engine layer.**
  I targeted user-facing surfaces (menus, tooltips, settings, the shipped Help doc);
  I did not exhaustively read every engine doc-comment for "comment says X, code does Y"
  at the algorithm level (that overlaps the correctness dimension more than the
  spec/label dimension).
- **Rust-core crate doc-comments** (`rust-core/crates/*`) vs. FFI behavior — out of
  scope for a user-facing spec/label lens; the FFI seam is its own review unit.
- **Uncommitted in-flight work.** `MCPSocketBridge.swift` / `main.swift` show as
  modified in `git status` and a new bridge-launch-order test is untracked; I reviewed
  committed behavior and did not audit the in-progress diff.
- **Localization / i18n string mismatches** — all UI strings are English literals; no
  localization layer to cross-check.
