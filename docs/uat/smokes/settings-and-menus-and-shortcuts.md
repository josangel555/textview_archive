# UAT smokes — Settings, Menus & Keyboard Shortcuts

**Area:** `settings-and-menus-and-shortcuts`
**App under test:** `dist/TextView.app` (Finder name TextView.app; bundle id `com.markdownviewer.MarkdownViewer`)
**Tier:** T4 live-app (`LiveAppTestCase`) — these drive the real `NSMenu` bar, the global key-equivalent table, and the Settings `NSWindow`, so they must run on a GUI session (VM lane), not the headless merge gate. (Menu *validation* / relabel logic is also reachable model-level for a cheaper headless proxy, but the accelerator routing and `validateMenuItem` enable/grey-out only fire against a live menu bar + responder chain.)

## Scope

Durable, realistic user flows over the app-shell command surface:

```
Menu bar (HIG order):
  App (TextView) │ File │ Edit │ View │ Session │ Window │ Help │ [Debug — gated]
        └ ⌘,        └ ⌘T/⌘O   └ ⌘Z/⌘F   └ ⇧⌘R/⌃⌘S  └ ⇧⌘N    └ ⌘M/⌘1-9

Settings window (⌘, → single scrollable page, 460×540, deduped):
  Appearance (Theme · unified Zoom slider 50–300%)
  Editor      (Wrap · Show Invisibles · Indentation 2/4 spaces|Tabs 2/4/8)
  Sidebar     (Show-by-default · Width 160–480)
  Privacy     (Full Disk Access deep-link)
  Plugins     (Manage… · Open Log)
  Language servers (Open Diagnostics…)
  Advanced    (Clear All bookmarks [destructive] · Reset window state)
```

Cross-cutting invariants every smoke implicitly guards:
- **Dynamic validation:** `validateMenuItem` greys/relabels items per current state on every `menuNeedsUpdate` — *Show Rendered* ⇄ *Show Source*, *Bookmark This* ⇄ *Remove Bookmark*, Save enabled only on a dirty **editor** tab, Fold/Unfold/Go-to-Line only in editor mode, Pretty-Print only when a formatter is registered, jq only for JSON.
- **Settings dedup:** ⌘, opens **or re-focuses** the single reused window (`SettingsWindowController`) — never a second copy.
- **Settings ↔ model two-way binding:** Theme / Zoom / Wrap / Invisibles / Indentation / Sidebar-width changes apply **live** to the document window, and the menu checkmarks/labels reflect them.
- **Accelerator routing by context:** Find… routes to the rendered/editor/source find bar by view mode; ⌘Z/⇧⌘Z route into CM6 JS undo/redo **only** when an editor is mounted+focused, else fall through to the responder chain; ⌘W closes a tab when >1, falls through to `performClose` at the last tab.

## Conventions for steps

- **Script-verbs** below refer to the `--script` verb dispatcher and MCP tools (`open_path`, `select_tab`, `set_view_mode`, `current_state`, `toggle_bookmark`, `snapshot_window`); plain UI actions name the menu path / keyboard chord / the a11y id. **Window/NSApp-coupled verbs return false in the headless model dispatch** — exercise them on the live app.
- Shortcuts and labels below are verified against `Sources/MarkdownViewer/main.swift` (the `NSMenuItem` / `keyEquivalent` / `keyEquivalentModifierMask` wiring + `validateMenuItem`) and the Settings sections in `Sources/ViewerUI/SettingsView.swift`.
- "Fixtures" = files created under `FileManager.default.temporaryDirectory` (per-user `/var/folders/...`). **Never** write fixtures under `~/Documents`, `~/Desktop`, `~/Downloads` — and Settings *itself* writes `UserDefaults`, so each smoke that mutates prefs must record and restore (or run with a throwaway defaults domain).

---

## SC-MENU-01 — Dynamic menu validation: labels & enable-state track the active tab's type and view mode

**Combines:** Menu-bar `validateMenuItem` relabel/grey logic, View menu (Show Rendered/Source toggle ⇧⌘R, Pretty-Print ⌥⌘F, jq ⌥⌘J, Fold/Unfold ⌥⌘[ /⌥⌘], Go to Line ⌘L), Edit ▸ Save (⌘S editor-dirty gating), Edit ▸ Bookmark (⌘D relabel), ModeBar view-mode routing, CodeMirror editor dirty-state.

