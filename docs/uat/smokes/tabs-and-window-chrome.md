# UAT smokes — Tabs & Window Chrome

**Area:** `tabs-and-window-chrome`
**App under test:** `dist/TextView.app` (Finder name TextView.app; bundle id `com.markdownviewer.MarkdownViewer`)
**Tier:** T4 live-app (`LiveAppTestCase`) — these exercise the real window/chrome composition, so they must run on a GUI session (VM lane), not the headless merge gate.

## Scope

Durable, realistic user flows over the window-chrome stack:

```
┌─────────────────────────────────────────┐
│ SessionTabBar  (mdv.sessionTabBar)        │ ← nested sessions (only when sessionsApp injected)
├─────────────────────────────────────────┤
│ TabBar         (mdv.tabbar)               │ ← per-file tabs, dirty dot, bookmark star, +
├─────────────────────────────────────────┤
│ ModeBar        (mdv.modebar)              │ ← view-mode picker, Open As (mdv.openAs),
│                                           │   language badge (mdv.languageBadge), wrap/¶ toggles
├─────────────────────────────────────────┤
│ [left rail | center band | right rail]    │ ← shoulder rails (mdv.rail.<edge>.<kind>)
├─────────────────────────────────────────┤
│ StatusBar      (mdv.statusBar)            │ ← path, live Ln/Col, metrics, Modified chip
└─────────────────────────────────────────┘
```

Cross-cutting invariants every smoke implicitly guards:
- **Chrome-pin invariant:** TabBar / ModeBar / StatusBar hold fixed heights; the center band absorbs 100% of any window shrink. The bars must never compress, clip, or blank.
- **Bar visibility coupling:** `SessionTabBar` (+ its `Divider`) is present only when `sessionsApp` is injected; `StatusBar` is present only when `currentURL != nil`. `ModeBar` picker is hidden when a type has a single available mode (binary/unknown = HEX-only).

> **Dedup note:** the *session feature itself* (create / switch / rename /
> restore / LRU / autosave / per-session capture) lives in the dedicated
> **Sessions** area (`sessions.md`, SESS-01..12), not here. The old
> `SC-CHROME-03` was a full clone of it and has been removed; this area keeps
> only the chrome-*composition* angle of the `SessionTabBar` (see SC-CHROME-05
> step 5). Likewise the shoulder-rail panel *behavior* is owned by **SFB-05/06**
> — SC-CHROME-05 keeps only the chrome-pin invariant under rail over-subscription.

## Conventions for steps

- **Script-verbs** below refer to the `--script` verb dispatcher and MCP tools (`open_path`, `select_tab`, `set_view_mode`, `current_state`, `snapshot_window`); plain UI actions name the AppKit gesture + the a11y id.
- a11y ids are load-bearing and verified against source: `mdv.tabbar`, `mdv.tab.dirtyDot`, `mdv.sessionTabBar`, `mdv.sessionTab.<uuid>`, `mdv.sessionTab.close.<uuid>`, `mdv.sessionTab.rename.<uuid>`, `mdv.sessionTab.new`, `mdv.modebar`, `mdv.openAs`, `mdv.languageBadge`, `mdv.wrapToggle`, `mdv.invisiblesToggle`, `mdv.statusBar`, `mdv.statusBar.path`, `mdv.statusBar.helpDescription`, `mdv.statusBar.modified`, `mdv.rail.<edge>`, `mdv.rail.<edge>.<kind>`.
- "Fixtures" = files created under `FileManager.default.temporaryDirectory` (per-user `/var/folders/...`). **Never** write fixtures under `~/Documents`, `~/Desktop`, `~/Downloads`.

---

## SC-CHROME-01 — Multi-tab lifecycle: open, switch, dirty-dot, close-with-prompt, neighbor-selection

**Combines:** Tabs (open/switch/close/dirty), CodeMirror editor dirty-state, ModeBar view-mode routing, Window title + represented document, StatusBar live metrics, Window menu per-tab list, keyboard shortcuts (⌘T/⌘W/⌘1-9/⌥⌘→).

