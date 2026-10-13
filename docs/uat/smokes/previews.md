# UAT Smokes — Previews (image / audio / video / PDF / SQLite / CSV)

Area: **Content viewer / specialized viewers** — native media preview
(`MediaPreviewView` → Image / Audio / Video / PDF), SQLite browser
(`SQLiteBrowserView` → `ResultTableView`), CSV/TSV table (`CSVTableView`),
and the cross-cutting routing that puts them on screen: the **Open As** chip,
the **view-mode picker (ModeBar)**, the **HEX fallback**, the per-tab
`.preview` `ViewMode`, and the right-side **MetadataPanel**.

These smokes are deliberately **multi-feature**: each one walks a realistic
user flow that crosses preview rendering, mode routing, sidebar/tab
navigation, metadata, and the documented regression traps (HEX-flip on open,
mode-switch async loader race, Editor→HEX flash, off-main sibling
enumeration). The regression history for this area is dense — fresh media
once defaulted to HEX (Bug B), `.preview` tabs flipped to HEX on open (three
twins), and the mode-switch race landed `HexView` under a non-HEX picker
(Bug C). Several of these smokes exist specifically to keep those fixed.

## Conventions

- **Script-verbs** refer to the `--script` dispatcher and MCP tools
  (`open_path`, `set_view_mode`, `select_tab`, `current_state`,
  `snapshot_window`, `visible_text`). App actions are the live UI gestures.
- **A11y ids** are quoted where they exist: `mdv.imagePreview`,
  `mdv.csvTable`, `mdv.csvFilter.*`, `mdv.hexView`, `mdv.hex.search.*`,
  `mdv.modebar`, `mdv.openAs`.
- **Preconditions** list fixtures to stage under
  `FileManager.temporaryDirectory` (never `~/Documents|Desktop|Downloads`).
- Run order is independent per smoke unless a smoke says otherwise.
- "Expected" is the per-step assertion; "Variations / edge-states" are
  additional cases to also exercise once the happy path is green.

---

## PV-01 — Image preview: open, fit/zoom/pan, sibling navigation, metadata, never-HEX-on-open

**Combines:** native image preview · auto-fit-to-window · zoom & pan gestures ·
sibling prev/next enumeration (off-main) · MetadataPanel (Image dims) ·
view-mode default routing (`.preview` not `.hex`) · sidebar→tab open ·
ModeBar picker (Preview + HEX only)

**Preconditions**
- A temp folder `imgs/` containing ≥3 images of mixed type and size, e.g.
  `a.png` (large, > window), `b.jpg` (small, < window, e.g. 64×64),
  `c.gif`, plus one **corrupt** image `bad.png` (truncated bytes).
- App launched against `dist/TextView.app`; `imgs/` opened as the sidebar root.

**Steps**
1. In the sidebar FILES tree, single-click `a.png`.
   - **Expected:** Opens in the current tab as **Preview** (native image),
     NOT HEX. Image is **fit-to-window** on first paint (didFit guard),
     centered on both axes. `mdv.imagePreview` control bar visible.
     ModeBar (`mdv.modebar`) shows exactly **Preview** + **HEX** (no
     Source/Editor for a binary image). Open-As chip is **Auto** (not
     accent-tinted).
2. Read the control bar: confirm prev/next chevrons present, `n / count`
   position reads `1 / 3` (or matching sibling count, excluding `bad.png`
   if it failed to enumerate — see variations), `Fit`, `1:1`, zoom −/+,
   percent HUD, and pixel-dimension readout.
   - **Expected:** Position index and count reflect the real sibling set
     (current URL listed first per enumeration order). Dimension readout
     shows `a.png`'s real WxH.
3. Press **Right arrow** (or click next chevron).
   - **Expected:** Advances to the next sibling, control bar position
     increments, image swaps, zoom resets per-tab (ephemeral). MetadataPanel
     (260pt, right side) updates File + Image (dims) section to the new file.
4. Zoom: press `+` / `Cmd-+` a few times, then `Cmd-scroll` over a point.
   - **Expected:** `+` zooms centered; `Cmd-scroll` anchors at the cursor.
     Percent HUD updates. Zoom clamps to **10×** max.
5. While zoomed in, click-drag the image.
   - **Expected:** Pans with closed-hand cursor, clamped to image bounds
     (no runaway past edges). Plain wheel pans (does not zoom) when zoomed.
