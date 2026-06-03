# UAT smokes — Search (find-bar / cross-file / unified panel / jq / css / xpath)

Durable user-acceptance smokes for the **search** area of TextView.app
(`com.markdownviewer.MarkdownViewer`). Each smoke is a realistic, multi-feature
user flow — not a unit test. Run live against the installed `dist/TextView.app`.

## Scope of this area

| Surface | Activation | Engine | Notes |
|---|---|---|---|
| Rendered find bar | `Cmd+F` in Rendered (md/mermaid/html) | WKWebView find | literal + case only — **no regex** (WKWebView limitation) |
| Source find bar | `Cmd+F` in Source/Format | `FindEngine` (NSTextView) | literal + **case + regex**, match minimap |
| Editor find bar | `Cmd+F` in Editor | CM6 search bridge | literal + case + regex, native replace panel |
| HEX search toolbar | in HEX view | `HexSearchEngine` | Hex / ASCII modes, non-overlapping, 50k cap |
| Cross-file search (modal) | `Shift+Cmd+F` | `CrossFileSearch` grep | folder grep, 500-match / 8-row caps |
| Search Anywhere (sidebar) | sidebar Search panel / rail | `CrossFileSearch` grep | live, debounced 200ms, ≥2 chars |
| CSV / SQLite filters | in those viewers | per-viewer | column-scoped filters — **owned by `previews.md` PV-04/PV-05**; here only the `Cmd+F`-vs-filter surface boundary (SMK-SEARCH-08 step 6) |
| jq filter | `Cmd+Opt+J` (Format/JSON) | `/usr/bin/jq` out-of-process | result opens as new `.json` tab |
| jq / css / xpath modes in unified panel | reserved scope-picker cases | **not engine-backed today** | only `.text` grep runs; `.css`/`.xpath`/`.jq` shape the picker, no engine/UI |

**Source-of-truth caveats baked into the smokes below (verified in code):**

- Cross-file / Search-Anywhere: skips binary (NUL heuristic), files > **2 MiB**,
  hidden files, and `.git`/`node_modules`/`.build`/`dist`/`target`/… dirs;
  total cap **500 matches**, **8 rows shown per file** then `+ N more`; hard
  walk cap **50 000 entries** (symlink-loop backstop). No true-total count.
- Search Anywhere needs **≥ 2 trimmed chars** and debounces **200 ms** async;
  query change/scope change re-runs; clearing the field empties results.
- Cross-search file-shaped scope (`Pick File…` / Active File) under the
  folder-required `.text` mode **auto-falls-back to the parent folder** — it does
  *not* search just that one file. The reserved `.jq`/`.css`/`.xpath` modes
  would require single-file scope but have **no engine or UI wired**.
- Find-bar state is **three independent bags** (rendered / source / editor) —
  query/case/regex do **not** carry between view modes.
- Rendered `Cmd+F` historically broken; match-count + highlight-clear-on-dismiss
  now plumbed, but **regex toggle is hidden** in rendered.
- jq probes `/usr/bin/jq` then `/opt/homebrew/bin/jq`; absent → NSAlert with brew
  hint; result cached under `caches/MarkdownViewer/jq` by path+filter hash.
- HEX search: hex pattern must be **even-length hex per token** (`"de a"` →
  invalid → red field); matches **non-overlapping**; match cap **50 000** shown
  as `i / N+`.

**Script verbs / a11y ids referenced:** `mdv.crossSearchPanel`,
`mdv.unifiedSearch.scope.*`, `mdv.searchAnywhere`, `mdv.searchAnywhere.scope.*`,
`mdv.hex.search.{mode,field,count,prev,next}`, `mdv.csvFilter.*`. MCP/script:
`find`, `set-cross-query`, `cross-search`, `goto_line`, `open_path`,
`set_view_mode`.

> Preconditions common to all smokes unless noted: a fresh launch of
> `dist/TextView.app`; scratch fixtures created under
> `FileManager.default.temporaryDirectory` (never `~/Documents`,`~/Desktop`,
> `~/Downloads`). Build a small fixture repo once and reuse it.

### Shared fixture (build once)

