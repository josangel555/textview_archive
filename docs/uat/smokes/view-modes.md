# UAT smokes — View modes (source / editor / hex / rendered / preview / formatted)

**Area:** Content viewer / view-mode routing (`ViewMode` + `ViewModeOptions` + ModeBar +
Open-As override + per-mode content surfaces).

These are durable, end-to-end smokes. Each one **combines multiple features into one
realistic user flow** — it is not a unit assertion. Run them live against the installed
`dist/TextView.app` (Finder name TextView.app, bundle id `com.markdownviewer.MarkdownViewer`).

## Source of truth

`ViewMode` raw values (used verbatim by the `editor-set-mode <rawValue>` script verb and
the MCP `set_view_mode` enum):

```
rendered  source  editor  formatted  table  diff  preview  hex
```

Default-mode precedence (`ViewModeOptions.defaultMode`):
`diff > table > rendered(md/mermaid) > preview(media/sqlite) > hex(binary/unknown) > source`.

Per-type available modes (`ViewModeOptions.availableModes`) — the ModeBar picker shows
**only these**, in this order:

| File type            | Picker offers (left→right)                     | Default  |
|----------------------|------------------------------------------------|----------|
| `.md` / `.mmd`       | Rendered, Source, Editor, HEX                  | Rendered |
| `.html` / `.htm`     | Source, Rendered, Editor, Formatted, HEX       | Source   |
| `.json` / `.xml` …   | Source, Editor, Formatted, HEX                 | Source   |
| `.csv` / `.tsv`      | Table, Source, Editor, Formatted, HEX          | Table    |
| `.diff` / `.patch`   | Diff, Source, HEX                              | Diff     |
| other text / code    | Source, Editor, HEX                            | Source   |
| image/audio/video/pdf/sqlite | Preview, HEX                           | Preview  |
| binary / unknown     | HEX only (picker hidden)                       | HEX      |

## ModeBar surface IDs (live a11y identifiers)

| Element                          | a11y id              |
|----------------------------------|----------------------|
| Mode segmented picker            | `mdv.modebar`        |
| Open-As chip + dropdown          | `mdv.openAs`         |
| Language-badge chip + menu       | `mdv.languageBadge`  |
| Wrap toggle (source/format)      | `mdv.wrapToggle`     |
| Show-invisibles ¶ toggle         | `mdv.invisiblesToggle` |
| Enable-JS toggle (HTML rendered) | `mdv.htmlJSToggle`   |
| HEX byte grid                    | `mdv.hexView`        |
| CSV table                        | `mdv.csvTable`       |
| CM6 editor host                  | `mdv.editor`         |

## Script verbs available for these flows

`open <path>` · `open-lazy <path>` · `select-tab <1-based>` · `toggle-view`
(⇧⌘R rendered↔source) · `editor-set-mode <rawValue>` · `toggle-format` (⌥⌘F) ·
`open-as <path>` / `set-open-as <category>` · `zoom-in` / `zoom-out` / `zoom-reset` ·
`editor-set-text <text>` · `editor-save` · `snapshot`.
Keyboard equivalents to drive the live app: ⇧⌘R toggle rendered/source, ⌥⌘F Pretty-Print,
⌃⌘H Open As HEX, ⌘= / ⌘- / ⌘0 zoom, ⌘\\ split.

---

## SMOKE VM-01 — Markdown: default Rendered, ⇧⌘R round-trip to Source, find in both, zoom carries

**Combines:** default-mode routing (md→Rendered) · ModeBar picker · ⇧⌘R toggle-view ·
rendered WKWebView find (⌘F) · source NSTextView find · zoom (chrome + content) · mode
carry on tab switch · Ln/Col status bar.

**Preconditions**
- App freshly launched, no workspace restore noise (`MDV_SKIP_WORKSPACE_RESTORE=1`).
- A real `.md` fixture with headings, a GFM table, a fenced code block, and a body word that
  appears ≥3 times (e.g. "render"). Keep it < 4 MB (under the `markdownRenderMaxBytes` cap).

**Steps**
1. `open <fixture.md>` → opens in a tab; default ViewMode is **Rendered**. ModeBar picker
   (`mdv.modebar`) shows **Rendered | Source | Editor | HEX** with Rendered selected.
   - *Expect:* WKWebView paints HTML (heading typography, bordered table, highlighted code
     fence). No "too large" placeholder. Status bar shows path; Ln/Col **hidden** (rendered).