**Preconditions**
- TextView.app launched clean (`MDV_SKIP_WORKSPACE_RESTORE=1`).
- Fixtures in a temp dir: `a.md` (markdown), `data.json` (json), `note.txt` (plain text), `pic.png` (image binary).

**Steps**

| # | Action / script-verb | Expected result |
|---|---|---|
| 1 | `open_path a.md` (markdown, Rendered) | **View** menu: *Show Rendered/Source* toggle item reads **"Show Source"** (we're in Rendered) and is **enabled** (`supportsViewModeToggle`). *Pretty-Print* is **disabled** (no formatter for md). *Apply jq Filter…* is **disabled**. *Fold All / Unfold All / Go to Line…* are **disabled** (not editor mode). |
| 2 | ⇧⌘R | Toggles Rendered→Source; re-open the View menu → the toggle item now reads **"Show Rendered"**. |
| 3 | **Edit ▸ Save** state on `a.md` (any non-editor mode) | *Save* (⌘S) is **greyed/disabled** — Save only enables on a dirty **editor** tab. *Undo/Redo* fall through to the responder chain (no editor mounted). |
| 4 | `open_path data.json`; set ModeBar to **Source** | View menu: *Pretty-Print* (⌥⌘F) becomes **enabled** (JSON has a registered formatter) with an on/off checkmark. *Apply jq Filter…* (⌥⌘J) becomes **enabled** (current file is loaded JSON). |
| 5 | Toggle **Pretty-Print** (⌥⌘F or menu) | The view pretty-prints; re-open View menu → the *Pretty-Print* item carries a **checkmark** (`.on`). Toggle again → checkmark clears, raw source returns. |
| 6 | Switch `data.json` to **Editor** mode, type a character | The tab grows a dirty dot. **Edit ▸ Save** (⌘S) is now **enabled** (dirty editor tab). *Fold All* (⌥⌘[), *Unfold All* (⌥⌘]), *Go to Line…* (⌘L) all become **enabled** (editor mounted via `CodeMirrorEditorRegistry.current()`). *Undo* (⌘Z) now routes into CM6. |
| 7 | ⌘L (Go to Line) | A small inline **NSAlert** "Go to Line" prompt appears; entering a line number scrolls the editor to it. |
| 8 | ⌘D on `data.json` | **Edit ▸ Bookmark** item relabels to **"Remove Bookmark"** (it's now bookmarked); a yellow star appears on the tab. ⌘D again → label flips back to **"Bookmark This"**, star clears. |
| 9 | `open_path pic.png` (image) | **Bookmark** item: `bookmarkTargetURL` is the image URL so ⌘D is still enabled. *Save / Pretty-Print / jq / Fold / Go-to-Line / Show-Rendered* are all **disabled** (no editor, no formatter, no view-mode toggle for an image). |
| 10 | ⌘T to a blank tab (no `currentURL`) | Most **View**/**Edit** content items (Reload, Find, Pretty-Print, Bookmark, zoom-needs-tab) **grey out** — `hasFile`/`hasTab` guards. *Toggle Sidebar* (⌃⌘S) stays enabled (returns true unconditionally). |

**Expected end-state:** menu labels/checkmarks consistently mirror the focused tab; no item is enabled in a context where its action would no-op or crash.

**Variations / edge-states**
- **jq not installed:** with jq absent from `/usr/bin/jq` and `/opt/homebrew/bin/jq`, *Apply jq Filter…* still validates as enabled for JSON, but invoking it raises the **"jq is not installed"** NSAlert with a brew hint (validation is about file type, not binary presence).
- **Toggle-view scope:** *Show Rendered/Source* (⇧⌘R) is disabled for non-markdown/non-mermaid types (`supportsViewModeToggle` false) — confirm on `note.txt`.
- **Save accelerator gating:** with the editor tab **clean** (typed back to original / saved), *Save* greys again and the ⌘S accelerator is inert — matches Xcode/VS Code.
- **Sidebar checkmark:** *Toggle Sidebar* shows `.on`/`.off` reflecting `sidebar.isVisible`; toggling via ⌃⌘S flips the checkmark on next menu open.
- **Submenu lazy rebuild:** the *Open Recent*, *Window* per-tab, and *Jump to Session* submenus are rebuilt on `menuNeedsUpdate` — they reflect the live tab/session list each time they open.

---

## SC-MENU-02 — Open Recent + Window + per-tab number shortcuts + the documented shortcut collisions

**Combines:** File ▸ Open Recent (HistoryStore, Clear Recents confirm), Window menu per-tab list (⌘1-9 + checkmark, ⌥⌘→/← next/prev, ⌥⌘[ /⌥⌘] move tab), the **⌥⌘[ /⌥⌘] collision** (Move Tab vs Fold All), the **Find Previous ⌥⌘G** relocation (off ⇧⌘G, reserved for Go to Path), Tabs (TabBar), CLI/Finder Open Recent integration.

**Preconditions**
- Clean launch (`MDV_SKIP_WORKSPACE_RESTORE=1`).
- Fixtures: `one.md`, `two.json`, `three.txt`, `four.csv`, `five.py` in a temp dir.
- A history with at least a couple prior files (open + close them, or pre-seed `history.json`).

**Steps**

| # | Action / script-verb | Expected result |
|---|---|---|
| 1 | Open the **File ▸ Open Recent** submenu | Lists recent files (capped 20 in the menu) most-recent first, plus a **Clear** item. With *no* recents it shows the placeholder **"(no recent files)"** and **Clear** is disabled. |
| 2 | Pick a recent entry | The file opens; the sidebar root does **not** collapse all expansions (the historic `setRoot`-clears-expanded bug — re-opening the same folder via Open Recent must keep its tree). |
| 3 | **File ▸ Open Recent ▸ Clear** | A **Clear Recents** NSAlert confirm appears; confirming empties the list → next open of the submenu shows "(no recent files)". |
| 4 | Open `one.md … five.py` (5 tabs) | Tab strip has 5 tabs in open order. |
| 5 | Open the **Window** menu | One item per open tab (`one.md`…`five.py`); the active tab carries a **checkmark**. `⌘1-9` accelerators are shown on the first 9. |
| 6 | ⌘3 | Jumps directly to the 3rd tab (`three.txt`); window title + ModeBar + StatusBar track it. The Window-menu checkmark moves. |
| 7 | ⌥⌘→ / ⌥⌘← (also Ctrl+Tab / Ctrl+Shift+Tab) | Next/previous tab; selection advances/retreats and the checkmark follows. |
| 8 | **⌥⌘]** (Move Tab Right) on a **non-editor** tab | The active tab moves one slot right; the tab strip reorders; ⌘1-9 now map to the **new** visual order. (`Move Tab Left/Right` are `[.command,.option]` + `[` / `]`.) |
| 9 | **⌥⌘]** with an **editor** tab focused | **Documented ambiguity:** ⌥⌘[ /⌥⌘] are *also* Fold All / Unfold All (same `[.command,.option]` mask + `[`/`]` key in `main.swift`). Record which action fires when an editor is mounted — the collision is a known issue, not a pass/fail gate; the smoke's job is to *surface* the actual behavior, not assert a winner. |
| 10 | ⌘F (Find…) then **Find Previous** | *Find Previous* lives on **⌥⌘G**, *not* ⇧⌘G — ⇧⌘G is reserved for **Go to Path** (File ▸ Go to Path). Confirm ⌥⌘G steps to the previous match and ⇧⌘G opens the Go-to-Path prompt (`mdv.goto.panel`), not Find-Previous. (Breaks pre-existing ⇧⌘G muscle memory — intentional.) |
| 11 | ⌘G (Find Next) | Steps to the next match in the current find bar (rendered/editor/source per the active view mode). |

**Variations / edge-states**
- **Empty Window menu:** with all tabs closed (blank/no-tab state) the Window menu shows **"(no open tabs)"**.
- **Only first 9 numbered:** open >9 tabs → ⌘1-9 cover the first nine; the rest are reachable only by click / ⌥⌘→.
- **Recents cap:** opening >20 files keeps the menu at 20 entries (HistoryStore size cap 256KB); the underlying recents store may hold more for Quick Open.
- **CLI/Finder recents feed:** files opened via the `mdv` CLI / `markdownviewer://open?path=` / Finder "Open in TextView" also land in Open Recent.
- **Move-tab at edges:** Move Tab Right on the rightmost tab / Left on the leftmost is a no-op (no wrap).

---

## SC-SET-01 — Settings window: dedup, live two-way binding to the document window, and menu reflection

**Combines:** Settings window (⌘,, dedup via `SettingsWindowController`), Appearance (Theme picker, unified Zoom slider 50–300% step 10% + readout), Editor (Wrap / Show Invisibles / Indentation), Sidebar (Show-by-default / Width 160–480), Zoom/UI-scale (content + chrome), ModeBar wrap/¶ toggles, menu checkmark reflection.

**Preconditions**
- Clean launch; a markdown + a source file open (e.g. `readme.md` in Rendered, `app.py` in Source), so theme/zoom/wrap/indent changes are observable on real content.
- **Record current `UserDefaults`** (zoom, sidebarWidth, theme, wrap, invisibles, indentation) and restore at end.

**Steps**

| # | Action / script-verb | Expected result |
|---|---|---|
| 1 | ⌘, (App ▸ Settings…) | A single scrollable Settings window (460×540) opens with sections **Appearance / Editor / Sidebar / Privacy & Permissions / Plugins / Language servers / Advanced**. |
| 2 | ⌘, **again** while it's open | The **same** window re-focuses — no second Settings window (dedup). |
| 3 | Appearance → **Theme** picker → *Xcode Dark* | The document content (markdown CSS + source highlighting) flips to the dark theme **live**, applied to `model.themeOverride`. *Follow System* and *Xcode Light* are the other options. |
| 4 | Appearance → **Zoom** slider → drag toward ~150% | The `%` readout updates (`Int(zoom*100)%`). **Both content and chrome scale together** — WKWebView `pageZoom`, NSTextView font (13×zoom), and the chrome bar labels/heights. Slider clamps to 50%…300% in 10% steps. |
| 5 | Cross-check with the **View** menu: ⌘= / ⌘- / ⌘0 | Zoom In/Out/Actual move the **same** unified zoom — the Settings readout tracks the menu accelerators and vice-versa (one slider drives `DocumentModel.uiSize`). |
| 6 | Editor → toggle **Wrap** on | The Source view rewraps live; the **ModeBar Wrap toggle** (`mdv.wrapToggle`) reflects the same state; the **View ▸ Wrap** menu item (⌥⌘W) shows a checkmark. |
| 7 | Editor → toggle **Show Invisibles** on | Whitespace glyphs render in source/format; **View ▸ Show Invisibles** (⌥⌘I) checkmark mirrors it; ModeBar ¶ toggle (`mdv.invisiblesToggle`) too. |
| 8 | Editor → **Indentation** → *Tabs (width 4)* | Sets `model.editorIndentation`; in a CM6 editor the Tab key now inserts a tab rendered at width 4. (Options: 2 spaces / 4 spaces / Tabs width 2/4/8.) |
| 9 | Sidebar → toggle **Show sidebar by default** off; drag **Width** slider | Width clamps 160…480; the live sidebar resizes as you drag; the default-visibility toggle is bound (PERF-note: it's a `Toggle` not the live `sidebar.isVisible`, so it governs *next launch* default — confirm semantics). |
| 10 | Close Settings; quit (⌘Q) + relaunch | Theme / zoom / wrap / invisibles / indentation / sidebar-width persist across relaunch (`UserDefaults` / `PreferencesStore`). **Theme override is `@Published` but not persisted** (known bug-ish) — note whether the theme survived the relaunch; if it reverted to Follow-System, that's the documented gap, not a regression. |

**Expected end-state:** every Settings control mutates the *live* document window and is mirrored by the corresponding menu item state; restore recorded defaults afterward.

**Variations / edge-states**
- **Zoom floor/cap:** drag the slider hard to both ends → floors at 50% (`minZoom`), caps at 300% (`maxZoom`); ⌘- can't go below 0.5, ⌘= can't exceed 3.0.
- **Zoom is GLOBAL not per-session:** changing zoom in one session and switching sessions keeps the new zoom (#184). Cross-check with the chrome/sessions smokes.
- **Theme = Follow System:** with the OS in Light then toggled to Dark, *Follow System* flips the content theme on OS appearance change.
- **High-zoom chrome:** at ~300% the ModeBar mode-picker must use `.fixedSize` intrinsic content and not overflow/clip the toolbar.
- **Settings window title:** falls back to **"TextView"** (from `CFBundleName`).

---

## SC-SET-02 — Advanced: Clear All bookmarks (destructive confirm) + Reset window state (now real)

**Combines:** Settings ▸ Advanced (Clear All bookmarks `confirmationDialog`, Reset window state), Bookmarks store (file + line), Window frame autosave (`NSWindow Frame MainWindow`), Bookmark menu/⌘D + ⌥⌘D, persistence across relaunch.

**Preconditions**
- Clean launch; open 2-3 files and **bookmark** them (⌘D) plus add at least one **line bookmark** (⌥⌘D in source/editor). Confirm the BOOKMARKS sidebar section + tab stars show them.
- Move the window to a deliberately **off-center / odd** position so a re-center is observable.
- **Record** `UserDefaults` keys `MarkdownViewer.zoom`, `MarkdownViewer.sidebarWidth`, `NSWindow Frame MainWindow`, and `bookmarks.json`; restore at end.

**Steps**

| # | Action / script-verb | Expected result |
|---|---|---|
| 1 | ⌘, → **Advanced** section | Two rows: **Clear All** (bookmarks) and **Reset** (window state), each with an explanatory caption. |
| 2 | Click **Clear All** | A **confirmationDialog** appears: *"Clear All Bookmarks"* (destructive role) + *Cancel*, with the warning *"This removes every file and line bookmark. This can't be undone."* |
| 3 | Choose **Cancel** | Nothing changes — all bookmarks (file + line), tab stars, sidebar BOOKMARKS rows, and gutter dots remain. |
| 4 | Click **Clear All** again → confirm **Clear All Bookmarks** | All file *and* line bookmarks are removed: tab stars clear, the BOOKMARKS section shows **"No bookmarks yet."**, gutter line-dots vanish, and the **Edit ▸ Bookmark** label for the active tab flips back to **"Bookmark This"**. `bookmarks.json` is emptied. |
| 5 | Click **Reset** (Reset window state) | Removes the persisted defaults `MarkdownViewer.zoom`, `MarkdownViewer.sidebarWidth`, **and** `NSWindow Frame MainWindow` (the latter was the no-op bug — Reset previously never re-centered). The caption tells you to **quit + relaunch** for the window to re-center. |
| 6 | Quit (⌘Q) + relaunch | The window **re-centers** (frame-autosave key gone → falls through to `window.center()`), and zoom + sidebar width are back to defaults. Bookmarks stay cleared. |

**Variations / edge-states**
- **Clear with no bookmarks:** invoking Clear All on an empty store is harmless and idempotent; the confirm still appears.
- **Reset doesn't touch bookmarks/recents:** Reset window state only drops the three UI-state keys — it must **not** wipe `bookmarks.json` or recents (separate concern).
- **Bookmark cap interaction:** add >200 bookmarks first (store caps at 200, oldest dropped) → Clear All still empties everything cleanly.
- **Line bookmark survival until cleared:** a line bookmark to a since-edited file is still listed (resolved at add time) until Clear All removes it; the TOCTOU symlink-swap gap is a known deferred issue, not exercised here.

---

## SC-SET-03 — Privacy, Plugins, and LSP Diagnostics: the deep-link and tool-window launchers

**Combines:** Settings ▸ Privacy & Permissions (Full Disk Access deep-link), Settings ▸ Plugins (Manage… → Plugins window, Open Log enable/disable gating), Settings ▸ Language servers (Open Diagnostics… → LSP Diagnostics window), single-window dedup for the launched tool windows, audit-log presence gating.

**Preconditions**
- Clean launch. For the Plugins-log assertions, run once with the JSONL audit log **absent** (`~/Library/Logs/.../plugins.log`) and once with it present (drop a bundled plugin / trigger a grant so the log file is created).
- For LSP: a `.py` or `.ts` file open is not required to open the diagnostics window, but having one makes the table non-empty.

**Steps**

| # | Action / script-verb | Expected result |
|---|---|---|
| 1 | ⌘, → **Privacy & Permissions** | A **Full Disk Access** row with an **"Open System Settings…"** button + caption explaining why some locations need FDA. |
| 2 | Click **Open System Settings…** | System Settings opens to the **Full Disk Access** pane (falls back to the Privacy & Security root if the specific anchor is unavailable). TextView itself does not crash/hang on the deep-link. |
| 3 | Settings → **Plugins** section | Rows: **Manage…** and **Open Log**, plus a caption naming the Plugins dir (`~/Library/Application Support/com.markdownviewer.MarkdownViewer/Plugins/`). With the audit log **absent**, **Open Log** is **disabled** (`fileExists` false). |
| 4 | Click **Manage…** | The **Plugins management window** (460×540) opens: per-plugin rows (name, version, BUNDLED pill, monospaced id, capabilities, status, enable/disable switch, Revoke), and the empty-state pointing at the Plugins dir when none installed. |
| 5 | Re-open **Manage…** | The Plugins window re-focuses (no duplicate). |
| 6 | (Log present run) Click **Open Log** | **Open Log** is now **enabled**; clicking opens the JSONL audit log (0o600, dir 0o700). |
| 7 | Settings → **Language servers** → **Open Diagnostics…** | The **LSP Diagnostics window** opens: a Table of *Language / Root / State / Reqs / Last-ms / Crashes / Last-error* with a 2s poll + Refresh. With a `.py`/`.ts` tab and a discovered server it shows live rows; otherwise it's empty/idle. |
| 8 | Re-open **Open Diagnostics…** | Re-focuses the existing LSP Diagnostics window (the controller caches `lspDiagnosticsWindow`); `isReleasedWhenClosed=false`. |

**Variations / edge-states**
- **Log gating both ways:** confirm **Open Log** (Settings) and **Show Log** (Plugins window) are both disabled exactly when the audit log file is absent, and both enable once it exists.
- **No plugins installed:** Plugins window shows **"No plugins installed."** pointing at the Plugins dir; no Manage actions error.
- **LSP server missing:** with a language whose server isn't on `PATH`, the diagnostics table shows the install-hint state, not a crash; outline/hover degrade gracefully.
- **LSPDiagnosticsView reachability:** it's reachable in **all** builds from Settings despite a dev-only docstring (documented quirk) — its presence here is expected, not a Debug-gated surprise.

---

## SC-MENU-03 — Find accelerator routing, Edit clipboard, and the unsaved-edits guard gap

**Combines:** Edit menu (Undo/Redo ⌘Z/⇧⌘Z editor-vs-responder-chain routing, Cut/Copy/Paste/Select All, Find submenu), Find… (⌘F) routing by view mode, Find in Folder… (⇧⌘F cross-file), Go to Path (⇧⌘G) clipboard paste, ⌘W tab-vs-window behavior, the **no app-quit/window-close unsaved guard** (documented gap).

**Preconditions**
- Clean launch; fixtures: `doc.md` (markdown, Rendered), `code.ts` (TypeScript, for editor), a folder root open so Find in Folder has a scope.

**Steps**

> **Scope note (dedup):** the *find-bar internals* — each bar's controls, the
> three independent find bags, regex availability per mode, match-count /
> minimap / wrap behavior — are owned by `search.md` **SMK-SEARCH-01**. This
> smoke asserts only the **menu accelerator routing**: that `⌘F` reaches the
> *correct* bar for the active view mode, that `⌘Z`/`⇧⌘Z` route by editor-focus
> context, that `⇧⌘G` is Go-to-Path (not Find-Previous), and the `⌘W` tab-vs-
> window branch + the app-quit unsaved guard gap.

| # | Action / script-verb | Expected result |
|---|---|---|
| 1 | `open_path doc.md` (Rendered) → ⌘F | `⌘F` routes to the **rendered** find bar (`MarkdownFindBar`). (Bar internals → SMK-SEARCH-01.) |
| 2 | Switch `doc.md` to **Source** → ⌘F | `⌘F` now routes to the **source** find bar (`SourceFindBar`). ⌘G / ⌥⌘G are the Find-Next / Find-Previous accelerators. |
| 3 | `open_path code.ts`, set **Editor**, ⌘F | `⌘F` routes to the **editor** find bar (`EditorFindBar`, CM6 search panel). Confirms accelerator routing tracks the active view mode across all three bars. |
| 4 | In the editor, type to edit, then ⌘Z / ⇧⌘Z | Undo/Redo route **into CM6 JS** `undo()`/`redo()` (editor mounted+focused). |
| 5 | Open the **Go to Path** prompt (⇧⌘G), then ⌘V into the field | Paste works in the field (⌘V was historically swallowed; Edit menu Paste/Cut wiring fixed). Cut/Copy/Select-All also work in the prompt's TextField. ⇧⌘G is **Go to Path** — *not* Find Previous. |
| 6 | **Edit ▸ Find ▸ Find in Folder…** (⇧⌘F) | The **cross-file search** modal opens (`mdv.crossSearchPanel`) over a scrim, scoped to the active folder. |
| 7 | Undo in a **non-editor** context (e.g. focus the Go-to-Path field, ⌘Z) | `validateMenuItem` returns **false** for editorUndo/Redo when no editor is mounted → the keystroke **falls through** to the responder chain, so NSTextField undo still works in the prompt. (Routing-by-context guard.) |
| 8 | With a **dirty editor tab**, ⌘W (close that tab, >1 open) | The per-tab dirty prompt fires: **Save / Don't Save / Cancel** NSAlert. Choose **Cancel** → tab stays, dirty intact. |
| 9 | With a **dirty editor tab**, ⌘Q (quit) | **DOCUMENTED GAP:** there is **no app-quit / window-close unsaved-edits guard** (`hasAnyUnsavedEdits` forwarder has no caller). ⌘Q can silently drop unsaved buffers without a prompt. The smoke must *record* this behavior (and ideally a screencap of the lost edit) so the gap stays visible — it is a known issue, not a pass. |

**Variations / edge-states**
- **⌘W at the last tab:** with a single tab, ⌘W falls through to `performClose` (window-close path) rather than closing the tab — confirm the documented branch.
- **Find routing on a binary tab:** ⌘F on an image/HEX tab routes to that view's own find (HEX search toolbar) or no-ops gracefully — no crash, no orphaned find bar.
- **Editor Undo optimism:** ⌘Z/⇧⌘Z enable optimistically when an editor tab is selected even on empty history (CM6 exposes no per-tab can-undo) → invoking on empty history is a no-op, not an error.
- **Find Previous accelerator:** confirm ⌥⌘G (not ⇧⌘G) is wired to Find Previous everywhere; the muscle-memory break is intentional and load-bearing for ⇧⌘G = Go to Path.

---

## SC-MENU-04 — Session menu + Debug-menu gating + menu-bar absence in headless modes

**Combines:** Session menu *presence + accelerator wiring* (New ⇧⌘N, Next/Prev ⌃⇥/⌃⇧⇥, Jump ⌃1-9 + checkmark, Close ⇧⌘W), Debug menu DiagnosticGate (DEBUG-build / `MDV_ENABLE_DIAGNOSTICS=1` only), `--mcp-stdio` menu-bar-absent mode, HIG menu ordering, no native "Show Tab Bar"/"Merge All Windows".

> **Scope note (dedup):** the *session behavior* the menu triggers — activation
> order, LRU close, the ⌃1-9 vs ⌘1-9 collision check, lazy submenu rebuild,
> empty/single-session disable rules — is owned by `sessions.md` **SESS-11**
> (and **SESS-12** for strip presence). This smoke asserts only that the menu
> items + accelerators **exist and dispatch** in the right HIG position, plus
> the Debug-gating and headless menu-absence that are pure menu-bar concerns.

**Preconditions**
- App built with `sessionsApp` injected (so the Session menu + `mdv.sessionTabBar` exist). Clean launch (`MDV_SKIP_WORKSPACE_RESTORE=1`).
- Two fixture folders `projX/` and `projY/`.

**Steps**

| # | Action / script-verb | Expected result |
|---|---|---|
| 1 | Inspect the menu-bar order | **App (TextView) / File / Edit / View / Session / Window / Help** in HIG order. **No** native "Show Tab Bar" or "Merge All Windows" (automatic window tabbing is explicitly disabled). |
| 2 | Open the **Session** menu | Items present + wired: **New Session…** (⇧⌘N), **Next/Previous** (⌃⇥/⌃⇧⇥), **Jump to Session** submenu (⌃1-9 on the first 9, active-session checkmark, **"(no sessions)"** when empty), **Close Session** (⇧⌘W, distinct from ⌘W). Confirm the accelerators dispatch the matching `SessionsAppCoordinator` calls — the LRU/activation *behavior* is asserted in SESS-11, not re-walked here. |
| 3 | Launch a **DEBUG** build (or `MDV_ENABLE_DIAGNOSTICS=1`) | A **Debug** menu appears after Help with *Diagnostic Window* + *Instrumentation*. These windows re-focus existing instances (`isReleasedWhenClosed=false`). |
| 4 | Launch a **stock release** build (no env flag) | The **Debug menu is absent** entirely (`DiagnosticGate.isEnabled` false). The diagnostic windows are unreachable from the UI and are **never** exposed via MCP. |
| 5 | Launch with `--mcp-stdio` | **No menu bar / no window** — activation policy `.prohibited` (no Dock/menu/window). The process speaks Content-Length-framed JSON-RPC on stdio; the menu surface is entirely absent. |

**Variations / edge-states**
- **Single-session layout:** with `sessionsApp` **off**, the Session menu is absent and the session tab bar + its divider don't render.
- **Stale Settings docstring:** a stale `main.swift` comment claims Settings is a disabled stub — it is actually **wired** (SC-SET-01 proves it). Note if the comment is encountered; it's doc rot, not behavior.

---

## Run notes

- **Settings mutates `UserDefaults`.** Every smoke that touches Appearance/Editor/Sidebar/Advanced must snapshot the affected keys (`MarkdownViewer.zoom`, `MarkdownViewer.sidebarWidth`, `NSWindow Frame MainWindow`, theme/wrap/invisibles/indentation, `bookmarks.json`) before and restore after — or run against a throwaway defaults domain — so a UAT pass doesn't silently rewrite the operator's real preferences. The **TCC-stable** bundle id means real grants persist; don't fiddle with FDA state, just verify the deep-link opens.
- **Live-menu only.** `validateMenuItem` enable/grey + relabel and accelerator routing only fire against a real `NSMenu` + responder chain on a GUI session — run on the VM/GUI lane. The cheaper headless proxy is asserting the underlying model flags (`supportsViewModeToggle`, `supportsFormatToggle`, `isCurrentTabBookmarked`, `tabs.selected?.isDirty`, `sidebar.isVisible`) that the validator reads.
- **Occlusion / compositor.** Any "the window re-centered / chrome didn't blank" assertion (SC-SET-02 step 6) is authoritatively verified only by `screencapture(1)` on a live window (T5) — in-process `cacheDisplay`/`ImageRenderer` raster won't catch a WindowServer-level compositor blank. The T4 a11y-tree / window-frame read is a cheaper proxy.
- **Known issues these smokes deliberately surface (not fail on):** the **⌥⌘[ /⌥⌘] Move-Tab vs Fold-All collision** (SC-MENU-02 step 9), the **⌥⌘G Find-Previous relocation** off ⇧⌘G (SC-MENU-02 step 10 / SC-MENU-03), the **no app-quit/window-close unsaved-edits guard** (SC-MENU-03 step 9), the **theme override not persisted** across relaunch (SC-SET-01 step 10), and the **stale "Settings is a disabled stub" comment** (SC-MENU-04). Each is a documented gap; the smoke's job is to keep them visible, not to gate the run.
- **Do not** force the heavy tiers onto the host (a window/menu bar would appear and disrupt daily work) — these belong to the nightly VM lane.
