# UAT Run Log (undated)

Append-only per-smoke run log. Each UAT executor group appends its own
section; never overwrite a prior group's entry.

App under test: `dist/TextView.app` @ `main 798b7ee` (build 2026-06-03).
Driven live + occluded (`MDV_BACKGROUND=1`) via the `--script` verb
dispatcher; one `DiagnosticDump` JSON per step. a11y ids (`mdv.*`) do NOT
propagate onto `NSView.accessibilityIdentifier()` in the dump (confirmed via
live probe — matches `tabs-and-window-chrome.md` line 244), so assertions
read the authoritative `model` sub-dict + view-CLASS detection.

---

## Group 1/12 — tabs-and-window-chrome

- **Executor suite:** `Tests/ViewerUITests/uat/TabsAndWindowChromeUATTests.swift` (T4 `MultiScenarioTestCase`)
- **Run cmd:** `env -u MDV_HEADLESS_GATE swift test --filter 'ViewerUITests.TabsAndWindowChromeUATTests'`
- **Result:** 10 tests, 0 failures, 0 unexpected (41.2s). 1 known bug captured as `XCTExpectFailure`.
- **Evidence:** `docs/uat/evidence/SC-CHROME-02_carry-hex-onto-preview_desync.{json,png}`

### SC-CHROME-01 — Multi-tab lifecycle — PASS (with 1 manual-only carve-out)

`test_SC_CHROME_01_multiTabLifecycle` + `..._01var_symlinkDedup` + `..._01var_bookmarkToggle`.

| Step | Expected | Observed | Verdict |
|---|---|---|---|
| open a.md | 1 tab, rendered default, title=a.md, statusbar present | `tabCount=1, mode=rendered, windowTitle=a.md, currentURL!=""` | PASS |
| open b/c/d | 4 tabs in order, d.csv selected, **csv→table default** | `tabCount=4, sel=3, mode=table` | PASS |
| select-tab 1 | a.md re-selected, title flips, reverts to rendered | `sel=0, url=a.md, mode=rendered` | PASS |
| next-tab ×2 | a.md→b.json→c.txt | url tracks each | PASS |
| editor + edit | dirty buffer | mode=editor, set-text no error | PASS |
| close dirty tab | NSAlert Save/Don't/Cancel → neighbor select | **NOT script-reachable** (see findings) — substituted `editor-save` then close | PASS (close → 3 tabs, right neighbor d.csv selected) |
| reopen b (open) | no duplicate, switch to existing | `tabCount=3` unchanged, url=b.json | PASS |
| ⌘T blank tab | Untitled appended+selected, **statusbar disappears**, title falls back | `tabCount=4, currentURL="", windowTitle="" (fallback)` | PASS |
| ⌘O on blank | blank **reused**, not a 5th tab | `tabCount=4, url=a.md` | PASS |
| /var vs /private/var | single tab (symlink dedup) | `tabCount=1` after opening both forms | PASS |
| ⌘D bookmark | star toggles on/off | `isCurrentTabBookmarked` false→true→false | PASS |

### SC-CHROME-02 — ModeBar routing + Open As — PASS (1 bug flagged)

`test_SC_CHROME_02_modeBarRoutingAndOpenAs` + `..._previewRoutingAndOpenAs` + `..._asyncLoaderRace_latestSwitchWins` + `..._carryModeHexOntoPreview_DESYNC`.

| Step | Expected | Observed | Verdict |
|---|---|---|---|
| notes.md | rendered (multi-mode) | mode=rendered | PASS |
| toggle-format on md | no-op (md has no Format) | mode stays rendered, formatted flag stays false | PASS |
| data.json | source default | mode=source | PASS |
| toggle-format on json | Format applies | **isCurrentTabFormatted=true, mode stays `source`** (Format is a flag, not a view mode) | PASS |
| page.html | conservative **Source** default (not rendered) | mode=source | PASS |
| bin.dat (unknown) | HEX, single mode | mode=hex, state=binary | PASS |
| db.sqlite (clean state) | native Preview, NOT hex | mode=preview, state=preview | PASS |
| pic.png (clean state) | Preview | mode=preview, state=preview | PASS |
| Open-As HEX (=`binary` category) | byte grid | mode=hex, state=binary | PASS |
| Open-As Auto | reverts to Preview | mode=preview, state=preview | PASS |
| rapid HEX↔Source ×6 | latest-wins, no Hex-under-non-hex (Bug C) | final mode=source, state!=binary, no Hex view | PASS |
| **open preview file right after a HEX file** | picker should track the rendered pane (preview) | **mode=hex while state=preview — picker↔pane DESYNC** | **BUG** (expected-failure guard) |

### SC-CHROME-04 — StatusBar visibility coupling + type-awareness — PASS

`test_SC_CHROME_04_statusBarVisibilityCoupling`.

| Step | Expected | Observed | Verdict |
|---|---|---|---|
| open src.py | statusbar present, source | currentURL!="" , mode=source | PASS |
| open img.jpg | preview, statusbar present (Size shown) | mode=preview, currentURL!="" | PASS |
| ⌘T blank | **statusbar disappears entirely** | currentURL="" | PASS |

> Live caret Ln/Col channel, metric-chip tooltips, date-chip ViewThatFits
> truncation, and red stale-on-disk Modified chip are NOT script-reachable
> (no caret-move / hover / external-write verbs); left to MANUAL_TESTING.

### SC-CHROME-05 — Chrome-pin invariant under resize + sidebar — PASS

`test_SC_CHROME_05_chromePinUnderResizeAndSidebar`.

| Step | Expected | Observed | Verdict |
|---|---|---|---|
| sidebar-set-root repo | root set | no error, sidebar visible | PASS |
| resize 360×300 (tiny) | chrome bars never blank/collapse | content tree > 10 nodes, no error, file still loaded | PASS |
| resize back 1100×800 | chrome intact | no error | PASS |
| toggle-sidebar off | sidebar collapses | `sidebarVisible=false` | PASS |
| toggle-sidebar on | sidebar restores | `sidebarVisible=true` | PASS |

> Rail over-subscription (7-8 panels) + `BoundedAccordionScroll` window-clamp
> + the WindowServer pixel-blank check are not driveable from script verbs
> (no rail-toggle verb); the chrome-pin invariant is exercised here via the
> `resize` lever only. Pixel-blank authoritative check is T5/VM.

### SC-CHROME-06 — Zoom scaling — PASS (split-view not script-reachable)

`test_SC_CHROME_06_zoomScaling`.

| Step | Expected | Observed | Verdict |
|---|---|---|---|
| zoom-reset | 1.0 | zoom=1.0 | PASS |
| zoom-in ×3 | monotonic increase, ≤3.0 cap | strictly increasing, ≤3.0 | PASS |
| zoom-reset | 1.0 | zoom=1.0 | PASS |
| zoom-out | <1.0, ≥0.5 floor | within [0.5, 1.0) | PASS |

> Split view (⌘\ / ⇧⌘\), the Finder drag-drop overlay, and per-pane tabs
> have NO script verbs — the split/drop axes of SC-CHROME-06 are MANUAL/VM
> only. The zoom axis is fully covered here. (NB: zoom persists across runs
> via `PreferencesStore`, so scenarios `zoom-reset` first to normalize.)

### Findings summary (group 1/12)

1. **[BUG / S3] Carry-mode HEX leaks onto native-preview types — ModeBar picker↔pane desync.**
   Open any native-preview file (image/sqlite/pdf/audio/video) immediately
   after a HEX-mode file → ModeBar shows **HEX** selected while the native
   Preview lens (image/SQLite browser) is what renders (`mode=hex` but
   `state=preview`). Root cause: `DocumentModel.openResolved` carry-mode
   branch carries `.hex` because `.hex ∈ availableModes` for preview types
   (`[.preview, .hex]`); the loader returns `.preview` state and the
   HEX-load block is (correctly) skipped for `.preview`, leaving the picker
   selecting a mode the pane isn't in. Self-heals on any explicit re-pick or
   Open-As→Auto. Screenshot + dump evidence saved. Captured as a tracked
   `XCTExpectFailure`.