```
$TMP/uat-search/
  README.md           # has the word "needle" on 3 lines, mixed-case "Needle"
  notes.md            # CRLF line endings; "needle" once
  data.json           # {"items":[{"id":1,"tag":"needle"},{"id":2,"tag":"hay"}]}
  page.html           # <div class="needle">…</div> with a <script>
  doc.xml             # <root><item>needle</item></root>
  app.ts              # source file; "needle" in a comment + a string
  big.log             # > 2 MiB, contains "needle" (must be SKIPPED by grep)
  bin.dat             # binary w/ NUL bytes + ascii "needle" (must be SKIPPED)
  table.csv           # 4 cols incl numeric "amount"; "needle" in one cell
  latin1.txt          # CP1252/Latin-1 encoded, contains "needle"
  .hidden/secret.md   # "needle" inside a hidden dir (must be SKIPPED)
  node_modules/x.js   # "needle" (must be SKIPPED)
```

---

## SMK-SEARCH-01 — Find-bar isolation across view modes (rendered → source → editor)

Exercises the three independent find bags, mode-switch carry rules, and that
regex is offered in source/editor but hidden in rendered.

**Combines:** rendered find bar · source find bar · editor find bar ·
view-mode picker (ModeBar) · find-bag isolation · regex availability per mode.

**Preconditions:** `README.md` open (defaults to Rendered). Editor available
(file well under 50 MB cap).

| # | Action | Expected |
|---|---|---|
| 1 | `Cmd+F` in Rendered | Rendered find bar appears, field focused; **no regex (`.*`) toggle** present, Match-case (Aa) present. |
| 2 | Type `needle`, press Enter / Find Next a few times | Highlights injected; match-count readout shows `X of N`; current match scrolls into view; stepping wraps. |
| 3 | Toggle **Aa** (case) on; query stays `needle` | Re-runs case-sensitive; `Needle` (capital) no longer counts; count drops. |
| 4 | `Esc` to dismiss | Highlights cleared (no lingering yellow); query reset for rendered bag. |
| 5 | Switch ModeBar to **Source**; `Cmd+F` | Source find bar appears **empty** (rendered query did NOT carry); regex (`.*`) toggle **present**. |
| 6 | Enable regex, type `n[ae]+dle`, step with `Cmd+G` / `Opt+Cmd+G` | Regex matches `needle`; X-of-N count; minimap ticks appear on the gutter rail; prev/next steps. |
| 7 | Switch ModeBar to **Editor**; `Cmd+F` | Editor find bar appears **empty** (source query/regex did NOT carry); independent n/N count. |
| 8 | Back to Source via ModeBar; `Cmd+F` | Source bag still remembers its own regex+query from step 6 (per-view persistence within session). |

**Variations / edge-states:**
- Rendered match where **no match**: count shows `No matches` (or 0); field state non-destructive.
- `Opt+Cmd+G` is Find Previous (moved off `Shift+Cmd+G`, which is Go-to-Path) — verify Prev steps backward.
- Source minimap: click a tick → caret jumps to that match's line.
- Catastrophic regex (e.g. `(a+)+$`) typed in source: must NOT hang the UI (ReDoS guard + bounded deadline); invalid regex shows error state, not a recompile-per-keystroke stall.
- CRLF file (`notes.md`) in Source: line/column for a match must be correct (scalar-based line counting, not Character).

---

## SMK-SEARCH-02 — Cross-file search modal: scope, jump-to-line, and skip rules

The headline cross-file flow: `Shift+Cmd+F`, folder grep, click a match → open
at line, plus the binary/oversize/hidden/VCS skip guarantees.

**Combines:** cross-file modal (`mdv.crossSearchPanel`) · scope picker · live
onChange search · match-row jump to line · openPath(atLine:) → source coercion ·
skip rules (binary / >2 MiB / hidden / node_modules) · result caps.

**Preconditions:** sidebar rooted at `$TMP/uat-search/`. A tab open so Active
File scope is meaningful.