**Preconditions**
- TextView.app launched clean (`MDV_SKIP_WORKSPACE_RESTORE=1` so no restored tabs pollute the strip).
- Fixture folder with: `a.md` (markdown), `b.json` (json), `c.txt` (plain text), `d.csv` (csv) in a temp dir.
- Single window, single session (or sessionsApp off — either is fine here).

**Steps**

| # | Action / script-verb | Expected result |
|---|---|---|
| 1 | `open_path a.md` (newTab) | Tab strip (`mdv.tabbar`) shows one tab titled `a.md` with the markdown file-type icon, accent-tinted/semibold (selected). Window title = `a.md`. ModeBar offers **Rendered** first (selected), Source, Editor, HEX. StatusBar (`mdv.statusBar`) appears with the `~`-abbreviated path and Lines/Chars/Size metrics. |
| 2 | `open_path b.json`, `open_path c.txt`, `open_path d.csv` | Strip now has 4 tabs in open order; the last opened (`d.csv`) is selected. `d.csv` defaults to **Table** mode (ModeBar shows Table selected). Each tab shows its correct file-type icon. |
| 3 | `select_tab byIndex:1` (or ⌘1) | `a.md` re-selected; window title flips to `a.md`; ModeBar reverts to its Rendered default; StatusBar metrics update to `a.md`'s. |
| 4 | ⌥⌘→ (next tab) twice | Selection advances `a.md → b.json → c.txt`, wrapping-free within range; title + ModeBar + StatusBar track each switch. |
| 5 | Switch to `c.txt`, set ModeBar to **Editor**, type a character | Tab `c.txt` grows a dirty dot (`mdv.tab.dirtyDot`, accent); Save menu item enables; StatusBar metrics reflect edited buffer. |
| 6 | Click that tab's × (or ⌘W) | Dirty-buffer NSAlert appears: **Save / Don't Save / Cancel**. Choose **Don't Save**. Tab closes; the **right neighbor** (`d.csv`) becomes selected. |
| 7 | Open the **Window** menu | One menu item per open tab (`a.md`, `b.json`, `d.csv`); the active tab (`d.csv`) carries a checkmark. |
| 8 | Re-`open_path b.json` (already open) | **No duplicate tab** — selection just switches to the existing `b.json` tab. |
| 9 | ⌘T (new blank tab) | A blank `Untitled` tab appends and is selected. Window title falls back to `TextView`. ModeBar picker may hide (single/empty). StatusBar **disappears** (no `currentURL`). |
| 10 | ⌘O on the blank tab, pick `a.md` | The blank tab is **reused** (not a 5th tab) — `a.md` loads in place. |

**Expected end-state:** tabs `a.md`(reused-blank), `b.json`, `d.csv`; no orphan blank tab; StatusBar back.

**Variations / edge-states**
- **Close-last-tab selection:** close the rightmost tab → selection moves to the new last tab. Close a middle tab → right neighbor selected (already covered in step 6, vary the position).
- **Closing the only remaining tab:** ⌘W with a single tab should *not* close the window (when >1 it closes the tab; at 1 it falls through to `performClose`). Confirm window stays / behaves per menu validation.
- **Dirty + Cancel:** repeat step 6 choosing **Cancel** → tab stays open, dirty dot intact, nothing lost.
- **Drag-to-reorder:** drag `b.json` past `d.csv`; order persists; the dragged tab keeps its identity (stable id `mdv-tab:<uuid>` resolved at drop). After reorder, ⌘1-9 map to the *new* visual order.
- **Crowded strip:** open ~15 small fixtures → per-tab width shrinks toward the 54pt floor, then the strip overflows + scrolls horizontally. Programmatically `select_tab` an off-screen tab → it auto-scrolls to center. Titles middle-truncate, never blank.
- **/var vs /private/var symlink dedup:** open the same file once via `/var/...` and once via `/private/var/...` → resolves to a single tab (no twin).
- **Bookmark star:** ⌘D on the active tab → a yellow `star.fill` appears on the tab and mirrors into the FILES tree.

---

## SC-CHROME-02 — ModeBar view-mode routing + Open As override + language badge in one flow