2. **[HARNESS GAP / S4] Dirty-close NSAlert deadlocks `--script` automation.**
   `close-tab` on an editor-dirty tab calls `EditorCoordinator.confirmCloseIfDirty`
   → `NSAlert.runModal()`, which blocks the main thread forever in a
   headless/occluded run (no one clicks Save/Don't/Cancel). The script Task
   can't advance; the app must be SIGKILLed at timeout. There is an unused
   test override hook (`dirtyClosePromptOverride`) but it is NOT wired to any
   script verb. Consequence: SC-CHROME-01 step 6 (the Save/Don't-Save/Cancel
   prompt + neighbor-selection) is NOT automatable as written. Worked around
   by `editor-save` before close. Recommend adding a `confirm-dirty-close
   <save|discard|cancel>` script verb (routing through the existing override
   hook) so the modal branch becomes driveable.

3. **[NOTE, not a bug] Open-As "HEX" is the `binary` FileCategory, not a `hex` one.**
   There is no `hex` FileCategory; `set-open-as hex` is a silent no-op
   (`FileCategory(rawValue:"hex")==nil`). Forcing the byte grid via Open-As
   uses `set-open-as binary`. Worth a doc note so future smokes don't use the
   wrong arg.

---

## Group 2/12 — sidebar-filetree-and-bookmarks

- **Executor suite:** `Tests/ViewerUITests/uat/SidebarFileTreeAndBookmarksUATTests.swift` (T4 `MultiScenarioTestCase`)
- **Run cmd:** `env -u MDV_HEADLESS_GATE swift test --filter 'ViewerUITests.SidebarFileTreeAndBookmarksUATTests'`
- **Result:** 10 tests, 0 failures, 0 unexpected (48.8s). Self-skips all 10 under `MDV_HEADLESS_GATE=1` (verified).
- **Evidence:** `docs/uat/evidence/SFB-10_open-in-new-session_no-reroot.json`, `docs/uat/evidence/SFB-01_root-at-slash.json`

### Observability ceiling for this group (the dominant finding)

The sidebar + bookmarks surfaces are almost entirely SwiftUI. A live dump probe
confirmed (extending the group-1 a11y-id finding):

- **ZERO** `mdv.sidebar.*` / `mdv.bookmarks.*` / `mdv.rail.*` a11y ids reach the
  dump (`contentView` tree OR `recursiveDescription`).
- FILES rows, BOOKMARKS chips, sort/recency menu *values*, git status badge
  letters, the recency stripe tier, and the in-tree star state all render as
  `NSTextFieldSimpleLabel` / `SwiftUIPopupButton` whose **text is not captured**
  by the dump (no `nsTextView` payload; `recursiveDescription` carries no label
  strings).
- `ScriptVerb.modelStateDump` exposes `sidebar.rootURL`, `sidebar.isVisible`,
  `sidebarVisible`, `isCurrentTabBookmarked`, tab state, and sessions — but NOT
  `sidebar.selectedURL`, the `expanded` set, `sortMode`, `includeHidden`, the
  bookmarks LIST, line bookmarks, or `folderStatsExpanded`.

So the assertable contract is MODEL-level (root set/visible, bookmark-target
toggle, sessions, no `.error`) + STRUCTURAL (the realized sidebar subtree is
mounted and non-degenerate — `SidebarKeyMonitor` host present, a non-zero-sized
scroll host). Everything below in "NOT script-reachable" is logged for the
MANUAL/VM lane.

### SFB-01 — Open folder, navigate tree, open files, re-root — PASS

`test_SFB_01_openFolderNavigateTreeOpenFiles` + `..._rootAtFilesystemRoot`.

| Step | Expected | Observed | Verdict |
|---|---|---|---|
| `sidebar-set-root root` | FILES tree mounts, rooted, visible | `rootURL=…/root/`, `sidebarVisible=true`, scroll host non-zero | PASS |
| open already-focused a.md | no new tab | `tabCount=1`, url=a.md | PASS |
| open c.json | opens a tab | `tabCount=2`, url=c.json (see finding 2 — `open` does NOT reuse) | PASS |
| `sidebar-set-root sub` | re-root to child | `rootURL=…/sub/` | PASS |
| `sidebar-set-root root` (walk-up analogue) | re-root to parent | `rootURL=…/root/` | PASS |
| `sidebar-set-root /` | accepted, no error | `rootURL=file:///`, visible, no `.error` | PASS |

### SFB-02 — Keyboard tree navigation + sidebar toggle — PASS (selection state unobservable)

`test_SFB_02_keyboardNavAndSidebarToggle` + `..._hiddenSidebarKeysInert`.

| Step | Expected | Observed | Verdict |
|---|---|---|---|
| `SidebarKeyMonitor` mounted after root | arrow keys wired | host present in tree | PASS |
| `select-next ×4 / select-prev / walk-up ×2` over-driven past ends | clamp, no crash | no `.error` on any step, app exits cleanly | PASS |
| `toggle-sidebar` off → on | `sidebarVisible` false→true round-trip | `true→false→true` | PASS |
| nav verbs fired while sidebar HIDDEN | inert, no corruption | re-show leaves root intact, no `.error` | PASS |

> The actual SELECTION ROW (`SidebarModel.selectedURL`), auto-scroll-into-view,
> Left=collapse-vs-focus-parent, Right=expand-vs-focus-child, Return=open/toggle
> distinction, and single-row-tree edge are **NOT observable** (selection isn't
> in the dump, and Return/arrow semantics route through the SwiftUI key monitor
> with no model projection). MANUAL/VM.

### SFB-03 — File & folder bookmark toggle + JSON persistence — PASS

`test_SFB_03_fileBookmarkToggleAndPersist` + `..._folderBookmarkViaRootFallback`.

| Step | Expected | Observed | Verdict |
|---|---|---|---|
| ⌘D on a.md (`toggle-bookmark`) | bookmarked | `isCurrentTabBookmarked` false→true | PASS |
| ⌘D again | cleared | true→false; `bookmarks.json` entry gone | PASS |
| ⌘D on blank tab w/ folder rooted | bookmarks the FOLDER (target fallback) | false→true→false (folder url) | PASS |

> The four-surface MIRROR (tab star, FILES-tree star, BOOKMARKS section row,
> ⌘K palette row) and the shown/total count badge are SwiftUI-only and absent
> from the dump — MANUAL/VM. Store CAP (201st drops oldest), filtered-empty
> placeholder, and deleted-target-still-shown are store-internal / view-only.

### SFB-08 — Git-aware sidebar + folder-stats toggle — PASS (badge letters unobservable)

`test_SFB_08_gitRootAndFolderStatsToggle` + `..._nonRepoRootFolderStatsNoop`.

| Step | Expected | Observed | Verdict |
|---|---|---|---|
| root a git repo (staged/unstaged/untracked churn) | roots, tree mounts, no error | `rootURL=…/gitrepo/`, scroll host non-zero | PASS |
| `folder-stats on` / `off` | slide-down toggles, repo-only | no `.error`, root stays put across toggles | PASS |
| root a non-repo folder + `folder-stats on` | no-op envelope, no crash | rooted, no `.error` | PASS |

> The status BADGE LETTERS (M/A/?/U/conflict), repo-root folder glyph variants,
> tracked accent dot, the folder-stats aggregate VALUES, and the live FSEvents
> badge update (M→A on external `git add`) are SwiftUI-label text invisible to
> the dump. `folderStatsExpanded` itself is not projected in `modelStateDump`.
> MANUAL/VM. (Perf guard — memoized git-root, no 64× `fileExists` per body — is
> a code-level invariant, covered by the perf commits, not a UAT observable.)

### SFB-10 — Folder context menu: Open in New Session — PASS (with 1 observation)

`test_SFB_10_openInNewSession`. (Scope: this smoke owns the *entry point* only;
session machinery is `sessions.md` SESS-01/05.)

| Step | Expected | Observed | Verdict |
|---|---|---|---|
| `session-open-new <subfolder>` | new session created, rooted at the subfolder, active | session listed w/ `sidebarRootPath=…/subdir`, `activeSessionID` set | PASS |

### SFB-12 — Bookmark persistence across a real process boundary — PASS

`test_SFB_12_bookmarkPersistsAcrossLaunch` (two sequential launches, same real
`bookmarks.json`).

| Step | Expected | Observed | Verdict |
|---|---|---|---|
| launch 1: bookmark persist.md | set | `isCurrentTabBookmarked=true` | PASS |
| launch 2: re-open same file | STILL bookmarked from disk | `isCurrentTabBookmarked=true` BEFORE any toggle | PASS |
| launch 2: toggle off | store left clean | cleared; tearDown scrub confirms 0 scratch entries | PASS |

> Cross-relaunch SESSION restore (root / open tabs / expansion set / show-hidden
> / per-panel layout) is **DISABLED** in this harness (`MDV_SKIP_WORKSPACE_RESTORE=1`
> set inside `AppLauncher`). That lane is `sessions.md` SESS-05/06/07 + VM only.
> What IS proven here is the BookmarksStore JSON round-trip across a genuine
> process exit + reload.

### NOT script-reachable in this group (logged for MANUAL/VM)

No script verb exists for, and `modelStateDump` does not project, any of:

- **SFB-04 line bookmarks** — ⌥⌘D maps to `DocumentModel.toggleCurrentLineBookmark()`,
  which has **NO script verb** (`toggle-bookmark` is file-level only). Gutter
  dot, `<file>:N` chip, click-to-jump-to-line, and F/D/L filter chips are all
  unreachable. Highest-value gap to close — see finding 3.
- **SFB-05 shoulder rails** — no `rail-toggle <edge> <kind>` verb; panel
  show/hide, SidebarDataPresence fill/unfill, Recents-has-data, divider gating,
  and accordion over-subscription clamp are all undriveable.
- **SFB-06 resize** — `resize` is WINDOW-level only; there is no sidebar-width
  or per-panel-divider drag verb. Width/height persist, ~120px floor, narrow-
  header icon-only collapse, BoundedAccordionScroll, Reset-window-state — all VM.
- **SFB-07 sort & recency modes** — no verb for the sort menu, recency-color
  menu, or the 3px recency stripe; mtime-tier bucketing, future-date clamp,
  first-paint flicker, and the 2048-entry recency cache bound are unobservable.
- **SFB-09 file context menu** — Open in New Tab / Split / Open As… / Copy Path
  / Copy Relative Path / Reveal in Finder / File History gating. Only
  `set-open-as` and `file-history` have verbs (both owned by other groups);
  the menu itself and clipboard side-effects aren't reachable.
- **SFB-11 Reveal in Sidebar + Files-lock** — no `reveal-in-sidebar` or
  `files-lock` verb; the auto-root-on-reveal + lock-suppresses-reroot interplay
  is entirely UI-gesture-driven.

### Findings summary (group 2/12)

1. **[OBSERVABILITY / S3] The sidebar + bookmarks UI is a near-total dump blind spot.**
   No `mdv.*` a11y ids propagate to NSView, and SwiftUI label TEXT (row names,
   badge letters, BOOKMARKS chips, sort/recency menu values, in-tree star) is
   not captured by `DiagnosticDump`. Combined with `modelStateDump` omitting
   `selectedURL` / `expanded` / `sortMode` / `includeHidden` / the bookmarks
   list / line bookmarks / `folderStatsExpanded`, MORE THAN HALF of this group's
   smokes (SFB-04/05/06/07/09/11 and most edge cases of 02/03/08) cannot be
   asserted by an automated T4 run as the harness stands. Recommend EITHER
   widening `ScriptVerb.modelStateDump` with a `sidebar` projection
   (`selectedURL`, `expanded`, `sortMode`, `includeHidden`, `folderStatsExpanded`,
   a `bookmarks` summary) OR teaching `DiagnosticDump` to capture SwiftUI label
   text. This is the single biggest lever for making group-2 UAT real.

2. **[NOTE, not a bug] The `open` script verb opens a NEW tab for a different file; it does not reuse the focused tab.**
   `open <other-file>` from a loaded tab yields `tabCount += 1` (it dedups only
   if the file is ALREADY open). The smoke's "single-click file → current tab"
   reuse is a SwiftUI tap-gesture behavior distinct from the `openPath` model
   entry point the verb drives — so a verb-only run cannot exercise the
   reuse-current-tab path. Worth a doc note; not a defect.

3. **[HARNESS GAP / S3] No script verb for line bookmarks (⌥⌘D).**
   `DocumentModel.toggleCurrentLineBookmark()` and the source caret line
   (`sourceSelection.line`) have no `--script` entry point, so SFB-04 (set →
   gutter dot → jump-to-line → F/D/L filter) is wholly unautomatable. Recommend
   a `toggle-line-bookmark [<line>]` verb (and a `goto-line <n>` to position the
   caret) so the line-bookmark round-trip becomes driveable.

4. **[OBSERVATION / S4] `session-open-new` creates+activates the session but the LIVE sidebar root did not follow it within the ~300 ms capture window.**
   After `session-open-new <subfolder>`, the new session is listed and marked
   active (`activeSessionID` set), but the active `sidebar.rootURL` stayed on the
   PRIOR root in the captured dump (evidence:
   `SFB-10_open-in-new-session_no-reroot.json`). This MAY be a capture-timing
   artifact (the re-root lands after the snapshot) rather than a defect; the
   session-switch/re-root coupling is owned by `sessions.md` SESS-01/05, so it
   is logged as an observation, not asserted/failed here. Flag for the sessions
   group to confirm the re-root actually lands.

5. **[SIDE-EFFECT, mitigated] Live `toggle-bookmark` writes the REAL user bookmark store.**
   The shipped bundle has no bookmark-store-path override, so every UAT
   `toggle-bookmark` mutates `~/Library/Application Support/MarkdownViewer/bookmarks.json`.
   Scenarios toggle their bookmarks back off in-script, and the suite's
   `tearDown` scrubs any `/var/folders`|`/tmp`|`SidebarBookmarksUAT-` entry as a
   belt-and-suspenders against a SIGKILL'd mid-script launch. Verified: 0 scratch
   entries remain post-run; the user's 12 real bookmarks are untouched. Future
   harness work should expose a store-path override env var so live UAT never
   touches the user's real store at all.

---

## Group 1/12 — tabs-and-window-chrome — RE-RUN / VERIFY (fresh)

A fresh re-execution of the existing executor suite (no re-author needed — the
durable T4 companion already exists and compiles), plus a **beyond-assertion
realized-tree inspection** the original PASS table did not record.

- **Executor suite:** `Tests/ViewerUITests/uat/TabsAndWindowChromeUATTests.swift` (T4 `MultiScenarioTestCase`, 10 tests)
- **Compile:** `swift build --build-tests` → Build complete (clean).
- **Run cmd:** `env -u MDV_HEADLESS_GATE swift test --filter 'ViewerUITests.TabsAndWindowChromeUATTests'`
- **Result:** **10 tests, 0 failures, 0 unexpected (40.8s).** The carry-mode
  desync fires as a tracked `XCTExpectFailure` (`hex` ≠ `preview`) — i.e. the
  S3 bug is STILL LIVE and correctly captured, not regressed-fixed.
- **Coverage map:** SC-CHROME-01 (`_multiTabLifecycle`, `_01var_symlinkDedup`,
  `_01var_bookmarkToggle`), SC-CHROME-02 (`_modeBarRoutingAndOpenAs`,
  `_previewRoutingAndOpenAs`, `_asyncLoaderRace_latestSwitchWins`,
  `_carryModeHexOntoPreview_DESYNC`), SC-CHROME-04
  (`_statusBarVisibilityCoupling`), SC-CHROME-05 (`_chromePinUnderResizeAndSidebar`),
  SC-CHROME-06 (`_zoomScaling`). All PASS — re-confirming the prior run's table.

### Beyond-assertion: realized chrome-tree inspection (new this run)

Generated fresh `DiagnosticDump` JSONs from the live occluded bundle for two
levers the rigid assertions don't introspect at the view-geometry level:

1. **Chrome-pin holds at the window minimum — confirmed by node frames.**
   `resize 360x300` is clamped by the window `contentMinSize` to a realized
   `600x360` contentView (the window can't actually go to 360×300 — correct
   real-world behavior; the test's "360x300" comment is the *requested*, not
   realized, size). Across full→clamped the chrome holds: ModeBar
   `SystemSegmentedControl` stays a fixed `314x24`; the center band
   (`MarkdownRenderedView` WKWebView) is the only thing that shrinks —
   `802.5x621 → 302.5x249`. No chrome bar blanked, zero-sized, or hidden. The
   WKWebView is never zero-sized (`zeroSize` absent) in either state. The
   `DocumentView 0x0` / `HostingScrollView …x0` nodes in the dump are the
   *inactive* source-mode scroll chain (rendered mode is active), not a blanked
   pane — verified by the live WKWebView carrying the real `802.5x621` frame.

2. **Carry-mode HEX→preview desync — proven at the REALIZED tree, not just the
   model scalars.** The saved evidence dump
   (`docs/uat/evidence/SC-CHROME-02_carry-hex-onto-preview_desync.json`) shows
   `currentViewMode=hex` while the mounted subtree is
   `ZoomableImageScrollView` → `CenteredImageView` → `_NSImageViewSimpleImageView`
   and **NO `Hex*` view is present anywhere in the tree**. So the ModeBar picker
   genuinely highlights "HEX" over a pane that is unmistakably the native image
   lens — a user-visible lie, not a model bookkeeping artifact. (S3 bug, item 1
   in the original findings; re-confirmed live.)

3. **Single-mode binary genuinely HIDES the view-mode picker — confirmed.**
   Opening `bin.dat` (unknown binary): `mode=hex, state=binary`, `HexNSTextView`
   byte grid mounted, and the wide `314x24` ModeBar view-mode `SystemSegmentedControl`
   is **absent** from the tree (only HexView's own narrower `108x24`/`112.5x24`
   internal controls remain). The original table asserted `mode=hex` but did not
   verify the picker chrome actually disappears; the tree walk now does. No
   discrepancy — SC-CHROME-02 step 11 holds at the view layer.

### Findings (group 1/12, re-run) — agree with prior run; no new defects

- **[BUG / S3] Carry-mode HEX leaks onto native-preview types — picker↔pane
  desync.** REPRODUCED. ModeBar shows HEX selected while the native Preview lens
  (image/SQLite browser) is what renders (`mode=hex`, `state=preview`, no Hex
  view in tree). Root cause unchanged: `DocumentModel.openResolved` carry-mode
  carries `.hex` because `.hex ∈ availableModes` of preview types
  (`[.preview, .hex]`); the loader returns `.preview` and the HEX-load block is
  correctly skipped, leaving the picker selecting a mode the pane isn't in.
  Self-heals on any explicit re-pick or Open-As→Auto. Captured as a tracked
  `XCTExpectFailure` (remove the wrapper when a carry-mode guard lands).
- **[HARNESS GAP / S4] Dirty-close NSAlert deadlocks `--script` automation.**
  Unchanged. `close-tab` on an editor-dirty tab → `NSAlert.runModal()` blocks the
  main thread forever in a headless/occluded run. SC-CHROME-01 step 6
  (Save/Don't-Save/Cancel + neighbor-selection) is NOT automatable as written;
  worked around with `editor-save` before close. Recommend a
  `confirm-dirty-close <save|discard|cancel>` script verb routed through the
  existing unused `dirtyClosePromptOverride` hook.
- **[NOTE / S4] `set-open-as hex` is a silent no-op.** There is no `hex`
  `FileCategory`; the byte-grid lens is the `binary` category. Forcing HEX via
  Open-As must use `set-open-as binary`.
- **[OBSERVATION / S4] `resize 360x300` is clamped to `600x360`.** The `resize`
  verb cannot drive below the window's `contentMinSize`, so the chrome-pin
  invariant is exercised at the *minimum* window size, never below it — which is
  the real ceiling a user can reach by dragging. Sub-minimum behavior (if any)
  is not script-reachable; left to MANUAL/VM. Not a defect, just a scope note so
  the "360x300" in the test comment isn't mistaken for the realized geometry.
- **[NOT SCRIPT-REACHABLE — MANUAL/VM]** Same gaps as the prior run: dirty-close
  modal branch; live caret Ln/Col channel, metric-chip tooltips, date-chip
  ViewThatFits truncation, red stale-on-disk Modified chip (no caret-move / hover
  / external-write verbs); rail over-subscription + `BoundedAccordionScroll`
  window-clamp (no rail-toggle verb); split view (⌘\ / ⇧⌘\), Finder drag-drop
  overlay, per-pane tabs (no split verbs); the authoritative WindowServer
  pixel-blank check (T5/VM, since occluded windows suspend drawing and PNG snaps
  are blank).

---

## Group 2/12 — sidebar-filetree-and-bookmarks — RE-RUN / VERIFY (fresh)

- **When:** fresh re-run, same session date 2026-06-03.
- **App under test:** `dist/TextView.app` @ `main 798b7ee` (live, occluded via `MDV_BACKGROUND=1`, `MDV_SKIP_WORKSPACE_RESTORE=1`).
- **Suite:** `Tests/ViewerUITests/uat/SidebarFileTreeAndBookmarksUATTests.swift` (already authored by the prior run; compiled ONCE via `swift build --build-tests`, then run live).
- **Command:** `env -u MDV_HEADLESS_GATE swift test --filter 'ViewerUITests.SidebarFileTreeAndBookmarksUATTests'`
- **Result:** **10/10 tests PASSED** in 47.9s. No regressions vs the prior run.
  - `test_SFB_01_openFolderNavigateTreeOpenFiles` PASS (5.3s)
  - `test_SFB_01_rootAtFilesystemRoot` PASS (3.1s)
  - `test_SFB_02_hiddenSidebarKeysInert` PASS (4.9s)
  - `test_SFB_02_keyboardNavAndSidebarToggle` PASS (6.6s)
  - `test_SFB_03_fileBookmarkToggleAndPersist` PASS (4.6s)
  - `test_SFB_03_folderBookmarkViaRootFallback` PASS (4.8s)
  - `test_SFB_08_gitRootAndFolderStatsToggle` PASS (4.7s)
  - `test_SFB_08_nonRepoRootFolderStatsNoop` PASS (3.8s)
  - `test_SFB_10_openInNewSession` PASS (4.0s)
  - `test_SFB_12_bookmarkPersistsAcrossLaunch` PASS (6.1s)
- **Store hygiene:** verified `~/Library/Application Support/MarkdownViewer/bookmarks.json` has **0** scratch entries after the run (tearDown scrub + in-script toggle-off both held).

### Beyond-assertion observations (fresh dump inspection)

Drove the live bundle directly into a persistent artifact dir and inspected the
`DiagnosticDump` JSON tree per step (not just the model scalars the suite asserts).

1. **[CORRECTION to prior run's SFB-10 BUG-WATCH — harness artifact, NOT a production bug / S3]**
   The prior run flagged "the ACTIVE sidebar root did NOT follow the new session"
   as a possible capture-timing issue. Fresh inspection shows it is **deterministic
   across a >1.2s window** (5 consecutive dumps), and I traced the root cause:
   `MDV_SKIP_WORKSPACE_RESTORE=1` (which the harness always sets) **short-circuits
   `sessions.bootstrap()`** in `Sources/MarkdownViewer/main.swift:215-216`, so
   `core.setLifecycle(bridge)` is **never wired**. `core.openFolder(subdir, forceNew:true)`
   therefore creates + activates the session snapshot but its `lifecycle?.mount(snap)`
   is a nil-coalesced no-op — `SessionState.hydrate` (which calls
   `model.sidebar.setRoot(subdir)`, `SessionState.swift:242`) never runs. So under
   the script harness the live sidebar legitimately cannot re-root on session
   create/switch. This is an **observability limitation of the skip-restore harness**,
   not a defect in the production re-root path. The suite correctly asserts only the
   coordinator's session list (which IS populated + active), so it stays green and
   honest. *Production re-root-on-session-switch must be verified on the VM lane with
   real bootstrap — it is NOT covered by any host T4 here.*

2. **[TEST-INFRA QUALITY ISSUE / S3] `delay SECS` ignores its argument.**
   `Sources/MarkdownViewer/ScriptRunner.swift:43-46` sleeps a **fixed 300ms** after
   every step regardless of the verb. The `delay` verb is a pure no-op
   (`ScriptVerbDispatch.swift:197`). So a script line `delay 0.9` yields ~0.3s of
   settle, not 0.9s — the documented contract (`delay SECS  pause without action`,
   ScriptRunner doc-comment line 30) is unhonored. Consequence: every sidebar smoke
   that authors `delay 0.6`/`delay 0.9` to let FSEvents / the accordion / a re-list
   settle is actually only getting 300ms. Today nothing flakes (the model-level
   assertions settle inside 300ms), but this silently caps the longest settle window
   the harness can express, so a future async-settle race that needs >300ms would be
   structurally invisible to these T4 smokes. Recommend honoring the `delay` arg in
   the runner (parse `arg` as seconds and `Task.sleep` accordingly) so the smokes'
   stated intent matches reality.

3. **[NOTE — expected behavior, not a bug] File-open auto-roots the sidebar.**
   Launching with a FILE argv (`a.md`) sets `sidebar.rootURL` to the file's parent
   dir and selects the file, *before* any `sidebar-set-root` runs — confirmed in the
   step-01 dump. This is the intended `DocumentModel.swift:2433` auto-root
   (`sidebar.rootURL == nil` guard, user-action read-access). Flagging only so the
   step-01 root value isn't mistaken for a premature/duplicate re-root.

4. **[OBSERVATION / S4] One zero-sized `HostingScrollView` coexists with several
   non-zero ones.** The contentView tree carries 6 `HostingScrollView` + 6
   `DocumentView` hosts; one HostingScrollView (and 3 of 4 `NSScroller`s) report
   `zeroSize`. The suite's `assertSidebarSubtreeMounted` tolerates this (it only
   requires *at least one* non-zero scroll host), and it is almost certainly a
   collapsed/empty accordion panel or an off-screen overflow host rather than the
   FILES tree itself — but the dump cannot distinguish *which* panel is zero-sized
   (no a11y id, no label text). Whether a zero-sized accordion host is a latent
   "collapsed panel renders a 0-height envelope" glitch vs benign cannot be settled
   from the JSON tree; needs the VM pixel lane to eyeball.

### Observability gaps (unchanged from prior run, re-confirmed)

All sidebar/bookmarks SwiftUI a11y ids (`mdv.sidebar.*`, `mdv.bookmarks.*`,
`mdv.rail.*`) are **absent** from both `contentView` and `recursiveDescription`
(re-verified: 0 nodes with a non-empty `accessibilityIdentifier`). `modelStateDump`
exposes `sidebar.rootURL`, `sidebar.isVisible`, `isCurrentTabBookmarked`, tab state,
and sessions — but NOT selection (`selectedURL`), the expanded set, sort/recency
mode, include-hidden, the bookmark list, or line bookmarks. Consequently the
following smokes remain **NOT script-reachable** and belong to the MANUAL/VM lane:
SFB-04 (line bookmarks ⌥⌘D, gutter dot, jump-to-line — no verb), SFB-05 (shoulder
rail toggles — no `rail-toggle` verb), SFB-06 (sidebar/panel resize — `resize` is
window-only), SFB-07 (sort & recency-color menus + recency stripe tiers — no verb),
SFB-09 (file context-menu: New Tab / Split / Open As / Copy Path / Reveal / File
History — no verbs), SFB-11 (Reveal-in-Sidebar + Files-lock — no verb), and the
cross-relaunch session restore half of SFB-12 (disabled by `MDV_SKIP_WORKSPACE_RESTORE=1`;
only the BookmarksStore JSON round-trip is host-testable).

---

## Group 3/12 — view-modes (source / editor / hex / rendered / preview / formatted)

- **Executor suite:** `Tests/ViewerUITests/uat/ViewModesUATTests.swift` (T4 `MultiScenarioTestCase`)
- **Run cmd:** `env -u MDV_HEADLESS_GATE MDV_BACKGROUND=1 swift test --filter 'ViewerUITests.ViewModesUATTests'`
- **Result:** 13 tests, 0 failures, 0 unexpected (78.5s). 2 real findings captured as `XCTExpectFailure` (same root cause), 1 spec/behavior discrepancy logged.
- **Evidence:** `docs/uat/evidence/VM-01_markdown-rendered-happy-path.{json,png}`,
  `docs/uat/evidence/VM-PROBE_editorsetmode-rendered-python-desync.{json,png}`,
  `docs/uat/evidence/VM-06var_toggleview-python-offmenu-rendered.json`

### HARNESS limitation discovered (calibration, NOT an app bug)

The `--script` runner sleeps a **fixed 300 ms after every step** and **ignores
the `delay <seconds>` argument** (`Sources/MarkdownViewer/ScriptRunner.swift:45`
hard-codes `Task.sleep(nanoseconds: 300_000_000)`, never parsing `arg`). The
suite as originally authored used `delay 0.6` / `delay 0.9` between mode switches
and `open` verbs and asserted on a fixed dump index — so every async settle that
needs > 300 ms (WKWebView mount for rendered/editor, `loadBinaryAsync` for HEX,
`controller.open` restore for Preview, the async file `open`) was captured
mid-flight, producing **28 spurious failures** including a FALSE "Bug C / Hex
stuck under Preview". Root-caused by re-running each flow live with multiple bare
`delay` lines (each ≈ 300 ms) and inspecting the real dumps: every routing
behavior is correct once settled. The suite was reworked to (a) pad each settle
window with repeated bare `delay` lines and (b) assert on the **eventual**
per-`(url, mode)` dump via `dumps.first/last { … }` rather than a fixed index.
This is the same gotcha prior groups flagged; recommend honoring the `delay` arg
in the runner so a future > 300 ms async-settle race stays observable.

### VM-01 — Markdown default Rendered, ⇧⌘R round-trip, zoom — PASS (1 discrepancy)

`test_VM_01_markdownRenderedSourceRoundTripAndZoom` + `..._01var_mermaidDefaultsRendered`.

| Step | Expected | Observed | Verdict |
|---|---|---|---|
| open doc.md | Rendered default, WKWebView paints HTML, no Hex | mode=rendered, WKWebView mounted, HTML painted (heading/bold/table/code fence — see PNG) | PASS |
| ⇧⌘R → Source | raw markdown in non-hex NSTextView, never binary | mode=source, NSTextView w/ glyphs, state!=binary | PASS |
| ⇧⌘R → Rendered | symmetric round-trip back | mode=rendered, WKWebView re-mounted | PASS |
| zoom-reset; zoom-in | zoom > 1.0, stays rendered | zoom 1.0→1.1, mode=rendered | PASS |
| standalone .mmd | opens straight into Rendered | mode=rendered | PASS |

**[DISCREPANCY — S4] Ln/Col shown in Rendered mode (catalog says it should be hidden).**
VM-01 step 1 spec: *"Status bar shows path; Ln/Col **hidden** (rendered)."* Live
app in `mode=rendered` (confirmed via dump) still shows `Ln 1, Col 1 / Lines 11 /
Chars 146` in the status bar — see `evidence/VM-01_markdown-rendered-happy-path.png`.
There's no caret in the rendered WebView, so a Ln/Col readout is meaningless there.
Either the status bar should drop line/col positioning in rendered mode, or the
catalog is stale. Cosmetic, low severity.

### VM-02 — Source ↔ Editor ↔ HEX lifecycle — PASS

`test_VM_02_sourceEditorHexLifecycle` + `..._02var_editorCarryFallsBackToPreviewOnImage`.

| Step | Expected | Observed | Verdict |
|---|---|---|---|
| open .py | Source default, NSTextView w/ glyphs | mode=source, glyphs present | PASS |
| → Editor | CM6 WKWebView mounts, no Hex, no stale source | mode=editor, WKWebView, no Hex | PASS |
| set-text + save | no error, stays editor | no .error, mode=editor | PASS |
| → HEX | byte grid (HexNSTextView), state binary | mode=hex, state=binary, Hex* view + glyphs | PASS |
| → Source (back) | Source re-renders saved content, NO Hex leak (Bug C) | mode=source, state!=binary, no Hex, glyphs | PASS |
| Editor carry → open .png | falls back to Preview (Editor ∉ image modes), not stranded | mode=preview, state=preview, url=shot.png | PASS |

### VM-03 — CSV Table, JSON Format, Open-As cross-routing — PASS

`test_VM_03_csvTableAndJsonFormat` + `..._03var_openAsCrossRoutingAndInvalidJson`.

| Step | Expected | Observed | Verdict |
|---|---|---|---|
| open .csv | Table default | mode=table | PASS |
| Table ↔ Source | round-trip; Source shows raw CSV | source w/ glyphs, then table | PASS |
| open .json (minified) | conservative **Source** default, NOT formatted | mode=source, isCurrentTabFormatted=false | PASS |
| ⌥⌘F (toggle-format) | per-tab FLAG: formatted=true, **mode STAYS source** | formatted=true & mode=source captured | PASS |
| toggle-format off | flag clears | formatted=false | PASS |
| editor-set-mode formatted | the explicit Formatted **view mode** (distinct from ⌥⌘F flag) | mode=formatted, formatted=true, no Hex | PASS |
| Open-As code on CSV | force Source lens (default flips source) | csv reached mode=source | PASS |
| Open-As auto | revert to Table default | last csv dump mode=table | PASS |
| Format INVALID json | graceful: no .error, pane not blanked | state!=error, NSTextView glyphs present | PASS |

### VM-04 — Native Preview vs HEX routing — PASS (FALSE "Bug C" cleared)

`test_VM_04_previewHexRoutingRoundTrip` + `..._04var_emptyFileHex`.

| Step | Expected | Observed | Verdict |
|---|---|---|---|
| open .png | **Preview** (Bug-B guard: fresh image must NOT default to HEX) | mode=preview, state=preview, ZoomableImageScrollView, no Hex | PASS |
| → HEX | byte grid, state binary | mode=hex, state=binary, Hex* view | PASS |
| → Preview (back) | native image returns, **no Hex stuck** under Preview (Bug C) | mode=preview, state=preview, ZoomableImageScrollView, **no Hex** | PASS (was FALSE-fail under 300 ms settle) |
| open .db (sqlite) | Preview (browser), NOT HEX | mode=preview, state=preview | PASS |
| open .bin (unknown) | straight to HEX, state binary | mode=hex, state=binary, Hex* view | PASS |
| empty 0-byte file | HEX, no crash, no .error | mode=hex, no .error | PASS |

### VM-05 — Diff & HTML specialized views + Error envelope — PASS

`test_VM_05_diffAndHtmlSpecializedViews` + `..._05var_errorStateKeepsExistingTabs`.

| Step | Expected | Observed | Verdict |
|---|---|---|---|
| open .diff | Diff default (structured DiffView), no Hex | mode=diff, no Hex | PASS |
| Diff ↔ Source | raw unified diff text round-trips | source w/ glyphs, then diff | PASS |
| open .html | conservative **Source** default (not Rendered) | mode=source | PASS |
| → Rendered | sanitized HTMLRenderedView WKWebView mounts | mode=rendered, WKWebView, no Hex | PASS |
| open nonexistent path | existing tab KEPT, ErrorView appended (state .error) | tabCount>=1 kept, state=error | PASS |

### VM-06 — Per-tab mode persistence — PASS (1 real finding)

`test_VM_06_perTabModePersistenceAcrossSwitches` + `..._06var_toggleViewNoopOnPlainSource`.

| Step | Expected | Observed | Verdict |
|---|---|---|---|
| md→Source, py→Editor, csv→Table, png→Preview; cycle tabs | each tab RESTORES its own last mode (per-tab, not global) | a.md→source, b.py→editor, c.csv→table, d.png→preview on re-select | PASS |
| ⇧⌘R on a .py Source tab | should be a **NO-OP** (.py offers no Rendered mode) | **flips picker to off-menu `rendered`** | **FINDING** (XCTExpectFailure) |

### FINDINGS (2 real, same root cause)

**[FINDING-1 — S3] `toggleViewMode()` / `setCurrentViewMode()` accept an
off-menu mode → picker/pane desync.** `DocumentModel.setCurrentViewMode`
(`DocumentModel.swift:3157`) assigns `t.viewMode = mode` **unconditionally** — it
never checks `mode ∈ ViewModeOptions.availableModes(for: url)`. The only guard is
the 50 MB editor cap. Two reachable routes:
  - `toggleViewMode()` (⇧⌘R / `toggle-view` verb) on a `.py` flips the picker to
    `rendered`, which is NOT in Python's availableModes (`Source | Editor | HEX`).
  - `editor-set-mode rendered` (PROBE; also the MCP `set_view_mode` enum) forces
    the same off-menu state.

  **Visible symptom** (see `evidence/VM-PROBE_editorsetmode-rendered-python-desync.png`):
  with `currentViewMode == rendered` on `force.py`, the ModeBar picker renders
  `Source | Editor | HEX` (Python's real modes) with **NO segment highlighted** (no
  `rendered` segment exists to select), while the pane + status bar are fully in
  Source mode (NSTextView 15 glyphs, `Ln 3 Col 1 / Lines 2 / Chars 15`; **no
  WKWebView mounted**). The picker's selection indicator lies about what's shown.

  **Mitigating fact:** the LIVE ⇧⌘R menu item is DISABLED for non-markdown by
  `AppDelegate.validateMenuItem` (`return model.supportsViewModeToggle`,
  `main.swift:1435`), so a user cannot trigger this via the menu/keyboard — only
  un-gated callers (the `toggle-view`/`editor-set-mode` script verbs, the MCP
  `set_view_mode` tool, or any future call site) reach it. Severity is therefore
  S3, not higher: content does not break (graceful Source fallback, no crash, no
  blank pane, no Hex-under-non-Hex), and the common UI path is gated. The
  robustness gap is that the validity gate lives in the MENU layer, not in the
  model method itself — `setCurrentViewMode` should clamp an unavailable `mode` to
  a valid default (or no-op) so every caller is safe by construction.

  Both routes captured as `XCTExpectFailure` (PROBE + VM-06var): the suite is
  green while the gap persists and flips to "unexpectedly passed" the moment the
  model method self-guards.

### Coverage / observability gaps (MANUAL or VM-pixel lane)

The `model` dump + view-CLASS detection cover the routing/state core, but the
following VM-0x catalog beats are NOT script-reachable for this group and belong
to the MANUAL / VM-pixel lane:
- **ModeBar picker SEGMENTS** (which segments are offered for each type, their
  order, accent tint for an active Open-As / language override) — no a11y id in
  the dump; only verifiable visually (the FINDING above was caught by an occluded
  `cacheDisplay` PNG, which DID work — so picker-segment review is pixel-feasible
  on the VM lane).
- **⌘F find overlays** (MarkdownFindBar X-of-N count, rendered-vs-source regex
  difference, ⌘G/⌥⌘G stepping, minimap ticks) — `show-find` only toggles the
  rendered find bar; no match-count / step verbs.
- **Wrap / invisibles / Enable-JS toggles**, **split view (⌘\\)** with independent
  per-pane modes, **language-badge override** — no script verbs.
- **Large-file placeholders** (`LargeMarkdownPlaceholderView` >4 MB,
  `LargeEditorPlaceholderView` >50 MB, `LargeHTMLPlaceholderView` >4 MB) — drivable
  via a >cap fixture but the placeholder is a SwiftUI view with no NSView class /
  model scalar in the dump; needs pixel review.
- **Loading-state spinner** (delayed 100 ms) — transient, not capturable at the
  fixed 300 ms step boundary.
- **Cross-relaunch persisted-mode restore** (VM-06 step 6) — disabled by
  `MDV_SKIP_WORKSPACE_RESTORE=1` in the harness.
- **#218 HEX-entry latency / #219 Editor→HEX flash-of-Source** — timing/transient,
  invisible at the 300 ms capture boundary; known-open issues, not re-failed here.

---

## Group 4/12 — cm6-editor (edit / save / dirty / close)

Executor: T4 live-app suite `Tests/ViewerUITests/uat/Cm6EditorUATTests.swift`
(authored this run, compiled once, 10 scenarios run against the assembled
`dist/TextView.app` occluded via `MDV_BACKGROUND`, one `DiagnosticDump` JSON +
PNG per step). Plus direct `--script` drives with preserved artifacts under
`/tmp/cm6uat*` for beyond-assertion screenshot inspection.

**All 10 scenarios PASS their scripted assertions** (10 tests, 0 failures, 61.6 s).
The deterministic save round-trip is verified through the authoritative signal —
**bytes on disk** — for every edit/save beat. But the screenshot inspection
surfaced **two real render-layer defects** that the disk-based assertions cannot
see (and that a model-only assertion is structurally blind to).

### The dominant observability constraint for this group

The editor's *dirty state* is **NOT** projected into the per-step dump.
`ScriptVerb.modelStateDump` emits `currentViewMode / currentStateKind /
windowTitle / tabCount / selectedTabIndex / currentURL / ...` but **no**
`isDirty` / `hasUnsavedEdits` scalar, and `windowTitle` is a pure
`tabs.selected?.title` projection that carries **no dirty marker** (verified: the
title reads `'uat_edit.txt'` identically at the dirty step 08 and the clean
post-save step 10). The SwiftUI a11y ids (`mdv.tab.dirtyDot`, `mdv.editor`,
`mdv.editorFindBar`) are absent from the realized `NSView` tree the dump reads.
So the load-bearing save signal is **disk**; the dirty-dot / Save-menu /
find-bar / both NSAlerts are screenshot- or VM-manual-only.

### The close-dirty modal HANG hazard (informs every close scenario)

`close-tab` → `closeCurrentTab()` → `closeTab(at:)` → `confirmCloseIfDirty(at:)`
runs a **real blocking `NSAlert.runModal()`** on a dirty tab, and the script path
never wires `dirtyClosePromptOverride`. In the occluded run nothing clicks it, so
driving `close-tab` on a **dirty** tab would block until the scenario timeout (a
false "launcher threw", not a real assertion). Every `close-tab` in the suite is
therefore preceded by `editor-save` (clears dirty → no prompt) or issued on a
clean tab. The 3-button prompt itself (Save / Don't Save / Cancel) + its Cancel /
Don't-Save branches + the Close-Other / Close-to-Right batch prompts are
MANUAL / VM beats.

### cm6-1 — First edit → ⌘S round-trip — PASS (disk) + 2 render-layer findings

- `test_cm6_1_firstEdit_modeSwitch_saveRoundTrip`,
  `test_cm6_1var_markdownEditInEditorThenBackToRendered`,
  `test_cm6_1var_editThenRetypeOriginal_saveIsNoOp`,
  `test_cm6_1edge_emptyBufferSavesZeroBytes` all green.
- `.txt` opens Source by default; `editor-set-mode editor` mounts the CM6
  WKWebView (dump: `frame 790.5x615.0`, `isLoading=false`,
  `estimatedProgress=1`, loads `codemirror.html`) — **no blank box** (the
  WidgetType/duplicate-bootstrap regression guard holds). No stale Source
  NSTextView and no Hex grid leak under the Editor picker (the only NSTextView
  in editor mode is the chrome `_SystemTextFieldFieldEditor`, glyphs=0).
- Empty-buffer save → 0-byte file, no crash. Retype-to-original then save →
  disk byte-identical to the original (no spurious mutation).
- Markdown: opens Rendered, edit-in-Editor saves to disk, flip back to Rendered
  re-mounts a clean WKWebView (no Hex leak) — the stale-cache guard holds at the
  surface level.
- **FINDING 1 (BUG — dirty dot never appears on edit in editor mode).** See
  findings table. **FINDING 2 (BUG — status-bar metrics stale in editor mode).**

### cm6-2 — Undo/redo + find/replace — PARTIAL (multi-save persisted; JS surfaces not script-reachable)

- `test_cm6_2_multiSaveCycle_plainTextFallbackLanguage` (a `.rs`
  plain-text-fallback language: editor mounts, multi-save latest-wins on disk),
  `test_cm6_2edge_utf8RoundTrip` (multibyte `héllo 🌟 — café 日本語 — ünïcödé`
  round-trips losslessly through the save encoding path) — both green.
- **Undo (⌘Z) / Redo (⇧⌘Z), the editor find bar (`mdv.editorFindBar`,
  Match-case/Regex/n-of-N), and the CM6 native search+replace panel are NOT
  script-reachable** — they are JS-keymap interactions *inside* the WKWebView and
  there is no `editor-undo` / `editor-find` / `editor-replace` verb (`show-find`
  toggles the *rendered* find bar, a different surface). These are MANUAL / VM
  beats. The whole undo/redo responder-chain fall-through (editor-not-focused),
  multi-cursor, and undo-through-setText limitation are likewise out of script
  reach.

### cm6-3 — Close a dirty tab — PARTIAL (save-then-close PASS; prompt branches manual)

- `test_cm6_3_closeCleanTab_andSaveThenClose` green. Verified the two
  non-hanging close paths: edit A → `editor-save` (clears the model dirty flag —
  proven because the subsequent `close-tab` did **not** hang on a modal) →
  `close-tab` closes A, selection lands on neighbour B (tab 2→tab 1, Source),
  B's disk untouched, A's edit persisted. tabCount 2→1.
- This also pins that **the save clears `Tab.isDirty` at the model layer** — the
  dirty-dot bug below is purely render-layer, not a model-state defect.
- **Cancel / Don't-Save branches, the 3-button NSAlert content, and the
  Close-Other-Tabs / Close-to-the-Right batch prompts are MANUAL / VM** (modal,
  no script override → would hang). The documented **app-quit / last-window gap**
  (`hasAnyUnsavedEdits` has no caller on ⌘Q / window-close → silent dirty-buffer
  drop) is a known data-loss risk; not re-failed here, recorded as carry-over.

### cm6-4 — External-edit conflict prompt — PARTIAL (clean-stay PASS; conflict modal manual)

- `test_cm6_4_externalEditWhileClean_noConflictHang` green: a clean editor tab
  over a watched file stays healthy (editor mode, not error, WKWebView mounted)
  across watcher ticks; disk untouched.
- **The DIRTY conflict prompt (Keep My Edits / Discard & Reload) is a blocking
  modal with no script override → would hang.** And the *live external write*
  can't be injected from the single-threaded `--script` runner mid-run (no shell
  verb). So the full S1-A baseline-preservation flow, the duplicate-tick
  re-prompt guard, the FW-7 save-race reconcile, the symlink Follow-Link gap, and
  the read-only-dir save-failure alert are all MANUAL / VM beats. (The
  underlying logic has headless coverage in `EditorCoordinator*Tests`.)

### cm6-5 — Capacity / mode-routing / go-to-line / cursor restore — PASS (routing) + gaps

- `test_cm6_5_editorHexSourceRouting_andGotoLine` and
  `test_cm6_5edge_rapidToggling_latestWins` green. Editor↔HEX↔Source routing is
  clean at every landing: editor→hex(`binary`)→source(`loaded`)→editor(`loaded`),
  state always consistent with the picker — **no wrong-viewer-under-mismatched-picker
  (the fixed Bug C stays fixed)**, no `.loading`-stuck after a rapid 5-switch
  burst (latest switch wins). HEX renders a correct byte grid (offsets / hex
  cols / ASCII gutter / Width 16-32-64 / Hex-ASCII toggle); status `Size 35 B,
  Enc binary`. `goto 3` issued in editor without error.
- **Not script-reachable / not dump-observable** (MANUAL / VM): the indentation
  setting (Tabs vs N spaces, 1..16 clamp), Fold All / Unfold All (+ the ⌥⌘[ /
  ⌥⌘] vs Move-Tab collision), per-tab cursor/scroll **restore** on tab switch
  (CMSelectionSeed), the **50 MB cap placeholder** (`mdv.editor.largePlaceholder`
  + "View as Source" — a SwiftUI view with no NSView class / model scalar), the
  near-cap 32 MiB `EditorBuffer.load` truncation boundary, the native
  right-click editor menu (Go-to-Definition / Cut-Copy-Paste), and the #219
  Editor→HEX flash-of-Source (transient at the 300 ms capture boundary).

### FINDINGS (group 4/12) — 2 real render-layer bugs, same root cause

Both stem from the **same severed publish path**: `EditorCoordinator.onReplaceTab`
is wired as `{ [tc] idx, tab in tc.replace(at: idx, with: tab) }`
(`DocumentModel.swift:300`), which fires only `tabCoordinator.objectWillChange`.
PERF #1 (`fd11e61` era) severed `tabCoordinator.objectWillChange →
DocumentModel.objectWillChange` forwarding; the `61c1aef` LOADBUG fix re-added an
explicit `updateDerived()` republish **only at the three async load completions**,
NOT on the editor edit/save replace path. `TabBar` and `StatusBar` observe ONLY
`@ObservedObject DocumentModel`, so neither re-bodies when an editor edit/save
mutates the tab via `replace`.

| # | Title | Kind | Severity | Evidence |
|---|-------|------|----------|----------|
| F1 | Dirty dot never appears on edit in Editor mode (no `mdv.tab.dirtyDot` after `editor-set-text`, despite `Tab.isDirty` flipping true at the model) | bug / regression | S2 | `/tmp/cm6uat/mdv-step-08.png` + `tab_crop.png`: edited buffer shown, tab has only the `×`, no accent dot. `DocumentModel.swift:300`; `TabBar.swift:265` renders the dot on `tab.isDirty`; `TabBar.swift:5` observes only `DocumentModel`. |
| F2 | Status-bar Lines/Chars/Size stale in Editor mode — never reflect the live buffer while dirty, and don't refresh after `editor-save` until you leave editor mode | bug | S3 | `/tmp/cm6uat/mdv-step-10.png` (post-save, editor): `Lines 3 / Chars 20 / Size 20 B` = the on-disk-at-open values; disk is actually 42 B / 1 line. `/tmp/cm6uat2/mdv-step-13.png` (switch to Source): corrects to `Lines 1 / Chars 42 / Size 42 B`. `StatusBar.swift:223` reads `f.contents` from `tab.state`, observes no editor buffer. |

Severity calls: both are **render/observability only — no data loss** (the model
dirty flag and the on-disk bytes are correct throughout; the save-then-close path
proves the model clears dirty). F1 is S2 (the dirty dot is the primary unsaved-work
affordance — a user can't tell a tab is dirty in editor mode). F2 is S3 (the status
metrics are informational; misleading but not destructive).

**Important caveat (why these may *partially* mask on live human typing):**
`onCursorMirrorToStatusBar` writes `DocumentModel.sourceSelection` (a `@Published`
on `DocumentModel`) on every CM6 cursor move. Real keystrokes move the cursor, so a
live-typed edit *incidentally* republishes `DocumentModel` and would re-render
TabBar/StatusBar — likely making the dirty dot appear and the L:C readout update on
human typing. The programmatic `editor-set-text` path does **not** record a cursor
move, so it exposes the underlying severed-publish defect cleanly. **But F2's
save-path staleness is robust regardless of input method**: `editor-save` never
moves the cursor, so even after live typing, ⌘S would clear the model dirty flag
and rewrite `tab.state` without re-bodying the editor-mode status bar — the metrics
stay stale until the cursor next moves or the mode changes. Both warrant a VM
live-typing confirmation; F2 is the higher-confidence live bug of the two.

### Suite location & re-run

- `Tests/ViewerUITests/uat/Cm6EditorUATTests.swift` — durable T4 companion to
  `docs/uat/smokes/cm6-editor.md`.
- Re-run: `env -u MDV_HEADLESS_GATE swift test --filter
  'ViewerUITests.Cm6EditorUATTests'`. Self-skips on the headless gate
  (`MDV_HEADLESS_GATE=1`) and when `dist/TextView.app` isn't built.

---

## Group 5/12 — search (find-bar / cross-file / unified panel / jq / css / xpath)

Run date: 2026-06-03. Executor drove the assembled
`dist/TextView.app` occluded (`MDV_BACKGROUND=1`) via the `--script` verb
dispatcher; one `DiagnosticDump` JSON + PNG per step. Durable T4 companion:
`Tests/ViewerUITests/uat/SearchSurfacesUATTests.swift` (5 scenarios, all
green). Re-run: `env -u MDV_HEADLESS_GATE swift test --filter
'ViewerUITests.SearchSurfacesUATTests'`.

### Observability ceiling for this group (the dominant constraint)

Two hard limits shaped what is *assertable* vs *screenshot-only*:

1. **Zero `mdv.*` a11y ids in the dump.** Live probe of the cross-search
   overlay's `contentView` tree returned 0 accessibility identifiers — the
   SwiftUI `.accessibilityIdentifier()` ids (`mdv.crossSearchPanel`,
   `mdv.unifiedSearch.scope.*`, `mdv.hex.search.*`, `mdv.searchAnywhere`,
   `mdv.csvFilter.*`) do NOT propagate onto `NSView.accessibilityIdentifier()`.
   Same finding as groups 1–4.

2. **The model dump carries NO search results.** `ScriptVerb.modelStateDump`
   surfaces only `isCrossSearchPresented` + `isRenderedFindBarPresented`
   (Bool) and the sidebar root. It does NOT carry `crossSearchResults` count,
   `crossSearchIsRunning`, `crossSearchCaseSensitive`, nor any find-bar
   match-count. Result text is SwiftUI `Text` (rendered to CALayer, not an
   `NSTextView`), so it is unreadable from the JSON — but it IS legible in the
   per-step PNG.

**Detector used:** cross-search results are SwiftUI rows mounted into a
`HostingScrollView` inside the overlay; a populated search adds ~20 view
hosts to the `contentView` node count. The suite asserts this **relative** to
the same run's panel-open-no-match (chrome) baseline — fixture-independent
(absolute counts shift with how many files the sidebar tree lists). Verified
live (rich fixture): no-panel ≈141, panel+0-match ≈153 (chrome), panel+matches
≈174 (rows mounted). PLUS screenshot review of every populated step.

### NOT script-reachable in this group (logged for MANUAL / VM lane)

No `--script` verb exists for these surfaces — they are NOT failures, just
out of reach of the headless-occluded T4 lane:

- **SMK-SEARCH-05 — HEX viewer search toolbar.** No `mdv.hex.search.*` verb;
  Hex/ASCII mode toggle, even-length-hex validation (red field), non-
  overlapping match semantics, wrap-around stepping, click-to-highlight teal
  overlay, 50k cap `i / N+`, bytes-per-row relayout — all manual/VM. (Engine
  caps confirmed present in `HexSearchEngine.swift`.)
- **SMK-SEARCH-04 — Search Anywhere sidebar panel.** No verb to drive the
  section field/scope. The SEARCH rail + "Search files…" field IS visible in
  the cross-search screenshots, but its ≥2-char gate, 200ms debounce, scope
  picker (Pick Folder…/Clear Picked Folder), Aa toggle, zero-Divider layout
  invariant — all manual/VM.
- **SMK-SEARCH-06 — jq filter.** No verb; `Cmd+Opt+J` is a menu action. The
  result-as-new-tab, cache, bad-filter NSAlert, missing-binary NSAlert,
  runaway-filter rlimit, menu enable/disable gating — all manual/VM. (Catalog
  claim "no css/xpath equivalent" holds: only jq has a prompt.)
- **Cross-search Aa case toggle** (`crossSearchCaseSensitive`): no verb, so
  the case-sensitivity path is screenshot-only.
- **Source / Editor find BARS:** only the RENDERED bar has a `show-find`
  verb. The source `FindEngine` (regex + minimap ticks, ReDoS guard) and the
  CM6 editor find bridge can't be opened from script — manual/VM.

### SMK-SEARCH-01 — Find-bar isolation across view modes — PARTIAL + 1 bug

Reachable slice (rendered find bar mount/dismiss): **PASS** — `show-find`
sets `isRenderedFindBarPresented=true`, `dismiss-find` clears it, a clean
open→close cycle on `README.md` (Rendered), no error at any step.

**BUG (S3, real, screenshot-confirmed) — F-SEARCH-1:** The rendered find bar
renders a `.*` regex toggle that the catalog says must be ABSENT (WKWebView
find can't regex). Root cause: the shared `FindBar` view renders the `.*`
`Toggle` UNCONDITIONALLY (`MarkdownFindBar.swift:80-89`); the rendered bar
wires it to `isRegex: .constant(false)` (line 160) with the comment "toggle
is hidden visually but state is unused" — but **no code hides it**. The user
sees a dead control: it's bound to a constant, so clicking does nothing and
it can never show an on-state. Evidence: `mdv-step-04.png` (rendered find bar,
placeholder "Find in rendered markdown…", shows BOTH `Aa` and `.*` toggles).
Contradicts `search.md` SMK-SEARCH-01 step 1 and the scope table. The fix is a
one-line conditional to omit the regex toggle when `isRegex` is a constant /
for the rendered bar.

Steps 2–8 (match count, case toggle re-run, source regex `n[ae]+dle`, minimap
ticks, editor bag isolation, ReDoS guard, CRLF line/col) — NOT script-reachable
(source/editor find bars have no `show` verb; no query-injection verb; no
match-count in dump). Manual/VM.

### SMK-SEARCH-02 — Cross-file search modal: results, grouping, skips — PASS

Headless-reachable end-to-end via `sidebar-set-root` + `show-cross-search` +
`set-cross-query`. **PASS** with rich screenshot confirmation:

- Panel mounts over the content (`.overlay` in ContentView, NOT a sheet
  window) with field + Aa + clear-X + scope row ("…/uat-search" + "folder
  scope" chip).
- Zero-match (`zzqqxnomatch`): panel shows `No matches`, node count stays at
  the chrome baseline (no rows mount). `mdv-step-05.png`.
- Match (`needle`): results grouped by file with line numbers. Verified hits
  in `README.md (3)` (incl. capital `Needle` — case-INsensitive default
  correct), `app.ts` (2: comment + string), `data.json`, `page.html`,
  `doc.xml`, `table.csv`, `latin1.txt` (CP1252 file searched via the decode
  chain — NOT silently invisible), `notes.md` (CRLF). `mdv-step-10.png`.
- **Skips verified ABSENT from results:** `big.log` (>2 MiB), `bin.dat`
  (binary NUL), `.hidden/secret.md`, `node_modules/x.js`. The symlink loop
  (`loop -> ..`) did NOT hang — search terminated. All four poison files are
  correctly excluded while the grep still completes.
- No step errored the document while walking the poison files.

Variation **SMK-SEARCH-02var (stale-result guard + dismiss)**: **PASS** — a
rapid `needle`→`hay` re-query landed a stable result set without the panel
dropping or erroring (generation counter holds); `dismiss-cross-search` flips
`isCrossSearchPresented=false` and tears the overlay back below the with-
results node count (query + results cleared).

Not reachable: the 500-total / 8-rows-per-file caps (would need a 600-hit
fixture; caps confirmed in `CrossFileSearch.swift` — `maxResults: 500`,
entry-cap backstop). The match-row jump-to-line + rendered→source coercion
needs a click the script can't issue. Manual/VM.

### SMK-SEARCH-03 — Reserved jq/css/xpath modes inert; .text greps folder — PASS

**PASS.** `.text` grep ran against the FOLDER (multiple files matched, rows
mounted above the no-panel baseline) — confirming the only engine-backed mode
is the folder grep, NOT a single-file jq/css/xpath query. The catalog
invariant holds structurally: there is NO verb that selects `.jq`/`.css`/
`.xpath`, and no toggle exposes them — i.e. the reserved modes are present-but-
inert exactly as documented. The scope-picker menu items themselves and the
single-file→parent-folder fallback resolver are not script-drivable (no scope
verb); the fallback target (folder grep) is what we observed.

### SMK-SEARCH-08 — Cross-surface continuity: tab reuse + mode carry — PASS

**PASS.** Open cross-search + run `needle` + dismiss, then re-`open` the
already-open `app.ts` → tab count stays **1** at every step (no duplicate
tab), then switch to Editor → CM6 WKWebView mounts, mode carried, no stale
Hex grid, no error. The "follow the trail" continuity holds for the reachable
hops. Steps needing a result-row click / `goto_line` MCP / the CSV-`Cmd+F`-vs-
filter surface boundary / SQLite-SELECT-as-search are manual/VM (no verbs;
CSV/SQLite filter internals owned by PV-04/PV-05).

### Findings summary (group 5/12)

| ID | Title | Kind | Severity | Evidence |
|----|-------|------|----------|----------|
| F-SEARCH-1 | Rendered find bar shows a `.*` regex toggle that the catalog says must be absent (WKWebView can't regex); it is a DEAD control bound to `.constant(false)` — clicking does nothing, never shows on-state | bug / inconsistency | S3 | `mdv-step-04.png` (rendered find bar with both `Aa` and `.*`); `MarkdownFindBar.swift:80-89` (toggle rendered unconditionally) + `:160` (`isRegex: .constant(false)` with stale "hidden visually" comment) |

Known-open issues NOTED (not failed), per catalog: `#218` HEX entry latency,
`#219` Editor→HEX flash, rendered-`Cmd+F` regex absence-by-design (the F-
SEARCH-1 finding is the *opposite* — the toggle is wrongly PRESENT, not
absent), `#201` macOS-26 fragment host red.

### Suite location & re-run

- `Tests/ViewerUITests/uat/SearchSurfacesUATTests.swift` — durable T4
  companion to `docs/uat/smokes/search.md`. 5 scenarios:
  `test_SMK_SEARCH_01_renderedFindBarMountDismiss`,
  `test_SMK_SEARCH_02_crossFileModalResultsAndSkips`,
  `test_SMK_SEARCH_02var_staleGuardAndDismissClears`,
  `test_SMK_SEARCH_03_reservedModesInert_textGrepsFolder`,
  `test_SMK_SEARCH_08_tabReuseAndFindBarAcrossModes`. All PASS.
- Re-run: `env -u MDV_HEADLESS_GATE swift test --filter
  'ViewerUITests.SearchSurfacesUATTests'`. Self-skips on the headless gate
  (`MDV_HEADLESS_GATE=1`) and when `dist/TextView.app` isn't built.

## Group 6/12 — git-panel (status / log / stash / trees / remotes / file-history)

**App under test:** `dist/TextView.app` (built 2026-06-03, dated this run).
**Harness:** durable T4 `GitPanelUATTests` (`Tests/ViewerUITests/uat/`), driven
by `env -u MDV_HEADLESS_GATE swift test --filter 'ViewerUITests.GitPanelUATTests'`.
5 scenarios, **all 5 PASS** (21.0 s). Occluded `MDV_BACKGROUND` spawn; JSON
DiagnosticDump per step + same-process PNG window captures inspected.

### Headline: the tabbed GIT panel is NOT scriptable — most of the catalog is unreachable here

The single most important reality for this group, established by direct probing
of the live bundle:

1. **No `git-*` script verb exists.** The entire `ScriptVerbDispatch` vocabulary
   has exactly ONE git entry point: `file-history <path>`. The STATUS/LOG/STASH/
   TREES/REMOTES/REVIEW tab strip, the Refresh button / `⌥⌘R`, stash Apply/Pop/
   Drop, the header repo picker, worktree/remote row clicks, the commit→diff
   tab — every interactive panel control is a **live mouse/key gesture with no
   verb**, so the scripted T4 harness cannot select a tab, refresh, or click a
   row.
2. **SwiftUI a11y ids do NOT reach the NSView dump** (re-confirmed: ZERO
   `mdv.gitPanel` / `mdv.gitpanel.tab.*` / `mdv.gitpanel.repoPicker` /
   `mdv.rail.left.git` ids in `contentView` OR `recursiveDescription`). The tab
   strip, count badges, status/log/stash/trees/remotes rows render as generic
   `DocumentView` / `NSTextFieldSimpleLabel` hosts whose TEXT the dump never
   captures.
3. **`ScriptVerb.modelStateDump` carries NO git-panel state** — no `repoRoot`,
   `selectedTab`, branch, ahead/behind, per-tab counts, refresh timestamps. The
   only git-adjacent observable is the `hostedView` tab `file-history` spawns.

Consequence: **GP-01..GP-08 and GP-11 are NOT automatable from a `--script`
run** and are logged below as manual/VM-lane gaps. The genuinely-drivable
surface is **File History (GP-09 / GP-10)** via the `file-history` verb plus the
`openFileHistory` repo-membership gate — that is what the 5 passing scenarios
exercise.

### GP-09 — File History: hosted-view tab, master-detail mount — PASS

**PASS.** `file-history <repo>/hist.md` (a file with 3 commits) opens the in-app
FileHistoryView as a **second, selected tab**: dump shows
`currentStateKind=hostedView`, `windowTitle="History: hist.md"`, `tabCount=2`,
`selectedTabIndex=1` (the source file stays open in tab 1). The realized tree
mounts the master-detail layout — an `NSSplitView` (the HSplitView, 790×637, not
zero-sized) + a `SwiftUIOutlineListView` / `ListCoreScrollView` (the commit
List) — and a populated-list variant realizes `ListTableRowView` /
`CellHostingView` commit rows. Same-process PNG confirms the split pane mounts
(file size grows 165 KB → 195 KB the moment history opens). Off-main `git log`
shell-out + view hosting + `DocumentState.hostedView` routing all work over a
real process boundary.

*Not reachable here (logged gaps):* commit-row TEXT (short SHA · date · author ·
subject — SwiftUI labels, not in dump); single-commit segmented control
(This commit / vs Working Tree); Cmd-click two-commit range diff + Clear;
`Loading history…` / `Loading diff…` transient placeholders. All are live-click
/ SwiftUI-text surfaces with no verb and no model projection → manual/VM lane.

### GP-10 — File History gating on repo-membership — PASS (with a gate-layer nuance)

**PASS (outside-repo no-op).** `file-history <file-outside-any-repo>` is a clean
no-op: tab count stays 1, state stays `loaded` (NOT `hostedView`), the original
markdown stays focused. The `openFileHistory` `discoverRoot != nil` guard
correctly rejects a file with no enclosing git root.

**PASS (untracked-in-repo opens an empty history) — with an observation.** For an
UNTRACKED-but-inside-a-repo file (`untracked.txt`), `file-history` does **NOT**
no-op — it opens a hosted history tab (`currentStateKind=hostedView`,
`windowTitle="History: untracked.txt"`, NSSplitView mounted) showing the
graceful "No history for this file." empty state. This is NOT a bug, but it is a
**gate-layer discrepancy vs the doc-comment**: `openFileHistory`'s own guard is
`discoverRoot && rel && !rel.isEmpty` — it does NOT check `isTracked`. The
`isTracked` gate (`canShowFileHistory`) lives ONLY at the menu-item-enable layer
(GP-10 step 3: the menu item is greyed for untracked files). The script verb
bypasses the menu, so it reaches the more-permissive `openFileHistory`. The
catalog's GP-10 expectation (menu disabled for untracked) is consistent; the
nuance is that the underlying API is looser than its "No-op when the file isn't
tracked" comment claims. Logged as F-GIT-2 (low severity — graceful empty
state, menu-gated correctly in live UI). The menu enable/disable validation
itself (`validateMenuItem`) is not script-drivable → manual/VM gap.

### GP-01 / GP-11 — GIT accordion section mount — PROBE FINDING (F-GIT-1)

The catalog (GP-01 step 1) expects the GIT accordion section to appear once the
focused root resolves to a repo. **In every scripted/occluded probe the section
did NOT mount** — reproduced across 4 independent runs with varying triggers
(set-root only; set-root + open a 2nd file inside the repo; set-root +
`sidebar-select-next`) and settle times (1 s up to 2.5 s + 3 s + 1.5 s). In all
of them the sidebar is firmly rooted at `gitrepo/`, two tabs are open inside the
repo, and the **FILES tree is fully git-aware** (green repo-folder icon + a `?`
untracked badge on `new.txt` — proving `TrackedReposChannel` is populated). Yet
between the SEARCH and PROBLEMS accordion sections there is **no GIT section at
all**, and the left-rail git glyph is not in a filled/active state.
`recursiveDescription` carries zero git-section / tab-label text.

Root-cause hypothesis (best guess, unverified): `GitPanelSection` self-gates on
`panel.repoRoot != nil`, set by `syncRepo()` → `panel.followFocus(model.repoFocus.focusedRoot, …)`.
`RepoFocusTracker.updateFocusedRoot()` sets `focusedRoot` only AFTER
`handoffMirror()` ticks the channel version, inside the SAME async `recompute()`
Task — so when the section's `.onChange(of: trackedRepos.version)` fires it can
read a still-nil `focusedRoot`, and there is no later version tick to re-trigger
`syncRepo`. A republish-ordering window the scripted path does not survive.

**Severity caveat:** I could NOT confirm whether this reproduces in a normal
foreground GUI session — it may be specific to the occluded `MDV_BACKGROUND`
launch, and the panel content is un-observable via automation regardless. The
suite logs this as a NON-FATAL observation (`[UAT git-panel F-GIT-1]` print, not
an `XCTFail`) so the run stays green while the finding is captured for triage.
Worth a manual/VM confirmation: open a file inside a git repo and check whether
the GIT accordion appears in the sidebar.

### GP-02..GP-08 — Status / Diff / Log / Stash / Trees / Remotes / Refresh — NOT AUTOMATABLE (gaps)

None of these are reachable from a `--script` run (no tab-selection verb, no
refresh verb, no row-click verb, no model projection of panel state, no
dump-visible a11y ids/row text). Enumerated as manual/VM-lane gaps:

- **GP-02 Status:** STAGED/UNSTAGED/UNTRACKED grouping, status-letter badge
  color (A/D/M/U), row→open-file, Show Diff → hashed `.diff` cache tab → Diff
  view mode, the structured DiffView hunk/line render, untracked/binary/deleted/
  rename edge cases, >64 KB-status no-deadlock.
- **GP-03 Log:** GitGraphColumn lanes, HEAD/branch/tag chips, relative-time
  buckets, lazy `+200` pagination, 5000 hard cap, graph-too-wide flat-list
  fallback, commit→`git show` diff tab, detached-HEAD/empty-repo states.
- **GP-04 Stash:** Apply/Pop/Show/Drop chips, Drop destructive-confirm alert,
  Show→`.diff` tab, count-badge re-read, conflict-on-apply. (The deliberate
  write-exception path — un-runnable without live clicks.)
- **GP-05 Trees:** worktree rows, CURRENT/LOCKED/PRUNABLE chips, click-to-
  navigate, prunable inert, path `~`-shortening.
- **GP-06 Remotes:** name/URL/last-fetch rows, git@/ssh://→https:// translation
  + `.git` strip + web-open, file:// silent no-op, REMOTES `r`-chord-vs-`⌥⌘R`
  collision caveat.
- **GP-07 Multi-repo:** header repo picker (>1 repo), `pickRepoRoot` pin,
  `followFocus` focus-tracking, pin release on focus-move, cache isolation.
  (Doubly blocked: also depends on the GIT section mounting — see F-GIT-1.)
- **GP-08 Refresh:** on-focus / 60 s timer / `⌥⌘R` refresh, equality-guarded
  no-op republish, refresh-cancellation, stale-tab auto-refresh, `stop()` on
  panel hide.

### Findings summary (group 6/12)

| ID | Title | Kind | Severity | Evidence |
|----|-------|------|----------|----------|
| F-GIT-1 | GIT accordion section never mounts in the scripted/occluded run despite the sidebar being rooted INSIDE a tracked, git-aware repo with open tabs (FILES tree shows the repo icon + `?` badge, but no GIT section between SEARCH and PROBLEMS) | bug / discrepancy | S2 | 4 probe PNGs (e.g. `/tmp/gitpanel-probe.xarjhZ/art_select/mdv-step-06.png`); `recursiveDescription` has 0 git-section lines; `GitPanelSection.swift:32` `repoRoot != nil` gate ← `RepoFocusTracker.recompute()` sets `focusedRoot` AFTER `handoffMirror()`'s version tick (ordering race) |
| F-GIT-2 | `openFileHistory` opens a hosted (empty) history view for an UNTRACKED in-repo file — the `isTracked` gate is menu-only (`canShowFileHistory`), so the doc-comment "No-op when the file isn't tracked" overstates the API's own guard | inconsistency | S4 | `mdv-step` dump: `file-history untracked.txt` → `state=hostedView title="History: untracked.txt"`; `DocumentModel.swift:1183` `openFileHistory` guard lacks an `isTracked` check |

### Suite location & re-run

- `Tests/ViewerUITests/uat/GitPanelUATTests.swift` — durable T4 companion to
  `docs/uat/smokes/git-panel.md`. 5 scenarios:
  `test_GP_09_fileHistoryOpensHostedMasterDetail`,
  `test_GP_09_fileHistoryWithMultipleCommits`,
  `test_GP_10_fileHistoryGate_outsideRepoNoOp`,
  `test_GP_10_untrackedInRepoOpensEmptyHistory`,
  `test_GP_01_gitSectionMountWhenRootedInRepo` (the F-GIT-1 observation probe).
  All 5 PASS.
- Re-run: `env -u MDV_HEADLESS_GATE swift test --filter
  'ViewerUITests.GitPanelUATTests'`. Self-skips on the headless gate
  (`MDV_HEADLESS_GATE=1`) and when `dist/TextView.app` isn't built.
- **Manual/VM lane required** for the bulk of the catalog: the tabbed panel
  (GP-01..08, GP-11) needs real clicks against the visible section and should be
  run on the VM smoke (`bash scripts/vm-smoke.sh`) or by hand per
  `MANUAL_TESTING.md`. Confirm F-GIT-1 there first (does the GIT section even
  appear in a foreground session?).

---

## Group 7/12 — sessions (tabs-within-tabs / nested workspaces)

Suite: `Tests/ViewerUITests/uat/SessionsUATTests.swift` (T4
`MultiScenarioTestCase`). Drives the assembled `dist/TextView.app` via the
`--script` session verbs (`session-open-folder`, `session-open-new`,
`session-activate`, `session-next/prev`, `session-close-active`,
`session-rename`) and asserts on the `model.sessions` / `activeSessionID`
projection plus `sidebar.rootURL` / `tabCount`. 7 scenarios, **all PASS**.

Re-run: `env -u MDV_HEADLESS_GATE swift test --filter
'ViewerUITests.SessionsUATTests'`. Self-skips on the headless gate
(`MDV_HEADLESS_GATE=1`) and when `dist/TextView.app` isn't built.

### THE headline finding (F-SESS-1): the per-session FAÇADE is un-observable from a scripted run

The session **value layer** is fully observable and CORRECT. The session
**mount/façade layer** is NOT — and this dominates the group, gating most of
the catalog.

**Root cause (verified):** the Phase-1 façade swap (tab reset + `hydrate` +
sidebar re-root + watcher pause/resume on every session change) rides on
`SessionsCoordinator`'s `lifecycle` bridge, which is wired EXCLUSIVELY inside
`SessionsAppCoordinator.bootstrap()` (`main.swift:215-217`). `bootstrap()` is
gated behind `MDV_SKIP_WORKSPACE_RESTORE != "1"`. The test harness
(`AppLauncher.runScript`) ALWAYS sets `MDV_SKIP_WORKSPACE_RESTORE=1` to start
each scenario clean. Net: in EVERY scripted run `lifecycle == nil`, so
`openFolder` / `activate`'s `lifecycle?.mount(snap)` is a no-op. The session
list + active pointer update correctly (pure value-layer), but the shared
`DocumentModel` never re-hydrates — **tabs don't swap, the sidebar never
re-roots, nothing pauses.** Proven 3× across independent probes
(`tmp.vamDu56VjI`, `tmp.EcJDsiBlBy`): after `session-open-folder projB`,
`tabCount` stays at projA's count with projA's tab still selected, and after
`session-activate 1` (back to projA) the tab list is unchanged (`b1.json` still
selected). `sidebar.rootURL` stays pinned at the argv file's parent (the temp
scratch dir) the whole run, never moving to projA/projB.