| # | Action | Expected |
|---|---|---|
| 1 | `Shift+Cmd+F` | Modal appears over scrim; field focused; scope row shows a resolved path + scope picker (`Active File` / `Active Folder` / `Pick File…` / `Pick Folder…`). |
| 2 | Set scope → **Active Folder**; type `needle` | Live results grouped by file; `README.md` shows `(3)` matches; `notes.md` (CRLF) shows its hit; `app.ts`, `data.json`, `page.html`, `doc.xml`, `latin1.txt` appear. |
| 3 | Verify **skips** | `big.log` (>2 MiB), `bin.dat` (binary NUL), `.hidden/secret.md`, `node_modules/x.js` are **absent** from results. |
| 4 | Click a file-group header for `README.md` | File opens (current tab); modal dismisses; lands at line 1 region. |
| 5 | Re-open `Shift+Cmd+F`, search `needle`, click the **2nd match row** under `README.md` | File opens AND scrolls/selects that exact 1-based line (Source mode coerced from Rendered if needed). |
| 6 | Confirm `latin1.txt` matched | CP1252/Latin-1 file is searched via the shared decode chain (not silently invisible). |

**Variations / edge-states:**
- **Caps:** craft a file with 600 hits of `needle`; results stop at 500 total, and any single file shows 8 rows then `+ N more`. There is no true-total count beyond the cap.
- **Case toggle (Aa):** with Aa off, `Needle` matches `needle`; with Aa on it does not — and the case-insensitive path must still preserve the highlighted matchRange (no dropped highlight for `ß`/`Σ`/`İ`-style folding).
- **No matches:** type `zzqqx` → panel shows `No matches`; while a scan is in flight it shows `Searching…` + spinner.
- **Empty query:** field empty → placeholder (`Type to search the folder.` or `Open a folder to search across files.` when no root).
- **Stale-result guard:** type fast (`needle` then immediately `hay`) — slow completions for the old query must NOT clobber the newer results (generation counter).
- **Symlink loop:** add `$TMP/uat-search/loop -> ..`; search must terminate (visited-inode set + 50k entry backstop), not spin.

---

## SMK-SEARCH-03 — Cross-file file-scope folder-fallback + reserved jq/css/xpath modes

Verifies the documented "single-file scope under text mode falls back to parent
folder" behavior and that the reserved `.jq`/`.css`/`.xpath` scope-picker cases
are present-but-inert (no engine wired).

**Combines:** cross-file modal · `Pick File…` scope · folder-fallback resolver ·
reserved mode scaffolding (`.jq`/`.css`/`.xpath`) · scope-disable logic ·
right-click "Search in Folder" preset.

**Preconditions:** sidebar rooted at `$TMP/uat-search/`.

| # | Action | Expected |
|---|---|---|
| 1 | `Shift+Cmd+F`; scope → **Pick File…**; choose `app.ts` | Scope row shows `app.ts`'s resolved path; mode is `.text` (folder-requiring). |
| 2 | Type `needle` | Because `.text` requires a folder, the engine **runs against `app.ts`'s parent folder** (`uat-search/`), not just that one file — results include other files too. This fallback is intentional and predictable. |
| 3 | Inspect the scope picker menu items | `Active File` / `Pick File…` are present; today they are governed by mode (`.text` keeps folder-style behavior). The `.jq`/`.css`/`.xpath` single-file modes are **reserved** — no toggle exposes them in this build, and no engine runs for them. |
| 4 | From the FILES tree, right-click a folder → **Search in Folder** | Cross-search opens with scope **pre-set** to that folder (preset scope honored on appear). |

**Variations / edge-states:**
- No active file + a folder root: scope auto-reconciles to **Active Folder** on appear.
- No root and no file: scope label reads `No active folder — pick a folder.`; Active Folder disabled.
- Confirm there is **no user-facing jq/css/xpath search mode** today — if one appears, that is a behavior change vs the catalog and should be flagged.

---

## SMK-SEARCH-04 — Search Anywhere sidebar panel: live debounce, scope, jump

The non-modal sidebar grep widget: ≥2-char gate, 200ms debounce, match
highlight, scope row (Sidebar Folder / Pick Folder… / Clear Picked Folder),
click-to-open-at-line, and the "zero Divider" layout invariant.