**Combines:** View-mode picker (ModeBar), Open As override (`mdv.openAs`), language badge (`mdv.languageBadge`), wrap/invisibles toggles (`mdv.wrapToggle`/`mdv.invisiblesToggle`), HTML per-tab JS toggle, carry-mode-on-file-switch, async loader latest-switch-wins.

> **Scope note (dedup):** this smoke owns the **ModeBar chrome rendering** — how
> the picker segments / Open-As chip / language badge / wrap+¶ toggles / HTML
> Enable-JS toggle *appear and recolor in the toolbar*, and that they hold at
> high zoom without overflow. The underlying *routing logic depth* (the
> exhaustive Open-As viewer list with magic-byte float, carry-mode fallback
> semantics, and the latest-switch-wins **Bug C** race) is owned by
> `view-modes.md` **VM-06**; the steps below touch them only as far as the chrome
> reflects them — drive the full routing matrix via VM-06.

**Preconditions**
- Clean launch; fixtures: `notes.md`, `data.json`, `page.html`, `pic.png`, `db.sqlite` (a tiny ≤8KB sqlite), `bin.dat` (random bytes, unknown type) in a temp dir.

**Steps**

| # | Action / script-verb | Expected result |
|---|---|---|
| 1 | `open_path notes.md` | ModeBar (`mdv.modebar`) segmented picker: **Rendered**(sel) / Source / Editor / HEX. Right side shows the `~`-shortened path. Open As chip (`mdv.openAs`) present (not accent-tinted; Auto). |
| 2 | ⌘⇧R | Toggles Rendered↔Source for the markdown tab (the picker selection flips). |
| 3 | Switch to Source, toggle **Wrap** (`mdv.wrapToggle`) and **¶ invisibles** (`mdv.invisiblesToggle`) | Both toggles appear only in source/format modes; toggling visibly rewraps / shows whitespace glyphs. |
| 4 | `open_path data.json` | ModeBar offers **Format** (Pretty-Print) in addition to Source/Editor/HEX. Wrap + ¶ toggles also offered in Format mode. Language badge (`mdv.languageBadge`) shows `Auto (json)`. |
| 5 | Open the language badge menu, pick a different language (e.g. `JavaScript`) | Badge becomes **accent-tinted** with a tooltip; the Source view recolors per the override (per-tab). |
| 6 | Pick `Auto` from the badge | Override clears; badge de-tints; reverts to extension detection (`json`). |
| 7 | `open_path page.html` | ModeBar order: **Source** is the conservative default and comes first; **Rendered** is inserted *after* Source. An **Enable JS** toggle (`mdv.htmlJSToggle`) is offered for HTML rendered mode (default OFF). |
| 8 | Switch to Rendered, toggle Enable JS on | Page reloads fresh with JS opt-in; default-deny was active before. |
| 9 | On `pic.png`: open the **Open As** dropdown (`mdv.openAs`) | Menu lists **Auto + every applicable viewer** (Image, HEX, …), with the magic-byte-sniffed likely category (Image) floated near the top. Pick **HEX**. |
| 10 | After forcing HEX | The chip is **accent-tinted** (overridden); the view becomes the byte grid (HexView) and the picker collapses appropriately. Pick **Auto** → reverts to native Preview. |
| 11 | `open_path bin.dat` (unknown binary) | Only **one** available mode (HEX) → the ModeBar mode-picker is **hidden entirely**; Open As chip still available to force another viewer. |
| 12 | `open_path db.sqlite` (≤8KB) | Routes to native **Preview** (SQLite browser via `.preview`), **not** HEX (the historic hex-carry bug). |

**Variations / edge-states**
- **Carry-mode on switch:** with `data.json` in **Format**, switch to `notes.md` → Format isn't in markdown's available modes, so it falls back to the natural default (Rendered). Switch back to a JSON tab → an explicitly-picked non-default mode carries only when the new file's `availableModes` contains it.
- **Open As forces viewer default:** Open `db.sqlite` **As CSV** → routes to Table; Open `pic.png` **As HEX** → byte grid. Auto clears the override.
- **No current URL:** on a blank tab the Open As chip is hidden (no URL).
- **Async loader race (latest-switch-wins):** rapidly toggle a text file HEX↔Source several times fast → the final picker selection and the rendered view must agree; **no** HexView left under a non-HEX picker, **no** endless spinner. (Regression guard for Bug C.)
- **Editor refusal:** force a >50MB file's Open As to Editor → Editor segment refused / `LargeEditorPlaceholderView` with a "View as Source" CTA, not an upgrade.
- **High zoom overflow:** at ~300% zoom the ModeBar picker must use `.fixedSize` intrinsic content and not overflow/clip the toolbar.