`test_SESS01_tabAndSidebar_doNotSwitch_probe` PINS this current behaviour so a
future change that DOES wire the bridge under the clean-room flag trips the
probe and prompts promoting the gated smokes to hard asserts.

**Consequence — un-automatable here, deferred to the VM/foreground lane:**
- **SESS-01 steps 5-6** (tab restore + sidebar re-root on switch) — the
  headline regression guard for "my tabs disappeared on switch" (#184). Only
  the pill-creation + dedup + resolved-root half is asserted.
- **SESS-05** (per-session split / expansion / include-hidden reset + restore).
- **SESS-06** (GLOBAL-vs-per-session zoom/wrap across a switch).
- **SESS-08** (inactive-session watcher pause / active auto-reload).
- **SESS-09** (per-session shoulder-rail panel layout).
- **ALL relaunch-restore halves** (SESS-03 step 4, SESS-07 entirely, SESS-10
  crash-recovery): the harness exits the app at end-of-script AND launches with
  the clean-room flag, so a second-launch restore can't be observed; the
  `SessionStore` directory is hardcoded to `~/Library/Application Support/...`
  with no env override, so it can't be redirected to a clean scratch store
  either. These need a foreground VM session WITHOUT the skip flag (or a new
  test hook that wires the lifecycle bridge + redirects the store dir under the
  clean-room flag).

### What WAS asserted (value-layer — all green)

| Smoke | Coverage | Result |
|-------|----------|--------|
| SESS-01 | Two `session-open-folder` → two pills in creation order, folder-leaf displayName, RESOLVED (`/private`-collapsed, symlink-followed) `sidebarRootPath`, 2nd active | PASS |
| SESS-01 var | Re-open same path = reveal (no dup); symlink twin collapses (resolved-path dedup); `session-open-new` (forceNew) creates a 2nd pill over the SAME realpath | PASS |
| SESS-04 | LRU close: open A,B,C → activate B,C,A → close A re-activates **projC** (MRU), NOT projB (adjacent); close C → projB; close B → empty strip + `activeID` cleared | PASS |
| SESS-11 | `session-next`/`prev` cycle in list order and WRAP at the ends; `session-activate N` 1-based | PASS |
| SESS-03 | `session-rename` commits trimmed name; whitespace-only rename rejected (no clobber); no-op rename = equality-guarded no-op | PASS |
| SESS-12 | Strip scales 0 → 1 → 2 with opens; clean-room launch → empty strip + no active session | PASS |

### Findings summary (group 7/12)

| ID | Title | Kind | Severity | Evidence |
|----|-------|------|----------|----------|
| F-SESS-1 | Per-session façade (tab swap, sidebar re-root, watcher pause) never runs in a scripted run: the lifecycle bridge is wired only in `bootstrap()`, which `MDV_SKIP_WORKSPACE_RESTORE=1` (always set by the harness) skips → `lifecycle == nil` → `openFolder`/`activate`'s `lifecycle?.mount` is a no-op. Session LIST + activeID still update; the shared model does not re-hydrate. | quality / observability-gap | S3 | 3 probes: after `session-open-folder projB`, `tabCount`/selected tab stay projA's; after `session-activate 1`, tabs unchanged (`b1.json` still selected); `sidebar.rootURL` pinned at argv parent all run. `main.swift:215` gates `bootstrap()` (the only `setLifecycle` caller) behind the flag. Pinned by `test_SESS01_tabAndSidebar_doNotSwitch_probe`. |
| F-SESS-2 | `session-open-folder`/`session-open-new` on a TCC-protected root (`~/Documents`, `~/Desktop`, `~/Downloads`) is NOT refused — it creates AND PERSISTS the session. `sessions.md` (lines 56-59, 494) states the coordinator "deliberately refuses to re-root or persist" such roots; the only `isUnderTCCProtectedRoot` guard is in `bootstrap()`'s `initialRoot` seeding (`SessionsAppCoordinator.swift:141`), NOT in either coordinator's `openFolder`. | discrepancy / bug | S2 | Probe: `session-open-folder ~/Documents` created a 3rd session and wrote it to the real `Sessions/index.json` with `rootPath: /Users/me/Documents`. Neither `SessionsCoordinator.openFolder` nor `SessionsAppCoordinator.openFolder` calls `isUnderTCCProtectedRoot`. |
| F-SESS-3 | T4 session smokes pollute the user's REAL `~/Library/Application Support/MarkdownViewer/Sessions/` store: `openFolder`→`persist()` enqueues real index + per-session writes even under `MDV_SKIP_WORKSPACE_RESTORE=1` (the skip flag only suppresses RESTORE, not PERSIST). The store dir is hardcoded with no env override, so each scripted-session run appends scratch (`/var/folders/.../SessionsUAT-*`) pills that survive in `index.json`; prior UAT groups left similar `SidebarBookmarksUAT-*` / `/tmp/*` entries. A real relaunch (no skip flag) would show these as stale pills (gracefully skipped if the tmp dir is gone, but cluttering). | quality | S4 | `index.json` after the suite run lists 2 `SessionsUAT-*` tmp-rooted pills; pre-existing entries from groups 1/2 (`SidebarBookmarksUAT-*`, `/tmp/sfb-probe`, `/tmp/uat_sfb_probe`). |

### Notes on severity calls

- **F-SESS-1 is S3 (not a product bug):** the LIVE app (foreground, restore
  enabled) DOES run the façade swap — this is purely a harness blind spot. But
  it is the dominant finding because it makes ~half the catalog
  (SESS-01 core / 05 / 06 / 08 / 09 / 07 / 10) un-gateable from the merge/CI
  lane; those regressions can only be caught on the VM/foreground lane. Worth a
  test hook (env to wire the bridge + redirect the store under the clean-room
  flag) so the highest-value session guards become CI-observable.
- **F-SESS-2 is the only candidate genuine product defect** found: a TCC-root
  session is created and persisted where the documented contract says it must
  be refused. Impact: an "Open in New Session" on `~/Documents` yields a
  session that can't actually read the folder (sandbox/TCC) yet persists and
  re-appears on every relaunch — and silently re-roots at `$HOME` on restore
  via `mountSession`'s empty-root fallback only if the path is later emptied,
  not blocked up front. Recommend adding the `isUnderTCCProtectedRoot` guard to
  `SessionsCoordinator.openFolder` (return early / no-op) to match the doc.

### Manual / VM lane required

- **SESS-01 (tab restore on switch), SESS-05, SESS-06, SESS-08, SESS-09** — run
  in a FOREGROUND VM session (no `MDV_SKIP_WORKSPACE_RESTORE`) so the lifecycle
  bridge is live; assert on the visible pill strip + tab strip + sidebar via the
  `mdv.sessionTab.*` a11y ids (which DON'T appear in the occluded dump — same
  a11y-id-non-propagation finding as groups 1/2/5/6).
- **SESS-07, SESS-10 (relaunch / crash restore)** — two-launch flows; need the
  VM smoke (`bash scripts/vm-smoke.sh`) with restore enabled and a redirectable
  store, plus a `kill -9` between launches for SESS-10.
- **SESS-02 (`+` → GoTo prompt)** — the `+` button arms `requestNewSessionViaGoTo`
  / `firstPaintGoToToken`; there is no script verb for the `+` itself (only
  `show-goto` / `goto-commit-new-session`), and `mdv.goto.*` panel state isn't in
  the dump. Drive via real clicks on the VM.


---

## Group 8/12 — lsp (hover / go-to-def / outline / refs / diagnostics)

- **Executor suite:** `Tests/ViewerUITests/uat/LSPUATTests.swift` (T4 `MultiScenarioTestCase`)
- **Run cmd:** `env -u MDV_HEADLESS_GATE swift test --filter 'ViewerUITests.LSPUATTests'`
- **Result:** 4 tests, 0 failures, 0 unexpected (13.8s). All structural / no-crash
  / language-gating assertions PASS.
- **Server matrix on this host:** `typescript-language-server` / `pyright`
  **ABSENT**; only `sourcekit-lsp` is PATH-discoverable (`xcrun -f sourcekit-lsp`
  → `/Applications/Xcode.app/.../sourcekit-lsp`). So all fixtures are **Swift
  under a `Package.swift` root**, not the catalog's default TS.
- **Evidence:**
  `docs/uat/evidence/LSP-01_swift-source-open.{json,png}` — a `.swift` file open
  under a SwiftPM root with the sidebar rooted there.

### Headline: this is the LEAST script-automatable group in the catalog

Three independent walls, all confirmed against the live bundle (and the catalog
itself states the first: *"there is no LSP script verb"*):

1. **No LSP script verbs.** `ScriptVerbDispatch` has ZERO entries for hover /
   go-to-def / find-refs / outline-jump / problems-filter / diagnostics-window.
   Every primary LSP gesture is a live pointer/keyboard interaction (300 ms
   cursor-dwell hover, right-click "Go to Definition" / LSP nav submenu,
   Cmd-click, Outline row tap, References / Workspace-Symbols panel, Problems
   severity menu) with no verb. The scripted harness cannot fire any of them.
2. **`ScriptVerb.modelStateDump` carries NO LSP state.** No outline symbols, no
   problems/diagnostics rows, no references/nav rows, no per-server
   live/dead/crash/Reqs accounting, no hover payload. `lspPool` /
   `lspDiagnostics` / `lspNavigation` / `LSPOutlineModel` are entirely off the
   dump projection. The only LSP-adjacent scalar is `currentURL`.
3. **The realized tree can't distinguish LSP sidebar sections.** The
   a11y-id-non-propagation finding (groups 1/2/5/6) re-confirmed — zero `mdv.*`
   (`mdv.lspOutline`, `mdv.problems`, `mdv.lspNav`) in `contentView` OR
   `recursiveDescription`. Worse: the accordion sections render as **generic
   `HostingScrollView` hosts whose SwiftUI label text never appears** in the
   dump ("Outline", "PROBLEMS", "REFERENCES", "Loading symbols…", "No language
   server for this file." — all absent from `recursiveDescription`, alongside
   "Bookmarks"/"Search"/"FILES"/"Git"). The dump cannot tell WHICH accordion
   sections are mounted.

The one LSP signal that escapes the dump is the **`sourcekit-lsp` child process**
itself (`pgrep -x sourcekit-lsp`), which the suite uses as a backend-liveness +
gating side-channel.

### What the suite genuinely verifies (the observable floor — all PASS)

| Check | Mechanism | Verdict |
|---|---|---|
| `.swift` open under SwiftPM root never `.error`/stuck-`.loading` (LSP engaging must not break load) | `model.currentStateKind` across all steps | PASS |
| Source pane renders for `.swift` (non-hex NSTextView, contrasting glyphs, no WKWebView leak) | view-CLASS + `nsTextView` glyph/contrast | PASS |
| **Backend language-gating**: a markdown-only session spawns **zero** `sourcekit-lsp` | `pgrep -x` after run == 0 | PASS |
| CM6 editor parity host mounts for `.swift` (`editor-set-mode editor` → non-zero WKWebView, no hex/source leak) | view-CLASS + `wkWebView`/`zeroSize` | PASS |
| Multi-byte / non-ASCII source (`café` after an emoji comment) loads cleanly, not truncated at the surrogate boundary | `maxTextViewGlyphs > 80` + `.loaded` | PASS |

### Per-smoke verdicts

**LSP-01 — first-touch TS file (cold-start drives Outline + hover + Problems) — PARTIAL (floor PASS; panel population MANUAL/VM)**
`test_LSP_01_swiftOpenUnderRoot_noCrash_sourceRenders`. Substituted Swift for TS
(TS server absent). The no-crash + source-render floor PASSES. The catalog's
core claims — Outline populates with symbols + count chip, hover popover, the
deliberate type error appears in Problems with a red count pill, the Diagnostics
window shows a live TS server with Reqs≥1 — are **NOT script-reachable** (no verb,
no dump signal). See F-LSP-1 + the screenshot finding (S2-LSP-A) below.

**LSP-02 — navigate by symbol (Cmd-click / right-click submenu / Outline jump) — MANUAL/VM (editor-parity host PASS)**
`test_LSP_02_editorParitySurfaceMounts`. The CM6 editor WKWebView (the host the
editor-mode hover + "Go to Definition" bridge `DocumentModel.respondToEditorHover`
/ `respondToEditorCmdClick` attaches to) mounts non-zero for `.swift` — PASS.
The actual Cmd-click / right-click LSP submenu / Outline-row jump / multi-result
first-pick are live gestures: MANUAL/VM (F-LSP-2).

**LSP-03 — workspace symbols + Problems severity filter + cross-file diag nav — MANUAL/VM**
No part is script-reachable: `mdv.lspNav.modePicker` / `symbolField`, the Problems
`All/Errors/Warnings` filter + red/orange count pills, in-flight query
cancellation, and click-to-jump all need the visible panel + live clicks, none of
which the dump or verbs expose. Fully deferred (F-LSP-2).

**LSP-04 — resilience: crash/restart, position-encoding, language-gating,
diagnostics-window honesty — PARTIAL (gating + multibyte-load PASS; rest MANUAL/VM)**
`test_LSP_04_markdownDoesNotEngageServer` + `test_LSP_04_multiByteSourceLoadsCleanly`.
- Backend language-gating (step 5): a `.md`-only session leaves **zero**
  `sourcekit-lsp` children — PASS (hard assertion when sourcekit present).
- Multi-byte source LOADS cleanly (no truncation) — PASS. But the actual
  position-encoding *correctness* (hover/Cmd-click landing on the right COLUMN
  past the multi-byte chars) is a live gesture — MANUAL/VM.
- Crash/restart accounting + the Diagnostics window's live/dead/Crashes table,
  the `lsp.json` override no-op, `publishDiagnostics`-dropped — MANUAL/VM
  (F-LSP-2), except `publishDiagnostics`-dropped which the screenshot
  *corroborated* (S2-LSP-A).

### Findings beyond the assertions

**F-LSP-1 (S3) — `sourcekit-lsp` spawn is NON-DETERMINISTIC in the occluded/scripted run.**
Host probing (identical 3× root-then-open-`.swift` runs): the server child spawned
in **1 of 3** runs (poll for `pgrep -x sourcekit-lsp` over ~8 s). The spawn is
driven by `LSPOutlineWrapper.refresh()` (`.onAppear` / `.onChange(of: currentURL)`
→ `LSPOutlineModel.setFile` → `LSPPool.documentSymbol`), which only fires once the
lower accordion sections are realized — and the occluded window does not reliably
realize them. Same republish-ordering class as the git group's F-GIT-1. Not
hard-failed (it's a known scripted-path limitation + the spawn is a side effect,
not the contract); logged for the VM/foreground lane where it should be
deterministic.

**S2-LSP-A (S2) — Problems shows "No problems detected." despite a live server + a deliberate type error.**
The evidence screenshot (`LSP-01_swift-source-open.png`, captured on the run where
`sourcekit-lsp` DID engage) shows the sidebar **PROBLEMS** section reading
**"No problems detected."** while the open `main.swift` contains
`let badType: Int = "not an int"` — an unmistakable Swift type error. This visibly
corroborates the catalog's documented trap: *"`publishDiagnostics` inbound
notifications are dropped (diagnostics flow via the CM6 editor push path / pull,
not server-pushed)."* In Source view there is no CM6 push path, so the type error
never reaches the Problems panel. This is **expected-current-behavior per the
catalog**, but it is a genuine UX gap a user would read as a bug: a syntactically-
broken Swift file shows a green "No problems detected." A user in Source view gets
no diagnostics at all. Worth a backlog note: either wire the inbound
`publishDiagnostics` handler, or pull diagnostics on Source open the way the
Outline path already pulls `documentSymbol`.

**S3-LSP-B (S3) — OUTLINE / REFERENCES sections did not appear in the sidebar for a live `.swift` file.**
Same screenshot: with `main.swift` open under a SwiftPM root and the sidebar
rooted there, only the (collapsed) bookmarks-area, **SEARCH**, and **PROBLEMS**
sections are visible — **OUTLINE is absent**, REFERENCES is absent. Per
`SidebarDataPresence` (`Sources/ViewerCore/SidebarDataPresence.swift:57-59`),
`.lspOutline` is present when `hasRoot && hasLSPLanguage` (both true here) and
`.lspNavigation` whenever `hasRoot` (true) — so by the presence heuristic all
three SHOULD show. Their absence in the occluded/scripted run is the realized-tree
side of F-LSP-1 (the section's `isSupported`/refresh gate races the accordion
realization). Needs the foreground VM to confirm whether it reproduces in a real
GUI session; if it does, it's a real bug (Outline silently missing for a supported
language). Logged for the VM lane.