**Combines:** Search Anywhere section (`mdv.searchAnywhere`) · shoulder-rail
toggle · ≥2-char threshold · 200ms debounce · scope picker · query-substring
highlight · jump-to-line · empty/placeholder states · CrossFileSearch reuse.

**Preconditions:** sidebar visible, rooted at `$TMP/uat-search/`. Search panel
expanded (toggle via the left shoulder rail if collapsed).

| # | Action | Expected |
|---|---|---|
| 1 | Toggle the **Search** rail button | Search panel shows/hides; rail button fills (accent) when on, and reflects data-presence. |
| 2 | Type a single char `n` | **No search runs** (< 2 trimmed chars); placeholder `Type to search files…`. |
| 3 | Type `needle` | After ~200ms debounce, spinner then grouped results; header count chip shows total match count; matched substring rendered in accent/semibold within each line. |
| 4 | Click a match row | File opens at that 1-based line (`openPath(atLine:)`); rendered→source coercion handled. |
| 5 | Scope menu → **Pick Folder…**, choose a subfolder | Search re-runs against the picked folder; scope label updates (basename, full path on hover); a **Clear Picked Folder** item now appears in the menu. |
| 6 | Scope menu → **Clear Picked Folder** | Reverts to the sidebar root; results re-run. |
| 7 | Clear the field (x button) | Results emptied immediately; back to `Type to search files…`. |

**Variations / edge-states:**
- **Aa case toggle** in the section: flips case sensitivity and re-runs; highlight ranges still align (UTF-8 offset mapping).
- **Layout invariant:** the section body must contain **zero `Divider()`** — no spurious horizontal line under "Search". (Regression guarded by `SearchAnywhereSectionLayoutTests`.)
- **No root:** with no folder open, scope label reads `No folder`; Sidebar Folder disabled; typing yields nothing.
- **Rapid typing:** debounce + task cancellation means only the latest query's scan lands (no stale results).
- **Fixed envelope:** empty/short/populated states all occupy the same panel height (no jumpiness).

---

## SMK-SEARCH-05 — HEX viewer search: hex/ASCII modes, validation, stepping, caps

Binary-file search end-to-end: open-as-HEX, hex-pattern + ASCII-string modes,
invalid-query red state, non-overlapping matches, wrap-around stepping,
click-to-highlight, and the 50k cap readout.

**Combines:** Open As → HEX · HEX search toolbar (`mdv.hex.search.*`) ·
Hex/ASCII segmented mode · query validation · non-overlapping match semantics ·
prev/next + wrap · click-to-highlight overlay · 50k match cap · bytes-per-row.

**Preconditions:** `bin.dat` (or any binary) available. Open it (binary defaults
to HEX), or use **Open As → HEX** on a text file.

| # | Action | Expected |
|---|---|---|
| 1 | Open `bin.dat` | HEX view: offset / hex bytes / ASCII columns; `mdv.hexView` present; streaming `Building hex dump…` placeholder may flash then resolve. |
| 2 | Search mode = **Hex**; type `de ad be ef` (matching a known pattern) | Yellow highlights on hex + ASCII columns at each non-overlapping start; active match orange and auto-scrolled into view; count `mdv.hex.search.count` shows `i / N`. |
| 3 | `Enter` / Next (`Cmd+G`), then past the last match | Stepping **wraps around** to the first match. |
| 4 | Type an invalid hex query `de a` (odd nibble in token) | Field turns **red** / shows `invalid`; no highlights. |
| 5 | Switch mode → **ASCII**; type `needle` | Matches recomputed against UTF-8 bytes of `needle`; highlights on the ASCII column bytes. |
| 6 | Click a byte in the dump | Same-value bytes highlight teal (click-to-highlight overlay); `Esc` or empty-click clears. |
| 7 | Change **bytes-per-row** (e.g. 16 → 32) | Dump rebuilds at new width; matches re-laid-out; wider widths side-scroll. |