---

## SC-CHROME-03 — *(consolidated into the Sessions area — removed)*

> **Removed (duplicate).** This smoke was a near-complete clone of the dedicated
> **Sessions** area. Every surface it exercised is owned there with the same or
> deeper assertions:
> - session create / switch / per-session tab survival → `sessions.md` **SESS-01**
> - `+` → GoToPathPrompt new-session entry → **SESS-02**
> - inline rename → **SESS-03**
> - per-session sidebar root / expansion / Open-As restore → **SESS-05**, **SESS-07**
> - GLOBAL-vs-per-session zoom/wrap/theme (#184) → **SESS-06**
> - session shortcuts (⇧⌘N / ⌃⇥ / ⌃1-9 / ⇧⌘W) + Close Other Sessions → **SESS-11**, **SESS-12**
> - single-session-layout strip absence → **SESS-12**
> - workspace autosave / restore / bloat-heal → **SESS-07**, **SESS-10**
>
> The *chrome-composition* angle this smoke implicitly guarded (the
> `SessionTabBar` + its `Divider` sitting atop the TabBar/ModeBar/StatusBar stack,
> present only when `sessionsApp` is injected) is asserted by **SC-CHROME-05**
> (chrome assembly) and **SESS-12** (strip presence vs session count). The id is
> retired — not recycled.

---

## SC-CHROME-04 — StatusBar fidelity: live Ln/Col, metrics, stale-on-disk Modified chip, type-aware fields

**Combines:** Bottom status bar (`mdv.statusBar`), live caret channel (SourceViewChannel, no full republish), File watching / auto-reload, ViewThatFits truncation under width pressure, media/binary metric suppression, large-read-only sentinel.

**Preconditions**
- Clean launch; fixtures: `src.py` (multi-line text), `img.jpg` (image), `big.log` (>64MiB, large-read-only), all in a temp dir.

**Steps**

| # | Action / script-verb | Expected result |
|---|---|---|
| 1 | `open_path src.py` in Source mode | StatusBar visible. Left: `~`-abbreviated path (`mdv.statusBar.path`). Right metrics: **Ln/Col**, **Lines**, **Chars**, **Size**, **Indent** (Tabs/Spaces(n)), **EOL** (LF/CRLF/CR), **Enc** (UTF-8/…). Trailing **Created/Modified** date chips. |
| 2 | Click into the text, move the caret with arrow keys | **Ln/Col updates live** as the caret moves — *without* a full content republish (the SourceViewChannel path). |
| 3 | Hover a metric chip | Tooltip shows `Label: value` (e.g. `Lines: 412`). Hovering a `.helpInfo` control feeds the center description slot (`mdv.statusBar.helpDescription`). |
| 4 | Externally modify `src.py` on disk (atomic write) while the tab is **not** dirty | Auto-reload kicks in within ~1s; metrics update to the new content. |
| 5 | Make the tab dirty (Editor mode, type), then externally modify `src.py` on disk | The **Modified** chip (`mdv.statusBar.modified`) and its value render **RED**, with the "changed on disk" VoiceOver hint + tooltip. (Conflict NSAlert path is exercised by the editor smokes; here just assert the red staleness signal.) |
| 6 | `open_path img.jpg` (Preview) | Ln/Col **hidden** (line==0 sentinel); StatusBar shows Size + a `binary`/image-category encoding readout; date chips per availability. |
| 7 | `open_path big.log` (>64MiB) | Large-read-only fast path: highlighting auto-off, Ln/Col publishes the **line==0 sentinel** → Ln/Col chip hidden; soft-wrap forced; Size shown. App must not hang. |
| 8 | Narrow the window aggressively | **ViewThatFits** drops fields in priority order: the **path head-truncates first**, then the **date chips drop**; the **live metric chips never truncate** (`.fixedSize`). The bar stays one row, never wraps or clips the chrome. |
| 9 | ⌘T to a blank tab (no currentURL) | StatusBar **disappears entirely**. |

**Variations / edge-states**
- **No file dates:** a file with no creation date omits just the Created chip (Modified can still show).
- **Degenerate single-line minified JSON:** open a huge single-line JSON in Source → must not hang building the newline index (plain fast path); Ln/Col still sane.
- **Deleted active tab:** delete the open file on disk → the Modified chip goes red ("changed on disk"); the tab stays open (no tab dot today — status-bar red is the only affordance).
- **VoiceOver:** the right metrics group reads as **one** combined VoiceOver element.
- **Perf:** rapid caret movement must not spike RSS (the publishSelection O(log lines) newline-offset cache; the old @Published runaway).

---

## SC-CHROME-05 — Chrome-pin invariant: rails + accordion over-subscription and resize never blank/compress the bars

**Combines:** Window chrome assembly (chrome-pin invariant) · `BoundedAccordionScroll` window-clamp not pushing StatusBar off-bottom · StatusBar visibility coupling · TabBar non-blank-on-resize (Bug A) · Toggle Sidebar (⌃⌘S) master switch.

> **Scope note (dedup):** the shoulder-rail *behavior* itself — per-kind panel
> toggles, `SidebarDataPresence` icon fill/unfill, divider gating, forced-shown
> empty-panel placeholders, rail contrast/hover — is owned by
> `sidebar-filetree-and-bookmarks.md` **SFB-05** (and panel resize by **SFB-06**).
> This smoke uses the rails only as a *lever* to over-subscribe the accordion and
> then asserts the **chrome-composition** invariants that are unique to this area:
> the TabBar/ModeBar/StatusBar never blank, compress, or get pushed off-screen.

**Preconditions**
- Clean launch; open a **git repo** folder as the sidebar root (so Git/Problems/etc. panels can have data) with at least one source file and some recents.
- Window at a modest height so over-subscription is reachable.

**Steps**

| # | Action / script-verb | Expected result |
|---|---|---|
| 1 | Toggle ON **7-8 panels** at once via the left rail (`mdv.rail.left.<kind>`: Git, Search, Bookmarks, Claude, Problems, Recent, Plugins, …) | The accordion does **not** push the StatusBar off the window bottom (the P1 regression). Instead it is **window-clamped** (`BoundedAccordionScroll`, ~62% ceiling) + scrolls + `.clipped`. The StatusBar stays pinned at the bottom. (Rail toggling / data-presence / divider hygiene detail → **SFB-05**.) |
| 2 | Drag the window's bottom edge up to shrink it well below chrome+min-content | **Chrome-pin holds:** TabBar / ModeBar / StatusBar keep fixed heights; only the center band compresses. No bar blanks, compresses, or clips. (Regression guard for Bug A / chrome-compression / P1.) |
| 3 | Drag the window's **right** edge to make it very narrow (<248pt sidebar region) | Sidebar header menu value-labels collapse to **icon-only**; the TabBar must **not** blank on resize (Bug A guard — `availableWidth` measured via a non-layout `.background(GeometryReader)`). |
| 4 | `⌃⌘S` toggle sidebar off | The entire left rail + sidebar collapse (master switch `sidebar.isVisible`); the center content claims the freed width; chrome bars stay put. `⌃⌘S` again restores. |
| 5 | With `sessionsApp` injected, confirm the chrome stack order | `SessionTabBar` (+ its `Divider`) sits atop the TabBar → ModeBar → center band → StatusBar; it is present only when `sessionsApp` is injected (the assembly that **SC-CHROME-03** previously also touched — now owned here + **SESS-12**). |

**Variations / edge-states**
- **Pre-measurement first pass:** on first paint (available height ≤0) the accordion hugs content with no ceiling until height settles — no flicker of clipped panels.
- **Forced-shown empty panel still pins chrome:** force-show Git outside any repo → the `Not a git repository.` placeholder keeps a fixed-height envelope and does not destabilize the bar layout (placeholder *content* asserted in **SFB-05** / **GP-01**).
- **High-zoom + over-subscription:** at ~300% zoom with several panels open, the bars still hold fixed heights and the ModeBar picker uses `.fixedSize` (no toolbar overflow).

---

## SC-CHROME-06 — Split view + zoom + window-drop, all chrome bars cooperating

**Combines:** Split view (⌘\ / ⇧⌘\), Zoom / UI scale (⌘= / ⌘- / ⌘0, content + chrome), Window chrome assembly + native window (drag-drop overlay, title/represented doc), Tabs per-pane, StatusBar, large-file split guard, SQLite-unsupported-in-split.

**Preconditions**
- Clean launch; fixtures: `left.md`, `right.json`, `big.bin` (>64MiB), `db.sqlite` in a temp dir.

**Steps**

| # | Action / script-verb | Expected result |
|---|---|---|
| 1 | `open_path left.md` | Single pane, `left.md` rendered. |
| 2 | ⌘\ (toggle split) | Two viewer panes appear side-by-side; each has its own tabs + content + a close button. The chrome bars (Session/Tab/Mode/Status) remain single, framing both panes. |
| 3 | In the second pane, `open_path right.json` | Right pane shows `right.json` (its own tab/content); left pane keeps `left.md`. Each pane claims `maxWidth/maxHeight:.infinity` (no intrinsic-size collapse). |
| 4 | ⇧⌘\ (swap panes) | The two panes swap content/positions. |
| 5 | ⌘= three times (zoom in +10% each, cap 3.0) | **Both content and chrome scale together**: WKWebView `pageZoom`, NSTextView font (13*zoom), and the chrome bar labels/heights all grow. Zoom % readout in Settings reflects it. |
| 6 | ⌘0 (actual size) | Resets to 100%; chrome + content snap back. ⌘- below 0.5 floors. |
| 7 | Drag a file from Finder over the window | A **3pt accent rounded-rect drop overlay** highlights the whole window (`allowsHitTesting false`). Dropping routes the file via `handleDrop`. |
| 8 | Open a **new tab** in either pane after a split | New tabs land in the pane that has focus; ⌘1-9 / ⌥⌘→ operate within that pane's strip. |

**Variations / edge-states**
- **Large-file split guard:** open `big.bin` (>64MiB) in a split pane → `File too large for split view` placeholder (the body re-reads whole-file synchronously, guarded by `isSplitFileTooLargeForSyncRead`).
- **SQLite unsupported in split:** open `db.sqlite` in a split pane → `Open SQLite files in the main pane.` placeholder; the CSV/text/md paths do render in split.
- **Split layout persists:** quit + relaunch → the window remembers the split layout (per-session `splitURL`).
- **Zoom persistence:** zoom persists across opening a new tab (the previously-flaky case); zoom is **GLOBAL**, not per-session (so it's shared after a session switch too — cross-check with SC-CHROME-03 step 8).
- **Window recenter:** launch with a persisted off-screen / removed-screen frame → the window re-centers (no stranded window).
- **Window title:** on every tab/pane focus change the NSWindow title + represented document update via the Combine sink; `TextView`/`MarkdownViewer` fallback when no file.

---

## Run notes

- **Occlusion:** these are live-window smokes — run them on the VM/GUI lane. The compositor-blank class of bug (TabBar/ModeBar/Sidebar/StatusBar not compositing to WindowServer) is **only** detectable via `screencapture(1)` on a live window; in-process `cacheDisplay`/`ImageRenderer` raster will *not* catch it. Where a smoke asserts "bar did not blank/compress," a WindowServer pixel check (T5) is the authoritative verifier; the T4 a11y-tree check is a cheaper proxy.
- **Known acceptable noise:** the `mdv.tabbar` a11y-id may not propagate to the underlying NSView on some SwiftUI versions (some interaction-script tests XCTSkip on that). When the id is unreachable, fall back to model-level / Window-menu assertions for tab identity.
- **Do not** force the heavy tiers onto the host (a window would open and disrupt daily work) — these belong to the nightly VM lane.