**Note (not a bug) — no LSP affordance in the ModeBar.** The ModeBar offers
`Source / Editor / HEX` for `.swift`; there is no LSP toggle there (correct — LSP
surfaces live in the sidebar accordion + context menus, not the mode bar).

### Manual / VM lane required (F-LSP-2)

Everything needing a visible LSP panel or a live gesture — run in a FOREGROUND VM
session (`bash scripts/vm-smoke.sh`, restore enabled) with `typescript-language-server`
+ `pyright` installed so the catalog's TS/Python fixtures work, and assert on the
visible sidebar accordion + popovers + the Diagnostics tool window via real clicks:

- **Outline population + count chip + click-to-jump** (LSP-01 step 3, LSP-02 step 1).
- **Hover popover** geometry (≤380 pt wide, 60–360 pt tall, markdown body) +
  CM6 editor hover tooltip + the 2 s safety timeout / no-popover-storm (LSP-01
  step 4, LSP-02 editor parity, LSP-04 hover safety).
- **Cmd-click + right-click LSP submenu** (Definition / Declaration / Type Def /
  Implementation / Find References), multi-result silent first-pick, definition-
  returns-nothing silent no-op (LSP-02 steps 2-6 + edges).
- **References / Workspace-Symbols panel** — `mdv.lspNav` rows, mode picker
  (References disabled / Symbols selectable), `symbolField` query + newest-wins
  cancellation + no-match empty state (LSP-02 step 5, LSP-03 steps 1-4).