6. Press `0` (or `Cmd-0`).
   - **Expected:** Fit-to-window. Press `1` → actual size (1:1). Zoom-snap
     does not fight back (wheel/pinch magnification is pushed back into
     SwiftUI state — no oscillation).
7. Navigate to `b.jpg` (the small image).
   - **Expected:** Small image is **centered, not corner-pinned**, and
     **never upscaled past 1:1** on fit.

**Variations / edge-states**
- **Corrupt `bad.png`:** open it directly. Expected: no image drawn,
  `pixelSize` 0 so the dimension readout is **hidden**, but the control bar
  still shows. App does not crash.
- **Single image folder:** open a folder with exactly one image. Expected:
  prev/next chevrons **and** the `n / count` position are hidden.
- **Huge folder (thousands of images):** prev/next is **disabled until the
  off-main enumeration lands** (Task.detached). App stays responsive while
  the list materializes.
- **Fast cross-folder nav:** open image in folder X, immediately open image
  in folder Y. Expected: stale folder enumeration from X is discarded; the
  sibling set reflects Y.
- **Open As → HEX:** with `a.png` open, use the Open-As chip
  (`mdv.openAs`) to force **HEX**. Expected: switches to `mdv.hexView`,
  chip turns accent-tinted. Switch Open-As back to **Auto** → returns to
  Preview, chip de-tints. (Regression guard for the centering/HEX-return
  bugs.)
- **Regression sentinel:** a freshly-opened image must default to Preview,
  not HEX (Bug B, `6d04444`). Re-confirm after every code change touching
  default-mode order or the `.hex` carry block.

---

## PV-02 — Audio & video preview: playback transport, metadata, full-screen affordance differences

**Combines:** AudioPreview / VideoPreview (AVPlayerView) · MetadataPanel
(Audio sample-rate/channels vs Video fps/dims) · full-screen toggle present
for video / hidden for audio · ModeBar Preview+HEX routing · space-to-play
keybind · UnsupportedPreview fallback

**Preconditions**
- Temp folder with `clip.mp4` (or `.mov`), `tune.mp3` (or `.m4a`/`.wav`),
  and one deliberately **corrupt** media file `broken.mp4`.

**Steps**
1. Open `tune.mp3`.
   - **Expected:** Audio preview (AVPlayerView) with scrubber + volume.
     **No full-screen toggle.** MetadataPanel shows File + Audio section
     (sample rate · channels). ModeBar = Preview + HEX.
2. Press **Space**.
   - **Expected:** Play/pause toggles. Scrubber advances during playback.
3. Open `clip.mp4`.
   - **Expected:** Video preview with play/pause, scrubber, volume, **and a
     full-screen toggle** (video-only). MetadataPanel shows Video section
     (fps · pixel dims).
4. Scrub the video, adjust volume.
   - **Expected:** Seeks and volume respond; transport state consistent.

**Variations / edge-states**
- **Corrupt media `broken.mp4`:** open it. Expected: AVPlayer/PDFKit owns its
  own error chrome; metadata rows are empty rather than fabricated. No crash.
- **Unsupported category fallback:** force a category with no native player
  (Open As → an unhandled type if reachable). Expected: `UnsupportedPreview`
  shows "Preview not available for <category>".
- **HEX fallback:** Open As → HEX on `clip.mp4`. Expected: streams a hex
  dump via mmap (large file), `mdv.hexView` renders, picker de-emphasizes
  Preview. Switch back to Auto → Preview again.
- **Regression sentinel:** native-preview tabs (audio/video) must NOT flip
  to HEX on open (`35af305`, `ade3d04`).

---

## PV-03 — PDF preview: page navigation, zoom, metadata, large-file & HEX routing

**Combines:** PDFPreview (PDFView continuous mode, autoScales) · arrow page
nav · zoom · MetadataPanel (PDF pages/title/author) · Open As → HEX ·
default `.preview` routing

**Preconditions**
- Temp folder with `doc.pdf` (multi-page, with Title + Author metadata),
  a single-page `one.pdf`, and a large `big.pdf` (several MB).

**Steps**
1. Open `doc.pdf`.
   - **Expected:** PDF renders in continuous mode, auto-scaled. MetadataPanel
     File + PDF section shows page count, Title, Author. ModeBar = Preview +
     HEX. Defaults to Preview, not HEX.