**Variations / edge-states:**
- **Non-overlapping:** for bytes `AA AA AA` searching `AA AA` → result starts at offset 0 only (not 0 and 1).
- **Zero matches:** valid pattern with no hit → `0 matches`.
- **Cap:** a pattern with > 50 000 hits → count shows `i / N+`; cannot step past the 50 000th; paint bounded.
- **Empty file:** `Hex dump, 0 bytes`; search yields nothing, no crash.
- **Editor → HEX:** known transient flash of Source during mode transition (`#219`, open) — note but do not fail the smoke on it.
- **HEX entry latency:** a 6 KB file may take ~1s to enter HEX (`#218`, open) — note, don't fail.

---

## SMK-SEARCH-06 — jq filter pipeline (Format/JSON → result tab) with absence + error handling

Drives the jq filter prompt over a JSON document: apply a filter, get a new
`.json` result tab; then the unsupported-file disable, missing-binary NSAlert,
and filter-error NSAlert paths.

**Combines:** Format/JSON viewer · jq filter prompt (`Cmd+Opt+J`) · out-of-process
jq (timeout + resource caps) · result-as-new-tab · result cache · menu
enable/disable gating · error/absence alerts.

**Preconditions:** `data.json` open. (To exercise step 6, temporarily ensure jq
is absent on PATH probes — or document the expected alert without uninstalling.)

| # | Action | Expected |
|---|---|---|
| 1 | Open `data.json`; confirm Format available | `Cmd+Opt+J` (Apply jq Filter…) is **enabled** for JSON/JSONL/XML/plist/SVG/HTML; View menu item not greyed. |
| 2 | `Cmd+Opt+J`; prompt defaults to `.`; enter `.items[].tag`; Apply | jq runs out-of-process; result opens as a **new `.json` tab** containing `"needle"` and `"hay"` (one per line). |
| 3 | Re-apply the same filter on the same file | Result served from cache (`caches/MarkdownViewer/jq` keyed by path+filter hash) — no re-spawn needed; identical output. |
| 4 | Apply a **bad filter** `.items[` (syntax error) | Warning NSAlert surfaces jq's stderr (`jq: error …`); no result tab created; original document untouched. |
| 5 | Open a non-text/binary or unsupported file; check menu | Apply jq Filter… is **disabled** (jq only offered when current file is loaded supported text). |
| 6 | (jq absent on PATH) `Cmd+Opt+J` | NSAlert `jq is not installed` with a Homebrew install hint; no crash. |

**Variations / edge-states:**
- **Runaway filter** (`def f: f; f` or `[range(1e9)]`): terminated by the 10s wall-clock + CPU rlimit / 256 MB stdout cap → surfaces `outputTooLarge` / timeout error, never OOMs the app.
- **Empty result** (filter selects nothing, e.g. `.nope`): returns cleanly (jq run without `-e`), result tab is empty/`null` rather than an error.
- **Format-mode entry:** also reachable for a text file opened via **Open As… (text override)** that enables Format.
- **jq vs css/xpath:** confirm there is a jq prompt but **no** css/xpath equivalent (XML/JS/HTML beautify + css/xpath query engines are designed-not-shipped).

---

## SMK-SEARCH-07 — *(consolidated into PV-04 / PV-05 + SMK-SEARCH-08 — removed)*

> **Removed (duplicate).** The CSV / SQLite *in-viewer filter* mechanics this
> smoke walked are owned by the Previews area with deeper coverage:
> - CSV global + per-column + scope filters, row-count, per-tab filter/width
>   persistence, ragged-row padding, large-CSV memory bound, split own-filter
>   slot → `previews.md` **PV-05**.
> - SQLite seeded `SELECT … LIMIT 100`, `Cmd+Return` run / `Cmd+.` cancel,
>   read-only authorizer refusing `DELETE`/DDL/ATTACH, 1000-row cap, busy_timeout,
>   split-unsupported → `previews.md` **PV-04**.
>
> The one assertion that was genuinely a *search-area* concern — that the text
> find bar (`Cmd+F`) is a **distinct surface** from the structured-data filters
> (it must not hijack the CSV table filter), and that the SQLite **SELECT acts as
> the "search"** for `.db` — has been folded into **SMK-SEARCH-08** (step 6 +
> variations). The id is retired, not recycled.