- **Problems panel** rows + severity filter (All/Errors/Warnings) + red/orange
  count pills + filtered-empty vs truly-empty messages + cross-file 1-based
  click-jump (LSP-03 steps 5-7 + edges) — AND verify S2-LSP-A (whether Source-view
  diagnostics ever surface).
- **LSP Diagnostics tool window** — Settings → Language servers → Open Diagnostics…;
  live/dead/Crashes/Reqs/Last-ms table, the 2 s poll, crash→restart accounting
  (kill the server, watch Crashes increment), two-roots/two-languages rows
  (LSP-01 step 6, LSP-04 steps 1-4 + repeated-crash + position-clamp edges).
- **Position-encoding column correctness** — hover/Cmd-click landing on the right
  column past multi-byte chars (LSP-04 step 2; the load-cleanly half is automated).
- **`lsp.json` override** parse + the known init-options-not-forwarded gap
  (LSP-04 edge).
- **F-LSP-1 / S3-LSP-B** — confirm in a foreground session that the server spawns
  deterministically on `.swift` open and that OUTLINE/REFERENCES sections appear.

---

# Group 9/12 — plugins-and-mcp-automation

**Executor:** T4 live-app suite, occluded `MDV_BACKGROUND` runs against the
assembled `dist/TextView.app` (built 2026-06-03). Durable companion authored at
`Tests/ViewerUITests/uat/PluginsAndMcpAutomationUATTests.swift` (9 tests, all
GREEN). Run with `env -u MDV_HEADLESS_GATE swift test --filter
'ViewerUITests.PluginsAndMcpAutomationUATTests'`. Three driving seams, all the
REAL bundle: (1) the `--mcp-stdio` JSON-RPC server over a Content-Length framed
pipe; (2) the `--script` verb dispatcher + per-step `DiagnosticDump`; (3) the
bundle's own `PluginSubprocessHost` (public ViewerCore API) against real fixture
executables. State hygiene: the bookmark smoke backs up + restores the user's
real `bookmarks.json`; the plugin smoke uses a throwaway tmp audit log + tmp
plugin folder (the user's real `Plugins/`, `grants.json`, `plugins.log` are
never touched).