2. Press **⌘F**, type the repeated word → MarkdownFindBar overlay appears with an **X of N**
   match count and colored highlights injected into the page.
   - *Expect:* count ≥ 3, first match highlighted. The regex toggle is **absent** (WKWebView
     find can't regex); only Match-case (Aa) is offered.
3. Press **⌘G** twice (Find Next), then **⌥⌘G** (Find Previous).
   - *Expect:* selection steps forward then back; count readout updates; the view scrolls to
     keep the active match visible (no "can scroll past current match" stuck state). Press
     **Esc** → highlights cleared (no leftover yellow).
4. Press **⇧⌘R** (or pick Source in `mdv.modebar`) → switches to **Source**.
   - *Expect:* monospaced read-only NSTextView with the **raw markdown** text + line-number
     gutter. Status bar now shows **Ln/Col**, Lines, Chars. Language badge reads `Markdown`.
5. Press **⌘F**, type the same word, toggle **Regex (.\*)** on, search `rend\w+`.
   - *Expect:* source find honors regex (rendered did not); X-of-N count; ⌘G / ⌥⌘G step;
     clicking a minimap tick on the right rail jumps to that match's line.
6. **⌘=** twice (zoom in), then switch back to Rendered via **⇧⌘R**.
   - *Expect:* both source font (13·zoom pt) **and** chrome scaled up; Rendered WebView is
     page-zoomed to match. Zoom is global, so it persists. **⌘0** resets.

**Variations / edge-states**
- **Oversized md (> 4 MB):** open a 5 MB markdown → `LargeMarkdownPlaceholderView`
  ("Markdown too large to render" + byte size + **View as Source** button), no render
  attempt. Click the button → lands in Source. ⇧⌘R should not re-trigger a render.
- **Standalone `.mmd`:** opens straight into Rendered (synthesized single ```mermaid fence);
  picker still reads Rendered | Source | Editor | HEX.
- **Same-length external rewrite:** edit the file on disk to a different body of the **same
  byte count**, wait ~1 s → auto-reload re-renders (rendered-HTML cache is keyed on
  byteCount+mtime, so a same-length change must still invalidate). Stale render here is a bug.
- **No-match find:** type a string not present → count shows **0** / "No matches", no
  highlights, no scroll jump.

---

## SMOKE VM-02 — Same text file across Source ↔ Editor ↔ HEX (dirty state, save, mode carry, large-file caps)

**Combines:** Source view · CM6 Editor mode · dirty-dot + ⌘S save · HEX byte grid ·
ModeBar picker carry · Editor large-file placeholder · Editor→HEX flash (#219) ·
status-bar EOL/Enc/Size · auto-reload after save · text-vs-binary classification.

> **Scope note (dedup):** the *editor lifecycle* — dirty-dot debounce, the two
> save entry points (AppKit ⌘S vs CM6 `Mod-s` bridge), save-on-blur, undo/redo
> routing, the external-edit **conflict prompt**, the 50 MB cap, indentation /
> fold / go-to-line, per-tab cursor restore — is owned by the **cm6-editor**
> area (`cm6-1..5`). Here those appear only as *supporting beats* for the
> Source↔Editor↔HEX **mode-routing** story; assert the routing, defer the editor
> internals to cm6-editor.

**Preconditions**
- A small editable text/code fixture (e.g. a `.py` or `.txt`, a few KB, LF line endings,
  UTF-8) in a writable temp dir (NEVER `~/Documents` / `~/Desktop` / `~/Downloads`).
- Optional: a ~60 MB text file for the editor-cap variation.

**Steps**
1. `open <fixture.py>` → opens in **Source** (default for plain code). Picker shows
   **Source | Editor | HEX**.
   - *Expect:* syntax-highlighted read-only NSTextView; gutter; status bar shows
     Ln/Col, Lines, Chars, Size, **EOL = LF**, **Enc = UTF-8**, Indent.
2. Select **Editor** in `mdv.modebar` (or `editor-set-mode editor`).
   - *Expect:* CM6 editor (`mdv.editor`) mounts — NOT a blank white box, NOT a flash of an
     empty editor. Line gutter, fold chevrons, active-line highlight present. Tab is clean
     (no dirty dot, Save menu greyed).
3. Type a few characters (or `editor-set-text <newtext>`).
   - *Expect:* edit lands in the in-memory `EditorBuffer`; within ~200 ms the **dirty dot**
     (`mdv.tab.dirtyDot`) appears on the tab and **Save (⌘S)** becomes enabled.
4. Press **⌘S** (or `editor-save`).
   - *Expect:* buffer flushes to disk atomically; dirty dot clears; Save greys out again.
     Because the file is watched, no spurious external-change conflict prompt fires from our
     own save.
5. Switch to **HEX** (pick HEX in `mdv.modebar`, or **⌃⌘H**, or `editor-set-mode hex`).
   - *Expect:* `mdv.hexView` 3-column dump (8-digit offset / grouped hex / ASCII) reflecting
     the **just-saved** bytes. *Known issue #219:* a transient **flash of Source** may appear
     during the Editor→HEX transition — note it if seen but it is a known open bug, not a fail.
6. Switch back to **Source** via the picker.
   - *Expect:* Source re-renders the saved content; no HexView leaking under a non-HEX picker
     (the latest-switch-wins race, Bug C, must hold).

**Variations / edge-states**
- **Editor cap (> 50 MB):** open the ~60 MB text file, select Editor → `LargeEditorPlaceholderView`
  (`mdv.editor.largePlaceholder`, "File too large for editor mode" + size + **View as Source**).
  `setCurrentViewMode(.editor)` must **refuse the upgrade** — picker should not get stuck.
- **Mode carry on file switch:** with Editor explicitly selected, `open` a second text file →
  the new tab should carry **Editor** only if its `availableModes` contains it; if you'd
  explicitly picked HEX then open a markdown file, HEX carries (md offers HEX) but the natural
  default differs — verify carry-vs-default fallback behaves per the table above.
- **CRLF / UTF-16 fixture:** open a CRLF file → status bar **EOL = CRLF**; open a UTF-16-LE
  (BOM) file → **Enc = UTF-16 LE** and it must render as **text** (Source), not get
  misclassified as binary and forced to HEX. (This text-vs-binary *classification* is the
  view-mode concern owned here; the editor *conflict prompt* is owned by cm6-editor — below.)
- **External edit while dirty (cross-reference only):** the conflict NSAlert
  (**Keep My Edits** / **Discard & Reload**, dirty-baseline preservation, watcher
  fingerprint refresh, FW-7 reconcile) is owned by `cm6-editor.md` **cm6-4** — do not
  re-walk it here. This smoke only asserts that the same buffer survives the
  Source↔Editor↔HEX *mode* round-trips without losing the dirty state.

---

## SMOKE VM-03 — Structured data: CSV Table ↔ Source, JSON Format (Pretty-Print) ↔ Source, and Open-As cross-routing

**Combines:** CSV Table-mode default · Table↔Source · JSON default Source + Format toggle
(⌥⌘F / `toggle-format`) · pretty-print cache keying · Wrap + invisibles toggles in
formatted mode · Open-As override forcing a non-default viewer · per-tab override accent tint.

**Preconditions**
- A `.csv` with a header row and ≥20 data rows (one column numeric for the comparison filter).
- A `.json` fixture that is **minified** (single long line) and valid.
- A `.json` that is **invalid** (broken syntax) for the negative path.

**Steps**
1. `open <fixture.csv>` → opens in **Table** (default). Picker reads
   **Table | Source | Editor | Formatted | HEX**.
   - *Expect:* column-major grid (`mdv.csvTable`) with pinned header, alternating row shading;
     filter bar row-count label shows `N/N`.
2. Type in the global filter field (`mdv.csvFilter.global`) → debounced (~200 ms) filtering;
   row-count label drops to `M/N`. Clear it → immediately back to `N/N`.
3. Switch to **Source** in `mdv.modebar`.
   - *Expect:* raw CSV text in the NSTextView; per-tab CSV filter state is preserved (switch
     back to Table → the filter you typed, if re-typed, persists per tab id).
4. `open <fixture.json>` (minified) → opens in **Source** (the conservative default; JSON does
   NOT default to Format). Picker reads **Source | Editor | Formatted | HEX**.
   - *Expect:* one long unwrapped line; horizontal scroll.
5. Press **⌥⌘F** (Pretty-Print) or select **Formatted** / `toggle-format`.
   - *Expect:* pretty-printed multi-line JSON rendered through the Source NSTextView path;
     View menu **Pretty-Print** shows a checkmark. The **Wrap** (`mdv.wrapToggle`) and
     **invisibles ¶** (`mdv.invisiblesToggle`) toggles are available in formatted mode.
6. Toggle **Wrap** on, then **invisibles** on.
   - *Expect:* long lines soft-wrap; whitespace glyphs appear (note: known to render a touch
     too grey — cosmetic, not a fail).
7. **Open-As cross-routing:** `open-as <fixture.csv>` then `set-open-as code` (force the CSV
   open through the Source/JSON lens) — or use the **Open As** chip (`mdv.openAs`) → choose
   **Source**.
   - *Expect:* the CSV now opens with Source as default; the Open-As chip is **accent-tinted**
     (override active) with a tooltip; picker reflects the forced viewer's modes. Selecting
     **Auto** in the chip clears the override and reverts to Table default.

**Variations / edge-states**
- **Invalid JSON + Pretty-Print:** open the broken JSON, press ⌥⌘F → Format should fail
  gracefully (no crash; either unchanged source or a benign warning), not blank the pane.
- **jq filter (smoke-test only that it's reachable here):** with the valid JSON active, **⌥⌘J**
  (Apply jq Filter…) is **enabled** for the Format/JSON viewer. The full jq pipeline —
  out-of-process run, result-as-new-`.json`-tab, cache keying, missing-binary brew-hint NSAlert,
  filter-error NSAlert, runaway-filter caps, css/xpath absence — is owned by `search.md`
  **SMK-SEARCH-06**; do not re-walk it here, just confirm the menu/accelerator surfaces for JSON.
- **Pretty-print cache correctness:** format the JSON, edit the file on disk to a **same-byte-length**
  variant, reformat → must reflect the new content (cache keyed on tabID+mtime+byteCount, not
  length alone — the historical stale bug).
- **Force HEX on text:** `set-open-as` to HEX (or ⌃⌘H) on the CSV → HEX byte grid; picker
  collapses appropriately. Selecting **Auto** restores Table.
- **Filtered-to-zero CSV:** type a filter matching nothing → header row only, `0/N` rows, no
  crash.

---

## SMOKE VM-04 — Native preview vs HEX routing (the "fresh image → HEX" + carry-flip regressions)

**Combines:** Preview default for media/sqlite · Preview↔HEX as the only two lenses · the
historical native-preview→HEX carry-flip bugs (Bug B) · binary/unknown HEX-only (picker
hidden) · HEX entry cost (#218) · image control bar · Preview↔HEX round-trip not getting stuck.

> **Scope note (dedup):** the *HEX viewer internals* — hex/ASCII search modes,
> even-nibble validation, non-overlapping match semantics, prev/next wrap, the
> 50k match cap, bytes-per-row width rebuild, click-to-highlight teal overlay,
> streaming dump build — are owned by `previews.md` **PV-07** (HEX-as-universal-
> fallback) and `search.md` **SMK-SEARCH-05** (HEX search end-to-end). This smoke
> covers only the **view-mode routing** angle: that media/sqlite default to
> Preview (never HEX), that Preview↔HEX is the sole two-lens pair, and that the
> round-trip never strands a HexView under a non-HEX picker.

**Preconditions**
- A `.png` (or `.jpg`) image fixture with known pixel dimensions.
- A small `.db`/`.sqlite` (a few KB) with at least one table.
- A truly binary fixture with **no** native preview (e.g. a `.bin` / random bytes, or an
  unknown extension).

**Steps**
1. `open <fixture.png>` → opens in **Preview** (NOT HEX). Picker shows **Preview | HEX** only.
   - *Expect:* native `MediaPreviewView` image, auto fit-to-window, centered (not corner-pinned).
     Image control bar shows zoom %, Fit, 1:1, and pixel-dimension readout. Right-side
     MetadataPanel shows File + Image dims. **This is the explicit regression guard for "fresh
     image defaulted to HEX" (Bug B) and the native-preview→HEX carry-flip.** (Deep image
     fit/zoom/pan/sibling-nav coverage lives in `previews.md` **PV-01**.)
2. Switch to **HEX** (picker, or ⌃⌘H).
   - *Expect:* `mdv.hexView` paints the image's raw bytes. A bare small file should appear
     reasonably fast (note: #218 — HEX mode entry can take ~1 s even for ~6 KB; flag slowness
     but it is a known open perf issue, not a hard fail). HEX search / width / click-highlight
     mechanics → **PV-07** / **SMK-SEARCH-05**.
3. Switch **back to Preview** via the picker.
   - *Expect:* the native image returns; the round-trip does **not** leave a HexView stuck
     under a Preview picker (the latest-switch-wins race, Bug C, must hold — see VM-06).
4. `open <fixture.db>` → opens in **Preview** (SQLite browser), NOT HEX.
   - *Expect:* HSplitView schema sidebar + query pane; clicking a table seeds
     `SELECT * FROM "..." LIMIT 100;` and auto-runs. Picker shows **Preview | HEX**. Switching
     to HEX shows raw db bytes; switching back to Preview must NOT stay stuck on HEX. (Full
     SQLite-browser coverage → `previews.md` **PV-04**.)

**Variations / edge-states**
- **Binary / unknown file:** `open <fixture.bin>` → opens straight into **HEX** and the ModeBar
  **picker is hidden entirely** (single available mode). The Open-As chip can still force other
  lenses, but the segmented picker should be absent.
- **Empty file:** open a 0-byte file in HEX → "Hex dump, 0 bytes" (no crash).
- **Corrupt image:** an undecodable image → no image drawn, dimension readout hidden, control
  bar still present, no crash. (Corrupt-media edge depth in **PV-01/02**.)

---

## SMOKE VM-05 — Diff & HTML specialized rendered views, plus the universal Empty/Loading/Error envelope

**Combines:** `.diff` default Diff-mode · Diff↔Source raw-unified lens · `.html` Source-default
+ separate sanitized Rendered path + per-tab Enable-JS toggle · large-HTML placeholder ·
Empty/Loading/Error content states swapping regardless of mode · path/title in ModeBar.

**Preconditions**
- A real unified `.diff`/`.patch` fixture with ≥2 file blocks, adds + dels.
- An `.html` fixture with a heading, a link, and an inline `<script>` (to verify JS is stripped
  by default).
- A > 4 MB `.html` for the large-HTML placeholder variation.
- A path to a **nonexistent** file for the error path.

**Steps**
1. `open <fixture.diff>` → opens in **Diff** (default). Picker reads **Diff | Source | HEX**.
   - *Expect:* structured `DiffView` — per-file rounded block, header with status badge
     (A/D/R/M) + path + `+adds −dels`, hunk banners `@@ -old,N +new,N @@`, green-added /
     red-removed line rows with old#/new# cells. Vertical + horizontal scroll; lazy per-file.
2. Switch to **Source**.
   - *Expect:* raw unified-diff text (per-line `DiffHighlighter`, no TreeSitter). Status bar
     shows Ln/Col. Switch back to **Diff** → structured view returns. Note: Editor is **not**
     offered for diffs (editing a derived diff would desync).
3. `open <fixture.html>` → opens in **Source** (conservative default for untrusted HTML, NOT
   Rendered). Picker reads **Source | Rendered | Editor | Formatted | HEX**.
4. Select **Rendered**.
   - *Expect:* the SEPARATE sanitized `HTMLRenderedView` WKWebView (CSP `default-src 'none'`).
     The inline `<script>` is **stripped** (JS default-deny); the heading renders; the link,
     when clicked, opens the **system browser** (in-page file:/data:/javascript: nav is cancelled).
     The **Enable JS** toggle (`mdv.htmlJSToggle`) is visible in the ModeBar for HTML rendered.
5. Toggle **Enable JS** on.
   - *Expect:* a fresh reload; per-tab JS opt-in only (this is the only way to enable JS).
6. Switch to **Formatted** (⌥⌘F) → pretty-printed HTML through the Source path; Wrap/invisibles
   toggles available.

**Variations / edge-states**
- **Large HTML (> 4 MB):** open the big `.html`, select Rendered → `LargeHTMLPlaceholderView`
  ("HTML too large to render" + **View as Source**); no slurp of untrusted multi-MB into render.
- **Empty diff:** open a `.diff` that is unchanged/binary → "No diff content." / "Binary file —
  no textual diff." (graceful, not blank).
- **Error state:** `open <nonexistent path>` → existing tabs are **kept** and an **ErrorView**
  (exclamationmark.triangle + filename + message + **Reload** / **Reveal in Finder**) is appended
  — it must NOT clear all open tabs.
- **Loading state:** open a large file that takes > 100 ms to materialize → `LoadingStateView`
  spinner (delayed 100 ms so it doesn't flash) with the filename; no premature wrong-viewer paint.
- **State overrides mode:** Empty/Loading/Error swap the **whole content pane regardless of the
  selected ViewMode** — e.g. an error tab shows ErrorView even though the picker still reads its
  file type's modes.

---

## SMOKE VM-06 — Mode persistence, split view, and Open-As exhaustive coverage in one session

**Combines:** per-tab ViewMode persistence across tab switches · split view (⌘\\) with
independent per-pane modes · Open-As chip forcing every applicable viewer · language-badge
override · workspace snapshot restore of view mode · clamp of invalid persisted mode.

**Preconditions**
- Several fixtures open at once: one `.md`, one `.py`, one `.csv`, one `.png`.
- App able to relaunch (workspace restore enabled, i.e. NOT `MDV_SKIP_WORKSPACE_RESTORE`).

**Steps**
1. Open all four fixtures in tabs. On the `.md` tab, switch to **Source**; on the `.py` tab,
   switch to **Editor**; on the `.csv` tab, leave **Table**; on the `.png` tab, leave **Preview**.
2. Cycle through tabs with **⌥⌘→** / **⌥⌘←** (or `select-tab N`).
   - *Expect:* each tab restores **its own** last-picked mode (md→Source, py→Editor, csv→Table,
     png→Preview) — view mode is per-tab, not global.
3. Press **⌘\\** to toggle **split view** on the `.py` tab.
   - *Expect:* two panes; each pane has its own tabs/content + close button. Open a different
     file in the second pane and set a different mode → the two panes hold **independent** view
     modes. A `.db`/sqlite in a split pane shows "Open SQLite files in the main pane." (split
     SQLite unsupported). A > 64 MiB file shows "File too large for split view".
4. **Open-As exhaustive:** on the `.png` tab, open the **Open As** chip (`mdv.openAs`) → it lists
   **Auto** + every applicable viewer (Markdown rendered, Mermaid, Plain Text/CSV, Source/JSON,
   HTML, Image, Audio, Video, PDF, SQLite, HEX, Unknown). Magic-byte sniff floats the likely
   category (Image) to the top.
   - *Expect:* choosing **HEX** forces HEX + resets to that viewer's default; chip accent-tinted.
     Choosing **Auto** clears the override → back to Preview.
5. **Language badge:** on the `.py` tab in Source, open `mdv.languageBadge` → "Auto (Python)" +
   every `HighlightLanguage`. Pick a different language → re-highlights in place (no full
   re-layout); chip accent-tinted. Pick **Auto** → reverts to extension detection.
6. **Quit and relaunch** the app.
   - *Expect:* workspace restore brings back the tabs with their **persisted view modes** (md→Source,
     etc.). Lazy tabs materialize on selection. If a persisted mode is no longer valid for the file
     (e.g. file type changed), it is **clamped** to a valid default rather than showing a broken pane.

**Variations / edge-states**
- **⇧⌘\\ swap split panes:** verify the two panes exchange content and each keeps its mode.
- **Carry-mode fallback:** explicitly pick **Editor** on a text tab, then switch to a `.png` tab
  (Editor not in its availableModes) → must fall back to the image's natural default (Preview),
  not strand an empty Editor.
- **Single available mode:** select the binary fixture from VM-04 across a relaunch → picker stays
  hidden, mode stays HEX.
- **Toggle-view scope:** **⇧⌘R** only round-trips rendered↔source for markdown/mermaid; on a
  `.py` Source tab ⇧⌘R should be a no-op (no rendered mode to toggle to).

---

## Cross-cutting guards (apply to every smoke above)

- **No wrong-viewer paint:** after any mode switch or async load completion, the rendered surface
  must match the selected picker segment — never a HexView under a non-HEX picker, never an
  endless spinner (the Bug C latest-switch-wins guard, and the fd61ef-era load-bug republish fix).
- **Content actually loads:** the live app must show real file content, not "main.swift cannot be
  loaded" / a permanently empty pane — this is the exact class of regression that shipped in the
  fd11e61 build. Every smoke's step 1 implicitly asserts content rendered.
- **Chrome pin:** TabBar / ModeBar / StatusBar keep fixed heights when the window shrinks; the
  center band absorbs all shrink. The ModeBar picker must not overflow the toolbar at high zoom.
- **Known-open issues to note but NOT fail on:** #218 (HEX entry latency), #219 (Editor→HEX flash
  of Source), grey invisibles glyphs, rendered-mode ⌘F regex limitation, #201 macOS-26 host-only
  same-doc-fragment red.