2. Use **Down/Up arrows** (or scroll) to page through.
   - **Expected:** Smooth page navigation; scroll position tracks.
3. Zoom in/out (`Cmd-+` / `Cmd--`) and reset (`Cmd-0`).
   - **Expected:** Page scale responds; autoScales re-fits on reset.
4. Open As → **HEX** on `doc.pdf`, then back to **Auto**.
   - **Expected:** HEX dump renders; Auto restores PDF preview. No leftover
     HexView under a Preview picker.

**Variations / edge-states**
- **Single-page `one.pdf`:** page nav is a no-op past the single page; no
  crash.
- **No metadata:** a PDF with no Title/Author → those rows omitted/empty,
  not fabricated.
- **Corrupt PDF:** PDFKit shows its own error chrome.
- **Large `big.pdf`:** opens without slurping all bytes into Swift memory
  (large-file routing happens before preview categories; media bytes are
  never copied into the process heap as a String).

---

## PV-04 — SQLite browser: schema sidebar → seeded query → results, read-only enforcement, cancel

**Combines:** `SQLiteBrowserView` HSplitView · schema sidebar (Tables/Views/
Indexes/Triggers) · auto-seeded `SELECT * … LIMIT 100` · Run (Cmd+Return) /
Cancel (Cmd+.) · `ResultTableView` (pinned header, resizable cols, NULL
cells) · read-only authorizer · MetadataPanel (File + Database) · default
`.preview(sqlite)` routing (not HEX)

**Preconditions**
- Temp `app.db` (SQLite) with ≥2 tables (one with NULLs and > 1000 rows to
  exercise the cap), at least one view and one index. Also a `tiny.db`
  (≈8 KB) and a `locked.db` (held open by another writer to force busy).
- A non-database file renamed to `.db` (`fake.db`, actually text) to test
  the open-failure path.

**Steps**
1. Open `app.db` from the sidebar.
   - **Expected:** Routes to the **SQLite browser** (Preview is the primary
     lens), NOT HEX. Left schema sidebar lists Tables / Views / Indexes /
     Triggers groups; empty groups are hidden. Right pane shows the initial
     hint: "Click a table or write a SELECT, then ⌘↵ to run."
2. Click a table in the schema sidebar.
   - **Expected:** Seeds `SELECT * FROM "name" LIMIT 100;` into the SQL
     editor and **auto-runs**. `ResultTableView` shows pinned header,
     alternating row tint, NULL cells rendered as `NULL`. If the table has
     > 1000 rows, a truncation footer appears (maxRows = 1000).