## Findings summary

| ID | Sev | Kind | One-liner |
| --- | --- | --- | --- |
| F-PMA-EXIT | S2 | bug | `--mcp-stdio` process never exits on stdin EOF / `shutdown` / oversize-frame close — orphaned process; stderr logs a misleading `server exiting`. |
| F-PMA-OBS6 | S3 | bug | Missing/typo'd plugin `bin` writes the user's **absolute** plugin path into the 0o600 audit log `error` field — violates the documented OBS-6 "no absolute filesystem path in the log". |
| F-PMA-XSEARCH | S4 | discrepancy | Catalog says `set-cross-query` "(implies show+run)"; the verb only runs the search and never sets `isCrossSearchPresented`, so a script omitting `show-cross-search` searches invisibly. |

---

## SMOKE-PMA-01 — MCP handshake + drive a real document end-to-end — **PASS** (1 finding)

`test_PMA01_mcpHandshakeAndDriveDocument` + `test_PMA01var_eofBeforeHeaderExitsClean`.
Spawned `…/MacOS/MarkdownViewer --mcp-stdio` and drove the full lifecycle:

- **Ready banner / silent stdout** — stderr emits `mcp: server ready on stdio`;
  stdout stays byte-silent until the first framed response. No Dock tile (policy
  `.prohibited`).
- **initialize** — `result.protocolVersion == "2024-11-05"`, `serverInfo ==
  {name:"TextView", version:"1.0.0"}`, `capabilities.tools.listChanged == false`.
  Response CRLF-framed.
- **initialized notification** — dropped (no response); server stays alive
  (verified via a follow-up `ping`).
- **tools/list** — exactly **10** tools in the documented order
  (`open_path, select_tab, set_view_mode, find, goto_line, visible_text,
  current_state, toggle_bookmark, list_bookmarks, snapshot_window`); each has
  name + description + inputSchema.
- **open_path → set_view_mode source → find NEEDLE_TOKEN → goto_line 12 →
  visible_text → current_state** — all `isError:false`; `open_path` returns a
  uuid `tabId`; `find` returns `total ≥ 3, truncated:false` with the line-12 hit
  present and every match carrying `line/column/location/length`; `visible_text`
  contains `NEEDLE_TOKEN` with `totalBytes == text.utf8.count`; `current_state`
  reports the fixture tab in `source` mode.
- **Edge states** — `set_view_mode editor` on a text file succeeds;
  `{mode:"banana"}` → `isError:true`; degenerate `find {query:".", regex:true}`
  caps at exactly 1000 matches with `truncated:true`. `shutdown` → `result:null`.

**F-PMA-EXIT (S2, bug).** *Expected:* per catalog step 11, after `shutdown` +
stdin close (and per the PMA-01 EOF variation, on an immediate stdin close) "the
process exits cleanly". *Actual:* the read loop returns and stderr logs
`mcp: stdin EOF; server exiting`, but **the process keeps running indefinitely** —
`app.run()` (NSApplication) is never terminated, so the headless server has no
exit path. Verified directly: spawn → close stdin → still alive after 4 s with
stderr already showing `server exiting`. *Impact:* an agent that opens a session
per task leaks one `MarkdownViewer --mcp-stdio` process every disconnect; the
"server exiting" log line is actively misleading. Root cause: `main.swift`
`applicationDidFinishLaunching` calls `startMCPServer()` and returns, but nothing
wires the server's read-loop end (EOF / `stop()` / framing-error close) to
`NSApp.terminate(_:)` / `exit()`. *Repro:* `MarkdownViewer --mcp-stdio`, close
stdin, observe the process lingers. *Fix sketch:* on `runLoop()` return (and in
`stop()`), hop to the main actor and `NSApp.terminate(nil)` (or `exit(0)`).

---

## SMOKE-PMA-02 — MCP path containment, error taxonomy, malformed framing — **PASS** (orphan-exit finding recurs)

`test_PMA02_containmentAndErrorTaxonomy`. Every guarded boundary held:

- **parseError −32700** (non-JSON body in a valid frame; `id:null`), **invalidRequest
  −32600** (`jsonrpc:"1.0"`, echoes id), **methodNotFound −32601** (names the
  method). Server stayed alive across all three.
- **open_path containment** — `/etc/hosts` → `isError:true` "outside … home";
  nonexistent path → `isError:true` "does not exist"; `~/` → allowed.
- **select_tab arg validation** — no args → `isError` "provide byIndex or byId";
  `byId:"not-a-uuid"` → `isError` "not a valid UUID"; `byIndex:999` →
  `{changed:false}` (no-op, **not** an error, exactly as documented).
- **goto_line 0** → `isError` "line must be >= 1".
- **Framing edges** — LF-only header block accepted (response still CRLF-framed);
  `Content-Length: 0` → empty body → parseError; **two frames in one write**
  both decode (the macOS-26 `Data` slice-offset regression guard holds);
  `Content-Length: 20000000` (> 16 MiB) → the framing loop logs an error and
  closes without allocating the buffer.
- **F-PMA-EXIT recurs** here on the oversize-frame path: after the framing loop
  closes, the process should exit but lingers (same NSApp-never-terminated root
  cause). Logged, not re-counted.

---

## SMOKE-PMA-03 — MCP bookmarks round-trip + window snapshot (headless) — **PASS**

`test_PMA03_bookmarksRoundTripAndHeadlessSnapshot`. Backed up + restored the
user's real `bookmarks.json`.

- file-level + line-5 `toggle_bookmark` → `{ok:true}`; `list_bookmarks` count
  goes B0 → B0+2; both shapes present (one no-`line`, one `line:5`); each entry
  carries `path/displayName/addedAt`.
- re-toggle file-level → idempotent off; count B0+1; the **line-5 bookmark
  survives** the file-level re-toggle.
- `snapshot_window` headless → `isError:true` "no window available" (documented
  headless failure mode, correct — **not** a bug).
- `toggle_bookmark {line:0}` → tool error.
- **Persistence across relaunch** — shut the server down, spawned a FRESH
  `--mcp-stdio` process, `list_bookmarks` again → the line-5 bookmark survives
  (read back from `bookmarks.json`). (F-PMA-EXIT meant the first server had to be
  force-terminated before relaunch to avoid two processes racing the store.)

---

## SMOKE-PMA-04 — `--script` verb dispatch drives the model headlessly — **PASS** (1 discrepancy)

`test_PMA04_scriptVerbDispatch` + `test_PMA04var_openMissingAppendsErrorTab` +
`test_PMA04var_editorSetTextSaveRoundTrip`. One long verb flow + 2 variations:

- `open a.md` → `currentURL` ends `a.md`, `tabCount==1`, `loaded`.
- `open-lazy b.txt` + `select-tab 2` → the lazy `.empty` tab **materializes** via
  `materializeIfNeeded` and SETTLES to `.loaded` (`tabCount==2`, `selIdx==1`).
  Observed progression (live dumps): `.empty` for ~1 dump (~300 ms), then
  `.loaded` and stable — i.e. **no** stuck-on-empty / "cannot be loaded" load-bug;
  the model-republish fix holds on the assembled bundle.
- `toggle-view` flips the mode; `zoom-in` ×2 pushes `zoom > 1.05` and
  `zoom-reset` returns it to `1.0`; `show-palette`/`show-goto` track the presented
  flags true→false; `sidebar-set-root` commits the folder root; `toggle-bookmark`
  flips `isCurrentTabBookmarked`. No step errored the document.
- **Variations:** `open` a MISSING file keeps existing tabs and appends an
  `.error` tab (never clears all tabs); the CM6 `editor-set-mode editor` +
  `editor-set-text` + `editor-save` round-trip reaches editor mode and **writes
  the edit to disk** (re-read confirmed the marker).