---

## SMK-SEARCH-08 — Cross-surface search continuity & open-at-line consistency

A composite "follow the trail" flow: find a term in the rendered doc, jump to it
project-wide via cross-search, refine in Search Anywhere, land in the editor at
the exact line, and confirm the structured-data filter surfaces are *distinct*
from the text find bar — proving all open-at-line paths agree and that `Cmd+F`
never collides with the CSV/SQLite in-viewer filters.

**Combines:** rendered find · cross-file modal · Search Anywhere · openPath(atLine:)
coercion · view-mode carry · status-bar Ln/Col · tab reuse (no dup tab) · `Cmd+F`
vs CSV-table-filter / SQLite-SELECT-as-search surface distinction.

**Preconditions:** sidebar rooted at `$TMP/uat-search/`; `README.md` open;
`table.csv` (a column with the word `needle`) and a small `.sqlite`/`.db` fixture
present (the structured-data *filter internals* are exercised in PV-04/PV-05; here
we only assert the surface boundary).

| # | Action | Expected |
|---|---|---|
| 1 | In Rendered `README.md`, `Cmd+F` `needle` | Finds in-doc matches; note approximate location. |
| 2 | `Shift+Cmd+F`, Active Folder, `needle`, click `app.ts` match on its comment line | `app.ts` opens at that line; status bar `Ln/Col` reflects the matched line. |
| 3 | Open Search Anywhere, `needle`, click the `app.ts` string-literal match (different line) | Re-uses the **same `app.ts` tab** (no duplicate tab), scrolls to the new line. |
| 4 | Switch `app.ts` to **Editor**; `Cmd+F` `needle`; step | Editor find lands on the same logical occurrences; n/N count consistent with what cross-search found in that file. |
| 5 | Use script/MCP `goto_line` to a known match line | Caret/scroll lands on that 1-based line, matching the UI jumps. |
| 6 | Open `table.csv` (Table), then press `Cmd+F`; separately, open the `.db` fixture and type a `WHERE … LIKE '%needle%'` SELECT (`Cmd+Return`) | **Surface boundary:** `Cmd+F` on the CSV opens the *text find bar*, **not** the `mdv.csvFilter.*` global filter — the two are distinct surfaces and `Cmd+F` must not hijack the table filter. The SQLite **SELECT is the search** for `.db` (results capped 1000, read-only). Filter/authorizer/cap internals → **PV-05** / **PV-04**. |

**Variations / edge-states:**
- Click a cross-search result for a file **not yet open** → opens a new tab at line; clicking a result for an **already-open** file switches to it (no dup).
- Rendered doc that's a non-source category (e.g. PDF/image) won't have a source line — cross-search jump should still open it sensibly (Preview), not error.
- After `Cmd+Shift+R` (toggle rendered/source), the per-view find bar for the now-active mode is the relevant one (bags don't leak).
- Status bar on a media/binary match: `Ln/Col` hidden (line==0 sentinel), size/category shown instead.
- **SQLite-in-split / CSV-in-split** filter surfaces: each split pseudo-tab gets its own filter slot; SQLite in a split shows `Open SQLite files in the main pane.` (asserted in PV-04/PV-05 — cross-referenced here only as the surface boundary).

---

## Notes for the executor

- These are **occluded live** smokes — drive via script verbs / MCP where
  possible (`open_path`, `set_view_mode`, `find`, `set-cross-query`,
  `cross-search`, `goto_line`) and assert on `current_state` / `visible_text`.
- Known-open issues to **note, not fail**: `#218` HEX entry latency, `#219`
  Editor→HEX flash of Source, rendered-`Cmd+F` regex absence (by design),
  `#201` macOS-26 same-doc-fragment host red (unrelated to search).
- Reserved-but-inert by design: **jq/css/xpath as cross-search modes** (only
  `.text` grep runs). If any of these become user-reachable, that is a product
  change — flag it against this catalog rather than silently passing.
- Always create scratch fixtures under `FileManager.default.temporaryDirectory`;
  never write to `~/Documents`, `~/Desktop`, `~/Downloads`.
