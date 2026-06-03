# UAT smokes — cm6-editor (edit / save / dirty / close)

Area: the CodeMirror 6 editor mode — an editable CM6 instance hosted in a
WKWebView (vendored bundle, `mdv.editor` / `mdv.editor.webView`,
`drawsBackground=false`). Covers the full edit → dirty → save → close
lifecycle and its interaction with the rest of the chrome: the per-tab
dirty dot (`mdv.tab.dirtyDot`), the Save menu item / in-WebView `Mod-s`
JS bridge, optional save-on-blur, undo/redo routed from the AppKit Edit
menu into JS, the editor find/replace bar (`mdv.editorFindBar`),
indentation + fold + go-to-line, the external-edit conflict prompt
(`Keep My Edits` / `Discard & Reload`), the 50 MB editor cap placeholder
(`mdv.editor.largePlaceholder`), per-tab cursor/scroll restore, and the
close-tab unsaved-buffer prompt.

These smokes are deliberately **multi-feature**: each is a realistic
session that touches several editor surfaces at once, not an isolated
unit assertion. Run them against the installed `dist/TextView.app` (T4
live-app tier). Where a UI affordance can't be reached from a script,
the equivalent **script verb** is given in `code` so the flow stays
automatable: `editor-set-mode <ViewMode.rawValue>`, `editor-set-text
<text>` (same entry point the CM6 debounced-change bridge fires),
`editor-save` (⌘S equivalent), `select-tab <n>`, `close-tab`,
`open <path>`, `goto <line>`.

> Conventions used below
> - **App action** = something a human does in the live window (type,
>   click, press a shortcut).
> - **Script verb** = the headless-driveable equivalent for the T4 suite.
> - "dirty dot" = the accent dot rendered on the tab via
>   `mdv.tab.dirtyDot`; "Save enabled" = the File ▸ Save (⌘S) menu item
>   is not greyed.

---

## Preconditions common to all smokes

- `dist/TextView.app` is the **fixed-bug** build (≥ `798b7ee`); the broken
  `fd11e61` build cannot load source files at all, which would mask every
  editor result. Confirm a plain `.txt`/`.md`/`.swift` opens and shows
  content in **Source** before trusting any editor result.
- Scratch files live under `FileManager.temporaryDirectory`
  (`/var/folders/...`). **Never** create fixtures in `~/Documents`,
  `~/Desktop`, `~/Downloads` (TCC-protected, and project policy forbids it).
- Each smoke starts from a clean window unless it says otherwise
  (`MDV_SKIP_WORKSPACE_RESTORE=1` for a clean-room launch).
- The editor only mounts for text files whose `availableModes` include
  `.editor` (every text file gets Source + Editor + HEX; media/binary
  do not). The picker's **Editor** segment is refused for files over
  `codeMirrorEditorMaxBytes` (50 MB).

---

## SMOKE cm6-1 — First edit makes a tab dirty, ⌘S clears it, status/tab reflect the round-trip

**Combines:** view-mode picker (Source→Editor), CM6 mount + typing,
dirty-dot lifecycle, Save menu-item enable/disable, in-WebView `Mod-s`
JS-bridge save vs menu ⌘S, status-bar metrics (Ln/Col, Lines, Chars,
EOL, encoding) updating after edit, file-watcher pause-during-write.

**Preconditions**
- A small writable UTF-8 text fixture in the temp dir, e.g.
  `/var/folders/.../uat_edit.md` with 3 short lines, LF line endings.
- App launched; that file opened (`open /var/folders/.../uat_edit.md`).

**Steps**