**F-PMA-XSEARCH (S4, discrepancy).** *Expected (catalog step 8):* `set-cross-query
NEEDLE` "(implies show+run)" → `isCrossSearchPresented == true`. *Actual:* the
verb does `model.crossSearchQuery = arg; model.runCrossSearch()` only
(`ScriptVerbDispatch.swift:116`); `DocumentModel.runCrossSearch`
(`DocumentModel.swift:959`) runs the grep but **never** sets
`isCrossSearchPresented`. A script that calls `set-cross-query` without a prior
`show-cross-search` searches with the panel closed (results land in the model but
the overlay isn't shown). The test was adjusted to `show-cross-search` first
(matching the working `SearchSurfacesUATTests` flow), then passes. *Impact:* doc
says one verb suffices; in practice two are needed. Either update the catalog or
have `set-cross-query` imply `showCrossSearch()`.

---

## SMOKE-PMA-06 — Tier B plugin failure taxonomy + subprocess sandbox containment — **PASS** (1 finding)

`test_PMA06_subprocessFailureTaxonomy`. Drove the bundle's own
`PluginSubprocessHost` (public ViewerCore API, headless-constructable) against
real fixture scripts with a throwaway temp audit log. Every documented outcome
reproduced:

- **timeout** (`sleep 30`, 1 s cap) → `.timedOut`; **stdout overflow** (> 1 MiB) →
  `.stdoutOverflow`; **non-zero exit 3** → `.nonZeroExit(3, …)` with a bounded
  stderr tail carrying `boom`; **invalid JSON** → `.decodeFailed` whose descriptor
  is byte-free (does **not** contain the offending `not json` bytes — OBS-6 on the
  in-memory result); **happy path** → `.ok` with the `Hello — from plugin` row.
- **Symlink escape (SEC-007)** — a symlink in the folder pointing at `/bin/echo`
  is refused with "bin escapes plugin folder after symlink resolution"; the target
  is never run.
- **Env scrub** — child's `env` dump contains **only** `HOME`; seeded
  `OPENAI_API_KEY` / `AWS_SECRET_ACCESS_KEY` / `PATH` / `USER` are all absent.
- **String-level rejects** — `bin` containing `..` rejected; a non-+x bin rejected
  "not executable"; the 30 s max-timeout constant holds and an over-max request is
  clamped (fast plugin still succeeds).
- **Audit log** — dir `0o700`, file `0o600`, one JSON object per line; the
  decode-failed line does **not** leak plugin bytes.

**F-PMA-OBS6 (S3, bug).** *Expected (catalog step 5 / OBS-6):* a spawn failure
records `bin_basename` and a stable errno-style descriptor with **no absolute
filesystem path in the log**. *Actual:* the **missing-bin preflight**
(`PluginSubprocessHost.swift:148`) builds
`.spawnFailed("bin not found: \(executable.path)")` — embedding the **absolute**
plugin path — which `writeAudit` (line 457) then writes verbatim into the 0o600
audit log's `error` field. The `process.run()`-failure branch (line 207)
correctly uses the byte-free `stableSpawnErrorDescriptor`, and the comment at
line 453-457 even *claims* `msg` is "already byte-free … stable descriptors built
in `call`" — but the missing-bin path predates that and isn't byte-free. So a
user with a typo'd / not-yet-built plugin `bin` leaks their absolute plugin path
into a log meant to be path-free. *Note:* the pre-existing unit test
`PluginSubprocessHostTests.test_spawnFailed_audit_records_bin_basename` only
checks `bin_basename`, so it passes while the `error` field leaks the path — this
gap is currently unguarded. *Fix sketch:* in the two preflight branches at
lines 148/153, replace `\(executable.path)` with the bin basename or a stable
descriptor (and add a regression assertion that no audit `error` contains an
absolute path).

---

## SMOKE-PMA-05 / SMOKE-PMA-07 — GUI-bound: grant prompt, Settings → Plugins, sidebar sections — **DEFERRED to VM/GUI lane** (headless half PASS)

`test_PMA05_07_bundleLaunchesCleanlyWithPluginsBootstrap` (PASS) confirms the
assembled bundle still launches and drives a document cleanly with
`PluginsBootstrap.loadAtLaunch` running — i.e. the plugins bootstrap does not
wedge the app at launch. The pixel/alert-level assertions in PMA-05 and PMA-07
genuinely need a foreground GUI session (the catalog itself flags these as the
VM/GUI lane) and are NOT host-reachable from `--script` / `--mcp-stdio`:

- **PMA-05** — the first-install grant `NSAlert` ("Install "Greeter" (v0.1.0)?"
  with capability bullets + source path), Cancel → `.denied`
  `loadedWithWarnings`, Settings → Plugins "User denied — click Revoke to
  re-prompt", Revoke → re-prompt on relaunch, Install → `.granted` + the
  `GREETINGS` Tier B section rendering `Hello — from plugin` + the `plugins.log`
  `result:"ok"` line, and the enable/disable-keeps-grant toggle. (The Tier B
  subprocess half — env scrub, the listRows envelope round-trip, the audit line —
  IS exercised headless in PMA-06; only the **alert + sidebar render** are
  deferred.)
- **PMA-07** — the bundled Row Counter (`com.markdownviewer.builtin.rowcounter`,
  `ROW COUNTS` / `number.square`, "N lines" detail, no grant prompt, BUNDLED pill,
  no toggle/Revoke), the `ROW COUNTS` rows tracking the open-file set, multi-plugin
  load isolation (`bad-manifest` / `bad-version` failing without poisoning a good
  sibling), the Settings → Plugins listing, and the "Show Log" gating. The
  plugin-load-isolation + manifest-parse + grant-store layers are constructable
  headless (`PluginRegistry` / `PluginGrantStore(url:)`) and could be driven
  in-process in a follow-up; the **SwiftUI sidebar accordion + Settings pane**
  rendering needs the VM.

**For the VM lane** (`bash scripts/vm-smoke.sh`, restore enabled): drop the
`tv-greeter` (Tier B) + `good`/`bad-manifest`/`bad-version` fixtures into a
clean-room `Plugins/`, launch foreground, and assert on the grant alert text +
the visible `GREETINGS` / `ROW COUNTS` sidebar rows + the Settings → Plugins list
(BUNDLED pill, toggles, Revoke, Show Log) via real clicks/screenshots.

---

# Group 10/12 — Previews (image / audio / video / pdf / sqlite / csv)

**Suite:** `Tests/ViewerUITests/uat/PreviewsUATTests.swift` (durable T4 companion).
**Run:** `env -u MDV_HEADLESS_GATE MDV_BACKGROUND=1 swift test --filter
'ViewerUITests.PreviewsUATTests'` against the installed `dist/TextView.app`.
**Result:** 9/9 tests PASS (PV-01..08 + 2 variations), 74.8 s.
Beyond the green assertions, dumps + window screenshots were inspected directly
(driven via `--script` with a persistent `MDV_ARTIFACT_DIR`) to catch visual /
UX issues a rigid assertion misses. Fixtures (PNG via CoreGraphics, WAV via
hand-built RIFF/PCM, MP4 via `AVAssetWriter`, PDF via PDFKit, SQLite header,
CSV/TSV) are generated in-Swift — no external tooling.

## PASS — routing matrix is rock-solid

The core regression sentinels for this area are all GREEN, verified at both the
model layer and the realized NSView tree:

- **PV-01 image** → `.preview` (NOT HEX); the realized tree mounts
  `ZoomableImageScrollView` + `CenteredImageView`. Open-As→HEX→auto round-trip
  returns to a clean preview with NO `Hex*` view stranded under the Preview
  picker (Bug-B + Bug-C sentinels green). Corrupt PNG does not crash / .error.
- **PV-02 audio + video** → `.preview`, both mount `AVPlayerView`. Audio's
  player carries an `_NSImageViewSimpleImageView` artwork placeholder (the
  generic audio-waveform glyph), video does not — expected AVKit behavior.
  Video Open-As→HEX→auto round-trip clean.
- **PV-03 pdf** → `.preview`, mounts `PDFView`; MetadataPanel shows Pages 3,
  Title, Author, Producer. HEX round-trip clean.
- **PV-04 sqlite** → `.preview(sqlite)` browser (`NSSplitView`), NOT HEX; the
  result pane shows the exact catalog hint "Click a table or write a SELECT,
  then ⌘↵ to run." Empty schema groups are hidden (header-only fixture → no
  table rows). `tiny.db` also routes `.preview` sub-ms (tiny-db→HEX regression
  guard green). `fake.db` (text masquerading as `.db`) does not hard-error.
- **PV-05 csv/tsv** → `.table` (full `Table | Source | Editor | HEX` picker),
  Table↔Source + Open-As→code→auto round-trips clean. Filter bar
  (`Filter rows…` / `All columns` scope / `Per-column` toggle / `30 rows`
  count) renders. Empty + ragged CSV open without crash/blank.
- **PV-06 matrix** (single launch, all types): image/audio/video/pdf/sqlite →
  Preview; csv → Table; `blob.bin` → HEX (state binary). All five preview
  categories are `.preview` state, none flipped to binary/HEX.
- **PV-07 hex fallback**: `data.bin`→HEX byte grid w/ glyphs; `empty.bin`
  (0 bytes)→HEX no crash; `code.txt` forced HEX via Open-As then back to Auto
  returns to Source with no Hex leak.
- **PV-08 open-or-reveal**: re-opening an already-open image switches to its
  existing tab (tabCount stays 3, no duplicate); per-tab modes preserved.

## FINDINGS (bugs / discrepancies surfaced beyond the assertions)

### F-PV-01 (S2, bug) — large image opens at 100% (overflowing), NOT fit-to-window

*Catalog (PV-01 step 1):* "Image is **fit-to-window** on first paint (didFit
guard), centered on both axes." *Actual:* an 800×600 `a.png` in a ~290–536 px
viewport opens at **100%** — the percent HUD reads `100%`, `documentView` stays
`800×600`, and the image visibly overflows (only the top-left quadrant in
frame, clipped right + bottom). **Reproduces in BOTH background AND foreground
launches** — not a capture/occlusion artifact.

*Evidence:* `/tmp/pv-uat/art/mdv-step-03.png` (background) and
`/tmp/pv-uat/art3/mdv-step-05.png` (foreground) both show HUD `100%` + a clipped
image; `nsScrollView.contentSize = 536.5x601.0` with `documentView_frame =
800x600` and HUD 100% even after a `resize` step
(`/tmp/pv-uat/art2/mdv-step-09.json`).

*Root cause (read of `MediaPreviewView.swift`):* `onLoad` DOES fire (the
`800 × 600` dimension readout is present, which only shows when `pixelSize > 0`
— so `didFit=true; fitToWindow()` ran). `fitToWindow()` sets the SwiftUI
`@State magnification = 0`; `ImageScrollHost.updateNSView` interprets `0` as
"fit" and calls `applyFit`, which sets `scroll.magnification = fitScale(...)`
(≈0.36 here — the `fitScale` math itself is correct) **but never writes the fit
value back into the `magnification` binding**. The HUD binds to `magnification`
(`ImagePreview.swift:159`), so it can't reflect the fit, and the next
`updateNSView` pass — seeing `magnification` back at its `1.0` default — takes
the `else if abs(scroll.magnification - magnification) > 0.001` branch
(`MediaPreviewView.swift:369`) and **snaps the scroll back to 1.0** (100%). Net:
the fit is computed and momentarily applied, then immediately reverted by the
state-desync. *Fix sketch:* have `applyFit` push the computed `fit` back into the
`magnification` binding (e.g. via the `onUserZoom`/a dedicated `onFit` callback)
so the SwiftUI state and the scroll's magnification agree, instead of leaving
`magnification` at `0`/`1.0` while the NSScrollView holds the real fit value.

*Scope note:* the in-preview zoom/pan/`Fit`/`1:1` controls themselves are not
script-reachable (SwiftUI buttons, no verb), so the durable suite asserts the
preview SUBTREE mounts; this fit defect was caught by direct screenshot/dump
inspection. A foreground VM pixel test should pin the fit-scale on first paint.

### F-PV-02 (S4, ux-oddity) — media/binary tabs show `Lines 0  Chars 0` in the status bar

*Catalog (PV-08 step 1):* "Ln/Col is hidden for a media tab (line == 0
sentinel)." *Actual:* Ln/Col IS hidden, but the status bar still renders
`Lines 0` and `Chars 0` for image / audio / pdf / sqlite tabs (see
`/tmp/pv-uat/art/mdv-step-03.png` image, `…-07.png` audio, `…-15.png` pdf,
`…-19.png` sqlite). Showing `Lines 0 / Chars 0` for a binary/media file is
mildly misleading — a user could read it as "an empty 0-line document" rather
than "line metrics don't apply." Low severity / cosmetic; the literal "Ln/Col
hidden" claim is honored. Consider hiding the `Lines`/`Chars` chips too (not
just Ln/Col) for non-text categories, matching how the CSV (text) tab correctly
shows `Ln 1, Col 1 | Lines 353 | Chars 353`.

### F-PV-03 (informational, not a bug) — PDFView content blank in same-process `cacheDisplay` capture

*Observation:* in the screenshot, the PDF tab's center pane is blank/white even
though `PDFView` is mounted non-zero-sized and the MetadataPanel shows the
correct Pages/Title/Author (`/tmp/pv-uat/art/mdv-step-15.png`). This is almost
certainly a **capture-fidelity limit**: `DiagnosticDump.captureWindowToPNG`
uses `NSView.cacheDisplay`, which does not reliably capture PDFKit's
layer-hosted/Metal-backed page content. The dump confirms the view is present
and laid out, so this is NOT evidence of a real blank pane — flagged so a
reviewer doesn't mistake the screenshot for a render bug. A foreground VM pixel
test (real WindowServer composite) is needed to confirm the PDF page actually
paints. *(Side note: opening the PDF emitted a macOS Vision OCR log line
`addTextFromVisionDocument: numWordQuads = 5` — PDFKit runs on-device OCR over
the document; benign but worth knowing for perf on large PDFs.)*

## Not script-reachable (logged for the MANUAL / VM lane)

The verb vocabulary cannot drive the in-preview interactive controls, so these
catalog steps are NOT covered by the durable suite and need the foreground VM /
manual lane:

- **Image** (PV-01): fit/zoom/pan gestures, the `+`/`-`/`Fit`/`1:1` buttons,
  Cmd-scroll cursor-anchored zoom, 10× zoom clamp, prev/next sibling chevrons +
  `n / count` position, single-image-hides-chevrons.
- **Audio/Video** (PV-02): AVPlayerView transport (Space-to-play, scrubber,
  volume), the video-only full-screen toggle vs audio's absence of it.
- **PDF** (PV-03): arrow/scroll page nav, Cmd-+/- zoom, Cmd-0 re-fit.
- **SQLite** (PV-04): clicking a table to auto-seed+run `SELECT … LIMIT 100`,
  Cmd+Return Run, Cmd+. Cancel of a slow query, read-only authorizer rejecting
  DELETE/DDL/ATTACH, `ResultTableView` pinned header / NULL cells / 1000-row
  cap, `locked.db` busy-timeout.
- **CSV** (PV-05): the filter fields (`mdv.csvFilter.*`), scope menu,
  per-column comparison filters, Clear All, column-resize 40 pt clamp, Copy
  Cell, per-tab filter/width persistence, large-file memory bound.
- **HEX** (PV-07): the search field (hex + ASCII modes), match count /
  prev/next, bytes-per-row width picker, click-to-highlight same-value bytes,
  50k match cap, the #219 Editor→HEX flash + #218 entry-latency observations.
- **MetadataPanel**: verified present + populated for File/Image/Audio/Video/
  PDF/Database sections via screenshots, but its live updates on
  sibling-nav / tab-switch are gesture-driven.

# Group 11/12 — settings-and-menus-and-shortcuts

**Catalog:** `docs/uat/smokes/settings-and-menus-and-shortcuts.md`
(SC-MENU-01..04, SC-SET-01..03).
**Durable suite:** `Tests/ViewerUITests/uat/SettingsMenusAndShortcutsUATTests.swift`
(T4 `MultiScenarioTestCase`, 9 scenarios). Run:
`env -u MDV_HEADLESS_GATE swift test --filter 'ViewerUITests.SettingsMenusAndShortcutsUATTests'`.
**Result:** 9/9 green (1 documented bug captured as `XCTExpectFailure`).
App under test: `dist/TextView.app` (debug runner, occluded via `MDV_BACKGROUND`).

## Reachability constraint (the dominant fact for this group)