3. Edit the SQL to `SELECT * FROM "name";` and press **Cmd+Return**.
   - **Expected:** Runs off-main on `dbQueue` (ProgressView + "Running
     query…" briefly visible). Result still capped at 1000 rows; per-cell
     text clamped at 2000 chars.
4. Attempt a write: type `DELETE FROM "name";` and Run.
   - **Expected:** **Refused** — the SQLite authorizer denies
     INSERT/UPDATE/DELETE/DDL and ATTACH/DETACH at prepare time
     (`SQLITE_OPEN_READONLY` + authorizer). Red "Query error" surfaces; DB is
     untouched.
5. Run a deliberately slow query (e.g. a cartesian join) and press
   **Cmd+.** (Cancel) while it's running.
   - **Expected:** Query interrupts (`SQLITE_INTERRUPT`) via
     `sqlite3_progress_handler`; UI shows "Query cancelled"; app stays
     responsive.
6. Open the right-side **MetadataPanel**.
   - **Expected:** File section + Database section populated.

**Variations / edge-states**
- **Open failure (`fake.db`):** Expected error view: "Couldn't open
  database" + error + path.
- **`tiny.db` (≈8 KB):** routes to `.preview(sqlite)` sub-millisecond **with
  no byte read**; must NOT flip to HEX (regression guard, fixed twice).
- **`locked.db` (contended):** Run a query. Expected: 5s `busy_timeout`,
  then a clean step-failure message — no hang, no freeze.
- **ATTACH hardening:** `ATTACH DATABASE 'x' AS y;` denied at prepare time.
- **Superseded query:** click table A, immediately click table B. Expected:
  A's run is dropped via `runToken`; only B's results render.
- **Split pane:** open `app.db` into a split pane. Expected: "Open SQLite
  files in the main pane." (unsupported in split).
- **HEX secondary lens:** Open As → HEX shows raw bytes; back to Auto
  returns the browser.

---

## PV-05 — CSV/TSV table: filter (global + per-column + scope), column resize, virtualization, persistence

**Combines:** `CSVTableView` column-major grid · pinned header (LazyVStack
virtualization) · global filter (`mdv.csvFilter.global`, 200ms debounce) ·
scope menu All/per-column (`mdv.csvFilter.scope`) · per-column comparison
filters (`mdv.csvFilter.col<i>`) · clear-all (`mdv.csvFilter.clear`) ·
row-count (`mdv.csvFilter.count`) · draggable resizers · Copy Cell ·
per-tab filter/width persistence · large-file memory bound

**Preconditions**
- Temp `data.csv` (≥5 columns incl. one numeric, ≥2000 rows so the
  pre-lowercased rows cache kicks in for ≥256 KB) and a `tab.tsv`.
- A `headerless.csv` with **ragged rows** (some rows shorter than the header)
  and a row whose first cell is **blank** to exercise "Column N" labeling.
- An `empty.csv` (header only, zero data rows).

**Steps**
1. Open `data.csv`.
   - **Expected:** Routes to **Table** mode by default. `mdv.csvTable`
     visible: pinned header row, alternating row shading, all columns laid
     out. Row-count label shows `total / total`.
2. Type a substring into the global filter (`mdv.csvFilter.global`).
   - **Expected:** After ~200ms debounce, rows narrow to matches; row-count
     label updates to `N / total`. Clearing the field updates **immediately**
     (clear is not debounced).
3. Change scope (`mdv.csvFilter.scope`) from **All** to a single column,
   re-filter.
   - **Expected:** Filter applies only to that column. Blank-header columns
     are labeled "Column N" in the scope menu.
4. Toggle the per-column advanced filter row and apply a comparison filter
   on the numeric column (e.g. `> 100`).
   - **Expected:** `mdv.csvFilter.col<i>` accepts `>, <, >=, <=, =, !=`;
     rows filtered numerically; row-count updates.
5. Click **Clear All** (`mdv.csvFilter.clear`).
   - **Expected:** All filters cleared; full row set returns; row-count back
     to `total / total`.
6. Drag a column-header right edge to resize.
   - **Expected:** Column resizes, min width clamped at **40pt**.
7. Right-click a cell → **Copy Cell**; also select cell text.
   - **Expected:** Cell value copied to clipboard; text selectable.
8. Switch to another tab and back (or switch view mode and back).
   - **Expected:** Filter state **and** column widths are **persisted
     per-tab** (`csvFilterStates`, keyed by tab id) — restored exactly.

**Variations / edge-states**
- **`empty.csv`:** header-only renders with `0 / 0` rows (filtered-to-zero
  also shows header + `0 / total`).
- **`headerless.csv` ragged rows:** short rows are **padded**; per-column /
  scope filters that reference a now-missing column are pruned on shape
  change. Blank-header columns show "Column N".
- **`tab.tsv`:** opens in Table mode the same as CSV.
- **Large-file memory:** open `data.csv` and confirm RSS stays in the
  ~10–20 MB range, NOT ~1 GB (LazyVStack virtualization regression guard for
  the 1 MB CSV → ~1 GB bug).
- **Split pane:** open the CSV into a split pane. Expected: the split
  pseudo-tab gets its **own** filter slot, freed on disappear (no static-UUID
  leak across files).
- **Open As → Source:** force the CSV into Source mode and back to Table via
  the Open-As chip; both modes available for text-backed CSV.

---

## PV-06 — Default-mode routing per preview category + HEX fallback (preview-type matrix)

**Combines:** ModeBar picker (`mdv.modebar`) available-modes-by-type for *preview
categories* · default-mode order (image/audio/video/pdf/sqlite→Preview;
binary/unknown→HEX) · HEX fallback for binary/unknown · single-available-mode
picker hidden · Open-As chip reachable per preview type.

> **Scope note (dedup):** the *cross-type* Open-As mechanics — the exhaustive
> applicable-viewer list, magic-byte float-to-top, accent-tint/Auto-clears,
> carry-mode-on-file-switch, and the mode-switch async-loader **race guard
> (Bug C)** — are owned by `view-modes.md` **VM-06** (and the chrome-ModeBar
> rendering of the chip by `tabs-and-window-chrome.md` **SC-CHROME-02**). This
> smoke covers only the **preview-category routing matrix**: that each media /
> sqlite type lands on the right default lens and that binary/unknown collapses
> to a hidden HEX-only picker. Drive the exhaustive Open-As / race separately
> via VM-06.

**Preconditions**
- One folder with a representative file of each preview type: `pic.png`,
  `song.mp3`, `movie.mp4`, `doc.pdf`, `app.db`, `data.csv`, plus a genuinely
  **binary/unknown** file `blob.bin` and a `notes.md`.

**Steps**
1. Open `pic.png`, `app.db`, `data.csv`, `notes.md` in separate tabs.
   - **Expected per type:**
     - `pic.png` → default **Preview**; picker = Preview + HEX.
     - `app.db` → SQLite routes to **Preview(sqlite) browser**; picker =
       Preview + HEX.
     - `data.csv` → default **Table**; picker includes Table + Source +
       Editor + HEX.
     - `notes.md` → default **Rendered** (markdown); picker = Rendered +
       Source + Editor + HEX.
2. Open `song.mp3`, `movie.mp4`, `doc.pdf`.
   - **Expected:** each defaults to **Preview**, picker = Preview + HEX. (Their
     transport / metadata depth → PV-02 / PV-03.)
3. Open `blob.bin`.
   - **Expected:** Default **HEX**; the mode picker is **hidden entirely**
     (single available mode for binary/unknown). The Open-As chip is still
     reachable to force another lens.
4. On `pic.png`, open the **Open As** dropdown and pick **HEX**, then **Auto**.
   - **Expected:** HEX forces `mdv.hexView`; Auto returns to Preview. (The
     exhaustive viewer list + magic-byte float + carry-mode are asserted in
     **VM-06** — here just confirm the chip is present and round-trips for a
     preview-category file.)

**Variations / edge-states**
- **Mode-switch race (Bug C) — cross-reference only:** the rapid HEX↔Preview
  latest-wins guard is exercised in **VM-06** and `tabs-and-window-chrome.md`
  **SC-CHROME-02**; do not re-walk it here.
- **No current URL:** with no file open, the Open-As chip is **hidden**.
- **Single available mode:** for `blob.bin`, confirm the picker never appears.

---

## PV-07 — HEX viewer as the universal fallback: dump, search (hex & ASCII), width, click-highlight

**Combines:** `HexView` (`mdv.hexView`) 3-column dump · streaming build
("Building hex dump…") · search mode segmented (`mdv.hex.search.mode`) ·
query (`mdv.hex.search.field`) + count (`mdv.hex.search.count`) +
prev/next (`mdv.hex.search.prev/next`) · bytes-per-row width picker
(`mdv.hex.widthPicker`) · click-to-highlight same-value bytes · Open-As
entry from any preview type · Editor→HEX flash (known issue) · match cap

**Preconditions**
- A binary `data.bin` (a few KB to ~4 MB, containing a known byte sequence
  `DE AD BE EF` and an ASCII token like `MAGIC`).
- An `empty.bin` (0 bytes).
- A text file `code.txt` open in **Editor** mode (to reach the Editor→HEX
  transition).

**Steps**
1. Open `data.bin`.
   - **Expected:** Defaults to HEX. While streaming, "Building hex dump…"
     placeholder shows briefly (off-main `HexDumpBuilder`), then the
     3-column offset / hex bytes / ASCII dump renders.
2. Set search mode to **Hex** and type `de ad be ef`; press Enter.
   - **Expected:** Yellow match highlights on **both** the hex and ASCII
     columns; active match orange; count (`mdv.hex.search.count`) shows
     `i / N`; the active match auto-scrolls into view. Cmd+G / Shift+Cmd+G
     step with wrap-around.
3. Switch search mode to **ASCII** and type `MAGIC`.
   - **Expected:** Matches recompute for ASCII; highlights update.
4. Change **bytes-per-row width** (`mdv.hex.widthPicker`) to a wider value.
   - **Expected:** Dump rebuilds; wide widths enable horizontal side-scroll.
     Width persists per-tab and globally (`PreferencesStore.hexBytesPerRow`).
5. Click a byte.
   - **Expected:** All same-value bytes highlight teal; drag selects a
     multi-byte pattern; Esc / empty-click clears.

**Variations / edge-states**
- **`empty.bin`:** shows "Hex dump, 0 bytes".
- **Invalid query:** type a malformed hex string. Expected: field turns red +
  "invalid"; zero matches shows "0 matches".
- **Match cap:** if matches exceed 50,000, the count shows `i / N+` and you
  cannot step past the 50,000th hit (highlight paint bounded).
- **Editor→HEX flash (known open issue #219):** open `code.txt` in Editor,
  then Open As → HEX. Expected today: a **transient flash of Source** during
  the mode-routing transition before HEX settles. Log it; do not fail the
  smoke on the flash (documented open issue), but DO fail if it lands on the
  wrong final view.
- **HEX entry latency (known open issue #218):** note time-to-first-paint
  when entering HEX on a ~4 MB file (builds ~20 MB string). Streaming
  mitigates TTFP; the sync mode-switch entry cost is still flagged. Record
  the observation; not a fail unless it hangs.

---

## PV-08 — Media tab × sidebar × status-bar interplay (cross-folder enumeration discard, follow-active-tab)

**Combines:** sidebar follow-active-tab / auto-root for a media tab · tab
open-or-reveal (no dup) · status bar media tab (Ln/Col hidden, size + category
encoding) · MetadataPanel tracking · per-tab ephemeral zoom reset · **stale
cross-folder sibling enumeration discard**.

> **Scope note (dedup):** the single-folder image *sibling-navigation
> mechanics* (off-main enumeration, prev/next chevrons, `n / count` position,
> single-image-hides-chevrons) are owned by **PV-01**. This smoke focuses on the
> *cross-surface interplay* PV-01 doesn't cover: switching the sibling set when
> the active media tab moves to a **different folder**, the sidebar following /
> revealing the media tab, status-bar media-tab fields, and that a stale
> enumeration from the old folder is discarded.

**Preconditions**
- Two sibling image folders `setA/` and `setB/`, each with several images.
- Sidebar opened at a common parent; follow-active-tab enabled.

**Steps**
1. Open `setA/img1.png` from the sidebar.
   - **Expected:** Sidebar auto-roots / reveals the containing folder
     (follow mode); status bar shows the file path, **size**, and category
     encoding (e.g. "binary"); **Ln/Col is hidden** for a media tab
     (line == 0 sentinel).
2. Use the in-preview next chevron to walk through `setA`.
   - **Expected:** Sibling nav stays within `setA`; MetadataPanel and the
     `n / count` position track; per-tab zoom resets on each swap.
3. Open `setB/img1.png` in a **new tab**.
   - **Expected:** New tab; sibling set is now `setB` (stale `setA`
     enumeration discarded). Re-opening an already-open image switches to its
     existing tab (no duplicate).
4. Switch back to the `setA` tab.
   - **Expected:** Its own sibling context and metadata restore.

**Variations / edge-states**
- **Reveal in Sidebar** from the tab context menu on a media tab: switches
  root if needed (unless Files is locked), expands ancestors, selects target.
- **Files locked:** with the sidebar lock on, opening a media file does NOT
  re-root the sidebar.
- **Status bar narrow window:** date chips drop cleanly; size metric never
  truncates.

---

## Cross-cutting regression sentinels (must stay green across this area)

These are not standalone flows but invariants every preview smoke should
re-confirm — they encode the documented bug history:

1. **Fresh native-preview tab never opens as HEX.** Images, PDFs, SQLite,
   audio, video all default to `.preview` / `.preview(sqlite)`, not `.hex`
   (Bug B `6d04444`; hex-carry twins `1e29835` / `35af305` / `ade3d04`).
2. **Mode-switch is latest-wins.** No `HexView` under a non-HEX picker; no
   endless spinner on rapid toggles (Bug C `ac4fcee`).
3. **SQLite is read-only by construction.** No INSERT/UPDATE/DELETE/DDL/
   ATTACH/DETACH ever mutates the DB; runaway queries cancel cleanly.
4. **CSV memory stays bounded** (LazyVStack) — never the ~1 GB blow-up.
5. **Media bytes are never slurped into Swift memory** — large-file routing
   precedes preview categories.
6. **Off-main enumeration / dump building never blocks the UI** — sibling
   lists (Task.detached) and hex dumps (`HexDumpBuilder` actor) stay async.

### Known-open issues to observe (log, don't fail unless behavior is worse)

- **#218** — HEX mode entry latency on mode-switch (sync attributed-dump
  build); streaming mitigates TTFP but entry cost remains.
- **#219** — Editor→HEX transition shows a transient flash of Source.