| # | App action | Script verb | Expected result |
|---|------------|-------------|-----------------|
| 1 | Open the fixture; it lands in **Source** (md default would be Rendered first — but pick a `.txt` if you want Source default, or switch). Switch the ModeBar picker to **Editor**. | `editor-set-mode editor` | CM6 mounts in the WebView (`mdv.editor` / `mdv.editor.webView` present), file text visible, line-number gutter + active-line highlight shown. NO blank white box (regression guard for the WidgetType / duplicate-state bootstrap bugs). File ▸ Save is **greyed** (clean buffer). No dirty dot. |
| 2 | Click into the editor and type a word at end of line 1. | `editor-set-text "<orig L1> EDITED\n<orig L2>\n<orig L3>\n"` | Within ~200 ms (debounce) the tab shows the **dirty dot** (`mdv.tab.dirtyDot`); File ▸ Save (⌘S) becomes **enabled**. Status bar Chars/Ln-Col update live without a full re-body. |
| 3 | Press ⌘S (menu Save). | `editor-save` | File is written to disk; the **dirty dot clears**; Save greys again. The file-watcher is paused for the write window and re-attached after (no self-triggered reload loop). Re-reading the file on disk shows the edited text. |
| 4 | Type another change, then save via the **in-WebView `Mod-s`** path (focus the editor, press ⌘S so CM6's keymap fires `post("save")` over the bridge — not the AppKit menu). | (drive `editor-set-text` then trigger the JS keymap; or `editor-save`) | Same outcome as step 3 — dirty dot clears, disk updated. Confirms both save entry points (AppKit menu **and** CM6 JS bridge) reach `saveActiveEditor()`. |
| 5 | Type a change, then **manually retype it back to the exact original bytes**. | `editor-set-text "<original full text>"` | Dirty dot **clears on its own** (buffer text == originalText) — Save greys. Typing back to original is a no-op dirty state, not a forced save. |

**Variations / edge-states to also try**
- **Save-on-blur ON** (Settings or `$editor.saveEditorOnBlur`): edit, then
  click another tab / another app — buffer auto-saves on blur, dirty dot
  clears without an explicit ⌘S.
- **Markdown file (Rendered default):** opening `.md` defaults to Rendered;
  ⌘S should be greyed (Rendered isn't editing). Switch to Editor, edit,
  ⌘S — save works; flipping back to Rendered shows the new content (cache
  keyed on byteCount+mtime must invalidate — this was a stale-cache bug).
- **EOL/encoding preserved:** open a CRLF file, edit one line, save — the
  saved file keeps CRLF (status bar EOL chip should still read CRLF), not
  silently normalized to LF.
- **Empty buffer:** select-all + delete everything, save — produces a
  0-byte file, no crash, Lines reads 0.

---

## SMOKE cm6-2 — Undo/redo across the AppKit menu ↔ CM6 JS bridge, with find/replace

**Combines:** Edit-menu Undo (⌘Z) / Redo (⇧⌘Z) routed into JS
`undo()`/`redo()` **only when the editor is mounted+focused**, editor
find bar (`mdv.editorFindBar`: query / Match-case `Aa` / Regex `.*` /
prev-next / n-of-N), CM6 native search panel (replace via `searchKeymap`),
dirty-state interplay with undo back to a clean baseline.

**Preconditions**
- Fixture `/var/folders/.../uat_undo.txt` with at least 6 lines, several
  occurrences of the token `foo`.
- Tab open in **Editor** mode, focused.

**Steps**

| # | App action | Expected result |
|---|------------|-----------------|
| 1 | Make three distinct edits (type on line 1, delete on line 3, paste on line 5). | Dirty dot appears after the first edit and stays. |
| 2 | Press ⌘Z three times. | Each ⌘Z routes to CM6 `undo()` (editor is focused) and reverts one edit. After the third undo the buffer equals the original → **dirty dot clears** (back to clean baseline). |
| 3 | Press ⇧⌘Z twice (Redo). | CM6 `redo()` re-applies two edits; dirty dot returns. (Note: Editor Undo/Redo menu items enable *optimistically* — CM6 exposes no per-tab can-undo — so the items may look enabled even with nothing to undo; the no-op is acceptable.) |
| 4 | Press ⌘F → editor find bar appears. Type `foo`. | `mdv.editorFindBar` shows; match count `1/N` (or `n/N`); first match highlighted/selected. |
| 5 | Toggle **Match-case** (`Aa`) and re-search a mixed-case token; toggle **Regex** (`.*`) and search `f.o`. | Case toggle narrows matches; regex toggle treats query as a pattern (editor find supports regex, unlike rendered find). Invalid regex must not hang (ReDoS guard) — show no matches / no spinner-of-death. |
| 6 | Step matches with Find-Next/Prev (⌘G / ⌥⌘G). | Selection advances/retreats through matches; n-of-N count updates. |
| 7 | Open the CM6 **native search+replace** panel and replace one `foo`→`bar`. | Replace mutates the buffer → dirty dot appears; the replaced text is undoable with ⌘Z. |

**Variations / edge-states to also try**
- **Editor NOT focused:** click into the sidebar so the editor loses focus,
  then ⌘Z — it must fall through the responder chain (NOT silently eat
  the keystroke as a JS undo). Verify it doesn't corrupt the buffer.
- **Plain-text-fallback language** (e.g. a `.rs` / `.go` file — CM6 only
  maps markdown/js/ts/python/json): editing + find/replace still work,
  just without syntax highlighting. Undo/redo unaffected.
- **Multi-cursor:** make a multi-selection (rangeCount > 1) and type — all
  cursors edit; one undo reverts the whole multi-edit.
- **Undo "through" a Swift-driven setText:** known limitation — a
  Swift-side rewrite uses `resetHistory:false`, so a prior edit can be
  undone *through* an external rewrite. Note behavior, don't fail the run.

---

## SMOKE cm6-3 — Close a dirty tab: Save / Don't Save / Cancel prompt, and the app-quit gap

**Combines:** tab close routing through the dirty-buffer prompt, the
3-button NSAlert (Save / Don't Save / Cancel), close-tab keyboard +
context-menu paths, "Close Other Tabs" / "Close Tabs to the Right"
batch-close honoring per-tab dirty prompts, and the **known gap** that
⌘Q / closing the last window has *no* unsaved-edits guard.

**Preconditions**
- Two tabs open, both in Editor mode: tab A edited+dirty, tab B clean.

**Steps**

| # | App action | Script verb | Expected result |
|---|------------|-------------|-----------------|
| 1 | With dirty tab A active, click its `×` (or ⌘W). | `close-tab` | A modal NSAlert appears: **Save** / **Don't Save** / **Cancel** for the unsaved buffer. The tab does NOT close until the user chooses. |
| 2 | Choose **Cancel**. | (drive prompt override) | Alert dismisses; tab A stays open, still dirty. Nothing written to disk. |
| 3 | ⌘W again → choose **Don't Save**. | | Tab A closes, edits discarded, disk file unchanged. Selection moves to the right neighbor (or new last). |
| 4 | Re-open + re-dirty A; ⌘W → choose **Save**. | `editor-save` then `close-tab` | Buffer is written, dirty dot would have cleared, then the tab closes. Disk reflects the edit. |
| 5 | With several tabs (some dirty), right-click a tab → **Close Other Tabs** / **Close Tabs to the Right**. | | Each dirty tab in the batch surfaces its own Save/Don't-Save/Cancel prompt; choosing Cancel on any aborts that close and leaves remaining tabs. "Close Other Tabs" disabled when ≤1 tab; "Close to the Right" disabled on the rightmost. |

**Variations / edge-states to also try**
- **App-quit gap (document the bug, don't expect a guard):** with a dirty
  editor tab, press ⌘Q (or close the *last* window). Per the catalog there
  is **no** app-quit / window-close unsaved-edits guard
  (`hasAnyUnsavedEdits` has no caller) — the dirty buffer is silently
  dropped. Record this as a finding (data-loss risk), not a pass/fail.
- **Closing the dirty active tab when it's the only tab:** ⌘W closes the
  tab (not the window) when >1; with a single tab ⌘W falls through to
  `performClose`. Verify the dirty prompt still fires before any close.
- **Close from the Window menu** (per-tab list item) — same dirty prompt
  must route through, not a silent close.

---

## SMOKE cm6-4 — External edit while dirty: the conflict prompt (Keep My Edits / Discard & Reload)

**Combines:** file-watcher detecting an on-disk change, the conflict
NSAlert (`<name> changed on disk` / "Keep My Edits" / "Discard & Reload"),
dirty-baseline preservation on Keep, watcher fingerprint refresh (no
re-prompt storm), and the status-bar **red "Modified"** stale-on-disk
signal. This is the highest-risk data-loss path in the editor.

**Preconditions**
- Fixture `/var/folders/.../uat_conflict.txt` open in Editor mode.
- A way to mutate the file from outside the app (a shell `printf >> file`
  or another editor) — this is the live external write.

**Steps**

| # | App action | Expected result |
|---|------------|-----------------|
| 1 | Edit the buffer (make it dirty) but do **not** save. | Dirty dot shown. |
| 2 | From outside the app, append a line to the file on disk. | Within ~1 s the watcher fires. Because the buffer is **dirty**, the app presents the conflict alert: **"`uat_conflict.txt` changed on disk — You have unsaved changes. Reloading will discard them."** with **Keep My Edits** and **Discard & Reload**. |
| 3 | Choose **Keep My Edits**. | Buffer keeps the user's edits and stays **dirty** (originalText baseline NOT clobbered — this was the S1-A bug where Keep collapsed the dirty baseline and broke Revert). The saved-fingerprint is refreshed so the *duplicate* watcher tick from the same write does **not** re-prompt. |
| 4 | Now ⌘S. | The user's edits overwrite the external change on disk; dirty clears. |
| 5 | Re-dirty; external-write again; this time choose **Discard & Reload**. | Editor buffer is discarded and the tab reloads the on-disk content; dirty dot clears; the editor shows the externally-written text. |

**Variations / edge-states to also try**
- **External edit while CLEAN (not dirty):** appending to the file when the
  buffer is clean should just **auto-reload** (no conflict prompt) within
  ~1 s — verify the editor content updates and no alert appears.
- **Save-then-external-write race:** ⌘S, and immediately (within the
  watcher-paused window) have another process write the file. The
  post-save re-stat (FW-7 lost-event reconcile) should detect the
  mismatch and surface the conflict rather than silently keeping stale
  content.
- **Symlink save target (known unwired gap):** open a file that is a
  symlink, edit, ⌘S. The writer refuses by default
  (`EditorWriteError.targetIsSymlink`) but the *intended* Follow-Link /
  Replace prompt is NOT wired — you get the generic "Couldn't save
  `<name>`" warning alert. The buffer **stays dirty** so a retry is
  possible (no silent edit drop). Record the missing follow-link UI as a
  finding.
- **Save to a now-read-only / deleted directory:** ⌘S surfaces the generic
  save-failure alert and stays dirty (retryable), no crash.

---

## SMOKE cm6-5 — Editor capacity, mode-routing, indentation/fold/go-to-line, and per-tab cursor restore

**Combines:** the 50 MB editor cap placeholder
(`mdv.editor.largePlaceholder` + "View as Source"), Editor-segment
refusal for oversized files, indentation setting (tabs vs N spaces,
clamped 1..16), Fold All (⌥⌘[) / Unfold All (⌥⌘]), Go to Line (⌘L),
per-tab cursor/scroll restore on tab switch, and the Editor→HEX
transition flash (open bug #219).

**Preconditions**
- Three fixtures in the temp dir:
  - `small.py` (~40 lines, foldable blocks) — Editor-capable, mapped lang.
  - `big.log` just **over** 50 MB — to hit the editor cap.
  - any second small text file for the tab-switch restore check.

**Steps**

| # | App action | Script verb | Expected result |
|---|------------|-------------|-----------------|
| 1 | Open `small.py` in **Editor**. Set indentation to **Spaces (2)** in Settings; press Tab at line start. | `editor-set-mode editor` | Tab inserts 2 spaces. Change to **Tabs (width 4)** → Tab inserts a tab glyph rendered 4-wide. Out-of-range widths clamp to 1..16. |
| 2 | Press **Fold All** (⌥⌘[), then **Unfold All** (⌥⌘]). | | Fold gutter chevrons collapse all foldable regions, then expand them. (Caveat: ⌥⌘[ / ⌥⌘] collide with Move-Tab-Left/Right — verify which action the live build dispatches and record the ambiguity.) |
| 3 | Press **Go to Line** (⌘L), enter a line number. | `goto <n>` | NSAlert prompt accepts a 1-based line; the editor scrolls/selects that line. Out-of-range clamps. |
| 4 | Move the cursor to a specific line/column and scroll partway down. Switch to the second tab, then switch back to `small.py`. | `select-tab` | The editor restores the **per-tab cursor position and scroll** (CMSelectionSeed) — caret and viewport are where you left them, not reset to top. |
| 5 | Try to open `big.log` (>50 MB) **in Editor**. | `editor-set-mode editor` | Editor refuses the upgrade: the `mdv.editor.largePlaceholder` shows **"File too large for editor mode"** + the size + a **"View as Source"** button. The Editor picker segment is disabled/refused for this file. Clicking "View as Source" routes to Source (large read-only fast path), not a hang. |
| 6 | From an Editor tab, switch the ModeBar picker to **HEX**. | `editor-set-mode hex` | The HEX view loads. Note: a transient **flash of Source** during the Editor→HEX routing transition is the known open bug **#219** — record it; the end state must still be a correct HEX dump under the HEX picker (not HexView stuck under a non-HEX picker, the fixed Bug C). |

**Variations / edge-states to also try**
- **Right at the cap boundary:** a file just *under* 50 MB should open in
  Editor (slow but functional; `EditorBuffer.load` caps at 32 MiB on its
  own path — confirm no truncation surprise); a file just *over* hits the
  placeholder.
- **Rapid HEX↔Editor↔Source toggling** (Bug C regression guard): toggle the
  picker fast several times — the *latest* switch must win; you must never
  end with the wrong viewer under a mismatched picker or an endless spinner.
- **Native "Editor" right-click context menu:** right-click in the editor →
  Go to Definition (LSP, if a server is available) + Cut/Copy/Paste; Cut/
  Copy are disabled with no selection.
- **Plain-text fallback fold:** a non-mapped language has no syntax tree —
  Fold All should be a safe no-op (or fold only indent-based regions),
  not a crash.