This catalog is, by its own "Live-menu only" run note, mostly **not
script-reachable**. The `--script` verb vocabulary cannot open the Settings
`NSWindow` (⌘, has no verb), cannot read a menu item's enabled/grey state,
title relabel, or `.on`/`.off` checkmark (none reach the `DiagnosticDump`),
cannot drive any NSAlert (Go-to-Line ⌘L, Clear Recents, the dirty-close
Save/Don't-Save/Cancel prompt, Clear-All-bookmarks confirm, the FDA deep-link)
— a modal `runModal()` would block the spawned app's main thread forever — and
cannot launch the Plugins / LSP-Diagnostics tool windows or exercise the ⌘Q
app-quit guard. So, exactly as the catalog prescribes, the durable suite
asserts the **model flags `validateMenuItem` reads** plus realized-tree CLASS
detection. The genuinely menu/NSWindow/NSAlert-coupled steps are logged for the
manual / VM lane at the bottom of this section.

## Per-smoke results

### SC-MENU-01 — Dynamic menu validation (model-flag proxy) — PASS

`test_SC_MENU_01_dynamicValidationModelFlags` (11-verb flow) + the bug-guard
variation below. Asserted the validator's *input* signals, which all behaved:
- markdown opens **Rendered** and is the only `supportsViewModeToggle` type;
  `toggle-view` (⇧⌘R) flips it Rendered→Source.
- JSON opens **Source**, `isCurrentTabFormatted` starts false; `toggle-format`
  (⌥⌘F) flips it true (Pretty-Print checkmark), and a second toggle clears it.
  (Format is a per-tab flag layered on Source — `currentViewMode` stays
  `source`, matching `TabsChromeUAT`'s finding; it is NOT a `.formatted` mode.)
- `editor-set-mode editor` mounts a non-zero WKWebView (the gate that enables
  Save / Fold / Unfold / Go-to-Line) and survives `editor-set-text`.
- ⌘D (`toggle-bookmark`) sets `isCurrentTabBookmarked` (Bookmark→"Remove
  Bookmark" relabel signal); a second ⌘D clears it.
- image opens `.preview` (no editor / format / view-toggle); a blank `new-tab`
  clears `currentURL` (the hasFile guard that greys most View/Edit items) and
  cannot be bookmarked.

**Observation (not a bug):** opening `note.txt` while the prior tab was an
**editor** carried `.editor` onto note.txt rather than its `.source` default.
This is the documented carry-mode behavior and is *correct* here — `.editor` is
in plainText's `availableModes` `[.source, .editor, .hex]`, so picker and pane
agree. (My first draft wrongly expected `source`; corrected to assert "a valid
plainText mode, never `.rendered`".)

### SC-MENU-01 (bug guard) — toggle-view / ⇧⌘R desync on a non-toggleable type — DOCUMENTED BUG (suite green via XCTExpectFailure)

`test_SC_MENU_01var_viewModeToggleScopeDESYNC`. **See F-MENU-01 below.**

### SC-MENU-02 — Tab number-jump + next/prev dispatch — PASS

`test_SC_MENU_02_tabNavigationDispatch`. Opened 5 tabs; `select-tab 3` (⌘3)
jumps to index 2 and the window title tracks; `next-tab`/`prev-tab` (⌥⌘→/⌥⌘←)
advance/retreat by one; `select-tab 1` (⌘1) returns to index 0. No errors.
(Open Recent submenu, the ⌥⌘[/⌥⌘] Move-Tab-vs-Fold-All collision, the ⌥⌘G
Find-Previous relocation, and the per-tab checkmark are live-menu-only — logged
for manual.)

### SC-MENU-03 — Find / Go-to-Path / cross-search accelerator routing — PASS

`test_SC_MENU_03_findGotoCrossRouting` + `…var_overlayFlagsAreIndependent`.
- ⌘F in Rendered raises `isRenderedFindBarPresented`; dismiss clears it.
- ⇧⌘G raises `isGoToPathPresented` and does **NOT** co-raise a find bar —
  confirming ⇧⌘G is **Go-to-Path, not Find-Previous** (the deliberate
  muscle-memory break holds at the model layer).
- ⇧⌘F raises `isCrossSearchPresented` (cross-file modal); dismiss clears it.
- editor mode mounts a WKWebView; the command palette raises/dismisses.
- the independence guard confirms palette / goto / cross flags never co-fire
  when raised in isolation (no stuck double-scrim).

### SC-MENU-04 — Session menu dispatch — PASS

`test_SC_MENU_04_sessionMenuDispatch`. `session-open-folder projX` (⇧⌘N New),
`session-open-new projY` (forced-new) grow the session list and each appear in
the snapshot; `session-prev`/`session-next` (⌃⇧⇥/⌃⇥) keep a non-empty
`activeSessionID`; `session-activate 1` (⌃1) makes the FIRST session's id
active. The Session-menu items dispatch the matching `SessionsAppCoordinator`
calls. (Debug-menu DiagnosticGate, `--mcp-stdio` menu-absent mode, and HIG menu
order are pure menu-bar concerns — logged for manual.)

### SC-SET-01 — Zoom accelerator parity + sidebar/wrap toggles — PASS

`test_SC_SET_01_zoomParityAndSidebarToggle` + `…var_zoomClamps`. The unified
zoom scalar (the same `model.zoom` the Settings slider AND View-menu ⌘=/⌘-/⌘0
drive): `zoom-reset`→1.0, `zoom-in` monotone, `zoom-out` below 1.0; 40
`zoom-in`s clamp at exactly **3.0** (300% cap), 40 `zoom-out`s floor at exactly
**0.5** (50% floor). `toggle-sidebar` (⌃⌘S) flips `sidebarVisible` and a second
toggle restores it (the checkmark signal). (The Settings window itself, the
Theme picker, and the Wrap/Invisibles/Indentation pickers are not
script-reachable — logged for manual.)

### SC-SET-02 — Bookmark store (the surface Clear-All acts on) — PASS

`test_SC_SET_02_bookmarkStoreToggleAcrossTabs`. Bookmarked three tabs of
different types via ⌘D; re-selecting the first tab shows the bookmark **survived
the tab switch** — confirming the store persists per-file (so Settings ▸
Advanced ▸ Clear All would have something to clear). The destructive
`confirmationDialog`, the gutter line-bookmark (⌥⌘D), "Reset window state", and
the relaunch re-center are NSAlert/NSWindow-coupled — logged for manual.

## Findings

### F-MENU-01 (S3, bug) — `toggle-view` / ⇧⌘R sets an invalid `.rendered` mode on non-toggleable file types, desyncing the ModeBar picker from the drawn pane

*Catalog (SC-MENU-01 "Variations / edge-states", + the smoke's "Show
Rendered/Source toggle is disabled for non-markdown/non-mermaid types").*

*Repro:* open any plain-text / source / JSON file (e.g. `note.txt`), then invoke
`toggle-view` (the ⇧⌘R "Show Rendered/Source" action) — via `--script`, MCP
`set_view_mode`, or any programmatic caller.

*Expected:* a no-op — ⇧⌘R is scoped to markdown/mermaid (`supportsViewModeToggle`
false for everything else), so the view mode should stay `source`.

*Actual:* `model.currentViewMode` flips to **`rendered`**, but plainText's
`availableModes` is `[.source, .editor, .hex]` — there is **no Rendered view**
for the file. The content pane (correctly) keeps drawing the source
`NSTextView` (verified via direct dump probe: `currentStateKind == loaded`, 1
`NSTextView`, 0 `WKWebView`), so the **ModeBar picker LIES**: it shows
"Rendered" while a Source pane is on screen — a picker↔pane desync. Toggling
again returns to `source` (the `currentViewMode == .rendered ? .source :
.rendered` swap is symmetric), so it self-heals on a second invoke, but a single
invoke leaves the picker mislabeled.

*Root cause:* `DocumentModel.toggleViewMode()` is unconditional —
```swift
let new: ViewMode = currentViewMode == .rendered ? .source : .rendered
setCurrentViewMode(new)
```
no `supportsViewModeToggle` guard; and `setCurrentViewMode(_:)` does not reject
a mode absent from `ViewModeOptions.availableModes(for:)`. Same defect family as
the documented carry-mode HEX-onto-preview desync
(`TabsChromeUAT.test_SC_CHROME_02_carryModeHexOntoPreview_DESYNC`).

*Severity rationale (S3):* In the **live menu bar** the ⇧⌘R item is greyed for
non-markdown types (`validateMenuItem` reads `supportsViewModeToggle`), so a
keyboard user can't usually trip it — which caps the blast radius. But the
underlying model action is unguarded, so MCP `set_view_mode`, `--script
toggle-view`, and any future programmatic toggle WILL desync the picker. No
crash, no data loss, content stays readable; it's a state-consistency / UX
correctness defect.

*Fix:* guard `toggleViewMode()` on `supportsViewModeToggle` (early-return when
false), and/or have `setCurrentViewMode(_:)` reject a mode not in the current
tab's `availableModes`. Either makes the picker the single source of truth and
heals the desync at the model layer (defending all callers, not just the menu).

*Evidence:* `test_SC_MENU_01var_viewModeToggleScopeDESYNC` captures it as a
green `XCTExpectFailure(strict: false)` (suite log: `XCTExpectFailure: matcher
accepted … toggle-view put plainText into 'rendered'`). Remove the wrapper when
a guard lands — it will then fire "unexpectedly passed".

## Not script-reachable (logged for the MANUAL / VM lane)

The `--script` verb vocabulary cannot reach the Settings `NSWindow`, the live
menu-bar enable/grey/relabel/checkmark state, the modal NSAlerts, or the tool
windows, so these catalog steps are NOT covered by the durable suite and need
the foreground VM / manual lane:

- **Settings window (SC-SET-01/02/03):** ⌘, open + the **dedup** (re-focus, no
  second window); the **Theme** picker live-applying Xcode Dark/Light/Follow
  System; **Wrap / Show Invisibles / Indentation** pickers live-applying to the
  document + mirroring the ModeBar/View-menu checkmarks; **Sidebar** width
  slider (160–480 clamp) + show-by-default toggle (next-launch semantics);
  **Advanced** Clear-All-bookmarks `confirmationDialog` (Cancel vs Confirm) +
  Reset-window-state (now real — drops `NSWindow Frame MainWindow`) +
  relaunch **re-center**; **Privacy** FDA deep-link; **Plugins** Manage… /
  Open-Log enable-gating; **Language servers** Open-Diagnostics… window; the
  high-zoom (~300%) chrome non-overflow; theme-override-not-persisted gap.
- **Live menu-bar (SC-MENU-01..04):** every `validateMenuItem` enable/grey +
  title relabel (Show Rendered⇄Source, Bookmark This⇄Remove Bookmark) + ON/OFF
  checkmark (Pretty-Print, Wrap, Invisibles, Sidebar, per-tab Window/Session
  active marks); the HIG menu order; **no native Show-Tab-Bar / Merge-All-
  Windows**; the **Debug-menu DiagnosticGate** (DEBUG / `MDV_ENABLE_DIAGNOSTICS=1`
  only) and its absence in a stock release; `--mcp-stdio` menu-bar-absent mode.
- **NSAlerts / modal prompts:** ⌘L Go-to-Line prompt; Open Recent ▸ Clear
  confirm; the dirty-tab close ⌘W Save/Don't-Save/Cancel; the **⌘Q app-quit
  unsaved guard GAP** (documented: `hasAnyUnsavedEdits` has no caller — ⌘Q can
  silently drop buffers). These need a real responder chain — a script-spawned
  occluded app would deadlock on `runModal()`.
- **Documented known issues (surface, don't gate):** ⌥⌘[/⌥⌘] Move-Tab vs
  Fold-All collision; ⌥⌘G Find-Previous relocation off ⇧⌘G; the ⌘Q unsaved
  guard gap; theme-override-not-persisted; the stale "Settings is a disabled
  stub" `main.swift` comment.

---

# Group 12/12 — Walkthrough player + Code Review (`docs/uat/smokes/walkthrough-and-code-review.md`)

**Executor:** UAT live-app driver, group 12/12. **App under test:** assembled
`dist/TextView.app` (built Jun 3 02:57), bundle id
`com.markdownviewer.MarkdownViewer`, run OCCLUDED via `MDV_BACKGROUND=1`.
**Durable companion:**
`Tests/ViewerUITests/uat/WalkthroughAndCodeReviewUATTests.swift` (T4,
`LiveAppTestCase`). Run with
`env -u MDV_HEADLESS_GATE swift test --filter 'ViewerUITests.WalkthroughAndCodeReviewUATTests'`.

## Harness reality — why this group is structurally different

This is the ONLY UAT group whose surfaces are **not reachable through the
`--script` verb dispatcher**. Per the smoke catalog §38 and re-confirmed by
reading `Sources/ViewerUI/Automation/ScriptVerbDispatch.swift`:
`ScriptVerbDispatch` has **no walkthrough-playback and no review-authoring
verb**. The shared `AppLauncher.runScript` additionally hardcodes
`argv = ["--script", scriptPath, fileArg]` — it cannot inject `--walkthrough
PATH` or `TV_WALKTHROUGH_DROP=1`. So the authored suite owns a **private
launcher** (`runWalkthrough`) that spawns the bundle with BOTH
`--walkthrough <tour.json> --script <delay-steps>`: the tour auto-plays while
the script's `delay` steps keep the process alive and emit a `DiagnosticDump`
JSON per step. Engine/loader/bridge/store contracts are covered by the existing
HEADLESS suites (re-run below); the T4 suite adds the live CLI→controller→model
integration that those cannot reach.

## Suite result

```
WalkthroughAndCodeReviewUATTests — 6 tests, 0 failures (15.1s)
  test_WCR_01_cliWalkthroughDrivesModel ............ PASS
  test_WCR_01_highlightStepDoesNotDerailTour ....... PASS
  test_WCR_02_multiTargetVerbsDoNotDerail .......... PASS
  test_WCR_03_nonexistentScriptPath_appSurvives .... PASS
  test_WCR_03_unknownVerbScriptDoesNotPlayAndAppSurvives  PASS
  test_WCR_06_tourDoesNotMutateProjectLocalReview .. PASS
```

Supporting HEADLESS evidence (re-run fresh this session, all green):
- Walkthrough layer: `WalkthroughEngineTests` (17), `WalkthroughAutoAdvanceTests`
  (10), `WalkthroughLoaderTests` (16), `WalkthroughScriptTests` (24),
  `WalkthroughSchemaErrorTests` (13), `WalkthroughDropTransportTests` (3),
  `WalkthroughBridgeTests` (7), `WalkthroughAnchorKeyTests` (12),
  `WalkthroughSampleScriptTests` (4), `WalkthroughFixtureFileTests` — **94/94 PASS**.
- Review layer: `ReviewSessionTests` (14), `ReviewStoreTests` (12),
  `ReviewStoreProjectLocalTests` (9), `ReviewModelTests` (17),
  `ReviewExporterTests` (13), `ReviewExporterPolishTests` (2),
  `ReviewExportTests` (4), `DiffViewReviewTests` (4) — **75/75 PASS**.

## Per-smoke pass/fail + observations

### WCR-01 — CLI-launched v1 walkthrough auto-advance — PARTIAL PASS (live), engine PASS (headless)

- **PASS (proven live):** `--walkthrough tour.json` + `--script` coexist and the
  CLI flag genuinely arms + runs the engine against the real process. Step 1's
  `openFile main.swift` + `setView source` land on the live `DocumentModel`
  (`currentURL` = main.swift, mode = source, a tour tab opened alongside the
  argv file). The persistent `highlightRange` overlay stripe **renders correctly**
  over the target line (visually confirmed in a captured PNG: line 4 carries the
  focus stripe, `Ln 4` cursor). So engine + delegate + overlay all work live.
- **F-WCR-AUTOADV (S3, occlusion limitation):** in the occluded
  (`MDV_BACKGROUND`) CLI launch, auto-advance progresses by **exactly ONE step**
  from the initial `WalkthroughPlayerController.start()`, regardless of
  `dwellSec`. `start()` lands step 1 and fires one `scheduleAdvanceIfNeeded()`;
  the auto-advance `Task` calls `engine.next()` DIRECTLY (the engine's `next()`
  does not re-schedule — only the *controller's* `next()` does), and the
  SwiftUI-strip lifecycle callbacks that would re-arm the scheduler don't fire
  while the window is occluded/non-foreground. A `dwellSec:1.0` tour therefore
  stalls; a `dwellSec:0` step advances synchronously but still only ONCE. Probed
  deterministically: a 3-step zero-dwell chain (main→helper→README) reaches
  helper (step 2), not README (step 3). Whether the re-arm fires in a *foreground*
  VM session is the open question (likely yes — the strip's `onChange`/`onAppear`
  drives it). Transport/dwell timing is the headless `WalkthroughAutoAdvanceTests`
  lane + the VM lane, not the occluded host. The suite encodes the one-advance
  contract (step1 = open+setView, step2 = openFile helper → helper focused).
- **F-WCR-STRIP (S2, see WCR-shared below):** the player transport STRIP itself
  never mounts in the realized tree in this launch — only the overlay does.

### WCR-01 highlight-does-not-derail — PASS

- A tour with an `openFile` + `setView` + `highlightRange` chain keeps the file
  open and out of `.error`/`.loading`. The persistent stripe renders in the
  overlay (visually confirmed). Stripe COLOR-per-`kind`, live re-position on
  scroll, and off-screen hide/show are overlay observables not in the dump →
  VM-lane gaps (logged, not failed).

### WCR-02 — Multi-target verbs (showPopover / splitFile / revealInSidebar / openGitPanel / addBookmark) — PASS (no-derail), several VM-lane gaps

- **PASS:** against a real git repo, the full verb chain (openFile → showPopover
  line-anchor → splitFile → revealInSidebar → openGitPanel status → addBookmark)
  runs without putting the document into `.error`/`.loading`; the focused source
  file survives the chain. NB: only the first auto-advance fires (F-WCR-AUTOADV),
  so the later verbs are exercised here primarily via the engine-layer headless
  suites; the live assertion is the no-derail + survival contract.
- **VM-lane gaps (logged, EXPECTED per catalog):** popover card render + Dismiss
  + overlay hit-testing toggle; split second-pane realization + primary-pane
  selection; the GIT accordion mount (same scripted/occluded non-mount as
  group-6 `GitPanelUATTests` F-GIT-1); the `[tour]`-namespaced bookmark + its
  removal-on-Exit. None are in `DiagnosticDump`/`modelStateDump`.

### WCR-03 — Schema rejection + load-failure survival — PASS

- **PASS (unknown-verb reject):** a `/v1` script whose step 2 carries an UNKNOWN
  verb kind (`teleport`) is rejected wholesale by `WalkthroughLoader`
  (`Action.init(from:)` → `dataCorrupted`). The live app **does not crash, does
  not partially play**: the argv `README.md` stays the focused tab and tabCount
  stays 1 (step 1's `openFile helper.swift` never ran). `startWalkthrough`'s
  stderr-only failure + no in-app error UI is the documented contract.
- **PASS (nonexistent path):** `--walkthrough /…/does-not-exist.json` →
  `ioFailed`, app alive, normal argv open undisturbed, no spurious tab.
- **CATALOG-NUANCE (logged, not a failure):** the catalog frames WCR-03's reject
  as "v1-reader rejects a v2-only `flash` verb." Re-checking the code, `flash`
  decodes fine under BOTH `/v1` and `/v2` today — the decoder is schema-agnostic
  for *known* kinds (pinned by
  `WalkthroughSchemaErrorTests.test_flashVerb_underV1Schema_decodesSuccessfully`).
  The genuine strict-reject the catalog wants is the **unknown schema string**
  (`UnsupportedSchemaError`, tested headless) or an **unknown verb kind** (driven
  live here). The "flash is v2-only at the wire level" claim in the catalog is
  inaccurate vs the shipped decoder — surfaced as a doc/spec drift (D-WCR-FLASH).
- **VM-lane gaps:** `awaitUser` silent-halt (no prompt/pills UI), the Note-button
  visual-only crumb, and `runDiff` surfacing git-log-only (sha discarded) are all
  engine/UI observables with no scriptable hook from the occluded run — covered
  by the catalog's EXPECTED-behavior list + engine headless tests.

### WCR-04 — Code review end-to-end — PASS at store/session layer (no live UI surface)

- The Git-panel `.review` tab, the `ReviewTabView` toolbar, the review-aware
  `DiffView` with inlined threads, and the create/resolve/delete/export controls
  are **unreachable from a `--script`/occluded run** (no review verb; no review
  keys in `modelStateDump`; the `.review` Git-panel tab shares group-6's
  scripted non-mount). Every WCR-04 behavior is asserted at the store/session
  layer instead, ALL GREEN this session:
  - state machine draft→inReview→complete→sent + illegal-transition no-op
    (`ReviewSessionTests`).
  - 6-severity model, resolved flag, staleness (`current`/`stale`/`unknown`)
    (`ReviewModelTests`, `ReviewSessionTests`).
  - resolve/reopen + delete-thread-as-unit (`ReviewSessionTests`).
  - export → JSON + `recordExport` → `.sent` transition (`ReviewExporterTests`,
    `ReviewExportTests`).
  - diff-with-threads rendering inputs (`DiffViewReviewTests`).
- **VM-lane gaps (logged, EXPECTED per catalog):** no create-comment affordance;
  Reply/Edit/scroll-to-anchor inert stubs; `exportToFile` NSSavePanel
  unreachable (clipboard-only); `draftInstructions` no editor UI; `ReviewTabView`
  not a first-class tab. All confirmed against source; none failed.

### WCR-05 — Empty/zero-review states + project-local store + flush durability + drop-transport gating — PASS at store/transport layer

- **PASS (store/transport layer):** project-local `.textview/reviews/` store,
  empty `_index.json`, empty→populated-after-flush, and **newest-wins flush
  durability under a 50-edit burst** are pinned by `ReviewStoreProjectLocalTests`
  + `ReviewSessionTests.test_burstOfEdits_coalesces_butLandsTheFinalValueOnDisk`
  (all green). Drop-transport **env-gate + `rootHint` path-escape rejection +
  FIFO/dedup** are pinned by `WalkthroughDropTransportTests` + the loader's
  path-escape pass (`WalkthroughLoaderTests`).
- **VM-lane gaps:** the two distinct empty-state placeholder STRINGS render in
  the Git-panel `.review` tab (no scripted access); the live drop-inbox
  end-to-end (`TV_WALKTHROUGH_DROP=1` + atomic-rename consumption) needs a
  foreground session. Logged.

### WCR-06 — Walkthrough + Code Review coexistence boundary — PASS

- **PASS (proven live):** a tour (openFile → setView → openGitPanel →
  highlightRange) plays against a repo that ALSO holds a hand-seeded
  project-local review JSON under `.textview/reviews/`. After the live run the
  tour's verbs landed on the model (a.swift focused, source, no error) AND the
  seeded review file on disk is **byte-identical** (checksummed before/after) —
  the active walkthrough does not touch the review. This is the durable
  regression anchor for the documented **Note→Code-Review decoupling**: the Note
  button is visual-only, so a tour cannot mutate a review. When the hookup lands,
  this smoke flips to assert "Note creates an anchored comment."

## Headline cross-cutting finding (shared by WCR-01/02/06)

**F-WCR-STRIP — the walkthrough player STRIP does not mount in the realized
tree (occluded T4), while the OVERLAY does.** Probed by diffing the full
`DiagnosticDump` `contentView` tree of a walkthrough-active run vs a no-walkthrough
run with identical argv: the trees are **byte-identical — 151 nodes, ZERO
class-count differences**. So `if walkthrough.isActive { WalkthroughPlayerView }`
(ContentView VStack, docked bottom-of-content) never inserts the transport strip
into the realized tree, even though the engine is demonstrably active (verbs
land; the `highlightRange` overlay stripe renders in the captured PNG). The
overlay updates because it's an always-present `.overlay(WalkthroughOverlay)`
reading `model.walkthroughBridge` (`@ObservedObject` on `DocumentModel`); the
strip's structural insertion is gated on `walkthrough.isActive`, a `@Published`
on the `@StateObject WalkthroughPlayerController`, whose change apparently isn't
re-bodying/committing ContentView in this path. This smells like the same
republish/forwarding class the matrix smoke documented (PERF #1 severed
`objectWillChange` forwarding). UNRESOLVED whether the strip mounts in a
foreground VM session — needs VM confirmation. If it doesn't mount foreground,
this is an S2 (the entire transport UI — prev/play-pause/next/speed/steps/note/
exit — is invisible, the user can't control or exit a running tour except via
the engine's own auto-advance). Logged for the VM lane.

## Manual / VM-lane checklist (cannot drive from the occluded host)

- Player strip render + a11y ids (`mdv.walkthrough.player/.speaker/.narration/
  .scrub/.prev/.playpause/.next/.speed/.steps/.note/.exit`) and ALL transport
  interactions (the SwiftUI a11y ids do NOT propagate onto NSView; the strip
  isn't even in the occluded tree per F-WCR-STRIP).
- Multi-step auto-advance dwell timing + speed-menu reschedule (F-WCR-AUTOADV).
- showPopover card + Dismiss + overlay hit-testing; splitFile second pane;
  GIT-section mount; `[tour]` bookmark add + Exit-cleanup.
- awaitUser silent-halt UI absence; Note crumb; runDiff git-log-only.
- The Git-panel `.review` tab, `ReviewTabView`, review-aware DiffView threads,
  per-severity colors, resolved strikethrough, staleness badges, resolve/delete
  count updates, Mark-Complete gating, Export…→clipboard + `.sent`.
- Two empty-state placeholder strings; live drop-inbox (`TV_WALKTHROUGH_DROP=1`).
